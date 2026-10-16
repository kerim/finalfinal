//
//  QuickUndoFixtures.swift
//  final finalTests
//
//  Tier 2 (t-94369a83 Phase 4b slice 2b): what the quick undo's guard suites share. The helpers on `EditorFirstRig` that press a
//  key, poll and wait, and the `QuickUndoFixtures` protocol (the article and book6 rigs, the delete helper, the stand-in rebuild
//  that stamps its read the way the three rebuild handlers do). Each suite conforms; nothing here is a test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

extension EditorFirstRig {
    /// Cmd-Z or Cmd-Shift-Z for `entry`, in a child task.
    func startPress(_ entry: StructuralEntry, _ direction: StructuralUndoController.UndoDirection = .undo) -> QuickUndoChildRun {
        let run = QuickUndoChildRun()
        Task { @MainActor in
            await self.controller.handleStructuralRequest(opId: entry.id.uuidString, direction: direction)
            run.done = true
        }
        return run
    }

    /// One routine poll cycle, in a child task.
    func startPoll() -> QuickUndoChildRun {
        let run = QuickUndoChildRun()
        Task { @MainActor in
            await self.sync.pollBlockChangesForTest()
            run.done = true
        }
        return run
    }

    /// Waits at most 5 s for every run to end.
    func awaitRuns(_ runs: [QuickUndoChildRun]) async -> Bool {
        await gateWaitUntil({ runs.allSatisfy(\.done) }, iterations: 1000)
    }

    /// A press that is awaited (bounded at 20 s), then everything settled.
    @discardableResult
    func pressAndSettle(_ entry: StructuralEntry, _ direction: StructuralUndoController.UndoDirection = .undo) async -> Bool {
        let run = startPress(entry, direction)
        let ended = await gateWaitUntil({ run.done }, iterations: 4000)
        let settled = await waitUntilSettled()
        return ended && settled
    }

    /// The outcome words of every undo/redo reply the editor received, in order (`undo performed`, `redo failed`, ...).
    func replyWords() -> [String] {
        events.items.compactMap { event -> String? in
            for (name, word) in [("receiveUndoOutcome", "undo"), ("receiveRedoOutcome", "redo")] where event.contains(name) {
                return word + " " + (["performed", "fallback", "failed", "cancelled"].first { event.contains("'\($0)'") } ?? "?")
            }
            return nil
        }
    }

    /// The text of every Notes definition row, in document order.
    func notesTexts() throws -> [String] {
        try blocks().filter { $0.isNotes && $0.blockType != .heading }.sorted { $0.sortOrder < $1.sortOrder }.map(\.textContent)
    }

    /// Where the database's document differs from `expected` (nil when it does not): a short message, never the whole book.
    func documentDiff(_ expected: String) throws -> String? {
        let actual = try assembledMarkdown()
        guard actual != expected else { return nil }
        let left = Array(actual)
        let right = Array(expected)
        let index = zip(left, right).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(left.count, right.count)
        func excerpt(_ characters: [Character]) -> String {
            String(characters[max(0, index - 40)..<min(characters.count, index + 80)])
        }
        let summary = "differ at offset \(index) (actual \(left.count) characters, expected \(right.count))"
        return summary + ": actual <<\(excerpt(left))>> expected <<\(excerpt(right))>>"
    }

    /// How many of `ids` are NOT rows of the database.
    func missingRowCount(_ ids: [String]) throws -> Int {
        let present = Set(try blocks().map(\.id))
        return ids.filter { !present.contains($0) }.count
    }

    /// How many of `ids` ARE rows of the database.
    func presentRowCount(_ ids: [String]) throws -> Int {
        let present = Set(try blocks().map(\.id))
        return ids.filter { present.contains($0) }.count
    }

    /// How many ids differ between the database's rows and `rows` (in either direction).
    func idDifferenceCount(_ rows: [Block]) throws -> Int {
        Set(try blocks().map(\.id)).symmetricDifference(Set(rows.map(\.id))).count
    }

