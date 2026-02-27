# Code Review: Cyclomatic Complexity Reduction Plan for ExportService

**Plan file:** `/Users/niyaro/Documents/Code/ff-dev/pandoc-pdf/docs/plans/mighty-mapping-cookie.md`
**Implementation file:** `/Users/niyaro/Documents/Code/ff-dev/pandoc-pdf/final final/Services/ExportService.swift`
**Reviewer:** Code Review Agent (Opus 4.6)
**Status:** Pre-implementation review -- 1 critical issue, 2 important issues, 4 suggestions

---

## Overall Assessment

The plan is well-structured and correctly identifies the two SwiftLint violations. The OptionSet + static table approach for `fontArguments(for:)` is a sound refactoring pattern that will meaningfully reduce complexity while preserving behavior. The extraction of `pdfEngineArguments()` and `citationArguments(...)` from `export()` is also appropriate.

However, the plan has one critical correctness issue in the `detectScripts` loop, two important design concerns around the `citationArguments` extraction and missed complexity sources, and several minor suggestions.

---

## 1. CRITICAL: `detectScripts` Loop Has a Performance Regression and a Subtle Correctness Concern

### 1a. The inner loop skips already-detected scripts but still iterates entries

The plan proposes:

```swift
for scalar in content.unicodeScalars {
    let codePoint = scalar.value
    for entry in Self.scriptRanges where !detected.contains(entry.script) {
        if entry.ranges.contains(where: { $0.contains(codePoint) }) {
            detected.insert(entry.script)
        }
    }
    if detected == .all { break }
}
```

The `where !detected.contains(entry.script)` clause correctly avoids re-processing already-detected scripts, which is good. And `.contains(where: { $0.contains(codePoint) })` on `[ClosedRange<UInt32>]` is valid Swift -- `ClosedRange<UInt32>` conforms to `Sequence` whose elements are `UInt32`, and `ClosedRange.contains(_:)` is an O(1) bounds check, so this works correctly.

**However, the existing `switch` statement is O(1) per scalar** -- it is a single pattern match that checks all ranges in one pass. The proposed replacement is **O(scripts x ranges) per scalar** -- for each scalar, it iterates up to 8 script entries and up to 4 ranges within each (for CJK). For a 50,000-character document, this changes from ~50K operations to ~50K x 11 operations (8 entries with ~11 total ranges). That is a roughly 10x regression.

This may not matter in practice for typical document sizes, but it is worth noting because the current `switch` is genuinely more efficient. The `switch` statement achieves the same "table-driven" result via the compiler's jump table optimization.

**Recommendation:** This is marked critical not because it will break functionality, but because the stated goal is to reduce *complexity* -- not to regress performance. Two options:

- **Option A:** Accept the trade-off. The loop is still fast enough for real-world documents (sub-millisecond for 100K characters). Document the trade-off in a code comment.
- **Option B:** Keep the `switch` for scanning but extract it into `detectScripts(in:)` as a separate method returning `DetectedScripts`. This achieves the complexity reduction (the `switch` lives in its own small method) without changing the algorithm. The `fontArguments(for:)` method still becomes a thin wrapper.

Option B preserves both the performance characteristic and the complexity reduction goal.

### 1b. `.contains(where:)` on `[ClosedRange<UInt32>]` -- API correctness confirmed

To be explicit: `entry.ranges.contains(where: { $0.contains(codePoint) })` is correct Swift. `Array.contains(where:)` takes a predicate, and `ClosedRange<UInt32>.contains(UInt32)` is the O(1) bounds check. There is no API misuse here. The `UInt32` from `scalar.value` matches the `ClosedRange<UInt32>` element type. This part is fine.

---

## 2. IMPORTANT: `citationArguments` Extraction Has Unresolved Side-Effect Complications

The plan proposes extracting citation logic into:

```swift
private func citationArguments(
    format: ExportFormat,
    content: String,
    zoteroStatus: ZoteroStatus,
    luaScriptPath: String?,
    tempDir: URL
) async -> (arguments: [String], tempBibURL: URL?, warnings: [String])
```

This signature is correct in principle, but the extraction creates a subtle ownership problem with `tempBibURL`.

### The problem

In the current code (lines 147-159 of `ExportService.swift`), `tempBibURL` is declared as a local `var` in `export()` and is captured by the `defer` block for cleanup:

