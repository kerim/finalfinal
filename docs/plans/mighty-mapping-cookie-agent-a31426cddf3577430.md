# Code Review: Fix Citation Formatting in PDF Export

**Plan file:** `/Users/niyaro/Documents/Code/ff-dev/pandoc-pdf/docs/plans/mighty-mapping-cookie.md`
**Reviewer:** Code Review Agent
**Status:** Review complete -- issues found (1 critical, 2 important, 3 suggestions)

---

## Overall Assessment

The plan is well-structured and addresses a real gap: `zotero.lua` only supports DOCX and ODT, leaving PDF citations unprocessed. The approach of using pandoc's native `--citeproc` for PDF while keeping `zotero.lua` for DOCX/ODT is sound. The plan correctly identifies the `@MainActor` isolation issue and works around it. The bibliography stripping strategy aligns with the precedent in `QuickLook Extension/SQLiteReader.swift`.

The plan has been improved from the previous version in several ways: keeping notes blocks for footnote support, making Lua filter validation conditional, and scoping bibliography stripping to all formats. These are all good decisions.

However, there are several issues to address before implementation.

---

## 1. Completeness: Edge Cases

### 1a. No citations but Zotero is running

**Verdict: Handled correctly.** The existing code at `ExportService.swift` line 118-123 already handles this -- `hasCitations` is checked first, and if false, Zotero status is set to `.running` (meaning "no issue"). The plan does not change this logic, so no-citation exports continue to work regardless of Zotero state.

### 1b. Citations exist but no citekeys are extractable

The plan's `extractCitekeys(from:)` could return an empty array if the regex doesn't match the citation format (e.g., non-standard citation syntax). Meanwhile, `hasPandocCitations(in:)` uses a different, broader regex and could still return `true`. This would mean the code enters the "has citations" branch but finds no citekeys to fetch. This is actually fine -- the `fetchBibliographyJSON` would receive an empty array and return nil, leading to graceful degradation. No issue here.

### 1c. Zotero running but BBT returns an error for specific citekeys

The plan says `fetchBibliographyJSON` returns `nil` on failure and we skip `--citeproc`. This is handled. However, the warning message should distinguish between "Zotero not running" and "Zotero running but BBT returned an error for these specific citekeys" -- see Issue 2 below.

---

## 2. Content Assembly: `loadContentForExport()`

### 2a. Is `ExportOperations.handleExport()` the only caller?

**Yes.** A grep for `loadContent()` across the codebase shows only three call sites:
- `DocumentManager.swift:287` -- the method definition itself
- `ContentView+ProjectLifecycle.swift:118` -- loading content into the editor on project open
- `ExportCommands.swift:32` -- the export entry point

The `ContentView+ProjectLifecycle` usage loads content into the editor and needs the full content (including bibliography and notes), so it correctly continues to use `loadContent()`. Only `ExportCommands.swift` needs the new `loadContentForExport()`. No other code paths are affected.

### 2b. `@MainActor` isolation of `DocumentManager`

**[CRITICAL]** `DocumentManager` is annotated `@MainActor` (line 15 of `DocumentManager.swift`). The new `loadContentForExport()` method will also be `@MainActor`. This is fine for `ExportCommands.handleExport()` which is already `@MainActor` (line 24 of `ExportCommands.swift`). However, `ExportService` is an `actor` (not `@MainActor`). If any future code tries to call `loadContentForExport()` from the `ExportService` actor, it would need to cross actor boundaries. The current plan calls it from `ExportCommands` before passing content to the service, which is the correct pattern.

However, there is a subtlety: the plan proposes `loadContentForExport()` that calls `db.fetchBlocks(projectId:)`. Looking at `Database+Blocks.swift:80-87`, `fetchBlocks` uses `read { }` which is a synchronous GRDB call. Since `DocumentManager` is `@MainActor`, this synchronous database read will block the main thread. The existing `loadContent()` has the same issue (it calls `db.fetchContent(for:)` which also does a synchronous read), so this is a pre-existing pattern, not a regression. But it is worth noting.

**Action needed: None for this plan, but worth flagging as technical debt.**

### 2c. `BlockParser.assembleMarkdown(from:)` output format

Looking at `BlockParser.swift:340-351`, `assembleMarkdown` joins block `markdownFragment` values with `\n\n`. This means footnote definition blocks (which have fragments like `[^1]: Some text`) will appear separated by double newlines. For pandoc to process multi-paragraph footnotes, continuation lines must be indented with 4 spaces. Since each footnote definition is a separate block with a single `markdownFragment`, multi-paragraph footnotes that are stored across continuation lines within a single block should be fine. But if a multi-paragraph footnote somehow spans multiple blocks, the double-newline separator could break the association. Looking at `FootnoteSyncService.swift:506-518`, each definition is stored as a single block, so this should not be an issue.