    /// A row's identity apart from its id: what a parity comparison looks at.
    /// `includingStatus: false` leaves out the section status: the slow undo's snapshot restore re-parses the document and gives a
    /// heading that had no status the default `next`, which the quick undo (the rows exactly as they were) does not.
    static func signature(_ rows: [Block], includingStatus: Bool = true) -> [String] {
        rows.sorted { $0.sortOrder < $1.sortOrder }.map {
            [
                $0.blockType.rawValue, String($0.headingLevel ?? 0), String($0.isNotes), String($0.isBibliography),
                includingStatus ? ($0.status?.rawValue ?? "") : "", ($0.tags ?? []).joined(separator: ","), $0.textContent, $0.markdownFragment
            ].joined(separator: "|")
        }
    }

    /// The parity check as one short message: nil when the two row lists agree, else where they first differ.
    static func parityProblem(_ lhs: [Block], _ rhs: [Block], includingStatus: Bool = true) -> String? {
        let left = signature(lhs, includingStatus: includingStatus)
        let right = signature(rhs, includingStatus: includingStatus)
        return left == right ? nil : firstDifference(left, right)
    }

    /// A short description of where two signatures first differ (the signatures themselves are a whole book's rows).
    static func firstDifference(_ lhs: [String], _ rhs: [String]) -> String {
        if lhs.count != rhs.count { return "row counts differ: \(lhs.count) vs \(rhs.count)" }
        guard let index = zip(lhs, rhs).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset else { return "equal" }
        return "row \(index): \(String(lhs[index].prefix(240))) VERSUS \(String(rhs[index].prefix(240)))"
    }

    /// Notes the renumber notifications the footnote service posts (`.renumberFootnotes`) into `events`, with their mapping.
    func observeRenumbers() -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: .renumberFootnotes, object: nil, queue: .main) { [events] note in
            let mapping = (note.userInfo?["mapping"] as? [String: String]) ?? [:]
            MainActor.assumeIsolated { events.note("renumber \(mapping.isEmpty ? "empty" : "mapping=\(mapping.count)")") }
        }
    }
}

/// A gate that any number of tasks may wait at. (`LifecycleEntryHarness.Gate` keeps ONE continuation: a second waiter replaces the
/// first, which is then never resumed.)
@MainActor
final class QuickUndoMultiGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        let parked = waiting
        waiting = []
        for continuation in parked { continuation.resume() }
    }
}

/// One Delete Section press: the section's root heading, its undo entry, and the ids of every block the section held.
struct QuickUndoDeleted {
    let root: Block
    let entry: StructuralEntry
    let subtree: [String]
}

/// The fixtures the quick undo's guard suites share (see the file header).
@MainActor
protocol QuickUndoFixtures {}

extension QuickUndoFixtures {
    static var villageRegisters: String { "1.2 The Village Registers" }
    static var fourSections: String {
        """
    # Chapter

    The chapter body.

    ## Section A

    The A body.

    ## Section B

    The B body.

    ## Section C

    The C body.
    """
    }

    /// The article, with the footnote service writing through the queue and the delete settle finding the post-delete text in
    /// `content` (as the other article tests do).
    func makeArticleRig() throws -> EditorFirstRig {
        let rig = try EditorFirstRig(markdown: ComplexDocumentFixture.article.editorMarkdown, lifecycleServices: true)
        rig.controller.testEFSettleHold = { [weak rig] in _ = try? rig?.syncEditorContentFromDatabase() }
        return rig
    }

    func makeBookRig() throws -> EditorFirstRig {
        try EditorFirstRig(markdown: ComplexDocumentFixture.book6.editorMarkdown, configureSyncServices: false)
    }

