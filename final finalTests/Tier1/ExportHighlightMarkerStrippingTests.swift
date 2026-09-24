//
//  ExportHighlightMarkerStrippingTests.swift
//  final finalTests
//
//  Split out of ExportIntegrityTests.swift to keep that file's struct body under SwiftLint's
//  type_body_length limit -- see the header comment there for the full export-integrity
//  background. This file covers `==highlight==` marker stripping
//  (MarkdownUtils.stripHighlightMarkers): `==highlight==` markers must not survive into
//  PDF/DOCX/ODT export as literal punctuation, so they're stripped cleanly to plain text via
//  ExportService.preprocessContentForExport(_:settings:) -- the only call site export() uses.
//  Markdown/TextBundle export is a separate, untouched code path that must keep `==` intact.
//

import Testing
import Foundation
import GRDB
@testable import final_final

extension ExportIntegrityTests {

    // MARK: - Highlight Marker Stripping (Export)
    //
    // `==highlight==` markers must not survive into PDF/DOCX/ODT export as literal
    // punctuation — highlight *rendering* isn't implemented for those formats, so a raw
    // `==` in exported output is meaningless garbage, not preserved formatting. Decision:
    // strip cleanly to plain text (MarkdownUtils.stripHighlightMarkers), called
    // unconditionally from ExportService.preprocessContentForExport(_:settings:), the only
    // call site export() uses. Markdown/TextBundle export (ExportService+MarkdownExport.swift)
    // is a separate, untouched code path — it's a round-trip format and must keep `==` intact.