```swift
var tempBibURL: URL?
// ...
defer {
    try? FileManager.default.removeItem(at: inputURL)
    if let bibURL = tempBibURL {
        try? FileManager.default.removeItem(at: bibURL)
    }
}
```

The `defer` block captures `tempBibURL` by reference -- it reads whatever value `tempBibURL` holds at the time the scope exits. If `citationArguments(...)` returns the URL in a tuple, the caller must assign it back to the local `var tempBibURL` so the `defer` block still sees it:

```swift
let result = await citationArguments(...)
arguments.append(contentsOf: result.arguments)
tempBibURL = result.tempBibURL  // MUST assign back for defer cleanup
warnings.append(contentsOf: result.warnings)
```

The plan does not show this call-site code. If the implementer forgets to assign `result.tempBibURL` back to the local variable, the bibliography temp file will leak (never cleaned up).

**Recommendation:** Show the complete call-site code in the plan, including the `tempBibURL` assignment. Alternatively, consider having `citationArguments` not create the temp file itself -- instead, have it return the bibliography JSON string, and let the caller handle file creation (keeping the temp file lifecycle entirely in `export()`). This would be a cleaner separation of concerns.

---

## 3. IMPORTANT: Plan Misses Other Complexity Contributors in `export()`

The plan identifies `pdfEngineArguments()` (complexity ~3) and `citationArguments(...)` (complexity ~8) as extraction targets. These are the right choices for the two most complex sub-blocks.

However, the plan claims `export()` has complexity 28. Let me count the remaining branching after extracting those two helpers:

| Branch | Lines | Complexity |
|--------|-------|------------|
| `guard !content.isEmpty` | 103 | +1 |
| `if !settings.includeAnnotations` | 109 | +1 |
| `guard pandocPath` | 114 | +1 |
| Ternary `hasCitations ? ... : ...` | 122-124 | +1 |
| `if format != .pdf, let luaPath` | 131 | +2 |
| `guard fileExists` | 132 | +1 |
| `if let refPath` | 138 | +1 |
| `guard fileExists` | 139 | +1 |
| `do/catch` for write | 149-153 | +1 |
| `if format == .pdf` (font args) | 190 | +1 |
| `if let refPath, format != .pdf` | 199 | +1 |
| `if hasCitations` (warning switch) | 238 | +1 |
| `switch zoteroStatus` (5 cases) | 239-250 | +4 |
| **Subtotal (after extraction)** | | **~17** |

Even after extracting `pdfEngineArguments()` (~3 saved) and `citationArguments(...)` (~8 saved), the remaining complexity is approximately 17, which is still well above the threshold of 10.

The Zotero status warning switch (lines 238-250) accounts for ~5 of those points. The validation guards at the top (lines 103-142) account for ~8 more.

**Recommendation:** The plan should acknowledge that extracting just two helpers will likely bring `export()` down to ~17, not below 10. To get below 10, additional extraction would be needed -- for example:
- Extract a `validateInputs(content:settings:format:)` method for the top validation block
- Extract the Zotero warning generation into a `zoteroWarnings(status:)` method

If the goal is merely to eliminate the SwiftLint *error* (complexity 28 -> below 20 or whatever the error threshold is), the current plan may suffice. But if the goal is to get below the *warning* threshold of 10, more work is needed.

---

## 4. SUGGESTION: `DetectedScripts` Should Be a Nested Type or Fileprivate

The plan declares `DetectedScripts` as `private struct`. Since `ExportService` is an `actor`, a `private struct` declared at the extension level would be file-private in Swift (private at the file scope when declared in an extension). This is fine for this single-file design. But if `ExportService` is ever split across files, `DetectedScripts` would need to be `fileprivate` explicitly or moved inside the actor body.

No action needed now, but worth a comment in the code noting that this type is intentionally file-scoped.

---

## 5. SUGGESTION: `scriptRanges` Static Property Placement

The plan declares `scriptRanges` as `private static let` but does not specify where it lives. Since `ExportService` is an actor, `static let` properties are fine (they are implicitly `nonisolated` and initialized lazily/once). However, placing it inside the same extension as `detectScripts` would be cleanest for readability.

No correctness issue -- just a code organization note.

---

## 6. SUGGESTION: `cjkFontArguments` Passes `content` Unnecessarily Wide

