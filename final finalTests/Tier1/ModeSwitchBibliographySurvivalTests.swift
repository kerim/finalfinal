//
//  ModeSwitchBibliographySurvivalTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  THE BUG (2026-10-09). Two VM runs of the six-chapter test document ended with no row flagged `isBibliography` in the saved document, after
//  about ten Markdown <-> Rich Text switches and no deliberate edit of the bibliography. A bibliography that loses its flag becomes ordinary
//  text and the next regeneration adds another one (the real document with five bibliographies, task t-3063c708).
//
//  THE CAUSE. `BlockParser.parse` flags the generated bibliography (heading and entries) only on evidence: the start marker, or a heading with the
//  right title whose run is closed by the END marker `<!-- ::auto-bibliography-end:: -->` (`BibliographyOpeningSelector`, tier 2). The text
//  `editorState.content` holds carries that end marker. The switch to Rich Text now saves `sourceContent` instead of `content`, so that the last keys
//  typed in the Markdown editor are saved (`EditorViewState.commitMarkdownTextForRichTextSwitch`). But `CodeMirrorCoordinator.saveAndNotify` filled
//  `sourceContent` from the page's `getContent()`, which strips EVERY hidden marker (`stripAnchors`, web/codemirror/src/anchor-plugin.ts, whose regex
//  lists the end marker since 2026-08-09). The text saved had no end marker, so the parse stored the bibliography as ordinary blocks.
//
//  THE FIX UNDER TEST. The pre-switch read asks the page for `getContentRaw()` (`CodeMirrorEditor.Coordinator.preSwitchContentScript`), and
//  `BlockSyncService.fetchContentScript` (the fetch the close, quit and project-switch save sequence makes of the Markdown page: the only
//  callers that reach a Markdown page, because export, Save Version and auto-backup pass no view and so ask the Rich Text page) keeps the end
//  marker for a Markdown page.
//
//  HOW THESE TESTS REACH THE REAL BEHAVIOUR. The web page cannot run here, so a tiny model of the Markdown page stands in for it: `getContentRaw()`
//  returns the document, `getContent()` returns it with every hidden marker stripped (the regex copied from anchor-plugin.ts). The tests run the
//  Swift side's own script string against that model in JavaScriptCore and feed the answer into the real functions
//  (`commitMarkdownTextForRichTextSwitch`, `flushContentToDatabase`, `injectSectionAnchors`, `injectBibliographyMarker`,
//  `assembleMarkdownForEditor`). So if either script string goes back to `getContent()`, the round trips below fail at the first switch to Rich
//  Text, naming the first row whose flags changed. (The TLA+ sync model does not represent bibliography flags or the end marker at all -- see
//  docs/architecture/tla/README.md -- so these tests are the evidence.)
//
//  Each round trip checks after EVERY switch: the same number of rows flagged isBibliography (the heading and one row per cited key) and isNotes;
//  no row's flags changed (the first differing row is named); exactly one bibliography heading; the bibliography heading row's flags unchanged;
//  and the text the database assembles for the editor equals what it was (plus the typed words, in the edit tests) and still ends with the end
//  marker, once.
//

import Foundation
import Testing
@testable import final_final

@Suite("Mode switches keep the bibliography and Notes flags — Tier 1: Silent Killers", .serialized)
@MainActor
struct ModeSwitchBibliographySurvivalTests {

    fileprivate static let endMarker = BlockParser.bibliographyEndMarker

    // MARK: - One round trip and five

    @Test("one full round trip, Rich Text -> Markdown -> Rich Text, keeps every bibliography and Notes flag (x1)")
    func oneRoundTripKeepsTheFlags() throws {
        let document = ComplexDocumentFixture.article
        let session = try makeSession(document)
        let base = try baseline(session)
        requirePreconditions(base, document)

        try switchToMarkdown(session)
        try check(session, against: base, step: "switch 1, Rich Text -> Markdown", expectedAssembled: base.assembled)
        try switchToRichText(session)
        try check(session, against: base, step: "switch 2, Markdown -> Rich Text", expectedAssembled: base.assembled)
    }

