//
//  ExportIntegrityTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for export integrity: zoom-state isolation, image path handling,
//  annotation stripping, and the loadContentForExport contract.
//  Export corruption silently destroys the user's shared output.
//
//  Uses assembleMarkdownForExport (Pandoc-flavored) — the path used by
//  ExportOperations.handleExport(). ExportAssemblyTests covers
//  assembleStandardMarkdownForExport (plain markdown for Markdown/TextBundle).
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Export Integrity — Tier 1: Silent Killers")
struct ExportIntegrityTests {

    // MARK: - Export Excludes Bibliography

    @Test("loadContentForExport excludes bibliography blocks")
    func exportExcludesBibliography() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let exportBlocks = blocks.filter { !$0.isBibliography }
        let exported = BlockParser.assembleMarkdownForExport(from: exportBlocks)

        // Bibliography content should not appear in export
        #expect(!exported.contains("Carroll, S. R., et al. (2020)"),
                "Export should exclude bibliography entries")
        #expect(!exported.contains("Himmelmann, N. P. (1998)"),
                "Export should exclude bibliography entries")

        // But the heading "References" (which is a bibliography section) should be excluded
        // Verify bibliography blocks are actually present in the full set
        let bibBlocks = blocks.filter { $0.isBibliography }
        #expect(!bibBlocks.isEmpty, "Rich content should have bibliography blocks")
    }

    // MARK: - Export Returns All Sections (Not Just Zoomed)

    @Test("Export assembles all sections regardless of zoom state simulation")
    func exportAllSectionsNotZoomed() throws {
        let content = """
        # Document Title

        Intro paragraph.

        ## Section One

        Content for section one.

        ## Section Two

        Content for section two.

        ## Section Three

        Content for section three.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)

        // Simulate what loadContentForExport does: filter out bibliography, assemble all
        let exportBlocks = blocks.filter { !$0.isBibliography }
        let exported = BlockParser.assembleMarkdownForExport(from: exportBlocks)

        // All sections should be present
        #expect(exported.contains("Section One"), "Export should include Section One")
        #expect(exported.contains("Section Two"), "Export should include Section Two")
        #expect(exported.contains("Section Three"), "Export should include Section Three")
        #expect(exported.contains("Intro paragraph"), "Export should include intro")
    }

    // MARK: - Export Preserves Footnote Definitions from Notes Section

    @Test("Export includes footnote definitions from Notes section")
    func exportIncludesFootnoteDefinitions() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let exportBlocks = blocks.filter { !$0.isBibliography }
        let exported = BlockParser.assembleMarkdownForExport(from: exportBlocks)

        // Notes section footnote definitions should be present
        #expect(exported.contains("[^1]:") || exported.contains("[^1]"),
                "Export should contain footnote references")
        #expect(exported.contains("OLAC metadata standards"),
                "Export should contain footnote definition text")
    }

    // MARK: - Annotation Stripping

    @Test("stripAnnotations removes annotation HTML comments")
    func stripAnnotationsRemovesComments() throws {
        let content = """
        Regular text here.

        <!-- ::task:: [ ] Review this section -->

        More text.

        <!-- ::comment:: This is a comment annotation -->

        Final text.
        """

        let stripped = MarkdownUtils.stripAnnotations(from: content)

        #expect(!stripped.contains("::task::"), "Stripped content should not contain task annotations")
        #expect(!stripped.contains("::comment::"), "Stripped content should not contain comment annotations")
        #expect(stripped.contains("Regular text here."), "Should preserve regular text")
        #expect(stripped.contains("More text."), "Should preserve regular text")
        #expect(stripped.contains("Final text."), "Should preserve regular text")
    }

    @Test("stripAnnotations preserves non-annotation HTML comments")
    func stripAnnotationsPreservesRegularComments() throws {
        let content = """
        Text with <!-- a regular HTML comment --> here.

        <!-- ::task:: [ ] Do something -->
        """

        let stripped = MarkdownUtils.stripAnnotations(from: content)

        #expect(stripped.contains("a regular HTML comment"),
                "Should preserve non-annotation HTML comments")
        #expect(!stripped.contains("::task::"),
                "Should strip annotation comments")
    }

    // MARK: - Image Path in Export

    @Test("Export preserves image markdown syntax")
    func exportPreservesImageSyntax() throws {
        let content = """
        # Document

        Some text.

        ![Alt text](media/photo.png)

        More text.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let exported = BlockParser.assembleMarkdownForExport(from: blocks)

        #expect(exported.contains("media/photo.png"),
                "Export should preserve image path")
    }

    @Test("Export preserves image with spaces in filename")
    func exportPreservesSpacesInFilename() throws {
        let content = """
        # Document

        ![Screenshot](media/my screenshot.png)

        Text.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let exported = BlockParser.assembleMarkdownForExport(from: blocks)

        #expect(exported.contains("my screenshot.png"),
                "Export should preserve image filename with spaces")
    }

    @Test("Export preserves image with URL-encoded filename")
    func exportPreservesUrlEncodedFilename() throws {
        let content = """
        # Document

        ![Screenshot](media/Screenshot%202.png)

        Text.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let exported = BlockParser.assembleMarkdownForExport(from: blocks)

        #expect(exported.contains("Screenshot%202.png"),
                "Export should preserve URL-encoded image filename")
    }

    // MARK: - Export Image Path Rewriting (ExportService)

    @Test("ExportService imagePathPattern matches markdown images")
    func imagePathPatternMatches() throws {
        // Test the regex pattern used by ExportService for image rewriting
        let pattern = #"!\[[^\]]*\]\(media/([^)]+)\)"#
        let regex = try NSRegularExpression(pattern: pattern)

        let testCases: [(input: String, expectedFilename: String)] = [
            ("![Alt](media/photo.png)", "photo.png"),
            ("![](media/image.jpg)", "image.jpg"),
            ("![Diagram of workflow](media/diagram-v2.pdf)", "diagram-v2.pdf"),
            ("![Screenshot](media/Screenshot%202.png)", "Screenshot%202.png")
        ]

        for testCase in testCases {
            let range = NSRange(testCase.input.startIndex..., in: testCase.input)
            let matches = regex.matches(in: testCase.input, range: range)
            #expect(matches.count == 1,
                    "Should match image syntax for: \(testCase.input)")

            if let match = matches.first,
               let captureRange = Range(match.range(at: 1), in: testCase.input) {
                let filename = String(testCase.input[captureRange])
                #expect(filename == testCase.expectedFilename,
                        "Should capture filename '\(testCase.expectedFilename)' from '\(testCase.input)'")
            }
        }
    }

    @Test("ExportService imagePathPattern truncates at parentheses (known gap)")
    func imagePathPatternParenthesesGap() throws {
        // Documents a known limitation: [^)]+ stops at first ')' in filename
        // Filenames with literal parentheses (e.g. "Screenshot (2).png") will
        // be truncated. URL-encoding the parens avoids this issue.
        let pattern = #"!\[[^\]]*\]\(media/([^)]+)\)"#
        let regex = try NSRegularExpression(pattern: pattern)

        let input = "![Screenshot](media/Screenshot (2).png)"
        let range = NSRange(input.startIndex..., in: input)
        let matches = regex.matches(in: input, range: range)

        // The regex matches but captures only up to the first ')'
        #expect(matches.count == 1, "Pattern should still match")
        if let match = matches.first,
           let captureRange = Range(match.range(at: 1), in: input) {
            let filename = String(input[captureRange])
            #expect(filename == "Screenshot (2",
                    "Known gap: parentheses in filename truncate capture")
        }
    }

    // MARK: - Export Assembles in Sort Order

    @Test("Export assembles blocks in sort order, not insertion order")
    func exportRespectsBlockSortOrder() throws {
        let content = """
        # First

        First content.

        ## Second

        Second content.

        ## Third

        Third content.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let exported = BlockParser.assembleMarkdownForExport(from: blocks)

        // Verify order: First before Second before Third
        if let firstIdx = exported.range(of: "First content")?.lowerBound,
           let secondIdx = exported.range(of: "Second content")?.lowerBound,
           let thirdIdx = exported.range(of: "Third content")?.lowerBound {
            #expect(firstIdx < secondIdx, "First should appear before Second")
            #expect(secondIdx < thirdIdx, "Second should appear before Third")
        } else {
            Issue.record("Export should contain all section content")
        }
    }

    // MARK: - Reference Doc Path Routing (ODT "fake data" fix)
    //
    // Regression coverage for a bug where ODT export passed the bundled Word
    // reference.docx to Pandoc as --reference-doc. Pandoc can't use a .docx as an
    // ODT reference, so it merged the Word file's internals into the .odt output —
    // including the reference template's sample body text — producing a malformed
    // hybrid file. effectiveReferenceDocPath(for:) must only ever hand a .docx path
    // to Word export and a .odt path to ODT export.

    @Test("effectiveReferenceDocPath routes a custom .docx reference only to Word export")
    func referenceDocPathRoutesDocxToWordOnly() throws {
        var settings = ExportSettings.default
        settings.useCustomReferenceDoc = true
        settings.customReferenceDocPath = "/x/reference.docx"

        #expect(settings.effectiveReferenceDocPath(for: .word) == "/x/reference.docx",
                "Word export should use the custom .docx reference doc")
        #expect(settings.effectiveReferenceDocPath(for: .odt) != "/x/reference.docx",
                "ODT export must never receive a .docx reference doc")
        #expect(settings.effectiveReferenceDocPath(for: .odt) != nil,
                "ODT should fall back to the bundled reference.odt when the custom doc isn't .odt")
        #expect(settings.effectiveReferenceDocPath(for: .pdf) == nil,
                "PDF export never uses a reference doc")
    }

    @Test("effectiveReferenceDocPath routes a custom .odt reference only to ODT export")
    func referenceDocPathRoutesOdtToOdtOnly() throws {
        var settings = ExportSettings.default
        settings.useCustomReferenceDoc = true
        settings.customReferenceDocPath = "/x/reference.odt"

        #expect(settings.effectiveReferenceDocPath(for: .odt) == "/x/reference.odt",
                "ODT export should use the custom .odt reference doc")
        #expect(settings.effectiveReferenceDocPath(for: .word) != "/x/reference.odt",
                "Word export must never receive the .odt reference doc")
        #expect(settings.effectiveReferenceDocPath(for: .pdf) == nil,
                "PDF export never uses a reference doc")
    }

    @Test("effectiveReferenceDocPath ignores the custom path when useCustomReferenceDoc is false")
    func referenceDocPathIgnoresDisabledCustomDoc() throws {
        var settings = ExportSettings.default
        settings.useCustomReferenceDoc = false
        settings.customReferenceDocPath = "/x/reference.odt"

        #expect(settings.effectiveReferenceDocPath(for: .odt) != "/x/reference.odt",
                "Custom reference doc should be ignored when useCustomReferenceDoc is false")
        #expect(settings.effectiveReferenceDocPath(for: .odt) != nil,
                "ODT should still fall back to the bundled reference.odt")
        #expect(settings.effectiveReferenceDocPath(for: .pdf) == nil,
                "PDF export never uses a reference doc")
    }

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

        #expect(result == "Line one has ab.\n\nPara two.\n\nAnd real highlight== here.",
                "Documented gap: two unrelated == occurrences in different paragraphs collapse into one span, even swallowing (and leaking the closing == of) a real highlight positioned between them")
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
