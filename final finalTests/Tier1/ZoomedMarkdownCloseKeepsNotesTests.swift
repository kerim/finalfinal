//
//  ZoomedMarkdownCloseKeepsNotesTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  THE BUG (found in review, 2026-10-09). A user zoomed into a chapter in the Markdown view, with a footnote in it, and closes the project,
//  quits or opens another project. The zoomed Markdown page holds the chapter and, after the hidden marker `<!-- ::zoom-notes:: -->`, a small
//  copy of the Notes (`# Notes` and the `[^n]:` definitions of the footnotes used in the chapter). The close, quit and project switch fetch the
//  page's text (`BlockSyncService.fetchContentScript`) and save it (`LifecycleWholeDocumentWrite.prepare`, then the write). `prepare` splits the
//  small Notes off on exactly that marker. The fetch script stripped the marker, so the split found nothing: the `# Notes` heading and the
//  definitions were parsed as part of the chapter and written into it. When the chapter is not the last one, that is the middle of the
//  document: a second Notes heading, the definitions twice, and an edit made to a definition while zoomed never reached the real Notes.
//
//  THE FIX UNDER TEST. The fetch script strips only the section anchors and the bibliography start marker; it keeps the zoom-notes marker (and
//  the bibliography end marker), which is the shape `editorState.content` has in Markdown mode when zoomed.
//
//  HOW THESE TESTS REACH THE REAL BEHAVIOUR. The web page cannot run here, so the Markdown page is the JavaScript model in
//  Helpers/MarkdownPageModel.swift. The production script string runs against it in JavaScriptCore, and its answer is fed to the real
//  `LifecycleWholeDocumentWrite.prepare` and, through `LifecycleFlushHarness`, to the real `EditorViewState.runLifecycleFlush` (a Markdown close
//  of a zoomed section) and the real write into a temporary project database. So if someone puts the zoom-notes marker back into the script's
//  strip list, the text loses the marker BEFORE it reaches `prepare`, and the first three tests below fail: the script test (the marker is
//  gone from the answer), the `prepare` test (no mini-Notes, Notes rows among the section's blocks) and the close test (a second Notes
//  heading, duplicate definitions, the real Notes unchanged). The two control tests run exactly that marker-less text through the same code
//  and assert the damage, so the failure that the first tests would show is the one documented here.
//
//  Not covered here: the lifecycle never fetches a Rich Text page through this script's Markdown branch, and the Rich Text editor serializes
//  the zoom-notes marker itself (web/milkdown/src/zoom-notes-marker-plugin.ts), so its answer is unchanged by this fix.
//

import Foundation
import Testing
@testable import final_final