    @Test("five round trips in a row (ten switches) keep every bibliography and Notes flag (x1)")
    func fiveRoundTripsKeepTheFlags() throws {
        let document = ComplexDocumentFixture.article
        let session = try makeSession(document)
        let base = try baseline(session)
        requirePreconditions(base, document)

        for trip in 1...5 {
            try switchToMarkdown(session)
            try check(session, against: base, step: "trip \(trip), Rich Text -> Markdown", expectedAssembled: base.assembled)
            try switchToRichText(session)
            try check(session, against: base, step: "trip \(trip), Markdown -> Rich Text", expectedAssembled: base.assembled)
        }
    }

    @Test("five round trips with a real edit in a body paragraph before EVERY switch keep the flags and save every typed word (x1)")
    func fiveRoundTripsWithAnEditBeforeEverySwitchKeepTheFlags() throws {
        let document = ComplexDocumentFixture.article
        let session = try makeSession(document)
        let base = try baseline(session)
        requirePreconditions(base, document)
        let paragraphs = try editableParagraphs(session, in: base.assembled)
        try #require(paragraphs.count >= 10, "the fixture has at least ten paragraphs to type into (\(paragraphs.count))")

        var expected = base.assembled
        for trip in 1...5 {
            // Rich Text: a word typed in a paragraph (the editor's last push already landed in `content`).
            let richTextWord = "typedrt\(trip)"
            let richTextParagraph = paragraphs[(trip - 1) * 2]
            session.state.content = try appendWord(richTextWord, toParagraph: richTextParagraph, in: session.state.content)
            expected = try appendWord(richTextWord, toParagraph: richTextParagraph, in: expected)
            try switchToMarkdown(session)
            try check(session, against: base, step: "trip \(trip) (edited), Rich Text -> Markdown", expectedAssembled: expected)

            // Markdown: a word typed in another paragraph within the last 50 ms before the switch: in the page's document, not yet in `content`.
            let markdownWord = "typedmd\(trip)"
            let markdownParagraph = paragraphs[(trip - 1) * 2 + 1]
            session.state.sourceContent = try appendWord(markdownWord, toParagraph: markdownParagraph, in: session.state.sourceContent)
            expected = try appendWord(markdownWord, toParagraph: markdownParagraph, in: expected)
            try switchToRichText(session)
            try check(session, against: base, step: "trip \(trip) (edited), Markdown -> Rich Text", expectedAssembled: expected)
            #expect(
                session.state.content.contains(markdownWord),
                "trip \(trip): the word typed in the last 50 ms before the switch was saved and is in the text the Rich Text editor loads")
        }
    }

    @Test("a word typed after the page's last push is saved, and the bibliography keeps its flags (x1, the gain and the safety together)")
    func aWordTypedAfterTheLastPushIsSavedAndTheFlagsSurvive() throws {
        let document = ComplexDocumentFixture.article
        let session = try makeSession(document)
        let base = try baseline(session)
        requirePreconditions(base, document)
        let candidates = try editableParagraphs(session, in: base.assembled)
        let paragraph = try #require(candidates.first)

        try switchToMarkdown(session)
        let staleContent = session.state.content
        session.state.sourceContent = try appendWord("lastfiftyms", toParagraph: paragraph, in: session.state.sourceContent)
        #expect(session.state.content == staleContent, "the setup models a page push that has not landed yet: `content` lacks the word")

        try switchToRichText(session)
        try check(
            session, against: base, step: "Markdown -> Rich Text with a word typed in the last 50 ms",
            expectedAssembled: try appendWord("lastfiftyms", toParagraph: paragraph, in: base.assembled))
    }

    @Test("one round trip of the six-chapter book (x6, the document of the VM runs) keeps every flag")
    func bookSixRoundTripKeepsTheFlags() throws {
        let document = ComplexDocumentFixture.book6
        let session = try makeSession(document)
        let base = try baseline(session)
        requirePreconditions(base, document)

        try switchToMarkdown(session)
        try check(session, against: base, step: "x6 switch 1, Rich Text -> Markdown", expectedAssembled: base.assembled)
        try switchToRichText(session)
        try check(session, against: base, step: "x6 switch 2, Markdown -> Rich Text", expectedAssembled: base.assembled)
    }

    // MARK: - The scripts, and the control

    @Test("the pre-switch read returns the whole document, hidden markers included (the end marker keeps the bibliography flagged)")
    func thePreSwitchReadKeepsTheHiddenMarkers() throws {
        let anchor = "<!-- @sid:11111111-1111-1111-1111-111111111111 -->"
        let document = "\(anchor)# Title\n\nText.\n\n<!-- ::auto-bibliography:: -->\n\n# Bibliography\n\nEntry.\n\n\(Self.endMarker)"
        let answer = try run(CodeMirrorEditor.Coordinator.preSwitchContentScript, onPageHolding: document)
        let difference = firstTextDifference(document, answer)
        #expect(
            answer == document,
            "the read must answer the raw document (`getContentRaw()`); `getContent()` would drop the end marker: \(difference)")
        #expect(answer.contains(Self.endMarker))
    }

    @Test("the fetch a close, quit or project switch makes keeps the end marker on a Markdown page, and is unchanged on Rich Text")
    func theFetchScriptKeepsTheEndMarker() throws {
        let anchor = "<!-- @sid:11111111-1111-1111-1111-111111111111 -->"
        let document = "\(anchor)# Title\n\nText.\n\n<!-- ::auto-bibliography:: -->\n\n# Bibliography\n\nEntry.\n\n\(Self.endMarker)"
        let markdownAnswer = try run(BlockSyncService.fetchContentScript, onPageHolding: document)
        #expect(
            markdownAnswer == "# Title\n\nText.\n\n\n\n# Bibliography\n\nEntry.\n\n\(Self.endMarker)",
            "a Markdown page: anchors and the start marker stripped as before, the end marker kept (got \(markdownAnswer.debugDescription))")

        let richTextAnswer = try run(BlockSyncService.fetchContentScript, onPageHolding: document, hasRawReader: false)
        #expect(
            richTextAnswer == "# Title\n\nText.\n\n\n\n# Bibliography\n\nEntry.\n\n",
            "a page with no `getContentRaw` (Rich Text) answers its own `getContent()`, exactly as before (got \(richTextAnswer.debugDescription))")
        #expect(BlockSyncService.fetchContentScript.contains("getContent()"), "the unit-test harnesses answer the fetch by this literal")
    }

    @Test("a Markdown close, quit or project switch saves the text it fetched through the whole-document write and keeps the flags (x1)")
    func lifecycleSaveOfAFetchedMarkdownPageKeepsTheFlags() throws {
        let document = ComplexDocumentFixture.article
        let session = try makeSession(document)
        let base = try baseline(session)
        requirePreconditions(base, document)
        try switchToMarkdown(session)
        let fetched = try run(BlockSyncService.fetchContentScript, onPageHolding: session.state.sourceContent)

        // The step the lifecycle takes with that text (EditorViewState.writeWholeDocumentForLifecycle): prepare, then the write body.
        let prepared = try #require(
            LifecycleWholeDocumentWrite.prepare(
                content: fetched, database: session.db, projectId: session.pid, zoomedRange: nil, zoomedSectionId: nil),
            "the fetched text is not empty, so a write is prepared")
        let body = LifecycleWholeDocumentWrite.body(prepared)
        _ = try session.db.write { try body($0) }

        try check(session, against: base, step: "whole-document save of the fetched Markdown page", expectedAssembled: base.assembled)
    }

    @Test("control: text without the end marker, which is what getContent() left in sourceContent, unflags the bibliography (the VM symptom)")
    func controlTextWithoutTheEndMarkerUnflagsTheBibliography() throws {
        let document = ComplexDocumentFixture.article
        let session = try makeSession(document)
        let base = try baseline(session)
        requirePreconditions(base, document)
        try switchToMarkdown(session)
        session.state.sourceContent = asGetContentReturnsIt(session.state.sourceContent)
        #expect(!session.state.sourceContent.contains(Self.endMarker), "the control text has no end marker")

        session.state.commitMarkdownTextForRichTextSwitch(sectionSyncService: session.service)

        let after = try rows(session)
        let flaggedAfter = after.filter(\.isBibliography).count
        UnitOutputFile.emit("bibliography-survival", [
            "[SURVIVAL] control (getContent() text without the end marker): rows flagged isBibliography "
                + "\(base.bibliographyRows) -> \(flaggedAfter); first row whose flags changed: \(describeFirstDifference(base, after))"
        ])
        // This control passes because `commitMarkdownTextForRichTextSwitch` saves exactly what it is given. It documents WHY the read above must
        // be raw. If the parser ever flags the bibliography without the terminator, this control may be retired -- that is its only valid change.
        #expect(
            flaggedAfter < base.bibliographyRows,
            "control: without the end marker the bibliography is stored as ordinary blocks (\(base.bibliographyRows) -> \(flaggedAfter))")
    }
}

