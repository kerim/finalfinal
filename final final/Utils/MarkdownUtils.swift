//
//  MarkdownUtils.swift
//  final final
//
//  Utilities for processing markdown text, including stripping syntax
//  for accurate word counts.
//

import Foundation

enum MarkdownUtils {
    /// Remove fenced code blocks and inline code from markdown.
    /// Used before citekey extraction to prevent false positives from examples.
    static func stripCodeContent(from markdown: String) -> String {
        var result = markdown
        // Remove fenced code blocks (``` and ~~~)
        result = result.replacingOccurrences(
            of: #"```[\s\S]*?```"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"~~~[\s\S]*?~~~"#,
            with: "",
            options: .regularExpression
        )
        // Remove inline code (`...`)
        result = result.replacingOccurrences(
            of: #"`[^`]+`"#,
            with: "",
            options: .regularExpression
        )
        return result
    }

    /// Strip markdown syntax from content to get plain text
    /// Used for accurate word counting that excludes formatting symbols
    static func stripMarkdownSyntax(from content: String) -> String {
        var result = content

        // Remove heading markers: # ## ### etc at line start
        let headingPattern = "^#{1,6}\\s+"
        if let regex = try? NSRegularExpression(pattern: headingPattern, options: .anchorsMatchLines) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Remove bold/italic markers: ** __ * _
        // Handle bold first (** and __), then italic (* and _)
        let boldPattern = "\\*\\*(.+?)\\*\\*|__(.+?)__"
        if let regex = try? NSRegularExpression(pattern: boldPattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1$2")
        }

        let italicPattern = "\\*([^*]+)\\*|_([^_]+)_"
        if let regex = try? NSRegularExpression(pattern: italicPattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1$2")
        }

        // Remove strikethrough: ~~text~~
        let strikethroughPattern = "~~(.+?)~~"
        if let regex = try? NSRegularExpression(pattern: strikethroughPattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
        }

        // Remove highlight markers: ==text==
        let highlightPattern = "==(.+?)=="
        if let regex = try? NSRegularExpression(pattern: highlightPattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
        }

        // Remove inline code backticks: `code`
        let inlineCodePattern = "`([^`]+)`"
        if let regex = try? NSRegularExpression(pattern: inlineCodePattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
        }

        // Remove images ![alt](url){width=N%} entirely (don't count alt text as words).
        // MUST run before the link stripper, otherwise the link regex matches
        // [alt](url) inside the image syntax and leaves a stray `!alt text` behind.
        let imagePattern = "!\\[[^\\]]*\\]\\([^)]+\\)(\\s*\\{[^}]*\\})?"
        if let regex = try? NSRegularExpression(pattern: imagePattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Convert links [text](url) to just text. Negative lookbehind `(?<!!)`
        // is belt-and-braces in case the image stripper missed an unusual variant.
        let linkPattern = "(?<!!)\\[([^\\]]+)\\]\\([^)]+\\)"
        if let regex = try? NSRegularExpression(pattern: linkPattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
        }

        // Remove list markers: - * + or 1. 2. etc
        let listPattern = "^\\s*(?:[-*+]|\\d+\\.)\\s+"
        if let regex = try? NSRegularExpression(pattern: listPattern, options: .anchorsMatchLines) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Remove blockquote markers: > at line start
        let blockquotePattern = "^>+\\s*"
        if let regex = try? NSRegularExpression(pattern: blockquotePattern, options: .anchorsMatchLines) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Remove section break markers: <!-- ::break:: -->
        let breakPattern = "<!--\\s*::break::\\s*-->"
        if let regex = try? NSRegularExpression(pattern: breakPattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Remove code fence markers: ```language
        let codeFencePattern = "^```[a-zA-Z]*\\s*$"
        if let regex = try? NSRegularExpression(pattern: codeFencePattern, options: .anchorsMatchLines) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Remove horizontal rules: ---, ***, ___
        let hrPattern = "^[-*_]{3,}\\s*$"
        if let regex = try? NSRegularExpression(pattern: hrPattern, options: .anchorsMatchLines) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Remove footnote references: [^1], [^2], etc.
        let footnoteRefPattern = "\\[\\^\\d+\\](?!:)"
        if let regex = try? NSRegularExpression(pattern: footnoteRefPattern) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Remove footnote definition prefixes: [^1]: at line start
        let footnoteDefPattern = "^\\[\\^\\d+\\]:\\s*"
        if let regex = try? NSRegularExpression(pattern: footnoteDefPattern, options: .anchorsMatchLines) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Remove annotations: <!-- ::type:: content -->
        result = stripAnnotations(from: result)

        return result
    }

    /// Strip annotation HTML comments from content
    /// Annotations follow the pattern: <!-- ::type:: content -->
    /// where type is task, comment, reference, or break
    static func stripAnnotations(from content: String) -> String {
        var result = content

        // Pattern matches: <!-- ::word:: any content -->
        // This handles task, comment, reference, break, and auto-bibliography annotations
        let annotationPattern = "<!--\\s*::\\w+::\\s*[\\s\\S]*?-->"
        if let regex = try? NSRegularExpression(pattern: annotationPattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        return result
    }

    /// Check if text is a ghost image reference from WebKit's native drop race condition.
    /// These look like `![Screenshot...](blob:...)` or `![...](data:...)` — never valid
    /// persisted image sources (legitimate images use the `projectmedia://` scheme).
    static func isGhostImageMarkdown(_ text: String) -> Bool {
        text.hasPrefix("![") && (text.contains("](blob:") || text.contains("](data:"))
    }

    /// Count words in markdown content, excluding syntax symbols and non-prose
    /// regions (code blocks, math, citations, HTML, YAML frontmatter, etc.).
    /// Tokens that are pure punctuation (e.g. a stray `.` left by a stripped
    /// citation) are not counted. See `stripForWordCount(from:)` for the full
    /// list of patterns removed.
    static func wordCount(for content: String) -> Int {
        let text = stripForWordCount(from: content)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        return trimmed.components(separatedBy: .whitespacesAndNewlines)
            .filter { token in
                !token.isEmpty && token.contains(where: { $0.isLetter || $0.isNumber })
            }
            .count
    }

    // MARK: - Citation render-count placeholder

    // Single source of truth for the CIT placeholder token used in `stripForWordCount`
    // for render-then-count citation handling. Changing this requires changing it here
    // only — the three substitution templates and the bracket-strip regex all derive
    // from `citToken`, so they can't drift apart.
    private static let citToken = "CIT"
    private static let citSingle = " \(citToken) "
    private static let citDouble = " \(citToken) \(citToken) "

    // MARK: - Precompiled regex patterns for stripForWordCount

    // NSRegularExpression compile is expensive; hoisting each pattern once
    // means `stripForWordCount` can run inside tight loops (e.g. the open-time
    // migration sweep) without ~15 regex recompilations per block.
    // Patterns below are compile-time constants — a failure is a programming
    // error, not a runtime condition, so `try!` is the right contract here.
    // swiftlint:disable force_try
    private static let rxYAMLFrontmatter = try! NSRegularExpression(
        pattern: #"\A---\s*\n[\s\S]*?\n---\s*(?:\n|$)"#
    )
    private static let rxFencedCodeBacktick = try! NSRegularExpression(
        pattern: #"```[\s\S]*?```"#
    )
    private static let rxFencedCodeTilde = try! NSRegularExpression(
        pattern: #"~~~[\s\S]*?~~~"#
    )
    private static let rxHTMLComment = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?-->"#
    )
    private static let rxDisplayMath = try! NSRegularExpression(
        pattern: #"\$\$[\s\S]+?\$\$"#
    )
    private static let rxInlineMath = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9$])\$(?=\S)[^\$\n]+?(?<=\S)\$(?![A-Za-z0-9$])"#
    )
    private static let rxReferenceLinkDef = try! NSRegularExpression(
        pattern: #"^\s*\[[^\^\]][^\]]*\]:\s*\S+.*$"#,
        options: [.anchorsMatchLines]
    )
    private static let rxInlineReferenceLink = try! NSRegularExpression(
        pattern: #"\[([^\^\]][^\]]*)\]\[[^\]]*\]"#
    )
    private static let rxHTMLTag = try! NSRegularExpression(
        pattern: #"<\/?[A-Za-z][^>]*>"#
    )
    // Citation substitutions (render-then-count). Escaped `\-` in the citekey
    // character class is CRITICAL: without the escape, `+-` reads as the ASCII
    // range `+`..`-` (43..45), which silently includes `,` (44). With the escape,
    // the class is the literal set `{+, -}`.
    private static let rxCitationSuppressAuthor = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])-@[A-Za-z][A-Za-z0-9_:+\-]*"#
    )
    private static let rxCitationKey = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9<\-])@[A-Za-z][A-Za-z0-9_:+\-]*"#
    )
    private static let rxCitationBracket = try! NSRegularExpression(
        pattern: #"\[([^\]]*\b"# + citToken + #"\b[^\]]*)\]"#
    )
    private static let rxPandocAttrs = try! NSRegularExpression(
        pattern: #"\{#[\w\-]+\}|\{\.[\w\-]+\}|\{[^}]*=[^}]*\}"#
    )
    private static let rxTaskCheckbox = try! NSRegularExpression(
        pattern: #"^\s*\[[ xX]\]\s+"#,
        options: [.anchorsMatchLines]
    )
    private static let rxTableSeparator = try! NSRegularExpression(
        pattern: #"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)+\|?\s*$"#,
        options: [.anchorsMatchLines]
    )
    // swiftlint:enable force_try

    /// Apply a precompiled regex to `input` with the given replacement template,
    /// in-place. Keeps call sites as one-liners.
    private static func apply(_ regex: NSRegularExpression, to input: inout String, with template: String) {
        let range = NSRange(input.startIndex..., in: input)
        input = regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: template)
    }

    /// Strip markdown syntax AND non-prose regions in preparation for word counting.
    /// More aggressive than `stripMarkdownSyntax`: also removes fenced code blocks,
    /// math (`$…$`, `$$…$$`), HTML tags/comments, YAML frontmatter, reference-style
    /// link definitions, Pandoc attribute blocks (`{#id}`, `{.class}`, `{key=val}`),
    /// task checkbox markers, and table pipes. Em- and en-dashes are converted to
    /// spaces so that `word—word` counts as two words.
    ///
    /// Pandoc citations are NOT stripped — they are rendered-count via placeholder
    /// substitution: `[@key]` → 2 tokens ("Smith 2020"), `[-@key]` → 1 token ("2020"),
    /// locator words inside the bracket preserved. This matches journal word counts.
    ///
    /// Ordering note: citation substitution runs AFTER `stripMarkdownSyntax` (which
    /// removes backticks so `` `[@x]` `` → `[@x]`) and AFTER the HTML-tag strip
    /// (which removes autolinks so `<alice@host.org>` doesn't trigger the `@key`
    /// regex). Do not reorder without updating the citation tests.
    static func stripForWordCount(from content: String) -> String {
        var result = content

        // YAML frontmatter at start of document
        apply(rxYAMLFrontmatter, to: &result, with: "")

        // Fenced code blocks (``` and ~~~) — entire block including content
        apply(rxFencedCodeBacktick, to: &result, with: "")
        apply(rxFencedCodeTilde, to: &result, with: "")

        // HTML comments (catches annotation comments and any other)
        apply(rxHTMLComment, to: &result, with: "")

        // Display math: $$ ... $$
        apply(rxDisplayMath, to: &result, with: "")

        // Inline math: $ ... $ (Pandoc rule — see regex comment)
        apply(rxInlineMath, to: &result, with: "")

        // Reference-style link definitions: [label]: url (excludes footnote defs [^N]:)
        apply(rxReferenceLinkDef, to: &result, with: "")

        // Inline reference-style links: [text][ref] → text (excludes footnotes [^N])
        apply(rxInlineReferenceLink, to: &result, with: "$1")

        // Run the inline syntax stripper for headings, bold/italic, strikethrough,
        // links, images, list markers, blockquotes, footnote refs/defs, horizontal
        // rules, section breaks, code-fence language markers, inline code, annotations.
        result = stripMarkdownSyntax(from: result)

        // Remaining HTML tags (after stripMarkdownSyntax). Running BEFORE the
        // citation substitution so `<alice@host.org>` is gone before @key scans.
        apply(rxHTMLTag, to: &result, with: "")

        // Pandoc citations — render-then-count. Order within this group matters:
        // 1. -@key → " CIT " (suppress author: renders to year only, 1 word)
        // 2. @key → " CIT CIT " (full: renders to name + year, 2 words)
        // 3. Outer [ … CIT … ] → inner content (locator words pass through)
        apply(rxCitationSuppressAuthor, to: &result, with: Self.citSingle)
        apply(rxCitationKey, to: &result, with: Self.citDouble)
        apply(rxCitationBracket, to: &result, with: "$1")

        // Pandoc attribute blocks: {#id}, {.class}, {key=val}
        apply(rxPandocAttrs, to: &result, with: "")

        // Task checkbox markers at start of (now-de-listed) lines: [ ] or [x]
        apply(rxTaskCheckbox, to: &result, with: "")

        // Table separator rows: |---|:--:|
        apply(rxTableSeparator, to: &result, with: "")

        // Table cell separators: pipe → space (so cells split into words)
        result = result.replacingOccurrences(of: "|", with: " ")

        // Em- and en-dashes split adjacent words
        result = result.replacingOccurrences(of: "\u{2014}", with: " ")
        result = result.replacingOccurrences(of: "\u{2013}", with: " ")

        return result
    }

    /// Ensures markdown content ends with exactly one blank line (`\n\n`), so it can be
    /// safely concatenated with more content after it without gluing the next section's
    /// header onto this content's last line. A no-op if content is already empty or
    /// already properly terminated.
    static func ensuringTrailingBlankLine(_ content: String) -> String {
        if content.isEmpty { return content }
        if content.hasSuffix("\n\n") { return content }
        if content.hasSuffix("\n") { return content + "\n" }
        return content + "\n\n"
    }
}