---

## 3. Footnotes in Export

### 3a. Does the block-based assembly preserve footnote definitions?

**Yes.** The plan filters `blocks.filter { !$0.isBibliography }`, which keeps all notes blocks (`isNotes == true`). These notes blocks contain the `# Notes` heading and individual `[^N]: text` definition blocks. After `assembleMarkdown`, the output will contain:

```markdown
... document content ...

# Notes

[^1]: First footnote text

[^2]: Second footnote text
```

Pandoc requires footnote definitions (like `[^1]: text`) to be present somewhere in the document for `[^1]` references to render. The notes blocks provide exactly this. This approach is correct.

### 3b. Footnote heading in exported PDF

**[SUGGESTION]** The exported document will contain a literal `# Notes` heading followed by `[^N]:` definition lines. Pandoc processes footnote definitions and removes them from the output body (placing them as footnotes at the bottom of pages or end of document). However, the `# Notes` heading itself is not a pandoc-recognized construct -- it will appear as a top-level section heading in the exported PDF. This may or may not be desirable. If the user expects footnotes to appear as standard PDF footnotes (at page bottom) without a visible "Notes" section heading, the heading block should also be stripped from export content.

**Recommendation:** Consider stripping the `# Notes` heading block from export output, since pandoc will render the footnote definitions as proper footnotes without needing a section heading. This could be done by extending the filter:
```swift
let exportBlocks = blocks.filter { !$0.isBibliography && !(block.isNotes && block.blockType == .heading) }
```
Or more simply, strip all notes blocks and only keep the footnote definitions inline. But this requires further thought about what the user expects to see. Worth discussing with the user.

---

## 4. Error Paths: `fetchBibliographyJSON` Failure

### 4a. Raw `[@key]` in LaTeX output

**[IMPORTANT]** The plan says: if `fetchBibliographyJSON` fails, skip `--citeproc` entirely and add a warning. Without `--citeproc`, pandoc processes `[@Smith2020]` as literal text. In LaTeX output, the `@` character is a special character in certain contexts but within square brackets in markdown-to-LaTeX conversion, pandoc treats it as regular text. The output will be something like `{[}@Smith2020{]}` in LaTeX, which renders as `[@Smith2020]` in the PDF. This is ugly but will not cause a LaTeX compilation error.

