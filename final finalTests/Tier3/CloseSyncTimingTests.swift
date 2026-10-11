//
//  CloseSyncTimingTests.swift
//  final finalTests
//
//  t-94369a83, Phase 4a: closing a book-length project took about 20 s at six chapters and about 70 s at twelve, because the close's
//  step 6b (`EditorViewState+Lifecycle.swift`: `sectionSyncService?.syncNow(content)`, `annotationSyncService?.syncNow(content)`) ran
//  `SectionSyncService.parseHeaders` on the text the web view hands back, and that text is a bridged `NSString`:
//
//    - `buildParsedHeaders` and `confirmNotesCandidates` called `markdown.count` and `markdown.index(markdown.startIndex, offsetBy:)`
//      for every section boundary, so the parse was quadratic (94% to 98% of the section sync, 11,564 ms at BOOK-6 and 46,113 ms at
//      BOOK-12 on bridged text, against 398 ms and 1,295 ms for the whole sync on native text);
//    - on a bridged string each of those calls is about 40 times slower than on Swift's own contiguous UTF-8 storage.
//
//  The fix has two halves, and these tests pin both:
//
//    (a) the index arithmetic carries its position forward (one count, one walk): the output must be IDENTICAL to the old arithmetic's.
//        `LegacyHeaderParse` is a verbatim copy of the old functions; the tests compare field by field on the book-length documents
//        and on small edge cases (multi-byte text, CRLF, sections at the very start and end, empty sections, Notes and bibliography
//        handling, a Notes heading inside a code fence);
//    (b) the same BOOK-12 text held as an `NSString`-backed copy, as the web view returns it, parses and syncs within seconds
//        (the old arithmetic took 46 s);
//    (c) the text is made contiguous UTF-8 once, where it arrives: `fetchContentFromWebView` and the lifecycle's fresh-content step
//        return text whose characters are unchanged and whose storage is contiguous.
//
//  BOOK-6 and BOOK-12 are `POCComplexGenerator` chapters plus the generated bibliography and its end marker, as the editor holds them
//  (349,810 and 699,139 characters before the bibliography).
//

import Foundation
import Testing
@testable import final_final

@MainActor
@Suite("Close-time section sync: header parse and fetched text (t-94369a83, Phase 4a)", .serialized)
struct CloseSyncTimingTests {

    // MARK: - Documents

    /// The text the editor holds at close: chapters, `# Notes`, the generated bibliography, its end marker.
    private static func editorText(chapters: Int) -> String {
        let generated = POCComplexGenerator.make(id: "BOOK-\(chapters)", title: "BOOK-\(chapters)", chapters: chapters)
        let entries = ComplexDocumentFixture.bibliographyEntries().joined(separator: "\n\n")
        return String(generated.markdown.dropLast()) + "\n\n# Bibliography\n\n" + entries + "\n\n"
            + ComplexDocumentFixture.bibliographyEndMarker
    }

    private static let book6 = editorText(chapters: 6)
    private static let book12 = editorText(chapters: 12)