// MARK: - Session, baseline and checks

private struct Session {
    let db: ProjectDatabase
    let pid: String
    let state: EditorViewState
    let service: SectionSyncService
}

private struct RowFlags: Equatable {
    let type: BlockType
    let level: Int?
    let bibliography: Bool
    let notes: Bool
    let pseudoSection: Bool
}

private struct Baseline {
    let flags: [RowFlags]
    let labels: [String]
    let bibliographyRows: Int
    let notesRows: Int
    let bibliographyHeadingRows: Int
    let bibliographyTitledHeadingRows: Int
    let bibliographyHeadingFlags: RowFlags?
    let assembled: String
}

@MainActor
private extension ModeSwitchBibliographySurvivalTests {

    func makeSession(_ document: ComplexDocumentFixture.Document) throws -> Session {
        let db = try TestFixtureFactory.createTemporary(content: document.editorMarkdown)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let state = EditorViewState()
        state.projectDatabase = db
        state.currentProjectId = pid
        // Rich Text mode as the app holds it after a load: `content` is the stored rows assembled for the editor.
        state.content = BlockParser.assembleMarkdownForEditor(from: try db.fetchBlocks(projectId: pid))
        return Session(db: db, pid: pid, state: state, service: SectionSyncService())
    }

    func rows(_ session: Session) throws -> [Block] {
        BlockParser.assemblySorted(try session.db.fetchBlocks(projectId: session.pid))
    }