    @Test("stripHighlightMarkers strips a simple highlighted word (the reported bug)")
    func stripHighlightMarkersSimpleCase() throws {
        let input = "This is a ==highlighted== word in a sentence."
        let result = MarkdownUtils.stripHighlightMarkers(from: input)

        #expect(result == "This is a highlighted word in a sentence.",
                "== markers should be stripped, leaving only the inner text")
    }

    @Test("stripHighlightMarkers strips multiple mid-sentence highlights on one line")
    func stripHighlightMarkersMultiplePerLine() throws {
        let input = "This ==first== highlight and this ==second== highlight are both stripped."
        let result = MarkdownUtils.stripHighlightMarkers(from: input)

        #expect(result == "This first highlight and this second highlight are both stripped.",
                "Two cleanly-delimited highlights on the same line should each strip independently")
    }

    @Test("stripHighlightMarkers: two == pairs on one unbackticked line collapse ambiguously (documented gap)")
    func stripHighlightMarkersAmbiguousMultipleOnOneLineIsADocumentedGap() throws {
        let input = "x==y and p==q"
        let result = MarkdownUtils.stripHighlightMarkers(from: input)

        // Only two "==" occurrences exist in total, so the regex has no way to know the
        // user meant two independent (non-highlight) uses of "==" rather than one
        // highlighted span running from the first marker to the last. This is inherent to
        // the ==...== syntax — Pandoc's own `mark` extension has the identical limitation —
        // not a bug in this function.
        #expect(result == "xy and pq",
                "Documented gap: ambiguous multi-== on one line collapses into a single span")
    }

    @Test("stripHighlightMarkers: two == pairs in DIFFERENT paragraphs collapse ambiguously, document-wide (documented gap)")
    func stripHighlightMarkersAmbiguousMultipleAcrossParagraphsIsADocumentedGap() throws {
        // The doc comment on stripHighlightMarkers previously described this gap as
        // confined to "two independent highlights on ONE unbackticked line" — that was
        // inaccurate. It's document-wide: two completely unrelated stray "==" occurrences
        // in different paragraphs pair up exactly the same way two on one line do, and can
        // even swallow a REAL highlight sitting between them, leaking that highlight's own
        // closing == into the output (reintroducing the exact bug this function exists to
        // fix). Bounding the highlight match to a single paragraph was considered as a fix
        // for this, but rejected: toggleHighlight() in the CodeMirror source editor wraps
        // any selection verbatim (including one spanning a blank line), and Milkdown's
        // toggle applies its mark via tr.addMark() across an arbitrary ProseMirror
        // selection, so a highlight legitimately spanning a paragraph break IS a reachable
        // shape in both editors — bounding would turn that real case into an unstripped ==
        // leak instead of fixing anything. This test pins the corrected, honest
        // (document-wide) understanding of the gap, not a narrower one.
        let input = "Line one has a==b.\n\nPara two.\n\nAnd ==real highlight== here."
        let result = MarkdownUtils.stripHighlightMarkers(from: input)

        #expect(
            result == "Line one has ab.\n\nPara two.\n\nAnd real highlight== here.",
            """
            Documented gap: two unrelated == occurrences in different paragraphs collapse into one span, even \
            swallowing (and leaking the closing == of) a real highlight positioned between them
            """
        )
    }

    @Test("stripHighlightMarkers strips a highlight whose selection spans multiple lines")
    func stripHighlightMarkersMultiLineHighlightStrips() throws {
        // Reachable via the CodeMirror source editor's toggleHighlight(), which wraps a
        // raw multi-line selection verbatim in ==...== with no newline check, and via
        // Milkdown's own highlight-parsing regex, which accepts embedded newlines too.
        let input = "Some text ==spanning\ntwo lines== of a paragraph."
        let result = MarkdownUtils.stripHighlightMarkers(from: input)

        #expect(result == "Some text spanning\ntwo lines of a paragraph.",
                "A highlight whose selection crossed a newline must still be stripped, not leaked as ==")
    }

    @Test("stripHighlightMarkers strips a highlight with trailing whitespace inside the closing marker")
    func stripHighlightMarkersTrailingWhitespaceInsideMarkerStrips() throws {
        // Reachable via a routine drag-select/double-click that catches a trailing space
        // before applying the highlight mark, e.g. ==foo ==.
        let input = "Text with ==foo ==bar mixed in."
        let result = MarkdownUtils.stripHighlightMarkers(from: input)

        #expect(result == "Text with foo bar mixed in.",
                "Whitespace immediately before the closing == must not block stripping")
    }

    @Test("stripHighlightMarkers strips a highlight with leading whitespace inside the opening marker")
    func stripHighlightMarkersLeadingWhitespaceInsideMarkerStrips() throws {
        // Reachable via a routine drag-select/double-click that catches a leading space
        // before applying the highlight mark, e.g. == foo==.
        let input = "Text with== foo== mixed in."
        let result = MarkdownUtils.stripHighlightMarkers(from: input)

        #expect(result == "Text with foo mixed in.",
                "Whitespace immediately after the opening == must not block stripping")
    }

    @Test("stripHighlightMarkers strips a highlight with whitespace inside both markers")
    func stripHighlightMarkersBothSidesWhitespaceInsideMarkersStrips() throws {
        // Reachable via a routine drag-select/double-click that catches whitespace on
        // both sides before applying the highlight mark, e.g. == foo ==.
        let input = "Text with== foo ==mixed in."
        let result = MarkdownUtils.stripHighlightMarkers(from: input)

        #expect(result == "Text with foo mixed in.",
                "Whitespace immediately inside both markers must not block stripping")
    }

    @Test("stripHighlightMarkers leaves an unbalanced/unmatched single == untouched")
    func stripHighlightMarkersUnbalancedMarkerSurvives() throws {
        let input = "The assignment reads value==threshold, with no closing marker anywhere."
        let result = MarkdownUtils.stripHighlightMarkers(from: input)

        #expect(result == input, "A single, unpaired == should be left completely untouched, not deleted")
    }

    @Test("stripHighlightMarkers does not touch a setext heading underline")
    func stripHighlightMarkersSetextHeadingSurvives() throws {
        let input = """
        Title
        =====

        Body text follows.
        """
        let result = MarkdownUtils.stripHighlightMarkers(from: input)

        #expect(result == input, "A setext heading's ===== underline must never be mistaken for a highlight marker")
    }

    @Test("stripHighlightMarkers: a 5-= setext underline survives intact AND a real highlight elsewhere in the same document still strips")
    func stripHighlightMarkersSetextHeadingSurvivesAlongsideRealHighlight() throws {
        // Regression for a real bug: the regex engine could fail to match an opening ==
        // at the very start of the "=====" run, then retry starting two characters later
        // INSIDE the same run and succeed there instead — swallowing the rest of the
        // underline plus everything up to the next real "==" it could find (here, the
        // real highlight's own opening marker), corrupting both. The previous version of
        // this test used a fixture with no second "==" anywhere else in the document, so
        // it passed despite this bug going undetected — this fixture closes that blind
        // spot by giving the regex an unrelated real highlight to find.
        let input = "Title\n=====\n\nSome ==highlighted== text."
        let result = MarkdownUtils.stripHighlightMarkers(from: input)

        #expect(result == "Title\n=====\n\nSome highlighted text.",
                "The ===== underline must survive completely intact, and the real highlight must still strip")
    }

    @Test("stripHighlightMarkers: a 3-= setext underline survives intact AND a real highlight elsewhere in the same document still strips")
    func stripHighlightMarkersOddLengthSetextUnderlineSurvivesAlongsideRealHighlight() throws {
        // Same bug as stripHighlightMarkersSetextHeadingSurvivesAlongsideRealHighlight,
        // but with an odd-length (3-=) underline. This variant didn't even need the
        // "retry two characters later" behavior to trigger — the very FIRST match
        // attempt (at the run's start) succeeded, because exactly one "=" is left over
        // after consuming the opening "==", and the old guard only rejected a leftover
        // run that connected directly to another "==" with nothing in between.
        let input = "Heading\n===\n\nBody with ==mark== here."
        let result = MarkdownUtils.stripHighlightMarkers(from: input)

        #expect(result == "Heading\n===\n\nBody with mark here.",
                "The === underline must survive completely intact, and the real highlight must still strip")
    }

    @Test("stripHighlightMarkers: a 2-= setext underline is NOT protected - it is a bare ==, so it falls into the documented ambiguity gap")
    func stripHighlightMarkersTwoCharSetextUnderlineFallsIntoAmbiguityGap() throws {
        // A 2-character setext underline ("Title\n==") is valid CommonMark, but it is
        // literally the string "==" - indistinguishable from an ordinary highlight
        // marker. The 3-or-more-= protection in stripHighlightMarkers's doc comment does
        // not (and cannot) apply here; this pins the actual, documented-gap behavior
        // rather than asserting a false "any length is protected" claim.
        let input = "Title\n==\n\nSome ==real== highlight here.\n"
        let result = MarkdownUtils.stripHighlightMarkers(from: input)

        #expect(result == "Title\n\n\nSome real== highlight here.\n",
                "A 2-= underline is not distinguishable from a highlight marker and is documented as an accepted ambiguity gap, not a protected case")
    }

    @Test("stripHighlightMarkers protects inline code containing ==")
    func stripHighlightMarkersInlineCodeSurvives() throws {
        let input = "This has `x==y==z` inline code that must survive untouched."
        let result = MarkdownUtils.stripHighlightMarkers(from: input)

        #expect(result == input, "Content inside inline code backticks must not be treated as a highlight marker")
    }

    @Test("stripHighlightMarkers protects fenced code blocks containing ==")
    func stripHighlightMarkersFencedCodeBlockSurvives() throws {
        let input = """
        Some text.

        ```
        let x = a==b
        ```

        More text.
        """
        let result = MarkdownUtils.stripHighlightMarkers(from: input)

        #expect(result == input, "Content inside a fenced code block must not be treated as a highlight marker")
    }

    @Test("stripHighlightMarkers protects display math ($$...$$) containing ==")
    func stripHighlightMarkersDisplayMathSurvives() throws {
        let input = "Equation: $$a==b$$ shown here."
        let result = MarkdownUtils.stripHighlightMarkers(from: input)

        #expect(result == input, "Content inside display math ($$...$$) must not be treated as a highlight marker")
    }

    @Test("stripHighlightMarkers protects inline math ($...$) containing ==")
    func stripHighlightMarkersInlineMathSurvives() throws {
        let input = "Formula $a==b$ shown here."
        let result = MarkdownUtils.stripHighlightMarkers(from: input)

        #expect(result == input, "Content inside inline math ($...$) must not be treated as a highlight marker")
    }

    @Test("stripMarkdownSyntax (word-count) is unaffected by the new stripHighlightMarkers function")
    func stripMarkdownSyntaxHighlightBehaviorUnaffected() throws {
        let input = "This is ==highlighted== text for word counting."
        let stripped = MarkdownUtils.stripMarkdownSyntax(from: input)

        #expect(stripped.contains("highlighted"),
                "stripMarkdownSyntax should still unwrap ==highlight== markers to inner text")
        #expect(!stripped.contains("=="),
                "stripMarkdownSyntax should still remove the == delimiters for word-count purposes")
    }

    @Test("ExportService.preprocessContentForExport strips == highlights unconditionally, independent of includeAnnotations")
    func preprocessContentForExportStripsHighlightsRegardlessOfAnnotationSetting() async throws {
        let service = ExportService()
        let content = """
        Regular text with ==a highlight== in it.

        <!-- ::comment:: An annotation comment -->
        """

        var settingsIncluding = ExportSettings.default
        settingsIncluding.includeAnnotations = true
        let withAnnotations = await service.preprocessContentForExport(content, settings: settingsIncluding)
        #expect(!withAnnotations.contains("=="),
                "Highlight markers must be stripped even when includeAnnotations is true")
        #expect(withAnnotations.contains("a highlight"), "Highlight inner text should survive")
        #expect(withAnnotations.contains("::comment::"), "Annotation should survive when includeAnnotations is true")

        var settingsExcluding = ExportSettings.default
        settingsExcluding.includeAnnotations = false
        let withoutAnnotations = await service.preprocessContentForExport(content, settings: settingsExcluding)
        #expect(!withoutAnnotations.contains("=="),
                "Highlight markers must be stripped when includeAnnotations is false")
        #expect(withoutAnnotations.contains("a highlight"), "Highlight inner text should survive")
        #expect(!withoutAnnotations.contains("::comment::"),
                "Annotation should be stripped when includeAnnotations is false")
    }
}
