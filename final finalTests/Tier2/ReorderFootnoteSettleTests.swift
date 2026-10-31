//
//  ReorderFootnoteSettleTests.swift
//  final finalTests
//
//  Tier 2 (t-0b70d1e9, a defect the VM runs found; EVERYDAY): moving a chapter that has footnotes. After the move the references in the
//  TEXT are out of reading order (the moved chapter's 10..18 now come before 1..9), and the footnote service must renumber them into
//  1..N and put the Notes definitions in the same order. The settle's footnote resync is what does it, and it did nothing: a move changes
//  the ORDER of the references but not which labels exist, so the renumber it would make ends in 1..N, the very list the service last
//  committed, and `FootnoteSyncService.performFootnoteUpdate` returned at its `contentHash != lastRenumberedHash` guard ("nothing
//  changed"). A delete or a duplicate changes the label list, so they never met it. `editorFirstJobSettled` therefore asks the footnote
//  resync of a reorder's settle to clear the committed hash itself (`resyncAfterEditorFirstDelete(forgetsCommittedNotes:)`, which passes
//  `resyncNow(forgetCommittedHash: true)`; t-f1a22aa7, Phase 4c, FIX-E / FIX-G: the resync runs `forgetCommittedNotesState()` after its
//  idle wait and just before it writes). Before Phase 4c the settle's first step (`settleReorderOverlay`) cleared it.
//
//  The unit rig's own footnote service never saw it because nothing had committed a hash before the move. These tests use a REAL
//  `FootnoteSyncService` (written through the writer's queue in the first, direct in the second) over a document with 21 footnotes in
//  three chapters, the middle one (labels 10 to 18) moved to the top, and they commit the hash first, as every earlier resync does.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