    func flags(of block: Block) -> RowFlags {
        RowFlags(
            type: block.blockType, level: block.headingLevel, bibliography: block.isBibliography,
            notes: block.isNotes, pseudoSection: block.isPseudoSection)
    }

    func label(of block: Block) -> String {
        String(block.markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
    }

    func isBibliographyTitledHeading(_ block: Block) -> Bool {
        block.blockType == .heading && block.textContent.trimmingCharacters(in: .whitespacesAndNewlines) == "Bibliography"
    }

    func baseline(_ session: Session) throws -> Baseline {
        let current = try rows(session)
        let heading = current.first { $0.blockType == .heading && $0.isBibliography }
        return Baseline(
            flags: current.map(flags(of:)),
            labels: current.map(label(of:)),
            bibliographyRows: current.filter(\.isBibliography).count,
            notesRows: current.filter(\.isNotes).count,
            bibliographyHeadingRows: current.filter { $0.blockType == .heading && $0.isBibliography }.count,
            bibliographyTitledHeadingRows: current.filter(isBibliographyTitledHeading).count,
            bibliographyHeadingFlags: heading.map(flags(of:)),
            assembled: BlockParser.assembleMarkdownForEditor(from: current))
    }

    /// The fixture is shaped like the app's own output, so the checks below cannot pass for lack of anything to lose.
    func requirePreconditions(
        _ baseline: Baseline, _ document: ComplexDocumentFixture.Document, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            baseline.bibliographyRows == document.counts.bibliographyEntries + 1,
            "precondition: the bibliography is the heading and one flagged row per cited key (\(baseline.bibliographyRows) flagged)",
            sourceLocation: sourceLocation)
        #expect(baseline.notesRows > 0, "precondition: the Notes section is flagged", sourceLocation: sourceLocation)
        #expect(
            baseline.bibliographyHeadingRows == 1, "precondition: exactly one flagged bibliography heading", sourceLocation: sourceLocation)
        #expect(
            baseline.bibliographyTitledHeadingRows == 1, "precondition: exactly one heading titled Bibliography", sourceLocation: sourceLocation)
        #expect(
            baseline.assembled.hasSuffix(Self.endMarker), "precondition: the editor text ends with the end marker", sourceLocation: sourceLocation)
    }

    func describeFirstDifference(_ baseline: Baseline, _ current: [Block]) -> String {
        let currentFlags = current.map(flags(of:))
        for index in 0..<min(baseline.flags.count, currentFlags.count) where baseline.flags[index] != currentFlags[index] {
            return "row \(index) \"\(baseline.labels[index])\": was \(baseline.flags[index]), now \(currentFlags[index])"
        }
        return baseline.flags.count == currentFlags.count ? "none" : "row count \(baseline.flags.count) -> \(currentFlags.count)"
    }

    func firstTextDifference(_ expected: String, _ actual: String) -> String {
        let left = Array(expected.utf16)
        let right = Array(actual.utf16)
        var index = 0
        while index < min(left.count, right.count), left[index] == right[index] { index += 1 }
        if index == left.count, index == right.count { return "identical" }
        func context(_ units: [UInt16]) -> String {
            String(decoding: units[max(0, index - 30)..<min(units.count, index + 60)], as: UTF16.self).debugDescription
        }
        return "expected \(left.count) characters, got \(right.count); first difference at offset \(index): "
            + "expected \(context(left)) got \(context(right))"
    }

    /// After a switch: the flags, the headings and the assembled editor text are what they were (plus the typed words).
    func check(
        _ session: Session, against baseline: Baseline, step: String, expectedAssembled: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let current = try rows(session)
        let difference = describeFirstDifference(baseline, current)
        let bibliographyRows = current.filter(\.isBibliography).count
        #expect(
            bibliographyRows == baseline.bibliographyRows,
            "\(step): rows flagged isBibliography \(baseline.bibliographyRows) -> \(bibliographyRows); first row whose flags changed: \(difference)",
            sourceLocation: sourceLocation)
        let notesRows = current.filter(\.isNotes).count
        #expect(
            notesRows == baseline.notesRows,
            "\(step): rows flagged isNotes \(baseline.notesRows) -> \(notesRows); first row whose flags changed: \(difference)",
            sourceLocation: sourceLocation)
        #expect(difference == "none", "\(step): a row's flags changed: \(difference)", sourceLocation: sourceLocation)
        let flaggedHeadings = current.filter { $0.blockType == .heading && $0.isBibliography }.count
        #expect(
            flaggedHeadings == baseline.bibliographyHeadingRows,
            "\(step): flagged bibliography headings \(baseline.bibliographyHeadingRows) -> \(flaggedHeadings)",
            sourceLocation: sourceLocation)
        let titledHeadings = current.filter(isBibliographyTitledHeading).count
        #expect(
            titledHeadings == baseline.bibliographyTitledHeadingRows,
            "\(step): headings titled Bibliography \(baseline.bibliographyTitledHeadingRows) -> \(titledHeadings) (a second bibliography)",
            sourceLocation: sourceLocation)
        let headingFlags = current.first(where: isBibliographyTitledHeading).map(flags(of:))
        let wasFlags = String(describing: baseline.bibliographyHeadingFlags)
        let nowFlags = String(describing: headingFlags)
        #expect(
            headingFlags == baseline.bibliographyHeadingFlags,
            "\(step): the bibliography heading row's flags were \(wasFlags), now \(nowFlags)",
            sourceLocation: sourceLocation)
        let assembled = BlockParser.assembleMarkdownForEditor(from: current)
        checkAssembledText(assembled, step: step, expected: expectedAssembled, sourceLocation: sourceLocation)
    }

    func checkAssembledText(_ assembled: String, step: String, expected: String, sourceLocation: SourceLocation) {
        let markerCount = assembled.components(separatedBy: Self.endMarker).count - 1
        #expect(
            assembled.hasSuffix(Self.endMarker),
            "\(step): the text assembled for the editor no longer ends with the end marker", sourceLocation: sourceLocation)
        #expect(
            markerCount == 1, "\(step): the end marker occurs \(markerCount) times in the assembled text, expected once",
            sourceLocation: sourceLocation)
        #expect(
            assembled == expected, "\(step): the assembled text changed: \(firstTextDifference(expected, assembled))",
            sourceLocation: sourceLocation)
    }

    // MARK: The page model and the two switches

    /// Runs `script` against the Markdown page model (Helpers/MarkdownPageModel.swift: `getContentRaw()` is the document, `getContent()` is
    /// the document with every hidden marker stripped) and returns the answer. With `hasRawReader: false` the page has no `getContentRaw`
    /// (a Rich Text page).
    func run(_ script: String, onPageHolding document: String, hasRawReader: Bool = true) throws -> String {
        try MarkdownPageModel.run(script, onPageHolding: document, hasRawReader: hasRawReader)
    }

    /// Mirror of `getContent()` on the Markdown page: every hidden marker stripped (the regex of ALL_HIDDEN_MARKERS_REGEX).
    func asGetContentReturnsIt(_ text: String) -> String {
        text.replacingOccurrences(
            of: "<!-- @sid:[0-9a-fA-F-]+ -->|<!-- ::auto-bibliography:: -->|<!-- ::auto-bibliography-end:: -->|<!-- ::zoom-notes:: -->",
            with: "", options: .regularExpression)
    }

    /// Rich Text -> Markdown: the WYSIWYG branch of `handleEditorModeToggle` (ViewNotificationModifiers.swift): save `content`, fetch the rows,
    /// compute the section offsets, inject the anchors and the start marker into the Markdown editor's text, then the page's first push.
    func switchToMarkdown(_ session: Session) throws {
        let state = session.state
        state.flushContentToDatabase(overrideContent: state.content, skipUnchangedWrite: true)
        let inputs = ComplexDocumentFixture.switchInputs(storedBlocks: try session.db.fetchBlocks(projectId: session.pid))
        let withAnchors = session.service.injectSectionAnchors(markdown: state.content, sections: inputs.adjustedSections)
        state.sourceContent = session.service.injectBibliographyMarker(markdown: withAnchors, sections: inputs.sectionsToInject)
        // The page's own push (CodeMirrorEditor's onContentChange): sourceContent as is; content without the anchors and the start marker.
        state.content = SectionSyncService.stripBibliographyMarker(from: session.service.stripSectionAnchors(from: state.sourceContent))
    }

    /// Markdown -> Rich Text: the pre-switch read of the Markdown page (the script `CodeMirrorCoordinator.saveAndNotify` runs, answered by the
    /// page model) lands in `sourceContent`, then the text half of the switch, then `onWebViewReady`'s `content = the assembled rows`.
    func switchToRichText(_ session: Session) throws {
        let state = session.state
        state.sourceContent = try run(CodeMirrorEditor.Coordinator.preSwitchContentScript, onPageHolding: state.sourceContent)
        state.commitMarkdownTextForRichTextSwitch(sectionSyncService: session.service)
        #expect(!state.content.contains("@sid"), "the Rich Text editor is handed text without the section anchors")
        #expect(
            !state.content.contains(BlockParser.bibliographyStartMarker),
            "the Rich Text editor is handed text without the bibliography start marker")
        state.content = BlockParser.assembleMarkdownForEditor(from: try session.db.fetchBlocks(projectId: session.pid))
    }

    // MARK: Typing between switches

    /// Body paragraphs that occur exactly once in `text`, standing alone between blank lines: safe places to type a word.
    func editableParagraphs(_ session: Session, in text: String) throws -> [String] {
        try rows(session)
            .filter { $0.blockType == .paragraph && !$0.isBibliography && !$0.isNotes && $0.markdownFragment.first?.isLetter == true }
            .map { $0.markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { text.components(separatedBy: "\n\n" + $0 + "\n\n").count == 2 }
    }

    func appendWord(_ word: String, toParagraph paragraph: String, in text: String) throws -> String {
        let range = try #require(
            text.range(of: "\n\n" + paragraph + "\n\n"), "the paragraph \"\(paragraph.prefix(30))\" stands alone between blank lines")
        return text.replacingCharacters(in: range, with: "\n\n" + paragraph + " " + word + "\n\n")
    }
}
