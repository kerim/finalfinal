# Fix Quick Look Preview: Block Separation

## Context

The Quick Look extension builds and loads, but all document content renders on a single line — headings, paragraphs, and sections are concatenated with no line breaks between them. The title and separator render correctly (custom code), but the body content from `parseAndStyle()` runs together.

## Root Cause

`AttributedString(markdown:, interpretedSyntax: .full)` does **not** include newline characters between block-level elements. It strips original whitespace and uses `PresentationIntent` attributes as metadata-only markers. Without explicit newlines, `NSTextView` has no paragraph boundaries to render.

Reference: [AttributedStringStyledMarkdown](https://github.com/frankrausch/AttributedStringStyledMarkdown) confirms this — their solution is to iterate `PresentationIntent` runs in **reversed order** and insert `\n` at each block boundary.

## File to Modify

`QuickLook Extension/MarkdownRenderer.swift` — the `parseAndStyle()` method (lines 97-180)

## Fix

Rewrite `parseAndStyle()` to follow the proven pattern:

1. **Parse** with `.full` interpretedSyntax (already correct)
2. **Insert block separators**: iterate `PresentationIntent` runs in **reversed** order, insert `\n` at each block's `lowerBound` (skip the first block). Reversed iteration prevents range invalidation.
3. **Apply styling**: walk runs again to set fonts, colors, paragraph styles per block type (headers, code blocks, blockquotes, lists, paragraphs)

```swift
private static func parseAndStyle(_ markdown: String) -> NSAttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
    guard var s = try? AttributedString(markdown: markdown, options: options) else {
        // fallback to plain text (unchanged)
    }

    // Step 1: Insert newlines between blocks (reversed to preserve ranges)
    for (intent, range) in s.runs[\.presentationIntent].reversed() {
        guard intent != nil, range.lowerBound != s.startIndex else { continue }
        s.characters.insert(contentsOf: "\n", at: range.lowerBound)
    }

    // Step 2: Apply base style
    s.font = .systemFont(ofSize: 14)
    s.foregroundColor = .labelColor

    // Step 3: Walk runs and apply block/inline styling (existing switch logic)
    // ... headers, code blocks, blockquotes, lists, inline code, links ...

    return try! NSAttributedString(s, including: \.appKit)
}
```

The existing styling switch (headers, code blocks, blockquotes, lists, inline code, links) remains unchanged — only the newline insertion step is added before it.

## Verification

1. Build: `xcodebuild -scheme "final final" -destination 'platform=macOS' build`
2. Reset cache: `qlmanage -r`
3. Test: `qlmanage -p "final finalTests/Fixtures/test-fixture.ff"`
4. Expect: "Test Document" heading on its own line, paragraph below it, "Second Section" heading on its own line, paragraph below that
