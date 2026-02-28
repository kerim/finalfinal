# Miscellaneous Patterns

Patterns for JavaScript, cursor mapping, build system, and PDF export. Consult before working in these areas.

---

## JavaScript

### Keyboard Shortcuts with Shift

`e.key` returns uppercase when Shift held. Always normalize:

```typescript
if (e.key.toLowerCase() === 'e') { ... }
```

---

## Cursor Position Mapping (Milkdown <-> CodeMirror)

### ProseMirror textBetween() Returns Plain Text

`doc.textBetween()` strips all markdown syntax (`**`, `*`, `` ` ``, etc.). Searching for this plain text in markdown source will fail because the markdown contains the syntax characters.

**Wrong approach (text anchor):**
```typescript
const textBefore = doc.textBetween(start, head, '\n');
markdown.indexOf(textBefore); // Fails - textBefore has no syntax
```

**Right approach (line matching + offset mapping):**
1. Match paragraph text content to markdown lines (strip syntax from both sides)
2. Use bidirectional offset mapping that accounts for inline syntax length

### Bidirectional Offset Mapping Required

Converting cursor positions between WYSIWYG and source requires accounting for inline syntax:

| Markdown | Text Length | Markdown Length |
|----------|-------------|-----------------|
| `**bold**` | 4 ("bold") | 8 |
| `*italic*` | 6 ("italic") | 8 |
| `` `code` `` | 4 ("code") | 6 |
| `[link](url)` | 4 ("link") | 12 |

Functions needed:
- `textToMdOffset(mdLine, textOffset)` -- ProseMirror -> CodeMirror
- `mdToTextOffset(mdLine, mdOffset)` -- CodeMirror -> ProseMirror

### Line-Start Syntax Must Be Handled Separately

Headers, lists, and blockquotes have line-start syntax that affects column calculation:

```typescript
const syntaxMatch = line.match(/^(#+\s*|\s*[-*+]\s*|\s*\d+\.\s*|\s*>\s*)/);
const syntaxLength = syntaxMatch ? syntaxMatch[0].length : 0;
const contentAfterSyntax = line.slice(syntaxLength);
```

Apply offset mapping only to content after syntax, then add syntax length back.

---

### Push-Based Content Sync over WKWebView Polling

**Problem:** Content polling via `evaluateJavaScript("getContent()")` at 500ms intervals added latency to every edit. Three sequential JS calls per poll cycle (content, stats, section title) competed for the WebKit IPC bridge.

**Solution:** Push content from JS to Swift via `window.webkit.messageHandlers.contentChanged.postMessage(markdown)` with 50ms debounce. Reduce polling to 3s fallback for supplementary data only (stats + section title), batched into a single `getPollData()` call returning JSON.

```typescript
// JS side: debounced push on doc change
if (update.docChanged) {
  if (pushTimer) clearTimeout(pushTimer);
  pushTimer = setTimeout(() => {
    window.webkit?.messageHandlers?.contentChanged?.postMessage(content);
  }, 50);
}
```

```swift
// Swift side: handle push in WKScriptMessageHandler
if message.name == "contentChanged", let content = message.body as? String {
    Task { @MainActor in self.handleContentPush(content) }
    return
}
```

**Key details:**
- Register `contentChanged` message handler in both the preloaded and fresh WebView paths (easy to forget one)
- Milkdown: wrap in dispatch override (ProseMirror has no `updateListener` equivalent)
- CodeMirror: use `EditorView.updateListener.of(...)` extension
- Grace period guard prevents push handler from overwriting content that Swift just pushed to the editor via `setContent()`
- Re-check `isSettingContent` guard after the 50ms debounce window (setContent may have run during the delay)

**General principle:** For WKWebView bridge communication, prefer push-based messaging (postMessage) over polling (evaluateJavaScript) when the JS side knows when data changes. Reserve polling for data without change events.

---

## Build

### Vite emptyOutDir: false

Changes to source `index.html` won't sync to output. Either manually sync or set `emptyOutDir: true`.

---

## Git Info at Build Time

A pre-build script in `project.yml` generates `final final/App/GitInfo.swift` on every build, embedding the current git branch and short commit hash. This is logged at launch in DEBUG builds:

```
[FINAL|FINAL] Build: open-proj-bug (27d9047)
```

The script uses `basedOnDependencyAnalysis: false` so it runs even after a branch switch with no source changes. A committed placeholder `GitInfo.swift` is required because xcodegen scans the source tree at project-generation time — without it, the file won't appear in compile sources.

---

## XeTeX / PDF Export

### Unicode Range Scanning Over NLLanguageRecognizer for Script Detection

**Problem:** `NLLanguageRecognizer` with a percentage-based confidence threshold misses non-Latin scripts in predominantly English documents. A paper with scattered Chinese terms (`九年一貫課程`, `原住民族教育法`) at ~3-5% of content falls below the 5% threshold, so the recognizer classifies the document as English-only and no CJK font gets passed to pandoc.

**Root Cause:** Language detection is probabilistic and percentage-based — it answers "what language IS this document?" Not "does this document CONTAIN characters that need special font support?"

**Solution:** Use Unicode scalar range scanning (Tier 1) to detect WHETHER non-Latin scripts are present. Use NLLanguageRecognizer (Tier 2) only to disambiguate WHICH CJK font when CJK ideographs are found without unambiguous script markers (Hiragana/Katakana/Hangul).

**General principle:** For font selection, presence detection (Unicode ranges) is more reliable than statistical language classification. A single CJK character in an English document still needs a CJK font to render correctly.

See [export.md](../architecture/export.md) for the full font detection architecture.

### Use -output-driver for Paths with Spaces

**Problem:** When the app bundle path contains spaces (e.g., "final final.app"), xelatex fails with error 32512 when calling xdvipdfmx:

```
sh: /Users/.../Build/Products/Debug/final: No such file or directory
```

**Root Cause:** XeTeX internally calls xdvipdfmx via shell without quoting the path. The shell interprets the space as an argument separator:

```
# What xelatex runs internally:
/path/to/final final.app/.../xdvipdfmx args

# Shell interprets as:
Command: /path/to/final
Arg 1: final.app/.../xdvipdfmx
Arg 2: args
```

**What doesn't work:**
- Setting `XDVIPDFMX` environment variable (xelatex ignores it)
- Setting `SELFAUTOLOC` and other kpathsea variables (only affects package resolution)
- Putting wrapper scripts in PATH (xelatex uses absolute path, not PATH lookup)
- Copying binaries to temp directory (breaks TeX package resolution)

**Solution:** Use XeTeX's documented `-output-driver` command-line option to specify the XDV-to-PDF driver command:

```swift
// 1. Create symlink to TinyTeX at space-free path (for package resolution)
let symlinkURL = tempDir.appendingPathComponent("TinyTeX")
try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: bundledTinyTeXURL)

// 2. Create xdvipdfmx wrapper script at space-free path
let wrapperScript = """
    #!/bin/bash
    exec "\(tinyTeXBin)/xdvipdfmx" "$@"
    """
try wrapperScript.write(to: wrapperURL, atomically: true, encoding: .utf8)

// 3. Pass to xelatex via -output-driver option (through Pandoc)
arguments.append(contentsOf: ["--pdf-engine", xelatexPath])
arguments.append(contentsOf: ["--pdf-engine-opt", "-output-driver=\(wrapperURL.path)"])
```

**Reference:** [XeTeX Reference Guide](https://mirrors.mit.edu/CTAN/info/xetexref/xetex-reference.pdf) -- the `-output-driver=CMD` option "use CMD as the XDV-to-PDF driver instead of xdvipdfmx"

**General principle:** When bundling TeX in macOS apps, avoid spaces in the app name. If unavoidable, use `-output-driver` to redirect xdvipdfmx calls through a wrapper script at a space-free path.

---

## QuickLook Extension Registration

### xcodegen Rewrites Source Info.plist

xcodegen completely regenerates the source `Info.plist` from `info.properties` on every `xcodegen generate`. Keys in the source plist that are NOT in `info.properties` are **silently deleted**. This means the source plist is not a reliable place to add keys manually — they must be declared in `project.yml`.

For QuickLook extensions, the `NSExtension` dict (including `QLSupportsSecureCoding`) must be in `project.yml`'s `info.properties` to survive xcodegen regeneration.

### pluginkit Registration Required for Script Builds

When building with `xcodebuild` via a build script (not the Xcode IDE), macOS may not automatically discover the extension. The build script must:

1. **Before build:** Remove stale registrations from DerivedData leftovers:
   ```bash
   pluginkit -r -i com.kerim.final-final.quicklook 2>/dev/null || true
   ```

2. **After signing:** Explicitly register the extension:
   ```bash
   pluginkit -a "$APPEX_PATH"
   ```

Without `pluginkit -a`, the system may continue using stale registrations pointing to old DerivedData builds, or fall back to the system's `Package.qlgenerator` for content types conforming to `com.apple.package`.

### QLSupportsSecureCoding Is Required

Without `QLSupportsSecureCoding: true` in `NSExtensionAttributes`, macOS does not recognize the extension as a valid QuickLook preview provider. The extension won't appear in `pluginkit -m -p com.apple.quicklook.preview` output.

---

## AttributedString Markdown Block Separation

### Problem

`AttributedString(markdown:, interpretedSyntax: .full)` strips original whitespace between block-level elements (headings, paragraphs, code blocks, etc.) and stores block structure only as `PresentationIntent` metadata attributes. Without explicit newline characters, `NSTextView` concatenates all blocks onto a single line.

### Solution

After parsing, iterate `PresentationIntent` runs in **reversed order** and insert `\n` at each block's `lowerBound` (skipping the first block). Reversed iteration is essential — it prevents earlier insertions from invalidating later range indices.

```swift
for (intent, range) in attributed.runs[\.presentationIntent].reversed() {
    guard intent != nil, range.lowerBound != attributed.startIndex else { continue }
    attributed.characters.insert(contentsOf: "\n", at: range.lowerBound)
}
```

This must happen **before** applying any styling (fonts, paragraph styles, colors), since the insertions shift all subsequent ranges.

**Reference:** [AttributedStringStyledMarkdown](https://github.com/frankrausch/AttributedStringStyledMarkdown) by Frank Rausch documents this pattern.

**Used in:** `QuickLook Extension/MarkdownRenderer.swift` — the `parseAndStyle()` method.

---

## CSS Variables: `--editor-muted` Is for UI Chrome, Not User Content

**Problem:** Image captions used `--editor-muted` (mapped to `editorTextSecondary`) for their text color. At reduced font sizes (0.85–0.9em), the contrast dropped below readable levels, especially in Low Contrast Night (`#777b84` on `#111113` ≈ 3.5:1 ratio, below WCAG AA).

**Root Cause:** Captions are **user content** (text the author wrote), but were styled like **UI chrome** (heading placeholders, section breaks, spellcheck messages). The `--editor-muted` variable is deliberately low-contrast for decorative elements that shouldn't compete with body text.

**Solution:** Use `--editor-text` (primary text color) for captions. The smaller font size (0.85–0.9em) already provides sufficient visual hierarchy to distinguish captions from body text.

```css
/* WRONG: treats caption as UI chrome */
.figure-caption { color: var(--editor-muted, #666); }

/* RIGHT: treats caption as user content */
.figure-caption { color: var(--editor-text, #1a1a1a); }
```

**Note on High Contrast Night:** In this theme, `editorText` (#BD6B15) is actually darker than `editorTextSecondary` (#ffa057) — an intentional design inversion for the amber-on-black theme. Using `--editor-text` still gives ~5:1 contrast (WCAG AA compliant) and is consistent since all text in that theme is amber.

**Exception:** The `.figure-caption:empty::before` placeholder ("Add a caption…") should keep `--editor-muted` — it *is* UI chrome, not user content.

**General principle:** Distinguish between user content and UI chrome when choosing CSS variables. User content (captions, footnotes, annotations with user text) should use `--editor-text`. UI chrome (placeholders, markers, decorative separators) should use `--editor-muted`.