@Suite("A zoomed Markdown close keeps the Notes in one piece — Tier 1: Silent Killers", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ZoomedMarkdownCloseKeepsNotesTests {

    private static let marker = "<!-- ::zoom-notes:: -->"
    private static let anchor = "<!-- @sid:11111111-1111-1111-1111-111111111111 -->"

    /// Four chapters and the real Notes at the end. The zoomed chapter (Beta) is NOT the last one and has a footnote.
    private static let seed =
        "# Alpha\n\nAlpha body with a note[^1].\n\n# Beta\n\nBeta body with a note[^2].\n\n# Gamma\n\nGamma body.\n\n"
        + "# Notes\n\n[^1]: Alpha definition.\n\n[^2]: Beta definition.\n"

    private static let zoomedBody = "# Beta\n\nBeta body with a note[^2], edited."
    private static let zoomedBodyBeforeEdit = "# Beta\n\nBeta body with a note[^2]."
    private static let editedDefinition = "Beta definition, edited."

    /// The Markdown page's whole document while zoomed on Beta, as `zoomToSection` builds it and the user left it: the chapter, then the
    /// zoom-notes marker and the small Notes with the user's edit to the definition. The section anchor sits on the heading line.
    private static let pageDocument =
        "\(anchor)\(zoomedBody)\n\n\(marker)\n# Notes\n\n[^2]: \(editedDefinition)\n"

    /// What the fetch must answer: the page's text without the anchor, with the marker.
    private static let expectedFetch = "\(zoomedBody)\n\n\(marker)\n# Notes\n\n[^2]: \(editedDefinition)\n"

    private struct ZoomedRig {
        let rig: LifecycleFlushHarness
        let beta: Block
        let gamma: Block
        var range: (start: Double, end: Double?) { (start: beta.sortOrder, end: gamma.sortOrder) }
    }

    /// A Markdown editor zoomed on Beta (Alpha before it, Gamma and the real Notes after it).
    private func zoomedMarkdownRig() throws -> ZoomedRig {
        let rig = try LifecycleFlushHarness(content: Self.seed)
        rig.editorState.editorMode = .source
        let beta = try #require(try rig.blocks().first { $0.blockType == .heading && $0.textContent == "Beta" })
        let gamma = try #require(try rig.blocks().first { $0.blockType == .heading && $0.textContent == "Gamma" })
        rig.editorState.zoomedSectionId = beta.id
        rig.editorState.zoomedBlockRange = (start: beta.sortOrder, end: gamma.sortOrder)
        // The content on hand: the zoomed text as it was before the last edit (not used when the fetch answers).
        rig.editorState.content = "\(Self.zoomedBodyBeforeEdit)\n\n\(Self.marker)\n# Notes\n\n[^2]: Beta definition.\n"
        return ZoomedRig(rig: rig, beta: beta, gamma: gamma)
    }

    private func trimmedFragments(_ rows: [Block]) -> [String] {
        rows.map { $0.markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func notesHeadings(_ rows: [Block]) -> [Block] {
        rows.filter { $0.isNotes && $0.blockType == .heading }
    }

    private func definitionRows(label: String, in rows: [Block]) -> [Block] {
        rows.filter {
            $0.isNotes && $0.blockType == .paragraph && FootnoteSyncService.parseNotesLabel(from: $0.markdownFragment)?.label == label
        }
    }

    // MARK: - The script

    @Test("the fetch of a zoomed Markdown page strips the section anchor and keeps the zoom-notes marker")
    func theFetchKeepsTheZoomNotesMarker() throws {
        let fetched = try MarkdownPageModel.run(BlockSyncService.fetchContentScript, onPageHolding: Self.pageDocument)

        #expect(
            fetched.contains(Self.marker),
            "the marker must reach the save: it is where the small Notes are split off (got \(fetched.debugDescription))")
        #expect(fetched.components(separatedBy: Self.marker).count - 1 == 1, "exactly one marker")
        #expect(!fetched.contains("@sid:"), "the section anchor is stripped")
        #expect(fetched == Self.expectedFetch, "got \(fetched.debugDescription)")
    }

    // MARK: - prepare

    @Test("the fetched zoomed Markdown text, through prepare, yields the small Notes and no Notes rows among the section's blocks")
    func prepareSplitsTheSmallNotesOff() throws {
        let zoomed = try zoomedMarkdownRig()
        let fetched = try MarkdownPageModel.run(BlockSyncService.fetchContentScript, onPageHolding: Self.pageDocument)

        let prepared = try #require(
            LifecycleWholeDocumentWrite.prepare(
                content: fetched, database: zoomed.rig.db, projectId: zoomed.rig.pid,
                zoomedRange: AnchoredSortOrderRange(unanchored: zoomed.range), zoomedSectionId: zoomed.beta.id),
            "the fetched text is not empty, so a write is prepared")

        #expect(prepared.miniNotes != nil, "a zoomed text with the marker yields the small Notes")
        #expect(
            prepared.miniNoteDefinitions == ["2": Self.editedDefinition],
            "the edited definition is carried to the real Notes (got \(prepared.miniNoteDefinitions))")
        #expect(
            !prepared.blocks.contains(where: { $0.isNotes }),
            "no Notes row among the section's blocks: \(prepared.blocks.map { "\($0.blockType) isNotes=\($0.isNotes)" })")
        #expect(prepared.blocks.count == 2, "the chapter is its heading and its paragraph (got \(prepared.blocks.count))")
        #expect(!trimmedFragments(prepared.blocks).contains(where: { $0.contains(Self.marker) }), "the marker is not stored in any block")
    }

    // MARK: - The close

    @Test("a zoomed Markdown close, of a section that is not the last and has a footnote, leaves one Notes heading and each definition once")
    func zoomedMarkdownCloseKeepsTheNotesInOnePiece() async throws {
        let zoomed = try zoomedMarkdownRig()
        let rig = zoomed.rig
        rig.fetchAnswer = try MarkdownPageModel.run(BlockSyncService.fetchContentScript, onPageHolding: Self.pageDocument)

        let result = await rig.run(.close)

        #expect(result.outcome == .flushed)
        #expect(result.fbOutcome == .applied, "the zoomed write was applied (got \(String(describing: result.fbOutcome)))")
        #expect(!result.usedFallback, "the fetch answered")
        let rows = try rig.blocks()

        // One Notes heading, and it is the last heading of the document (after Gamma), not one in the middle.
        let headings = notesHeadings(rows)
        #expect(headings.count == 1, "exactly one Notes heading (got \(headings.count))")
        let gammaIndex = try #require(rows.firstIndex(where: { $0.id == zoomed.gamma.id }))
        let notesIndex = try #require(rows.firstIndex(where: { $0.isNotes && $0.blockType == .heading }))
        #expect(notesIndex > gammaIndex, "the Notes heading comes after the last chapter")

        // Each definition once, and the edit made while zoomed is stored in the real Notes.
        #expect(definitionRows(label: "1", in: rows).count == 1, "[^1] once")
        #expect(definitionRows(label: "2", in: rows).count == 1, "[^2] once")
        let definitions = try rig.notesDefinitions()
        #expect(definitions["1"] == "Alpha definition.", "the other chapter's definition is untouched (got \(String(describing: definitions["1"])))")
        #expect(
            definitions["2"] == Self.editedDefinition,
            "the edit made while zoomed reached the real Notes (got \(String(describing: definitions["2"])))")

        // The chapters: Beta carries the edit, Alpha and Gamma are untouched, and the marker is stored nowhere.
        let body = trimmedFragments(rows.filter { !$0.isNotes })
        #expect(body.contains("Beta body with a note[^2], edited."), "got \(body)")
        #expect(!body.contains("Beta body with a note[^2]."), "the old text of the chapter is replaced")
        #expect(body.contains("Alpha body with a note[^1]."))
        #expect(body.contains("Gamma body."))
        let storedMarker = rows.contains(where: { $0.markdownFragment.contains(Self.marker) || $0.textContent.contains(Self.marker) })
        #expect(!storedMarker, "the marker is not stored")
    }

    // MARK: - Controls: what the marker-less text does

    @Test("control: the text with the marker stripped (what the fetch used to answer) yields no small Notes and Notes rows in the section")
    func controlWithoutTheMarkerPrepareFindsNoSmallNotes() throws {
        let zoomed = try zoomedMarkdownRig()
        let markerless = Self.expectedFetch.replacingOccurrences(of: Self.marker, with: "")

        let prepared = try #require(
            LifecycleWholeDocumentWrite.prepare(
                content: markerless, database: zoomed.rig.db, projectId: zoomed.rig.pid,
                zoomedRange: AnchoredSortOrderRange(unanchored: zoomed.range), zoomedSectionId: zoomed.beta.id))

        #expect(prepared.miniNotes == nil, "nothing to split on: no small Notes")
        #expect(prepared.miniNoteDefinitions.isEmpty)
        #expect(
            prepared.blocks.contains(where: { $0.isNotes && $0.blockType == .heading }),
            "the Notes heading is parsed as part of the chapter")
    }

    @Test("control: a zoomed Markdown close of the marker-less text writes a second Notes heading and the definition twice")
    func controlWithoutTheMarkerTheCloseDuplicatesTheNotes() async throws {
        let zoomed = try zoomedMarkdownRig()
        let rig = zoomed.rig
        rig.fetchAnswer = Self.expectedFetch.replacingOccurrences(of: Self.marker, with: "")

        let result = await rig.run(.close)

        #expect(result.fbOutcome == .applied)
        let rows = try rig.blocks()
        // Written from reading `replaceBlocksInRange`: the real Notes lie outside the zoom range, so nothing merges the parsed definition into
        // them, and the parsed Notes heading and definition are inserted inside the range, in the middle of the document.
        #expect(notesHeadings(rows).count == 2, "a second Notes heading in the middle of the document (got \(notesHeadings(rows).count))")
        let betaDefinitions = definitionRows(label: "2", in: rows)
        #expect(betaDefinitions.count == 2, "the definition twice (got \(betaDefinitions.count))")
        let lastDefinition = betaDefinitions.last.flatMap { FootnoteSyncService.parseNotesLabel(from: $0.markdownFragment)?.text }
        #expect(lastDefinition == "Beta definition.", "the real Notes, at the end, keep the old text (got \(String(describing: lastDefinition)))")
    }
}