    /// A copy of `text` backed by an `NSString` (CoreFoundation) instead of Swift's own UTF-8 storage: what `String` holds when it came
    /// from `webView.evaluateJavaScript(...)` cast `as? String`. `String.count` and `String.index(offsetBy:)` on it walk the text through
    /// CoreFoundation. (For text with characters outside Latin-1, which every document here has, `isContiguousUTF8` is false.)
    private nonisolated static func bridgedCopy(_ text: String) -> String {
        let units = Array(text.utf16)
        return units.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return "" }
            return NSString(characters: base, length: buffer.count) as String
        }
    }

    private nonisolated static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private static let fallbackBibTitle = "Bibliography"

    /// The (existing bibliography title, existing Notes title) pairs `parseHeaders` is called with: nothing known yet, a known
    /// bibliography, a known Notes, both, and custom names.
    private static let titleCombinations: [(bib: String?, notes: String?)] = [
        (nil, nil), ("Bibliography", nil), (nil, "Notes"), ("Bibliography", "Notes"), ("References", "Endnotes")
    ]

    // MARK: - Comparing two header lists

    private static let fieldNames = [
        "position", "title", "level", "isPseudoSection", "startOffset", "wordCount", "isBibliography", "isNotes"
    ]

    /// Every field of a header except the section text, as strings, in `fieldNames` order.
    private static func fields(_ header: ParsedHeader) -> [String] {
        [
            String(header.position), header.title.debugDescription, String(header.level), String(header.isPseudoSection),
            String(header.startOffset), String(header.wordCount), String(header.isBibliography), String(header.isNotes)
        ]
    }

    /// nil when the lists are identical in every field, else a short description of the first difference (never the section text itself).
    private static func firstDifference(new: [ParsedHeader], old: [ParsedHeader]) -> String? {
        if new.count != old.count { return "\(new.count) headers, the old arithmetic gave \(old.count)" }
        for (index, pair) in zip(new, old).enumerated() {
            let freshFields = fields(pair.0)
            let legacyFields = fields(pair.1)
            if let differing = zip(freshFields, legacyFields).enumerated().first(where: { $0.element.0 != $0.element.1 }) {
                let name = fieldNames[differing.offset]
                return "header \(index): \(name) \(differing.element.0) vs \(differing.element.1)"
            }
            if pair.0.markdownContent != pair.1.markdownContent {
                return "header \(index): section text differs (\(pair.0.markdownContent.count) vs \(pair.1.markdownContent.count) characters)"
            }
        }
        return nil
    }

    private static func describe(_ combination: (bib: String?, notes: String?)) -> String {
        "bibliography title \(String(describing: combination.bib)), notes title \(String(describing: combination.notes))"
    }

    private static func parseNew(_ text: String, bib: String?, notes: String?) -> [ParsedHeader] {
        SectionSyncService.parseHeaders(from: text, existingBibTitle: bib, existingNotesTitle: notes, fallbackBibTitle: fallbackBibTitle)
    }

    private static func parseOld(_ text: String, bib: String?, notes: String?) -> [ParsedHeader] {
        LegacyHeaderParse.parseHeaders(from: text, existingBibTitle: bib, existingNotesTitle: notes, fallbackBibTitle: fallbackBibTitle)
    }

    // MARK: - (a) Identical output

    @Test("parseHeaders gives exactly what the old index arithmetic gave on BOOK-6 and BOOK-12 (every field of every section)",
          .timeLimit(.minutes(5)))
    func parseHeadersMatchesTheOldArithmeticOnTheBooks() {
        for (label, text) in [("BOOK-6", Self.book6), ("BOOK-12", Self.book12)] {
            for combination in Self.titleCombinations {
                let fresh = Self.parseNew(text, bib: combination.bib, notes: combination.notes)
                let legacy = Self.parseOld(text, bib: combination.bib, notes: combination.notes)
                let difference = Self.firstDifference(new: fresh, old: legacy)
                #expect(difference == nil, "\(label), \(Self.describe(combination)): \(difference ?? "")")
                #expect(fresh.count > 100, "\(label): the comparison must cover a real section list (got \(fresh.count))")
            }
        }
    }

    /// Small documents that each put one special case on the index arithmetic's path.
    private static let edgeCases: [(name: String, text: String)] = [
        ("empty text", ""),
        ("blank lines only", "\n\n\n"),
        ("no headings", "just some text\nand a second line"),
        ("one heading and nothing else, no newline", "# Only"),
        ("a heading at the very start and the very end", "# First\n\nbody\n\n# Last"),
        ("a trailing newline", "# A\n\ntext\n"),
        ("empty sections", "# A\n# B\n\n# C\n\n\n# D\n"),
        ("text before the first heading", "preamble line\n\n# A\n\nbody\n"),
        ("emoji, a family sequence, flags and combining marks",
         "# \u{1F600} Smile \u{1F1FA}\u{1F1F8}\u{1F1E8}\u{1F1E6}\n\nfamily \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466} here, "
            + "e\u{0301} and n\u{0303}\n\n## \u{1F1EC}\u{1F1E7} Second\n\ncaf\u{00E9} e\u{0301}\u{0302}\n\n# Last \u{1F44D}\u{1F3FD}\n"),
        ("Chinese text, Traditional and Simplified",
         "# 引言\n\n这是一个测试。他們把帳冊收在潮濕的木箱裡。\n\n## 方法\n\n調查的結果和最初的假設並不一致。\n\n# 结论\n\n完。"),
        ("CRLF line endings", "# One\r\n\r\ntext\r\n\r\n# Two\r\nmore\r\n"),
        ("mixed LF and CRLF line endings", "# One\n\ntext\r\n\r\n# Two\nmore\r\n\n# Three\r\nlast"),
        ("Unicode line separator and next-line", "# A\n\nline\u{2028}sep and \u{0085}nel\n\n# B\n"),
        ("pseudo-sections",
         "# A\n\ntext\n\n<!-- ::break:: -->\n\nSecond part opening paragraph with **bold** words.\n\n<!-- ::break:: -->\n\n## B\n\nmore\n"),
        ("a section break at the very start", "<!-- ::break:: -->\nFirst words after the break\n\n# A\n\nbody"),
        ("a Notes section with footnote definitions", "# Body\n\nSome text[^1].\n\n# Notes\n\n[^1]: The note.\n\n# After\n\nmore text\n"),
        ("a Notes heading with no footnote under it", "# Body\n\ntext\n\n# Notes\n\njust a section called Notes\n\n# After\n\nmore\n"),
        ("two Notes headings, only the second real",
         "# A\n\nx[^1]\n\n# Notes\n\nplain heading, no footnotes\n\n# B\n\n# Notes\n\n[^1]: real note\n\n# C\n"),
        ("a Notes heading with definitions inside a code fence", "# A\n\n```\n# Notes\n[^1]: not a note\n```\n\n# B\n\ntext\n"),
        ("a custom Notes title with definitions", "# A\n\ntext[^1]\n\n# Endnotes\n\n[^1]: a custom-titled note\n\n# Z\n"),
        ("a code fence that never closes", "# A\n\n```\n# Hidden\ntext\n"),
        ("a bibliography closed by its end marker",
         "# A\n\ntext\n\n# Bibliography\n\nEntry one.\n\nEntry two.\n\n\(BlockParser.bibliographyEndMarker)\n\n# Appendix\n\nafter\n"),
        ("a bibliography opened by the legacy start marker",
         "# A\n\ntext\n\n\(BlockParser.bibliographyStartMarker)\n# Bibliography\n\nEntry.\n\n\(BlockParser.bibliographyEndMarker)\n\n# Appendix\n"),
        ("a Notes section, then the bibliography",
         "# Body\n\ntext[^1]\n\n# Notes\n\n[^1]: n\n\n# Bibliography\n\nEntry.\n\n\(BlockParser.bibliographyEndMarker)\n"),
        ("the bibliography first, then Notes",
         "# A\n\ntext[^1]\n\n# Bibliography\n\nEntry.\n\n\(BlockParser.bibliographyEndMarker)\n\n# Notes\n\n[^1]: n\n\n# Z\n"),
        ("a heading titled References as the custom bibliography",
         "# A\n\ntext\n\n# References\n\nEntry.\n\n\(BlockParser.bibliographyEndMarker)\n\n# Z\n"),
        ("indented and invalid headings", "  # Indented\n\n####### too deep\n\n#NoSpace\n\n# \n\n## Real\n\ntext"),
        ("one very long line", "# A\n\n" + String(repeating: "word ", count: 20_000) + "\n\n# B\n")
    ]

    @Test("parseHeaders gives exactly what the old index arithmetic gave on the edge-case documents, native and bridged")
    func parseHeadersMatchesTheOldArithmeticOnEdgeCases() {
        var sawNotes = false
        var sawBibliography = false
        var sawPseudoSection = false
        var comparisons = 0
        for edge in Self.edgeCases {
            let bridged = Self.bridgedCopy(edge.text)
            for combination in Self.titleCombinations {
                let legacy = Self.parseOld(edge.text, bib: combination.bib, notes: combination.notes)
                for (kind, text) in [("native", edge.text), ("bridged", bridged)] {
                    let fresh = Self.parseNew(text, bib: combination.bib, notes: combination.notes)
                    let difference = Self.firstDifference(new: fresh, old: legacy)
                    #expect(difference == nil, "\(edge.name) (\(kind)), \(Self.describe(combination)): \(difference ?? "")")
                    comparisons += 1
                }
                sawNotes = sawNotes || legacy.contains { $0.isNotes }
                sawBibliography = sawBibliography || legacy.contains { $0.isBibliography }
                sawPseudoSection = sawPseudoSection || legacy.contains { $0.isPseudoSection }
            }
        }
        // The comparison is not vacuous: the cases really reach the Notes confirmation, the bibliography clamp and the pseudo-section title.
        #expect(sawNotes, "no edge case produced a confirmed Notes section")
        #expect(sawBibliography, "no edge case produced a bibliography section")
        #expect(sawPseudoSection, "no edge case produced a pseudo-section")
        #expect(comparisons == Self.edgeCases.count * Self.titleCombinations.count * 2)
    }

    // MARK: - (b) Bridged text

    private struct SyncedRig {
        let db: ProjectDatabase
        let pid: String
        let section: SectionSyncService
        let annotation: AnnotationSyncService
    }

    /// A project database loaded the way the app loads it, with the section and annotation rows from a first sync of `text`.
    private static func makeSyncedRig(_ text: String) async throws -> SyncedRig {
        let db = try TestFixtureFactory.createTemporary(content: text)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        guard let contentId = try db.fetchContent(for: pid)?.id else { throw CocoaError(.coderValueNotFound) }
        let section = SectionSyncService()
        section.configure(database: db, projectId: pid)
        let annotation = AnnotationSyncService()
        annotation.configure(database: db, contentId: contentId)
        await section.syncNow(text)
        await annotation.syncNow(text)
        return SyncedRig(db: db, pid: pid, section: section, annotation: annotation)
    }

    private static func timed(_ body: () async -> Void) async -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        await body()
        return start.duration(to: clock.now)
    }

    @Test("BOOK-12 held as an NSString-backed copy (as the web view returns it): parseHeaders and both syncNow calls finish within seconds",
          .timeLimit(.minutes(5)))
    func bridgedBook12ParsesAndSyncsFast() async throws {
        let native = Self.book12
        let bridged = Self.bridgedCopy(native)
        try #require(!bridged.isContiguousUTF8, "precondition: the copy must be foreign storage, or this test proves nothing")
        #expect(bridged == native)

        // The parse alone. The quadratic arithmetic took 46,113 ms here; one pass takes a fraction of a second.
        var headers: [ParsedHeader] = []
        let parseTime = await Self.timed { headers = Self.parseNew(bridged, bib: "Bibliography", notes: "Notes") }
        #expect(
            parseTime < .seconds(3),
            "parseHeaders on bridged BOOK-12 took \(Self.milliseconds(parseTime)) ms (the old arithmetic: 46,113 ms)")
        let reference = Self.parseNew(native, bib: "Bibliography", notes: "Notes")
        #expect(Self.firstDifference(new: headers, old: reference) == nil, "the bridged parse must give what the native parse gives")

        // The two calls step 6b makes, on a database whose section and annotation rows already exist (the unchanged-text close).
        let rig = try await Self.makeSyncedRig(native)
        let sectionsBefore = try rig.db.fetchSections(projectId: rig.pid).count
        let sectionTime = await Self.timed { await rig.section.syncNow(bridged) }
        let annotationTime = await Self.timed { await rig.annotation.syncNow(bridged) }
        #expect(
            sectionTime < .seconds(10),
            "section.syncNow on bridged BOOK-12 took \(Self.milliseconds(sectionTime)) ms (the old arithmetic: 44,002 ms)")
        #expect(annotationTime < .seconds(10), "annotation.syncNow on bridged BOOK-12 took \(Self.milliseconds(annotationTime)) ms")
        #expect(
            try rig.db.fetchSections(projectId: rig.pid).count == sectionsBefore,
            "unchanged text must leave the section rows as they were")
        #expect(try rig.db.fetchContent(for: rig.pid)?.markdown == native, "the sync stores the text it was given")
    }

    // MARK: - (c) Contiguous text where it arrives

    /// A document with characters outside Latin-1, long enough that its bridged copy is foreign storage.
    private static let fetchedText =
        "# Alpha 引言\n\n這是 CODEMIRROR typed paragraph \u{1F600} with enough bytes to be stored.\n\n# Beta\n\nfour five six.\n"

    @Test("the contiguous-text helper keeps the characters, makes a bridged string contiguous UTF-8, and leaves a native one alone")
    func contiguousCopyKeepsTheCharacters() throws {
        let bridged = Self.bridgedCopy(Self.fetchedText)
        try #require(!bridged.isContiguousUTF8, "precondition: the bridged copy is foreign storage")

        let copy = bridged.contiguousUTF8Copy
        #expect(copy == Self.fetchedText)
        #expect(copy.isContiguousUTF8, "a bridged string must come back contiguous")
        #expect(!bridged.isContiguousUTF8, "the copy is a new string; the argument is not changed")

        let native = Self.fetchedText
        #expect(native.isContiguousUTF8)
        #expect(native.contiguousUTF8Copy == native)
        #expect(native.contiguousUTF8Copy.isContiguousUTF8)
        #expect("".contiguousUTF8Copy.isEmpty)
    }

    @Test("fetchContentFromWebView returns the web view's text as contiguous UTF-8 with the same characters")
    func fetchContentFromWebViewReturnsContiguousText() async throws {
        let rig = try LifecycleFlushHarness()
        let bridged = Self.bridgedCopy(Self.fetchedText)
        try #require(!bridged.isContiguousUTF8, "precondition: the web view's answer is foreign storage")
        rig.fetchAnswer = bridged

        let fetched = await rig.sync.fetchContentFromWebView(timeout: .seconds(2))

        #expect(fetched == Self.fetchedText)
        #expect(fetched?.isContiguousUTF8 == true, "the fetched text must be native contiguous UTF-8, not the bridged NSString")
    }

    @Test("a Rich Text close hands step 6b contiguous UTF-8 text with the same characters")
    func richTextCloseContentIsContiguous() async throws {
        let rig = try LifecycleFlushHarness()
        let bridged = Self.bridgedCopy(Self.fetchedText)
        try #require(!bridged.isContiguousUTF8, "precondition: the web view's answer is foreign storage")
        rig.fetchAnswer = bridged

        let result = await rig.run(.close)

        #expect(!result.usedFallback, "the fetch answered, so the content is the fetched text")
        #expect(result.fetchedContent == Self.fetchedText)
        #expect(result.fetchedContent?.isContiguousUTF8 == true, "step 6b receives this string: it must be contiguous UTF-8")
    }

    @Test("a Markdown close hands step 6b contiguous UTF-8 text with the same characters (after the bibliography marker is stripped)")
    func markdownCloseContentIsContiguous() async throws {
        let rig = try LifecycleFlushHarness()
        rig.editorState.editorMode = .source
        let withMarker = Self.fetchedText + "\n\(BlockParser.bibliographyStartMarker)\n"
        let bridged = Self.bridgedCopy(withMarker)
        try #require(!bridged.isContiguousUTF8, "precondition: the web view's answer is foreign storage")
        rig.fetchAnswer = bridged

        let result = await rig.run(.quit)

        #expect(!result.usedFallback, "the fetch answered, so the content is the fetched text")
        #expect(result.fetchedContent == Self.fetchedText + "\n\n", "the start marker is stripped; every other character is kept")
        #expect(result.fetchedContent?.isContiguousUTF8 == true, "step 6b receives this string: it must be contiguous UTF-8")
    }
}