The plan's `cjkFontArguments(for:content:)` takes the full `String content` only to pass it through to `disambiguateCJKFont(in:)`. This means the full document string is passed through two method calls just for the disambiguation case. This is fine (strings are copy-on-write in Swift, so no actual copy occurs), but semantically it would be cleaner to call `disambiguateCJKFont` directly in `fontArguments(for:)` when the CJK-only-no-kana-no-hangul case is hit, rather than threading the string through `cjkFontArguments`.

This is a minor style point and does not affect correctness.

---

## 7. SUGGESTION: The `== .all` Early Exit Comparison

The plan uses:

```swift
if detected == .all { break }
```

This is correct Swift for OptionSet equality comparison. `DetectedScripts` inherits `Equatable` from `OptionSet`, and `.all` is defined as the union of all flags. When `detected.rawValue == DetectedScripts.all.rawValue`, the comparison is true and the loop breaks. This is equivalent to the current 8-flag `&&` check.

One minor note: if new scripts are added in the future but `.all` is not updated, the early exit would trigger prematurely. Consider computing `.all` from `scriptRanges` rather than listing all cases manually:

```swift
static let all = scriptRanges.reduce(into: DetectedScripts()) { $0.insert($1.script) }
```

This keeps `.all` automatically in sync with the table.

---

## 8. Behavior Preservation Verification

I verified each behavior against the current code:

| Behavior | Preserved? | Notes |
|----------|-----------|-------|
| CJK detection (4 ranges) | Yes | Same ranges in `scriptRanges` table |
| Hiragana/Katakana -> Japanese font | Yes | `cjkFontArguments` checks `.isDisjoint(with: [.hiragana, .katakana])` |
| Hangul -> Korean font | Yes | `scripts.contains(.hangul)` check |
| CJK-only -> disambiguate SC/TC | Yes | Falls through to `disambiguateCJKFont(in:)` |
| CJK priority: kana > hangul > disambiguate | Yes | Same if/else-if chain in `cjkFontArguments` |
| Non-CJK first-match-wins for mainfont | Yes | `mainFontMap.first(where:)` preserves priority order |
| Early exit when all scripts detected | Yes | `detected == .all` check |
| `disambiguateCJKFont` unchanged | Yes | Plan explicitly states no change needed |
| PDF engine 3-tier fallback | Yes | `pdfEngineArguments()` preserves try/else-if/else chain |

**One nuance to verify:** In the current code, CJK font arguments and mainfont arguments are both appended to the same `args` array unconditionally. The plan splits them into two methods (`cjkFontArguments` and `mainFontArguments`) whose results are concatenated. This means a document with both CJK and Devanagari would get both `-V CJKmainfont=...` and `-V mainfont=...`, which is correct -- these are different pandoc variables that do not conflict. Behavior is preserved.

---

## Summary

| # | Severity | Issue |
|---|----------|-------|
| 1 | Critical | `detectScripts` loop is O(n*k) vs current O(n) switch; consider keeping switch inside the extracted method |
| 2 | Important | `citationArguments` extraction must show call-site code; `tempBibURL` assignment back to local var is required for cleanup |
| 3 | Important | Extracting 2 helpers reduces `export()` to ~17 complexity, still above threshold of 10; plan should acknowledge or add more extractions |
| 4 | Suggestion | `DetectedScripts` scope is fine now but note it is file-scoped |
| 5 | Suggestion | Place `scriptRanges` in same extension as `detectScripts` |
| 6 | Suggestion | `cjkFontArguments` takes full content string just for pass-through; minor style concern |
| 7 | Suggestion | Compute `.all` from `scriptRanges` to stay in sync automatically |

---

## Recommendation

The plan is sound in approach and correctly preserves all existing behavior. The most important feedback:

1. **For the `detectScripts` loop (Critical):** Strongly consider Option B -- keep the `switch` statement inside a new `detectScripts(in:) -> DetectedScripts` method. You get the same complexity reduction (the switch is now in its own method, `fontArguments` becomes a thin wrapper) without the algorithmic regression. The OptionSet and static table can still be used for the font-mapping helpers (`cjkFontArguments`, `mainFontArguments`) even if the scanning itself uses a switch.

2. **For `citationArguments` (Important):** Add the call-site code to the plan showing the `tempBibURL` assignment. This is easy to miss during implementation.

3. **For `export()` complexity (Important):** Decide whether the goal is "below error threshold" or "below warning threshold." If the latter, plan additional extractions now rather than discovering the need after implementation.

With these adjustments, the plan can proceed to implementation.
