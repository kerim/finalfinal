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
        var work = GuardedText(content)
        strippingSyntax(&work, stripListMarkers: stripListMarkers)
        return work.text
    }

    /// The body of `stripMarkdownSyntax`, working on a `GuardedText` so `stripForWordCount` can hand over a text whose
    /// character scan is already current. Every pattern is compiled once (`rxStrip...`, further down) and is run only when
    /// the text holds the characters it needs (see `GuardedText`), so a plain paragraph costs one scan instead of sixteen
    /// regular-expression passes. The order of the steps is unchanged.
    private static func strippingSyntax(_ work: inout GuardedText, stripListMarkers: Bool) {
        // Remove heading markers: # ## ### etc at line start
        work.replace(rxStripHeadingMarker, with: "") { $0.hash }

        // Remove bold/italic markers: ** __ * _
        // Handle bold first (** and __), then italic (* and _)
        work.replace(rxStripBold, with: "$1$2") { $0.doubleStar || $0.doubleUnderscore }
        work.replace(rxStripItalic, with: "$1$2") { $0.star || $0.underscore }

        // Remove strikethrough: ~~text~~
        work.replace(rxStripStrikethrough, with: "$1") { $0.doubleTilde }

        // Remove highlight markers: ==text==
        work.replace(rxStripHighlight, with: "$1") { $0.doubleEquals }

        // Remove inline code backticks: `code`
        work.replace(rxStripInlineCode, with: "$1") { $0.backtick }

        // Remove images ![alt](url){width=N%} entirely (don't count alt text as words).
        // MUST run before the link stripper, otherwise the link regex matches
        // [alt](url) inside the image syntax and leaves a stray `!alt text` behind.
        work.replace(rxStripImage, with: "") { $0.imageOpen && $0.linkJoin }

        // Convert links [text](url) to just text. Negative lookbehind `(?<!!)`
        // is belt-and-braces in case the image stripper missed an unusual variant.
        work.replace(rxStripLink, with: "$1") { $0.linkJoin }

        // Remove list markers: - * + or 1. 2. etc (unless the caller already
        // knows this isn't really list content -- see stripListMarkers's doc)
        if stripListMarkers {
            work.replace(rxStripListMarker, with: "") { $0.dash || $0.star || $0.plus || $0.dot }
        }

        // Remove blockquote markers: > at line start
        work.replace(rxStripBlockquoteMarker, with: "") { $0.greaterThan }

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
        work.replace(rxStripSectionBreak, with: "") { $0.breakMarker }

        // Remove code fence markers: ```language
        work.replace(rxStripCodeFenceMarker, with: "") { $0.fence }

        // Remove horizontal rules: ---, ***, ___
        work.replace(rxStripHorizontalRule, with: "") { $0.dash || $0.star || $0.underscore }

        // Remove footnote references: [^1], [^2], etc.
        work.replace(rxStripFootnoteReference, with: "") { $0.footnoteOpen }

        // Remove footnote definition prefixes: [^1]: at line start
        work.replace(rxStripFootnoteDefinitionPrefix, with: "") { $0.footnoteOpen }

        // Remove annotations: <!-- ::type:: content -->
        work.replace(rxAnnotation, with: "") { $0.commentOpen }
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

        guard let regex = highlightMarkerRegex else {
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

    /// The one alternation `stripHighlightMarkers` runs, compiled once (it used to be compiled on every call).
    ///
    /// Group numbers (used by the function to decide verbatim-copy vs. strip-to-inner-text):
    ///   1 = fenced code block (```)      2 = fenced code block (~~~)
    ///   3 = inline code (`...`)          4 = display math ($$...$$)
    ///   5 = inline math ($...$)          6 = full highlight match (==...==)
    ///   7 = highlight inner text (captured content between the == markers)
    private static let highlightMarkerRegex: NSRegularExpression? = {
        let pattern = #"""
        (```[\s\S]*?```)|(~~~[\s\S]*?~~~)|(`[^`]+`)|(\$\$[\s\S]+?\$\$)|\#
        ((?<![A-Za-z0-9$])\$(?=\S)[^\$\n]+?(?<=\S)\$(?![A-Za-z0-9$]))|((?<!=)==(?!=)((?:(?!==)[\s\S])+?)==)
        """#
        return try? NSRegularExpression(pattern: pattern)
    }()

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
        // Pattern (`rxAnnotation`) matches: <!-- ::word:: any content -->
        // This handles task, comment, reference, break, and auto-bibliography annotations
        var work = GuardedText(content)
        work.replace(rxAnnotation, with: "") { $0.commentOpen }
        return work.text
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
        // Each step runs only when the text, as it is at that step, holds the characters its pattern needs (`GuardedText`);
        // output is identical to running every step unconditionally.
        var work = GuardedText(content)

        // YAML frontmatter at start of document
        work.replace(rxYAMLFrontmatter, with: "") { $0.startsWithFrontmatterFence }

        // Fenced code blocks (``` and ~~~) — entire block including content
        work.replace(rxFencedCodeBacktick, with: "") { $0.fence }
        work.replace(rxFencedCodeTilde, with: "") { $0.tildeFence }

        // HTML comments (catches annotation comments and any other)
        work.replace(rxHTMLComment, with: "") { $0.commentOpen }

        // Display math: $$ ... $$
        work.replace(rxDisplayMath, with: "") { $0.displayMath }

        // Inline math: $ ... $ (Pandoc rule — see regex comment)
        work.replace(rxInlineMath, with: "") { $0.dollar }

        // Reference-style link definitions: [label]: url (excludes footnote defs [^N]:)
        work.replace(rxReferenceLinkDef, with: "") { $0.referenceDefinitionJoin }

        // Inline reference-style links: [text][ref] → text (excludes footnotes [^N])
        work.replace(rxInlineReferenceLink, with: "$1") { $0.referenceLinkJoin }

        // Run the inline syntax stripper for headings, bold/italic, strikethrough,
        // links, images, list markers, blockquotes, footnote refs/defs, horizontal
        // rules, section breaks, code-fence language markers, inline code, annotations.
        strippingSyntax(&work, stripListMarkers: true)

        // Remaining HTML tags (after stripMarkdownSyntax). Running BEFORE the
        // citation substitution so `<alice@host.org>` is gone before @key scans.
        work.replace(rxHTMLTag, with: "") { $0.lessThan && $0.greaterThan }

        // Pandoc citations — render-then-count. Order within this group matters:
        // 1. -@key → " CIT " (suppress author: renders to year only, 1 word)
        // 2. @key → " CIT CIT " (full: renders to name + year, 2 words)
        // 3. Outer [ … CIT … ] → inner content (locator words pass through)
        work.replace(rxCitationSuppressAuthor, with: Self.citSingle, mayKeepLength: true) { $0.suppressedCitation }
        work.replace(rxCitationKey, with: Self.citDouble, mayKeepLength: true) { $0.atSign }
        work.replace(rxCitationBracket, with: "$1") { $0.openBracket && $0.citationPlaceholder }

        // Pandoc attribute blocks: {#id}, {.class}, {key=val}
        work.replace(rxPandocAttrs, with: "") { $0.openBrace }

        // Task checkbox markers at start of (now-de-listed) lines: [ ] or [x]
        work.replace(rxTaskCheckbox, with: "") { $0.openBracket }

        // Table separator rows: |---|:--:|
        work.replace(rxTableSeparator, with: "") { $0.pipe && $0.dash }

        // Table cell separators: pipe → space (so cells split into words)
        work.replaceLiteral("|", with: " ") { $0.pipe }

        // Em- and en-dashes split adjacent words
        work.replaceLiteral("\u{2014}", with: " ") { $0.emDash }
        work.replaceLiteral("\u{2013}", with: " ") { $0.enDash }

        return work.text
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

// MARK: - Fast paths for the strip functions

// These are an extension, in this file, only so the helpers do not count against the length of `MarkdownUtils` itself; their
// `private` members are visible to the functions above.
extension MarkdownUtils {
    // swiftlint:disable force_try
    //
    // The patterns of `stripMarkdownSyntax` and `stripAnnotations` (they used to be compiled on every call: sixteen
    // compilations per block, twice per block when parsing). Same pattern text, same options, same order of use.
    private static let rxStripHeadingMarker = try! NSRegularExpression(
        pattern: "^#{1,6}\\s+", options: .anchorsMatchLines
    )
    private static let rxStripBold = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*|__(.+?)__")
    private static let rxStripItalic = try! NSRegularExpression(pattern: "\\*([^*]+)\\*|_([^_]+)_")
    private static let rxStripStrikethrough = try! NSRegularExpression(pattern: "~~(.+?)~~")
    private static let rxStripHighlight = try! NSRegularExpression(pattern: "==(.+?)==")
    private static let rxStripInlineCode = try! NSRegularExpression(pattern: "`([^`]+)`")
    private static let rxStripImage = try! NSRegularExpression(pattern: "!\\[[^\\]]*\\]\\([^)]+\\)(\\s*\\{[^}]*\\})?")
    private static let rxStripLink = try! NSRegularExpression(pattern: "(?<!!)\\[([^\\]]+)\\]\\([^)]+\\)")
    private static let rxStripListMarker = try! NSRegularExpression(
        pattern: "^\\s*(?:[-*+]|\\d+\\.)\\s+", options: .anchorsMatchLines
    )
    private static let rxStripBlockquoteMarker = try! NSRegularExpression(
        pattern: "^>+\\s*", options: .anchorsMatchLines
    )
    private static let rxStripSectionBreak = try! NSRegularExpression(pattern: "<!--\\s*::break::\\s*-->")
    private static let rxStripCodeFenceMarker = try! NSRegularExpression(
        pattern: "^```[a-zA-Z]*\\s*$", options: .anchorsMatchLines
    )
    private static let rxStripHorizontalRule = try! NSRegularExpression(
        pattern: "^[-*_]{3,}\\s*$", options: .anchorsMatchLines
    )
    private static let rxStripFootnoteReference = try! NSRegularExpression(pattern: "\\[\\^\\d+\\](?!:)")
    private static let rxStripFootnoteDefinitionPrefix = try! NSRegularExpression(
        pattern: "^\\[\\^\\d+\\]:\\s*", options: .anchorsMatchLines
    )
    private static let rxAnnotation = try! NSRegularExpression(pattern: "<!--\\s*::\\w+::\\s*[\\s\\S]*?-->")
    // swiftlint:enable force_try

    // MARK: - Cheap "can this pattern match at all" checks

    /// Which of the characters and short literals the patterns of `stripMarkdownSyntax` and `stripForWordCount` need occur in
    /// a text, found by `memchr` / `memmem` over its UTF-8 bytes. Everything looked for is ASCII (plus the two dashes of
    /// `stripForWordCount`, searched as their UTF-8 bytes), and UTF-8 never uses a byte of one character inside another
    /// character's bytes, so a byte string is present exactly when the characters are. A flag is only used to SKIP a step
    /// that needs the characters it names, spelled out in the pattern as adjacent literals, to match anything, so skipping it
    /// when they are absent cannot change the result. A multi-byte literal is only searched for when its single bytes are all
    /// present; the flag still means exactly "the literal occurs" (an occurrence needs each of its bytes).
    private struct SyntaxPresence {
        var hash = false
        var star = false
        var underscore = false
        var plus = false
        var dash = false
        var dot = false
        var backtick = false
        var greaterThan = false
        var lessThan = false
        var openBracket = false
        var openBrace = false
        var pipe = false
        var atSign = false
        var dollar = false
        var doubleStar = false
        var doubleUnderscore = false
        var doubleTilde = false
        var doubleEquals = false
        var displayMath = false
        /// `![`
        var imageOpen = false
        /// `](`
        var linkJoin = false
        /// `]:`
        var referenceDefinitionJoin = false
        /// `][`
        var referenceLinkJoin = false
        /// `[^`
        var footnoteOpen = false
        /// `<!--`
        var commentOpen = false
        /// `::break::`
        var breakMarker = false
        /// three backticks
        var fence = false
        /// three tildes
        var tildeFence = false
        /// `-@`
        var suppressedCitation = false
        /// `CIT`, the placeholder `stripForWordCount` substitutes for a citation. Searched only when `[` is present, because the
        /// one step that reads it (the bracket around a citation) needs both.
        var citationPlaceholder = false
        var emDash = false
        var enDash = false
        /// The text begins with `---` (the only place a YAML front-matter block can start)
        var startsWithFrontmatterFence = false

        init() {}

        init(scanning buffer: UnsafeBufferPointer<UInt8>) {
            guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
            let count = buffer.count
            func has(_ byte: UInt8) -> Bool { memchr(base, Int32(byte), count) != nil }
            func has(_ literal: StaticString) -> Bool {
                memmem(base, count, literal.utf8Start, literal.utf8CodeUnitCount) != nil
            }
            hash = has(0x23)
            star = has(0x2A)
            underscore = has(0x5F)
            plus = has(0x2B)
            dash = has(0x2D)
            dot = has(0x2E)
            backtick = has(0x60)
            greaterThan = has(0x3E)
            lessThan = has(0x3C)
            openBracket = has(0x5B)
            openBrace = has(0x7B)
            pipe = has(0x7C)
            atSign = has(0x40)
            dollar = has(0x24)
            let tilde = has(0x7E)
            let equals = has(0x3D)
            let bang = has(0x21)
            let closeBracket = has(0x5D)
            let openParen = has(0x28)
            let colon = has(0x3A)
            let caret = has(0x5E)
            doubleStar = star && has("**")
            doubleUnderscore = underscore && has("__")
            doubleTilde = tilde && has("~~")
            doubleEquals = equals && has("==")
            displayMath = dollar && has("$$")
            imageOpen = bang && openBracket && has("![")
            linkJoin = closeBracket && openParen && has("](")
            referenceDefinitionJoin = closeBracket && colon && has("]:")
            referenceLinkJoin = closeBracket && openBracket && has("][")
            footnoteOpen = openBracket && caret && has("[^")
            commentOpen = lessThan && bang && has("<!--")
            breakMarker = colon && has("::break::")
            fence = backtick && has("```")
            tildeFence = tilde && has("~~~")
            suppressedCitation = dash && atSign && has("-@")
            citationPlaceholder = openBracket && has("CIT")
            let possibleDash = has(0xE2)
            emDash = possibleDash && has("\u{2014}")
            enDash = possibleDash && has("\u{2013}")
            startsWithFrontmatterFence = count >= 3 && base[0] == 0x2D && base[1] == 0x2D && base[2] == 0x2D
        }
    }

    /// A text that remembers which characters it holds. Each step asks `replace(...)` to run a pattern only if the text, AS IT
    /// IS WHEN THE STEP RUNS, holds what the pattern needs. The scan is redone after a step that changed the text (a removal
    /// can bring two characters together that were apart: dropping the `**` of `!**[a**](b)` leaves the image `![a](b)`) and
    /// is kept while the text is untouched.
    private struct GuardedText {
        private(set) var text: String
        private var presence = SyntaxPresence()
        private var presenceIsCurrent = false

        init(_ text: String) {
            self.text = text
        }

        /// Replace every match of `regex` with `template`, but only if `needs` holds for the characters the text holds now.
        ///
        /// After a run the scan stays valid if nothing matched. That is read from the length: a pattern that replaces its
        /// (never empty) match with `""` or with a capture group inside the match always makes the text SHORTER, so an
        /// unchanged length means no match. A pattern that substitutes text of its own (the citation placeholders) can
        /// produce exactly the length of what it replaced (`@zhao2020` is nine characters, and so is ` CIT CIT `), so it
        /// passes `mayKeepLength` and the scan is always redone.
        mutating func replace(
            _ regex: NSRegularExpression,
            with template: String,
            mayKeepLength: Bool = false,
            if needs: (SyntaxPresence) -> Bool
        ) {
            refreshPresence()
            guard needs(presence) else { return }
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
            presenceIsCurrent = !mayKeepLength && text.utf16.count == range.length
        }

        /// `replacingOccurrences(of:with:)`, only if `needs` holds.
        mutating func replaceLiteral(_ target: String, with replacement: String, if needs: (SyntaxPresence) -> Bool) {
            refreshPresence()
            guard needs(presence) else { return }
            text = text.replacingOccurrences(of: target, with: replacement)
            presenceIsCurrent = false
        }

        private mutating func refreshPresence() {
            guard !presenceIsCurrent else { return }
            // `withUTF8` makes the text contiguous UTF-8 in place if a replacement left it bridged, so later scans copy nothing.
            presence = text.withUTF8 { SyntaxPresence(scanning: $0) }
            presenceIsCurrent = true
        }
    }
}
