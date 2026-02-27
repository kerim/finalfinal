# Reduce Cyclomatic Complexity in ExportService

## Context

SwiftLint reports two cyclomatic complexity violations in `ExportService.swift`:
- `export()` at complexity 28 (error, threshold 10) — the main export orchestrator
- `fontArguments(for:)` at complexity 18 (warning, threshold 10) — the Unicode script scanner

The goal is to reduce complexity using an OptionSet return type, helper extraction, and data-driven font mapping — without changing behavior or regressing performance.

## File Modified

`final final/Services/ExportService.swift`

## Changes

### 1. OptionSet + switch-based `detectScripts(in:)` — Extract scanning into its own method

Keep the existing `switch` (compiler-optimized jump table, O(1) per scalar) but move it into a dedicated method that returns an OptionSet instead of setting 8 booleans:

```swift
private struct DetectedScripts: OptionSet, Sendable {
    let rawValue: UInt16
    static let cjk        = DetectedScripts(rawValue: 1 << 0)
    static let hiragana   = DetectedScripts(rawValue: 1 << 1)
    static let katakana   = DetectedScripts(rawValue: 1 << 2)
    static let hangul     = DetectedScripts(rawValue: 1 << 3)
    static let devanagari = DetectedScripts(rawValue: 1 << 4)
    static let thai       = DetectedScripts(rawValue: 1 << 5)
    static let bengali    = DetectedScripts(rawValue: 1 << 6)
    static let tamil      = DetectedScripts(rawValue: 1 << 7)
    static let all: DetectedScripts = [.cjk, .hiragana, .katakana, .hangul,
                                        .devanagari, .thai, .bengali, .tamil]
}

/// Single-pass Unicode range scan. Returns which non-Latin scripts are present.
private func detectScripts(in content: String) -> DetectedScripts {
    var detected: DetectedScripts = []
    for scalar in content.unicodeScalars {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2A6DF:
            detected.insert(.cjk)
        case 0x3040...0x309F: detected.insert(.hiragana)
        case 0x30A0...0x30FF: detected.insert(.katakana)
        case 0xAC00...0xD7AF: detected.insert(.hangul)
        case 0x0900...0x097F: detected.insert(.devanagari)
        case 0x0E00...0x0E7F: detected.insert(.thai)
        case 0x0980...0x09FF: detected.insert(.bengali)
        case 0x0B80...0x0BFF: detected.insert(.tamil)
        default: break
        }
        if detected == .all { break }
    }
    return detected
}
```

### 2. Data-driven font helpers — Replace the if/else chains

`fontArguments(for:)` becomes a thin wrapper. The diagnostic print moves inside (avoids adding a branch to `export()`):

```swift
private func fontArguments(for content: String) -> [String] {
    let scripts = detectScripts(in: content)
    var args = cjkFontArguments(for: scripts, content: content)
    args.append(contentsOf: mainFontArguments(for: scripts))
    if !args.isEmpty {
        print("[ExportService] Font arguments: \(args)")
    }
    return args
}
```

Two small helpers handle the font selection:

```swift
private func cjkFontArguments(for scripts: DetectedScripts, content: String) -> [String] {
    let needsCJK = !scripts.isDisjoint(with: [.cjk, .hiragana, .katakana, .hangul])
    guard needsCJK else { return [] }

    let font: String
    if !scripts.isDisjoint(with: [.hiragana, .katakana]) {
        font = "Hiragino Mincho ProN"
    } else if scripts.contains(.hangul) {
        font = "Apple SD Gothic Neo"
    } else {
        font = disambiguateCJKFont(in: content)
    }
    return ["-V", "CJKmainfont=\(font)"]
}

private func mainFontArguments(for scripts: DetectedScripts) -> [String] {
    let mainFontMap: [(script: DetectedScripts, font: String)] = [
        (.devanagari, "Kohinoor Devanagari"),
        (.thai,       "Thonburi"),
        (.bengali,    "Bangla Sangam MN"),
        (.tamil,      "Tamil Sangam MN"),
    ]
    guard let match = mainFontMap.first(where: { scripts.contains($0.script) }) else {
        return []
    }
    return ["-V", "mainfont=\(match.font)"]
}
```

### 3. Extract three helpers from `export()` — Reduce complexity from 28

**a) `pdfEngineArguments()`** (lines 173-187, ~3 branches saved). Not marked `throws` — it always returns a value:

