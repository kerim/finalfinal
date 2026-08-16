//
//  MarkdownUtils.swift
//  final final
//
//  Utilities for processing markdown text, including stripping syntax
//  for accurate word counts.
//

import Foundation

enum MarkdownUtils {
    /// The three "code" shapes that must never contribute a false citekey match: fenced code
    /// blocks (``` and ~~~) and inline code (`...`). Shared between `stripCodeContent`
    /// (deletes each match) and `maskCodeContent` (blanks each match to same-length
    /// whitespace, preserving every other character's offset) so the two functions can never
    /// silently drift apart on what counts as "code". Order matches `stripCodeContent`'s
    /// original three `replacingOccurrences` calls (fenced-backtick, then fenced-tilde, then
    /// inline) -- unchanged by this hoist. Compile-time constant patterns: a `try?` failure
    /// here would be a programming error (a typo), so a failed pattern is simply dropped
    /// rather than crashing -- matches `stripCodeContent`'s own pre-hoist error handling,
    /// which silently no-op'd a pattern that failed to compile.
    private static let codeContentPatterns: [NSRegularExpression] = [
        #"```[\s\S]*?```"#,
        #"~~~[\s\S]*?~~~"#,
        #"`[^`]+`"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Remove fenced code blocks and inline code from markdown.
    /// Used before citekey extraction to prevent false positives from examples.
    static func stripCodeContent(from markdown: String) -> String {
        var result = markdown
        for pattern in codeContentPatterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        return result
    }

    /// Mask fenced code blocks and inline code in markdown by replacing each match with a run
    /// of space characters of IDENTICAL UTF-16 length, so `masked.utf16.count ==
    /// markdown.utf16.count` always. Unlike `stripCodeContent` (which deletes matches --
    /// exactly right for word counts, where losing the code's contribution to length is the
    /// point), this is for callers that need to scan for other content while excluding code
    /// (e.g. citekey rewriting) but then apply an edit back onto the ORIGINAL, unmasked
    /// string at an offset found via the mask -- deleting the matched text would shift every
    /// later offset and corrupt that edit.
    ///
    /// Each match is replaced by a run of exactly `match.range.length` space characters --
    /// built per-`NSRange` from a fresh `String(repeating:count:)`, never by mapping
    /// `Character`s one-to-one: an emoji or other surrogate-pair character inside a code span
    /// occupies 2 UTF-16 code units but iterates as a single `Character`, so a naive
    /// `Character`-for-`Character` replacement would silently shrink the UTF-16 length and
    /// shift every subsequent offset -- exactly the corruption this function exists to avoid.
    static func maskCodeContent(in markdown: String) -> String {
        var result = markdown
        for pattern in codeContentPatterns {
            result = maskMatches(of: pattern, in: result)
        }
        return result
    }

    /// Replace each match of `pattern` in `input` with a run of spaces of the same UTF-16
    /// length as the match, leaving every other character -- and the string's total UTF-16
    /// length -- untouched. Helper for `maskCodeContent`.
    private static func maskMatches(of pattern: NSRegularExpression, in input: String) -> String {
        let nsInput = input as NSString
        let fullRange = NSRange(location: 0, length: nsInput.length)
        var result = ""
        var lastEnd = 0

        pattern.enumerateMatches(in: input, options: [], range: fullRange) { match, _, _ in
            guard let match else { return }
            if match.range.location > lastEnd {
                result += nsInput.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            }
            result += String(repeating: " ", count: match.range.length)
            lastEnd = match.range.location + match.range.length
        }

        if lastEnd < nsInput.length {
            result += nsInput.substring(with: NSRange(location: lastEnd, length: nsInput.length - lastEnd))
        }

        return result
    }

    /// Strip markdown syntax from content to get plain text
    /// Used for accurate word counting that excludes formatting symbols
    ///
    /// - Parameter stripListMarkers: Whether to remove a leading `- `/`* `/`+ `/`N. `
    ///   list marker at the start of each line. Defaults to `true` for callers
    ///   stripping syntax out of genuine list/paragraph markdown. Callers that
    ///   already know the text belongs to a heading or a code block — which
    ///   can never actually BE a markdown list (e.g.
    ///   `BlockParser.extractTextContent`) — must pass `false`: a heading
    ///   titled "3. Title", or a numbered step inside a code sample, starts
    ///   with the same shape as an ordered-list marker, but it isn't one, and
    ///   this regex can't tell the difference from the string alone.
    ///   `BlockParser.extractTextContent` also passes `false` for
    ///   blockquotes, but for a different reason: "> 1. First item" IS a
    ///   normal markdown shape (an ordered list nested inside a blockquote),
    ///   so this regex genuinely cannot distinguish a quoted list from quoted
    ///   text that merely looks like one — preserving the literal text is the
    ///   safer default there.
    static func stripMarkdownSyntax(from content: String, stripListMarkers: Bool = true) -> String {
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

        // Remove list markers: - * + or 1. 2. etc (unless the caller already
        // knows this isn't really list content -- see stripListMarkers's doc)
        if stripListMarkers {
            result = strippingListMarkers(from: result)
        }

        // Remove blockquote markers: > at line start
        let blockquotePattern = "^>+\\s*"
        if let regex = try? NSRegularExpression(pattern: blockquotePattern, options: .anchorsMatchLines) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Remove section break markers: <!-- ::break:: -->
        // Deliberately a substring removal (matches the marker ANYWHERE in
        // `content`), not an exact/first-line equality check like
        // BlockParser.isSectionBreakMarker uses for classification. The two
        // are answering different questions over different-shaped input:
        // this strips marker syntax out of already-composed, heterogeneous
        // text (a whole `section.markdownContent` spanning marker + body,
        // or a single pre-split display paragraph) purely for word-count/
        // preview display, regardless of where the marker sits in that
        // string. BlockParser's check instead classifies ONE raw block's
        // own text as section-break-or-not, where a marker appearing
        // mid-sentence must NOT count (see
        // BlockParserSectionBreakClassificationTests.swift for that
        // distinction). Confirmed by
        // tracing every call site (BlockParser.extractTextContent,
        // MarkdownContentView.parseTextBlock, DocumentPreviewView) — none of
        // them feed this function a value that's supposed to answer the
        // classification question, so this pattern intentionally stays a
        // plain substring strip.
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

    /// Remove a leading `- `/`* `/`+ `/`N. ` list marker at the start of each line.
    /// Split out of `stripMarkdownSyntax` so that function's own complexity doesn't
    /// grow with this conditional step -- see `stripMarkdownSyntax`'s `stripListMarkers`
    /// parameter for why this is sometimes skipped.
    private static func strippingListMarkers(from content: String) -> String {
        let listPattern = "^\\s*(?:[-*+]|\\d+\\.)\\s+"
        guard let regex = try? NSRegularExpression(pattern: listPattern, options: .anchorsMatchLines) else {
            return content
        }
        let range = NSRange(content.startIndex..., in: content)
        return regex.stringByReplacingMatches(in: content, options: [], range: range, withTemplate: "")
    }

    /// Strip `==highlight==` markers from markdown content, reducing highlighted text to
    /// plain text. Highlight *rendering* is not implemented for exported documents
    /// (PDF/DOCX/ODT) — see `ExportService.preprocessContentForExport(_:settings:)`, the
    /// only call site — so a raw `==` marker surviving into that output is meaningless
    /// literal punctuation, not preserved formatting, and gets stripped unconditionally
    /// regardless of `ExportSettings.includeAnnotations` (a different concept: authoring
    /// comments, not text formatting).
    ///
    /// Implementation is a SINGLE regex pass over one alternation: each match is either
    /// (a) a "protected" region — a fenced code block (``` or ~~~), inline code, display
    /// math (`$$...$$`), or inline math (`$...$`) — copied through completely unchanged,
    /// or (b) a highlight marker, replaced by its inner text (dropping the `==` delimiters).
    /// Alternation order tries protected regions before the highlight alternative, but
    /// that ONLY resolves a tie when a protected region and a highlight would otherwise
    /// start matching at the exact same offset — it provides NO protection when a
    /// highlight's opening `==` sits to the LEFT of a protected region's start. E.g.
    /// `` ==this is `x==y` important== `` still lets the highlight's inner match swallow
    /// into the code span and corrupt its content (see the KNOWN GAPS list below).
    ///
    /// `toggleHighlight()` in the CodeMirror source editor (web/codemirror/src/api.ts)
    /// wraps a raw selection — verbatim, with no newline check — in `==...==`, and
    /// Milkdown's own highlight-parsing regex accepts embedded newlines too, so
    /// `==foo\nbar==` is a real, reachable highlight shape in this app, not a
    /// hypothetical. The highlight alternative —
    /// `((?<!=)==(?!=)((?:(?!==)[\s\S])+?)==)` — therefore allows the inner text to span
    /// multiple lines and to start or end with whitespace (both reachable via an ordinary
    /// double-click/drag-select that catches a leading or trailing space before applying
    /// the mark). What it rejects is an opening `==` that sits anywhere inside a run of
    /// three-or-more `=` characters — the shape of a setext heading underline
    /// (`Title\n=====`) — via a pair of one-character guards directly on the opening
    /// marker: `(?<!=)` refuses to start a match immediately after another `=` (so the
    /// regex engine can't retry two characters into the same run and succeed there
    /// instead — which is exactly how an EARLIER version of this guard, a single
    /// `(?!=*==)` lookahead with no lookbehind, still leaked `==` on a 5-`=` underline:
    /// the attempt at the run's first `=` correctly failed, but the engine simply retried
    /// starting two characters later, inside the same run, and that retry succeeded), and
    /// `(?!=)` refuses to start a match when the character immediately after the opening
    /// `==` is itself `=` (closing the remaining hole the lookbehind alone leaves open: on
    /// a 3-`=` underline exactly ONE `=` is left over after consuming the opening `==`,
    /// and the old `(?!=*==)` lookahead only fired when that leftover run connected
    /// *directly* to another `==` with nothing in between — so the single leftover `=`
    /// was accepted as ordinary inner text and the match swallowed forward through
    /// newlines and prose looking for the next `==` it could find, which could be a wholly
    /// unrelated real highlight later in the document). Together the two guards mean the
    /// only valid opening `==` in a pure `=` run is one immediately preceded AND followed
    /// by non-`=` characters, which never happens inside a run of 3 OR MORE `=` — so a
    /// setext underline of 3+ characters (`Title\n===`, `Title\n=====`, ...) is protected
    /// regardless of length. A 2-character underline (`Title\n==`) is NOT protected by
    /// these guards — it IS a bare `==`, indistinguishable from an ordinary highlight
    /// marker, so it falls into the document-wide ambiguity gap documented below rather
    /// than being specially recognized as a heading underline. An unmatched/unbalanced
    /// single `==` (no closing pair anywhere in the document) never matches at all and is
    /// left untouched rather than deleted.
    ///
    /// KNOWN GAPS (this is regex-based text substitution, not a real markdown parser —
    /// accepted, intentionally not fixed this round):
    /// - Two independent, unrelated `==` occurrences ANYWHERE in the document — not
    ///   confined to one line, or even one paragraph — can pair up across paragraph and
    ///   blank-line boundaries and collapse ambiguously into a single stripped span,
    ///   because the inner group can't tell, from the raw markers alone, where one
    ///   highlight ends and the next (or a stray non-highlight `==`) begins. This can
    ///   silently corrupt everything in between, and can even swallow a REAL
    ///   `==...==` highlight that happens to sit between the two stray markers — leaking
    ///   that highlight's own closing `==` into the output, i.e. reintroducing the exact
    ///   bug this function exists to fix. `x==y and p==q` colliding on one line is the
    ///   simplest case, but `value==threshold` in one paragraph pairing with an unrelated
    ///   `a==b` two paragraphs later behaves identically — this is inherent to the
    ///   `==...==` syntax, not a bug specific to one scope, and not a bug here — Pandoc's
    ///   own `mark` extension has the identical limitation.
    ///   Bounding the highlight's inner match to a single paragraph (rejecting a match
    ///   whose inner text crosses a blank line) was considered as a narrower fix, but was
    ///   rejected: it isn't just theoretically unsound, it's confirmed-unreachable-safe to
    ///   assume highlights stay within one paragraph. `toggleHighlight()` in the
    ///   CodeMirror source editor (web/codemirror/src/api.ts) wraps whatever text is
    ///   selected verbatim, with no check for a blank line in the selection, and
    ///   Milkdown's own toggle (web/milkdown/src/api-annotations.ts, wired to the shared
    ///   selection toolbar's Highlight button and ⌘⇧H) applies the mark via
    ///   `tr.addMark(from, to, …)`, which ProseMirror happily applies across multiple
    ///   paragraph nodes in one selection. So a highlight spanning a blank line is a real,
    ///   reachable shape in both editors, not a hypothetical — bounding by paragraph would
    ///   turn that legitimate case into an unstripped `==` leak instead, trading one gap
    ///   for another rather than closing it. See
    ///   `stripHighlightMarkersAmbiguousMultipleOnOneLineIsADocumentedGap` and
    ///   `stripHighlightMarkersAmbiguousMultipleAcrossParagraphsIsADocumentedGap` in
    ///   ExportIntegrityTests.swift for the exact (documented) resulting output.
    /// - A highlight whose opening `==` sits to the left of a protected region's start,
    ///   e.g. `` ==this is `x==y` important== ``, can have its inner match swallow into
    ///   the code span and alter its content, because alternation order only disambiguates
    ///   same-offset ties (see above).
    /// - Indented (4-space) code blocks are NOT in the protected-region list — only
    ///   fenced (``` / ~~~) blocks are — so `==` inside an indented code block still gets
    ///   stripped as if it were prose.
    /// - Two-or-more `==` pairs inside a URL or base64 data URI on one line (e.g. a data
    ///   URI's base64 padding, or two `==`-separated query-string values) can get
    ///   corrupted, since the mechanism has no way to distinguish these from ordinary
    ///   prose highlights.
    static func stripHighlightMarkers(from markdown: String) -> String {
        guard markdown.contains("==") else { return markdown }

        // Group numbers (used below to decide verbatim-copy vs. strip-to-inner-text):
        //   1 = fenced code block (```)      2 = fenced code block (~~~)
        //   3 = inline code (`...`)          4 = display math ($$...$$)
        //   5 = inline math ($...$)          6 = full highlight match (==...==)
        //   7 = highlight inner text (captured content between the == markers)
        let pattern = #"""
        (```[\s\S]*?```)|(~~~[\s\S]*?~~~)|(`[^`]+`)|(\$\$[\s\S]+?\$\$)|\#
        ((?<![A-Za-z0-9$])\$(?=\S)[^\$\n]+?(?<=\S)\$(?![A-Za-z0-9$]))|((?<!=)==(?!=)((?:(?!==)[\s\S])+?)==)
        """#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            // Unreachable unless the literal pattern above is edited into an invalid one.
            // Degrade to the input unchanged (highlights export with their `==` markers
            // intact) rather than crashing an export on a programming error.
            DebugLog.log(.fileOps, "[MarkdownUtils] stripHighlightMarkers: highlight pattern failed to compile; returning input unchanged")
            return markdown
        }

        let nsMarkdown = markdown as NSString
        let fullRange = NSRange(location: 0, length: nsMarkdown.length)
        var result = ""
        var lastEnd = 0

        regex.enumerateMatches(in: markdown, options: [], range: fullRange) { match, _, _ in
            guard let match else { return }

            // Copy any text between the previous match and this one through unchanged.
            if match.range.location > lastEnd {
                result += nsMarkdown.substring(
                    with: NSRange(location: lastEnd, length: match.range.location - lastEnd)
                )
            }

            let highlightInner = match.range(at: 7)
            if highlightInner.location != NSNotFound {
                // Highlight marker: keep only the inner text, dropping the `==` delimiters.
                result += nsMarkdown.substring(with: highlightInner)
            } else {
                // Protected region (code/math): copy through completely unchanged.
                result += nsMarkdown.substring(with: match.range)
            }

            lastEnd = match.range.location + match.range.length
        }

        if lastEnd < nsMarkdown.length {
            result += nsMarkdown.substring(with: NSRange(location: lastEnd, length: nsMarkdown.length - lastEnd))
        }

        return result
    }

    /// The image markdown pattern used by `strippingImages(from:)`: `![alt](url){attrs}`,
    /// with an OPTIONAL trailing `{...}` attribute block (Pandoc width/attrs syntax), a
    /// `\s*` allowance before that block so a space-separated attribute block (`![alt](x.png)
    /// {width=50%}` -- legal Pandoc, and what a hand-typed or pasted attribute block often
    /// looks like) is still recognized as part of the image rather than left behind as a
    /// stray, visible `{width=50%}` in the "Markdown Only" export, a deliberately permissive
    /// URL group (`[^)]*`, not `[^)]+`) so a hand-typed or pasted `![]()` placeholder is
    /// stripped too, and an escape-aware bracket-text group (`(?:[^\]\\]|\\.)*`, not a bare
    /// `[^\]]*`) so a caption containing an escaped bracket (`\]`) doesn't prematurely end the
    /// match -- same escape-aware approach `BlockParser.parseImageFragmentMeta`
    /// (BlockParser+Images.swift) uses for the identical reason.
    ///
    /// Close cousin of, but NOT unified with, `stripMarkdownSyntax`'s own inline image
    /// pattern (`imagePattern`, above): that one requires a non-empty URL (`[^)]+`) and a
    /// plain (non-escape-aware) bracket group, matching real generated markdown exactly for
    /// word-count purposes, where under-matching is safer than over-matching. Unifying the
    /// two risked silently changing `stripMarkdownSyntax`'s well-tested word-count behavior
    /// for the sake of one shared constant -- not worth the risk, so these stay two
    /// deliberately separate, slightly different patterns for two different callers with two
    /// different jobs.
    private static let imageStripPattern = try? NSRegularExpression(
        pattern: #"!\[(?:[^\]\\]|\\.)*\]\([^)]*\)(\s*\{[^}]*\})?"#
    )

    /// Remove image markdown (`![alt](url){attrs}`) from `markdown`, leaving fenced code
    /// blocks and inline code spans untouched -- e.g. an image reference someone typed
    /// inside a code fence to DOCUMENT markdown image syntax survives verbatim instead of
    /// being stripped as if it were a real image.
    ///
    /// Implemented by scanning `MarkdownUtils.maskCodeContent(in:)`'s masked (length-
    /// preserving) copy of `markdown` for matches -- so a real image inside code content is
    /// invisible to the pattern, since that span is now all spaces in the masked copy -- and
    /// then applying the removal to the ORIGINAL, unmasked string at those same offsets, so
    /// code content itself is copied through byte-for-byte rather than reconstructed from
    /// the mask. Used for the "Markdown Only" export (plain text, no images, no sidecar
    /// image folder) -- see `BlockParser.assembleMarkdownOnlyForExport`, the sole call site.
    static func strippingImages(from markdown: String) -> String {
        guard let pattern = imageStripPattern else { return markdown }

        let masked = maskCodeContent(in: markdown)
        let nsMarkdown = markdown as NSString
        let fullRange = NSRange(location: 0, length: nsMarkdown.length)
        var result = ""
        var lastEnd = 0

        pattern.enumerateMatches(in: masked, options: [], range: fullRange) { match, _, _ in
            guard let match else { return }
            if match.range.location > lastEnd {
                result += nsMarkdown.substring(
                    with: NSRange(location: lastEnd, length: match.range.location - lastEnd)
                )
            }
            lastEnd = match.range.location + match.range.length
        }

        if lastEnd < nsMarkdown.length {
            result += nsMarkdown.substring(with: NSRange(location: lastEnd, length: nsMarkdown.length - lastEnd))
        }

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