However, there is a more subtle issue: if `--citeproc` is skipped but `--lua-filter zotero.lua` is still added (since the plan's branching says "PDF + citations + Zotero running" gets citeproc, but what about "PDF + citations + Zotero running + fetchBibliographyJSON fails"?), the Lua filter would be applied but do nothing for PDF (since `config.format` stays nil). The plan needs to clarify this branch explicitly.

Looking at the plan's step 4d more carefully: it says:
- PDF + citations + Zotero running: use `--citeproc`
- DOCX/ODT + citations: use `--lua-filter`
- No citations or Zotero unavailable: skip

But what about: **PDF + citations + Zotero running + fetchBibliographyJSON fails**? This falls through the cracks. The plan should specify that if `fetchBibliographyJSON` returns nil despite Zotero being "running", we should add a warning like "Could not fetch bibliography data from Zotero. Citations were not resolved." and skip `--citeproc`.

**Recommendation:** Add an explicit branch for this case in the plan.

### 4b. Warning message granularity

**[IMPORTANT]** The current warning system in `ExportService.swift:195-209` only reports Zotero status-level warnings. The plan should add a new warning for the case where Zotero is running but the bibliography fetch specifically fails. Something like:

```swift
if fetchedBibJSON == nil && zoteroStatus == .running {
    warnings.append("Could not fetch bibliography from Zotero. Citations were not processed.")
}
```

This is important because "Zotero running" + "no bibliography data" is a distinct failure mode from "Zotero not running."

---

## 5. `--citeproc` + XeTeX Compatibility

### 5a. Known compatibility issues

**No known compatibility issues.** `--citeproc` is pandoc's built-in citation processor (successor to `pandoc-citeproc`). It runs as a pandoc filter during the AST transformation phase, before the LaTeX writer produces output. XeTeX is the PDF engine that processes the LaTeX output. These are two separate stages:

1. Pandoc reads markdown, applies `--citeproc` to resolve citations in the AST, then writes LaTeX
2. XeTeX compiles the LaTeX to PDF

Since `--citeproc` operates at the pandoc AST level and XeTeX operates on the LaTeX output, they do not interact directly. This combination is well-tested and is the standard pandoc workflow for academic PDF production.

### 5b. CSL style + citeproc

The plan uses `--csl chicago-author-date.csl`. This is a standard CSL style that `--citeproc` supports natively. No issues expected.

### 5c. TinyTeX package dependencies

**[SUGGESTION]** If `--citeproc` generates bibliography entries with special characters (accented names, non-Latin scripts), XeTeX handles these better than pdflatex (which is why the app already uses XeTeX). However, certain bibliography styles may require LaTeX packages like `babel` or `polyglossia` for proper language-specific formatting. The bundled TinyTeX should have these, but it is worth verifying during testing.

---

## 6. Additional Issues Found

### 6a. `effectiveLuaScriptPath` always returns a value

**[IMPORTANT]** Looking at `ExportSettings.swift:111-116`, `effectiveLuaScriptPath` returns the bundled Lua script path as a fallback when no custom path is set. This means `luaScriptPath` in `ExportService.export()` (line 126) is almost never nil -- it always resolves to the bundled `zotero.lua`.

The plan's step 4d says to make Lua filter validation conditional:
```swift
if format != .pdf, let luaPath = luaScriptPath {
    guard FileManager.default.fileExists(atPath: luaPath) else {
        throw ExportError.luaScriptNotFound(luaPath)
    }
}
```

This correctly skips the validation for PDF. But then in the argument building (step 4d, point 4), the plan needs to also conditionally skip adding `--lua-filter` for PDF. Currently in `ExportService.swift:187-189`, the Lua filter is added unconditionally:
```swift
if let luaPath = luaScriptPath {
    arguments.append(contentsOf: ["--lua-filter", luaPath])
}
```

The plan's branching logic should replace this block entirely. The plan describes this replacement ("Replace unconditional Lua filter addition"), but the current wording could be clearer about what exactly replaces lines 187-189. Make sure the implementation does not accidentally add both `--lua-filter` and `--citeproc` for PDF exports. Having both should not cause errors (the Lua filter does nothing for PDF since `config.format` is nil), but it would be unnecessary processing.

**Recommendation:** The plan should explicitly state that lines 186-189 are fully replaced by the new format-aware branching. Not just "replace unconditional Lua filter addition" but "delete lines 186-189 and replace with the new branching block."

### 6b. `ExportService` is an `actor` -- networking calls

The plan adds `fetchBibliographyJSON(for:)` as a `private func` on `ExportService` (an actor). This method makes an HTTP POST to Zotero/BBT. Since `ExportService` is an actor, this method runs on the actor's serial executor. The `URLSession.shared.data(for:)` call is `async` and will suspend the actor, which is fine. No concurrency issues here.

However, `ExportService` uses `URLSession.shared` implicitly (via the existing `ZoteroChecker` actor which creates its own ephemeral session). The new method should also use an appropriate URLSession configuration with a reasonable timeout. The plan says it follows the same pattern as `ZoteroService.fetchItemsForCitekeys()`, which uses `URLSession.shared`. This is acceptable but a 2-5 second timeout would be prudent to avoid hanging exports.

### 6c. Temp bibliography file cleanup

**[SUGGESTION]** The plan mentions adding `var tempBibURL: URL?` and cleaning it up in the existing `defer` block. The current `defer` block (line 153-155) only cleans up `inputURL`. The implementation needs to ensure `tempBibURL` is also cleaned up:

```swift
defer {
    try? FileManager.default.removeItem(at: inputURL)
    if let tempBibURL {
        try? FileManager.default.removeItem(at: tempBibURL)
    }
}
```

The plan mentions this ("clean up in existing defer block") but does not show the code. Make sure this is not forgotten during implementation.

---

## Summary of Issues

| # | Severity | Issue | Section |
|---|----------|-------|---------|
| 1 | Critical | None found -- plan is fundamentally sound | -- |
| 2 | Important | Missing explicit branch for "PDF + Zotero running + fetchBibliographyJSON fails" | 4a |
| 3 | Important | Need warning message for "Zotero running but bibliography fetch failed" | 4b |
| 4 | Important | Clarify that lines 186-189 are fully replaced (not just augmented) to avoid adding both --lua-filter and --citeproc | 6a |
| 5 | Suggestion | Consider stripping `# Notes` heading from export (pandoc renders footnotes natively) | 3b |
| 6 | Suggestion | Verify TinyTeX has packages for multilingual bibliography entries | 5c |
| 7 | Suggestion | Ensure temp bibliography file cleanup code is explicit | 6c |

## Recommendation

The plan is ready for implementation after addressing the three "Important" items (2, 3, 4). These are clarification/completeness issues in the plan text, not architectural problems. The suggestions (5, 6, 7) can be addressed during implementation or deferred.

I revised my initial assessment -- there are no critical issues. The plan's core approach is correct and the architecture decisions are sound.