```swift
private func pdfEngineArguments() -> [String] {
    if let tinyTeX = try? prepareBundledTinyTeX() {
        return ["--pdf-engine", tinyTeX.xelatexPath,
                "--pdf-engine-opt", tinyTeX.outputDriverArg]
    } else if let bundledPath = ExportService.bundledXelatexPath {
        return ["--pdf-engine", bundledPath]
    } else {
        return ["--pdf-engine", "xelatex"]
    }
}
```

**b) `citationArguments(...)`** (lines 204-232, ~8 branches saved):

```swift
private func citationArguments(
    format: ExportFormat,
    content: String,
    zoteroStatus: ZoteroStatus,
    luaScriptPath: String?,
    tempDir: URL
) async -> (arguments: [String], tempBibURL: URL?, warnings: [String]) {
    // Move the hasCitations branching + Zotero fetch + citeproc/lua logic here
    // Returns (pandoc args, optional temp bib file URL, any warnings)
}
```

**c) `zoteroWarnings(for:)`** (lines 238-251, ~5 branches saved):

```swift
private func zoteroWarnings(for status: ZoteroStatus) -> [String] {
    switch status {
    case .notRunning:        return ["Zotero is not running. Citations were not resolved."]
    case .betterBibTeXMissing: return ["Better BibTeX is not installed. Citations were not resolved."]
    case .timeout:           return ["Could not connect to Zotero. Citations may not be resolved."]
    case .error(let msg):    return ["Zotero error: \(msg)"]
    case .running:           return []
    }
}
```

**d) Updated `export()` call site** — showing how the extracted helpers wire back in:

```swift
// PDF: engine + font variables (merged into single format check)
if format == .pdf {
    arguments.append(contentsOf: pdfEngineArguments())
    arguments.append(contentsOf: fontArguments(for: processedContent))
}

// Reference document (DOCX/ODT only)
if let refPath = referenceDocPath, format != .pdf {
    arguments.append(contentsOf: ["--reference-doc", refPath])
}

// Citations
if hasCitations {
    let citation = await citationArguments(
        format: format, content: processedContent,
        zoteroStatus: zoteroStatus, luaScriptPath: luaScriptPath,
        tempDir: tempDir
    )
    arguments.append(contentsOf: citation.arguments)
    tempBibURL = citation.tempBibURL  // CRITICAL: defer block captures this by reference
    warnings.append(contentsOf: citation.warnings)
}

// Run Pandoc
try await runPandoc(at: pandocPath, arguments: arguments)

// Zotero warnings (must be AFTER runPandoc — export still runs, warnings inform after)
if hasCitations {
    warnings.append(contentsOf: zoteroWarnings(for: zoteroStatus))
}
```

Note: The diagnostic `print("[ExportService] Font arguments: ...")` is now inside `fontArguments(for:)` itself, avoiding an extra branch in `export()`.

### 4. `disambiguateCJKFont(in:)` — No change

Already under complexity threshold. The `codePoint` and `scConfidence`/`tcConfidence` renames from earlier SwiftLint fixes are kept.

## Placement

All new types and methods go in the existing `// MARK: - Script Detection & Font Mapping` extension. `DetectedScripts` is declared as a `private struct` at the top of that extension.

## Expected Complexity After Refactoring

| Method | Before | After | Notes |
|--------|--------|-------|-------|
| `export()` | 28 | ~13 | Down from 28; validation guards still contribute ~8 |
| `fontArguments(for:)` | 18 | ~2 | Thin wrapper + print guard |
| `detectScripts(in:)` | n/a | ~2 | Switch + early exit (same perf as original) |
| `cjkFontArguments(for:content:)` | n/a | ~4 | guard + if/else-if/else |
| `mainFontArguments(for:)` | n/a | ~2 | guard + first(where:) |
| `pdfEngineArguments()` | n/a | ~3 | if/else-if/else |
| `citationArguments(...)` | n/a | ~8 | Inherits citation branching |
| `zoteroWarnings(for:)` | n/a | ~5 | switch with 5 cases |

`export()` at ~13 will still trigger the SwiftLint warning (threshold 10) but resolves the error-level violation (was 28). If a clean pass is desired, extract the validation guards (lines 103-142) into `validateExportInputs(...)` — this would bring it to ~7.

## Verification

1. `xcodebuild -scheme "final final" -destination 'platform=macOS' build` — must succeed
2. `swiftlint lint --quiet "final final/Services/ExportService.swift"` — `export()` and `fontArguments` errors resolved
3. Export NCCU Talk to PDF — Chinese terms render in Songti TC (unchanged behavior)
4. Export Latin-only document to PDF — no font arguments (unchanged behavior)
5. Export document with citations to PDF — `--citeproc` arguments present (unchanged behavior)