    /// The level-2 sections (headings that are not Notes or Bibliography) whose blocks hold a footnote reference, in document order,
    /// with the number of references each holds.
    func footnotedSections(_ rig: EditorFirstRig) throws -> [(heading: Block, references: Int)] {
        let rows = try rig.blocks()
        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [(heading: Block, references: Int)] = []
        for heading in rows.filter({ $0.blockType == .heading && $0.headingLevel == 2 && !$0.isNotes && !$0.isBibliography })
        .sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let ids = try rig.db.sectionBlockIds(rootId: heading.id, projectId: rig.pid) ?? []
            let text = ids.compactMap { byId[$0]?.markdownFragment }.joined(separator: "\n")
            let count = FootnoteSyncService.extractFootnoteRefs(from: text).count
            if count > 0 { result.append((heading, count)) }
        }
        return result
    }

    /// Delete Section on the heading titled `title` (or the document's first chapter), the press of Delete Section answered by the rig.
    func delete(_ rig: EditorFirstRig, _ title: String? = nil, settle: Bool = true) async throws -> QuickUndoDeleted {
        let root: Block
        if let title {
            root = try rig.heading(title)
        } else {
            root = try #require(try rig.chapterHeadings().first)
        }
        let subtree = try #require(try rig.db.sectionBlockIds(rootId: root.id, projectId: rig.pid))
        try rig.setReply(.init(removedLeaderIds: [root.id]), forRoot: root.id)
        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        #expect(outcome == .performed)
        let entry = try #require(rig.unifiedUndo.undoStack.last)
        if settle {
            await rig.settle(entry.id)
            try rig.syncEditorContentFromDatabase()
        }
        return QuickUndoDeleted(root: root, entry: entry, subtree: subtree)
    }

    /// Where the sidebar's list first differs from the document's outline `expected` (a short description; never the lists), nil when they
    /// agree.
    func sidebarOrderProblem(_ rig: EditorFirstRig, expected: [Block]) -> String? {
        let shown = rig.editorState.sections
        guard shown.map(\.id) != expected.map(\.id) else { return nil }
        let index = zip(shown, expected).enumerated().first { $0.element.0.id != $0.element.1.id }?.offset ?? min(shown.count, expected.count)
        let got = index < shown.count ? shown[index].title : "(end)"
        let wanted = index < expected.count ? expected[index].textContent : "(end)"
        return "\(shown.count) sections vs \(expected.count); at \(index) got '\(got)', wanted '\(wanted)'"
    }

    func firstParagraph(in ids: [String], _ rig: EditorFirstRig) throws -> Block {
        let wanted = Set(ids)
        return try #require(try rig.blocks().sorted { $0.sortOrder < $1.sortOrder }.first {
            wanted.contains($0.id) && $0.blockType == .paragraph && !$0.isNotes && !$0.isBibliography && $0.textContent.count > 20
        })
    }

    func paragraphOutside(_ ids: [String], _ rig: EditorFirstRig) throws -> Block {
        let excluded = Set(ids)
        return try #require(try rig.blocks().sorted { $0.sortOrder < $1.sortOrder }.first {
            !excluded.contains($0.id) && $0.blockType == .paragraph && !$0.isNotes && !$0.isBibliography && $0.textContent.count > 20
        })
    }

    /// A stand-in for a Notes or bibliography rebuild that stamps its database read and pushes through the real guard
    /// (`stampRebuildRead`, `setContentWithBlockIds(stillWanted:)`, `skipStaleRebuildTail`), as the three handlers do. It reads the
    /// database now, lands when `mayLand` opens, and notes `rebuild read` / `rebuild landed` (with the editor state's `content`
    /// at that moment, `rebuild content=...`) in `rig.events`.
    func startStampedRebuild(_ rig: EditorFirstRig, mayLand: LifecycleEntryHarness.Gate) {
        let stamp = rig.editorState.stampRebuildRead()
        let read = rig.controller.fetchFullBlocksWithIds(db: rig.db, pid: rig.pid)
        rig.events.note("rebuild read")
        let task = Task { @MainActor in
            await mayLand.wait()
            if let read {
                rig.editorState.content = read.markdown
                _ = await rig.sync.setContentWithBlockIds(
                    markdown: read.markdown, blockIds: read.blockIds, imageMeta: read.imageMeta,
                    cursorBoundary: read.bibBoundaryIndex, cursorBoundaryEnd: read.bibBoundaryEndIndex,
                    expectedBlocks: read.expectedBlocks, managedBlockIds: read.managedBlockIds, preserveUserBlocks: true,
                    stillWanted: { rig.editorState.rebuildPushStillWanted(stamp) })
                _ = await rig.editorState.skipStaleRebuildTail(stamp, kind: "notes", blockSync: rig.sync)
            }
            rig.editorState.contentState = .idle
            rig.events.note("rebuild landed")
            rig.events.note("rebuild content-equals-live=\(rig.editorState.content == rig.quickEditorText)")
        }
        rig.editorState.registerRebuildTask(task)
    }
}