/// The `.renumberFootnotes` notifications posted while it is alive, with their mappings. Observed without a queue, so a post made on the
/// main thread has been recorded when `post` returns.
private final class RenumberLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String: String]] = []
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(forName: .renumberFootnotes, object: nil, queue: nil) { [weak self] note in
            guard let self else { return }
            let mapping = (note.userInfo?["mapping"] as? [String: String]) ?? [:]
            self.lock.lock()
            self.recorded.append(mapping)
            self.lock.unlock()
        }
    }

    deinit { if let token { NotificationCenter.default.removeObserver(token) } }

    var mappings: [[String: String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Whether a mapping that sends label 10 to 1 and 1 to 10 was posted: the move's own renumber (the notification is global, so another
    /// test's post must not count).
    var postedTheMoveRenumber: Bool {
        mappings.contains { $0["10"] == "1" && $0["1"] == "10" && $0["18"] == "9" && $0["9"] == "18" }
    }
}

@Suite("Reorder settle: footnotes renumbered into reading order (Tier 2)", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct ReorderFootnoteSettleTests {

    // MARK: - The document

    private static let labelCount = 21

    /// A chapter whose paragraphs each carry one reference, in the order of `labels`.
    private static func chapter(_ title: String, _ labels: [Int]) -> String {
        (["# \(title)"] + labels.map { "Claim \($0) rests on a source[^\($0)]." }).joined(separator: "\n\n")
    }

    /// The Notes section as the editor holds it (and as the database held it before the move): definition k is "Note k text."
    private static var notesSection: String {
        (["# Notes"] + (1...labelCount).map { "[^\($0)]: Note \($0) text." }).joined(separator: "\n\n")
    }

    private static let one = Array(1...9)
    private static let two = Array(10...18)
    private static let three = Array(19...21)

    /// Chapters in reading order, references 1..21, the Notes in the same order.
    private static var original: String {
        [chapter("Chapter One", one), chapter("Chapter Two", two), chapter("Chapter Three", three), notesSection].joined(separator: "\n\n")
    }

    /// Chapter Two moved to the top: the references now read 10..18, 1..9, 19..21. The editor's Notes section is untouched by a move.
    private static var moved: String {
        [chapter("Chapter Two", two), chapter("Chapter One", one), chapter("Chapter Three", three), notesSection].joined(separator: "\n\n")
    }

    /// The labels in reading order after the move.
    private static var movedLabels: [String] { (two + one + three).map(String.init) }
    private static var sequentialLabels: [String] { (1...labelCount).map(String.init) }

    /// The Notes definition rows of the database in document order.
    private func noteFragments(_ db: ProjectDatabase, _ pid: String) throws -> [String] {
        try db.fetchBlocks(projectId: pid)
            .filter { $0.isNotes && $0.blockType != .heading }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.markdownFragment)
    }

    /// What the rows must read once the Notes follow the text: row i is labelled i+1 and holds the note that was labelled `movedLabels[i]`.
    private func expectNotesFollowTheText(_ fragments: [String], _ roadName: String) {
        #expect(fragments.count == Self.labelCount, "\(roadName): \(fragments.count) Notes rows instead of \(Self.labelCount)")
        for (index, old) in Self.movedLabels.enumerated() where index < fragments.count {
            let fragment = fragments[index]
            let wanted = "[^\(index + 1)]:"
            #expect(
                fragment.hasPrefix(wanted) && fragment.contains("Note \(old) text."),
                "\(roadName): Notes row \(index + 1) should be '\(wanted) Note \(old) text.', it is '\(fragment)'")
        }
    }

    // MARK: - The settle

    // The settle after an editor-first reorder of Chapter Two (nine footnotes among 21): the service has committed 1..21; the editor's
    // text now reads 10..18, 1..9, 19..21. The settle must make the service renumber (notify the editor with the mapping) and put the
    // Notes definitions in reading order. Before the fix the resync was skipped as "nothing changed" and the Notes stayed 1..21.
    @Test("aMovedChapterWithFootnotesIsRenumberedIntoReadingOrderBySettle")
    func aMovedChapterWithFootnotesIsRenumberedIntoReadingOrderBySettle() async throws {
        let rig = try EditorFirstRig(markdown: Self.original, lifecycleServices: true)
        await rig.footnotes.resyncNow(footnoteRefs: Self.sequentialLabels, projectId: rig.pid, fullContent: Self.original)
        #expect(rig.footnotes.lastKnownRefs == Self.sequentialLabels, "precondition: the service has committed 1..\(Self.labelCount)")
        #expect(
            try noteFragments(rig.db, rig.pid).first?.hasPrefix("[^1]: Note 1 text.") == true,
            "precondition: the Notes start in the original order")
        // The editor has moved the chapter: its text is the moved text, and that is what the settle adopts.
        rig.editorState.content = Self.moved
        rig.quickEditorText = Self.moved
        rig.editorText = Self.moved
        #expect(
            FootnoteSyncService.extractFootnoteRefs(from: Self.moved) == Self.movedLabels,
            "precondition: the moved text reads its references 10..18, 1..9, 19..21")
        let log = RenumberLog()

        await rig.controller.editorFirstJobSettled(opId: UUID(), outcome: .applied, removedLeaders: [], kind: .sectionReorder)

        expectNotesFollowTheText(try noteFragments(rig.db, rig.pid), "after the settle")
        #expect(
            rig.footnotes.lastKnownRefs == Self.sequentialLabels,
            "the service does not hold 1..\(Self.labelCount) afterwards: \(rig.footnotes.lastKnownRefs)")
        #expect(log.postedTheMoveRenumber, "the editor was never told to renumber its references: \(log.mappings)")
    }

    // MARK: - The guard, on the service alone

    // The existing guard, pinned on its own. After the service has committed 1..21, a second resync whose references are only REORDERED
    // (10..18, 1..9, 19..21) renumbers to 1..21 again, hashes to the committed value and writes nothing: no renumber notification, the
    // Notes untouched. That is right for a retype of the same text, and wrong right after a structural job that moved the text. The
    // footnote resync of an editor-first reorder's settle must therefore clear the committed hash (`resyncNow(forgetCommittedHash: true)`
    // runs `forgetCommittedNotesState()` just before the write, FIX-E / FIX-G); this test calls that function by hand: with the hash
    // cleared the same resync writes.
    @Test("theCommittedStateGuardSkipsAMoveThatOnlyReordersTheReferencesUntilItIsForgotten")
    func theCommittedStateGuardSkipsAMoveThatOnlyReordersTheReferencesUntilItIsForgotten() async throws {
        let db = try TestFixtureFactory.createTemporary(content: Self.original)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let service = FootnoteSyncService()
        service.configure(database: db, projectId: pid)
        await service.resyncNow(footnoteRefs: Self.sequentialLabels, projectId: pid, fullContent: Self.original)
        #expect(service.lastKnownRefs == Self.sequentialLabels, "precondition: 1..\(Self.labelCount) is committed")
        let before = try noteFragments(db, pid)
        let log = RenumberLog()

        // Committed: the reordered references change nothing.
        await service.resyncNow(footnoteRefs: Self.movedLabels, projectId: pid, fullContent: Self.moved)
        #expect(try noteFragments(db, pid) == before, "the guard let a move that only reorders the references through")
        #expect(!log.postedTheMoveRenumber, "a renumber was posted although the guard should have skipped the resync")

        // Forgotten (what the settle of a reorder does): the same resync renumbers and reorders the Notes.
        service.forgetCommittedNotesState()
        await service.resyncNow(footnoteRefs: Self.movedLabels, projectId: pid, fullContent: Self.moved)
        expectNotesFollowTheText(try noteFragments(db, pid), "after forgetting the committed state")
        #expect(log.postedTheMoveRenumber, "the renumber was not posted once the committed state was forgotten: \(log.mappings)")
        #expect(service.lastKnownRefs == Self.sequentialLabels)
    }
}
