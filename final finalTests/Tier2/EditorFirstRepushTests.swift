//
//  EditorFirstRepushTests.swift
//  final finalTests
//
//  Tier 2 (t-18b7fa48 Phase 4b, round 1b-ii; the cure the judge ordered for the regression round 1b introduced). Driven with
//  `EditorFirstRig` (EditorFirstDeleteTests.swift).
//
//  THE PROBLEM. Each editor-first click (Delete Section now; Duplicate Section and the restores in the next rounds) makes a Notes or
//  Bibliography rebuild that read the database before the click, or while an editor-first job was pending, skip its editor push
//  (`rebuildPushStillWanted`). The database is already right; only the EDITOR keeps the deleted section's footnote definitions. The
//  operation's own settle cannot repair that (`FootnoteSyncService` skips a second resync of the same references), so after two
//  section operations back to back the editor's Notes stayed wrong, and a close right after saved them.
//
//  THE CURE. A skipped push for an editor-first reason raises `EditorViewState.managedRegionsNeedRepush`; the shared settle tail
//  (`settleManagedRegionsAtEndOfEditorFirstSettle`) pushes the database's Notes and Bibliography into the editor once the flag is up
//  and no editor-first job is pending, and, while a close or quit holds the editor, the existing closing push does it unconditionally.
//
//  WHAT THESE TESTS LOOK AT: the editor's Notes (the rig's `editorText`, which a merge-guarded push replaces) against the database's,
//  and the references against the definitions. The only counter is T3's spy, which pins that the cure is conditional.
//
//  THE RIG'S EDITOR. The rig has no ContentView, so no rebuild fires by itself: a held stand-in rebuild (`startHeldRebuild`) plays the
//  Notes rebuild that the operation's resync starts, through the real guard (`stampRebuildRead`, `setContentWithBlockIds(stillWanted:)`,
//  `skipStaleRebuildTail`). It is released only after the first operation's footnote resync has written the Notes to the database,
//  and it never assigns `content` itself (the real handlers do, and then the guard's tail puts the editor's own text back); that keeps
//  the settles' reads of `content` independent of when the stand-in lands. The editor's own document is modelled by `editorText`:
//  the sections gone and the references renumbered, with the Notes still the old ones (the half-updated state the real editor is
//  in until a push brings the database's Notes).
//
//  The article's footnote definitions of the section deleted first are marked "GONE-<label>" so that a leftover definition is
//  recognisable by its text.
//
//  ROUND 1e-ii: T1 and T4 repeat with the second operation a DUPLICATE of the footnote-free section B (`Scenario.duplicateClick`,
//  `testDeleteThenDuplicateRepairsTheEditorsNotes_article`, `testCloseRightAfterDeleteAndDuplicateSavesTheRightNotes_article`). The rig's
//  editor works out the post-duplicate document from its OWN text (`duplicateInsertsIntoEditorText`), so its Notes stay the half-updated
//  ones until the settle's re-push brings the database's.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Editor-first re-push after a skipped rebuild (t-18b7fa48 round 1b-ii, Tier 2)", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct EditorFirstRepushTests {

    // MARK: - The scenario

    private enum ScenarioError: Error {
        case noFootnotedSection
        case noFootnoteFreeSection
        case noSubtree
        case clickRefused
    }

    /// What the scenario finds in the article's text: the article with A's definitions marked, and the two titles.
    private struct Found {
        let marked: String
        let aTitle: String
        let bTitle: String
    }

    /// The article with section A (the first with footnotes) and section B (the first without any), A's definitions marked.
    @MainActor
    private final class Scenario {
        let rig: EditorFirstRig
        let aTitle: String
        let bTitle: String
        let rowsBefore: [Block]
        let subtreeA: Set<String>
        let subtreeB: Set<String>
        /// Opens the held stand-in rebuild.
        let mayLand = LifecycleEntryHarness.Gate()
        private var rebuildStarted = false

        init() throws {
            let found = try Scenario.discoverSections()
            let rig = try EditorFirstRig(markdown: found.marked, lifecycleServices: true)
            rig.js.answer("flushPendingBlockChanges", true)
            rig.fetchAnswerProvider = { [unowned rig] in rig.editorText }
            rig.controller.testOrderingSpy = { [spyLog = rig.spyLog, events = rig.events] step in
                spyLog.note(step)
                events.note("spy " + step)
            }
            let a = try rig.heading(found.aTitle)
            let b = try rig.heading(found.bTitle)
            guard let subtreeA = try rig.db.sectionBlockIds(rootId: a.id, projectId: rig.pid),
                  let subtreeB = try rig.db.sectionBlockIds(rootId: b.id, projectId: rig.pid) else { throw ScenarioError.noSubtree }
            self.rig = rig
            self.aTitle = found.aTitle
            self.bTitle = found.bTitle
            self.rowsBefore = try rig.blocks()
            self.subtreeA = Set(subtreeA)
            self.subtreeB = Set(subtreeB)
        }

        /// Reads the article's text (no database): the level-2 sections up to the Notes, with the footnote references each holds.
        private static func discoverSections() throws -> Found {
            let markdown = ComplexDocumentFixture.article.editorMarkdown
            var sections: [(title: String, labels: [String])] = []
            var current: (title: String, lines: [String])?
            func flush() {
                if let current {
                    sections.append((current.title, FootnoteSyncService.extractFootnoteRefs(from: current.lines.joined(separator: "\n"))))
                }
                current = nil
            }
            for line in markdown.components(separatedBy: "\n") {
                if line.hasPrefix("# ") {
                    flush()
                    if line == "# Notes" { break }
                } else if line.hasPrefix("## ") {
                    flush()
                    current = (String(line.dropFirst(3)), [])
                } else if current != nil {
                    current?.lines.append(line)
                }
            }
            flush()
            guard let a = sections.first(where: { !$0.labels.isEmpty }) else { throw ScenarioError.noFootnotedSection }
            guard let b = sections.first(where: { $0.labels.isEmpty }) else { throw ScenarioError.noFootnoteFreeSection }
            var marked = markdown
            for label in a.labels {
                marked = marked.replacingOccurrences(of: "\n[^\(label)]: ", with: "\n[^\(label)]: GONE-\(label) ")
            }
            return Found(marked: marked, aTitle: a.title, bTitle: b.title)
        }

        // MARK: Driving it

        /// The settles sync `content` from the database when they start (as `makeArticleRig` does); the first one also starts the held
        /// stand-in rebuild when `startsRebuild`: the Notes rebuild the operation's resync starts, whose read is stamped when the
        /// operation's job has ended (the pending count is already down) and before any later click.
        func holdSettles(startingRebuildAtFirstSettle startsRebuild: Bool) {
            rig.controller.testEFSettleHold = { [weak self] in
                guard let self else { return }
                _ = try? self.rig.syncEditorContentFromDatabase()
                if startsRebuild, !self.rebuildStarted {
                    self.rebuildStarted = true
                    self.startHeldRebuild()
                }
            }
        }

        /// A Notes rebuild that stamps and reads the database now and lands when `mayLand` opens (see the file header).
        func startHeldRebuild(kind: String = "notes") {
            let stamp = rig.editorState.stampRebuildRead()
            let read = rig.controller.fetchFullBlocksWithIds(db: rig.db, pid: rig.pid)
            rig.events.note("rebuild read")
            let rig = self.rig
            let mayLand = self.mayLand
            let task = Task { @MainActor in
                await mayLand.wait()
                if let read {
                    _ = await rig.sync.setContentWithBlockIds(
                        markdown: read.markdown, blockIds: read.blockIds, imageMeta: read.imageMeta,
                        cursorBoundary: read.bibBoundaryIndex, cursorBoundaryEnd: read.bibBoundaryEndIndex,
                        expectedBlocks: read.expectedBlocks, managedBlockIds: read.managedBlockIds, preserveUserBlocks: true,
                        stillWanted: { rig.editorState.rebuildPushStillWanted(stamp) })
                    if await rig.editorState.skipStaleRebuildTail(stamp, kind: kind, blockSync: rig.sync) {
                        rig.events.note("rebuild push skipped")
                    }
                }
                rig.editorState.contentState = .idle
                rig.events.note("rebuild landed")
            }
            rig.editorState.registerRebuildTask(task)
        }

        /// The Delete Section press on `title`'s section, answered by the rig's editor. The editor's own document loses the sections
        /// in `removed` (and has the footnote renumber applied) before the press, as it does inside the click.
        func click(_ title: String, editorLoses removed: Set<String>) async throws {
            rig.editorText = editorText(removing: removed)
            let root = try rig.heading(title)
            try rig.setReply(.init(removedLeaderIds: [root.id]), forRoot: root.id)
            let outcome = await rig.controller.performSectionDelete(rootId: root.id)
            guard outcome == .performed else { throw ScenarioError.clickRefused }
        }

        /// The Duplicate Section press on `title`'s section (the footnote-free B), answered by the rig's editor (round 1e-ii). The editor's
        /// own document is the half-updated one `editorText(removing:)` gives (the sections in `removed` gone, the references renumbered,
        /// the Notes still the old ones) with the copy inserted right after the section; the rig keeps the Notes the editor held.
        func duplicateClick(_ title: String, editorLoses removed: Set<String>) async throws {
            rig.editorText = editorText(removing: removed)
            rig.duplicateInsertsIntoEditorText = true
            let root = try rig.heading(title)
            let outcome = await rig.controller.performSectionDuplicate(rootId: root.id)
            guard outcome == .performed else { throw ScenarioError.clickRefused }
        }

        /// The Rich Text editor's document once the sections whose rows are `removed` are gone and the footnote renumber has run:
        /// the original rows without them (the Notes are still the old ones), the references numbered 1...n in document order and
        /// every definition that carries one of the renamed labels renamed with it. The deleted section's own definitions stay, so a
        /// label appears twice: the half-updated state the real editor is in.
        func editorText(removing removed: Set<String>) -> String {
            let kept = rowsBefore.filter { !removed.contains($0.id) }
                .sorted { ($0.sortOrder, $0.blockType == .heading ? 0 : 1) < ($1.sortOrder, $1.blockType == .heading ? 0 : 1) }
            return EditorFirstFootnoteLifecycleTests.renumbered(BlockParser.assembleMarkdownForEditor(from: kept))
        }

        /// Waits until section A's footnote resync has written its Notes: none of A's marked definitions is left in the database.
        func waitUntilNotesAreResynced() async -> Bool {
            await gateWaitUntil({ !((try? self.rig.assembledMarkdown()) ?? "GONE-").contains("GONE-") }, iterations: 3000)
        }

        // MARK: What the user sees

        /// The Notes section of `markdown`: from the Notes heading to the Bibliography heading (or the end).
        static func notesSection(_ markdown: String) -> String {
            guard let start = markdown.range(of: "\n# Notes\n") else { return "" }
            let rest = markdown[start.lowerBound...]
            guard let end = rest.range(of: "\n# Bibliography\n") else { return String(rest) }
            return String(rest[..<end.lowerBound])
        }

        /// Every reference has its definition and no definition is left over: the labels of the references and of the definitions
        /// are the same list.
        func expectReferencesAndNotesAgree(in markdown: String, _ context: String) {
            let labels = EditorFirstFootnoteLifecycleTests.footnoteLabels(in: markdown)
            let references = labels.references.sorted(by: EditorFirstFootnoteLifecycleTests.numeric)
            let definitions = labels.definitions.sorted(by: EditorFirstFootnoteLifecycleTests.numeric)
            let disagreement = "\(context): references and Notes disagree: \(references.count) references \(references), "
                + "\(definitions.count) definitions \(definitions)"
            #expect(references == definitions, Comment(rawValue: disagreement))
            #expect(!markdown.contains("GONE-"), "\(context): a definition from the deleted section is still in the Notes")
        }

        /// The editor's Notes are the database's, with none of the deleted section's definitions, and every reference has its note.
        func expectEditorNotesAreTheDatabases(_ context: String) throws {
            let editor = try #require(rig.editorText, "the rig's editor has no document")
            let database = try rig.assembledMarkdown()
            let editorNotes = Self.notesSection(editor)
            let databaseNotes = Self.notesSection(database)
            #expect(!databaseNotes.isEmpty, "\(context): the database has no Notes section (the fixture changed?)")
            let difference = "\(context): the editor's Notes differ from the database's (editor \(editorNotes.count) characters, "
                + "database \(databaseNotes.count))"
            #expect(editorNotes == databaseNotes, Comment(rawValue: difference))
            expectReferencesAndNotesAgree(in: editor, context)
        }
    }

    // MARK: - T1

    // T1: delete A (footnoted), A's Notes rebuild read just before the next click and lands after it; delete B (footnote-free). The
    // editor's Notes must be the database's.
    @Test("T1: Delete a footnoted section, then at once another: the editor's Notes end up the database's")
    func testDeleteThenDeleteRepairsTheEditorsNotes_article() async throws {
        let scenario = try Scenario()
        let rig = scenario.rig
        scenario.holdSettles(startingRebuildAtFirstSettle: true)
        defer { scenario.mayLand.open() }

        try await scenario.click(scenario.aTitle, editorLoses: scenario.subtreeA)
        #expect(await gateWaitUntil({ rig.events.items.contains("rebuild read") }, iterations: 3000), "A's settle never started its rebuild")
        #expect(await scenario.waitUntilNotesAreResynced(), "A's footnote resync never wrote the Notes")
        let staleNotes = try #require(rig.editorText).contains("GONE-")
        #expect(staleNotes, "precondition: the editor's Notes still hold the deleted section's definitions")

        // The next click comes while A's Notes rebuild (read after A's job, before this click) is still out.
        try await scenario.click(scenario.bTitle, editorLoses: scenario.subtreeA.union(scenario.subtreeB))
        scenario.mayLand.open()
        #expect(await rig.waitUntilSettled(iterations: 4000), "the two deletes never settled")
        await rig.editorState.awaitNoRunningRebuilds(label: "test", showsNotice: false)

        #expect(rig.events.items.contains("rebuild push skipped"), "precondition: the click made the rebuild's push stale")
        try scenario.expectEditorNotesAreTheDatabases("after two deletes")
        #expect(!rig.editorState.managedRegionsNeedRepush, "the re-push owed to the editor was made")
        #expect(rig.editorState.pendingEditorFirstJobs == 0)
    }

    // MARK: - T2

    // T2: the same, but the rebuild read while A's job was still pending and B is clicked while that job is still held.
    @Test("T2: A rebuild that read while the first job was pending, and a second click while it is held: the editor's Notes end up right")
    func testClickWhileTheFirstJobPendsRepairsTheEditorsNotes_article() async throws {
        let scenario = try Scenario()
        let rig = scenario.rig
        scenario.holdSettles(startingRebuildAtFirstSettle: false)
        defer { scenario.mayLand.open() }

        let blocker = try rig.holdQueue()   // A's job waits behind this
        defer { rig.release(blocker) }
        try await scenario.click(scenario.aTitle, editorLoses: scenario.subtreeA)
        #expect(rig.editorState.pendingEditorFirstJobs == 1, "precondition: A's job is pending")
        scenario.startHeldRebuild()   // reads the database while A's job is pending
        try await scenario.click(scenario.bTitle, editorLoses: scenario.subtreeA.union(scenario.subtreeB))
        #expect(rig.editorState.pendingEditorFirstJobs == 2, "precondition: both jobs are pending")

        rig.release(blocker)
        #expect(await scenario.waitUntilNotesAreResynced(), "A's footnote resync never wrote the Notes")
        let staleNotes = try #require(rig.editorText).contains("GONE-")
        #expect(staleNotes, "precondition: the editor's Notes still hold the deleted section's definitions")
        scenario.mayLand.open()
        #expect(await rig.waitUntilSettled(iterations: 4000), "the two deletes never settled")
        await rig.editorState.awaitNoRunningRebuilds(label: "test", showsNotice: false)

        #expect(rig.events.items.contains("rebuild push skipped"), "precondition: the guard made the rebuild's push stale")
        try scenario.expectEditorNotesAreTheDatabases("after a click while the first job was pending")
        #expect(!rig.editorState.managedRegionsNeedRepush, "the re-push owed to the editor was made")
        #expect(rig.editorState.pendingEditorFirstJobs == 0)
    }

    // T2b: no second click at all: the rebuild's only fault is that it read while A's job was pending, and A's own settle repairs it.
    @Test("T2b: A rebuild that read while the delete's job was pending: the delete's own settle puts the database's Notes into the editor")
    func testRebuildThatReadWhileTheJobPendedIsRepaired_article() async throws {
        let scenario = try Scenario()
        let rig = scenario.rig
        scenario.holdSettles(startingRebuildAtFirstSettle: false)
        defer { scenario.mayLand.open() }

        let blocker = try rig.holdQueue()   // A's job waits behind this
        defer { rig.release(blocker) }
        try await scenario.click(scenario.aTitle, editorLoses: scenario.subtreeA)
        scenario.startHeldRebuild()   // reads the database while A's job is pending; no click follows
        rig.release(blocker)
        #expect(await scenario.waitUntilNotesAreResynced(), "A's footnote resync never wrote the Notes")
        let staleNotes = try #require(rig.editorText).contains("GONE-")
        #expect(staleNotes, "precondition: the editor's Notes still hold the deleted section's definitions")
        scenario.mayLand.open()
        #expect(await rig.waitUntilSettled(iterations: 4000), "the delete never settled")
        await rig.editorState.awaitNoRunningRebuilds(label: "test", showsNotice: false)

        #expect(rig.events.items.contains("rebuild push skipped"), "precondition: the guard made the rebuild's push stale")
        try scenario.expectEditorNotesAreTheDatabases("after a rebuild that read while the job was pending")
        #expect(!rig.editorState.managedRegionsNeedRepush, "the re-push owed to the editor was made")
    }

    // MARK: - T3

    // T3: one footnoted delete and nothing after it: nothing was skipped, so nothing is re-pushed (the cure is conditional).
    @Test("T3: A footnoted delete with no rebuild skipped and no second click makes no re-push of the Notes")
    func testOneFootnotedDeleteMakesNoExtraRepush_article() async throws {
        let scenario = try Scenario()
        let rig = scenario.rig
        scenario.holdSettles(startingRebuildAtFirstSettle: false)

        try await scenario.click(scenario.aTitle, editorLoses: scenario.subtreeA)
        #expect(await rig.waitUntilSettled(iterations: 4000), "the delete never settled")
        await rig.editorState.awaitNoRunningRebuilds(label: "test", showsNotice: false)

        #expect(!rig.editorState.managedRegionsNeedRepush, "nothing was skipped, so nothing is owed")
        #expect(
            !rig.events.items.contains("spy efRepushManagedRegions"),
            "the settle re-pushed the managed regions though no rebuild had been skipped")
        let regionPushes = rig.pushes.filter { $0.preserveUserBlocks }
        #expect(regionPushes.isEmpty, "the settle pushed the managed regions though no rebuild had been skipped: \(regionPushes.count) push(es)")
        let finalMarkdown = try rig.assembledMarkdown()
        #expect(!finalMarkdown.contains("GONE-"), "precondition: the database's Notes were resynced")
    }

    // MARK: - T4

    // T4: delete A (footnoted) with its Notes rebuild held, delete B (footnote-free), press Cmd-W at once, release the rebuild. The
    // saved document's Notes carry nothing of A and agree with the references.
    @Test("T4: Delete a footnoted section, then another, then close at once: the saved Notes carry nothing of the first and match the references")
    func testCloseRightAfterTwoDeletesSavesTheRightNotes_article() async throws {
        let scenario = try Scenario()
        let rig = scenario.rig
        scenario.holdSettles(startingRebuildAtFirstSettle: true)
        defer { scenario.mayLand.open() }

        try await scenario.click(scenario.aTitle, editorLoses: scenario.subtreeA)
        #expect(await gateWaitUntil({ rig.events.items.contains("rebuild read") }, iterations: 3000), "A's settle never started its rebuild")
        #expect(await scenario.waitUntilNotesAreResynced(), "A's footnote resync never wrote the Notes")
        try await scenario.click(scenario.bTitle, editorLoses: scenario.subtreeA.union(scenario.subtreeB))

        // Cmd-W straight away, no wait; the rebuild lands only afterwards.
        let lifecycle = Task { @MainActor in await rig.runLifecycle(.close, bounds: .production) }
        let armed = await gateWaitUntil { rig.editorState.structuralGate.isClosedToNewWork }
        #expect(armed, "the close never reached its step 1")
        scenario.mayLand.open()
        let result = await lifecycle.value

        #expect(result.outcome == .flushed, "the close completed: \(result.outcome)")
        #expect(!result.opStillRunning, "the two deletes' follow-up work ended inside the wait")
        #expect(rig.events.items.contains("rebuild push skipped"), "precondition: the click made the rebuild's push stale")
        let saved = try rig.assembledMarkdown()
        scenario.expectReferencesAndNotesAgree(in: saved, "the saved document")
        #expect(!rig.editorState.managedRegionsNeedRepush, "the closing push was made")
    }

}

// The same two tests with a Duplicate as the second operation (round 1e-ii). An extension of the suite in the same file, so that the
// private `Scenario` above is in reach.
extension EditorFirstRepushTests {

    // MARK: - T1, with a Duplicate as the second operation (round 1e-ii)

    // T1 (duplicate): delete A (footnoted), A's Notes rebuild read just before the next click and lands after it; duplicate B (footnote-free).
    // The editor's Notes must be the database's, and the copy must be there.
    @Test("T1 (duplicate): Delete a footnoted section, then at once Duplicate another: the editor's Notes end up the database's")
    func testDeleteThenDuplicateRepairsTheEditorsNotes_article() async throws {
        let scenario = try Scenario()
        let rig = scenario.rig
        scenario.holdSettles(startingRebuildAtFirstSettle: true)
        defer { scenario.mayLand.open() }

        try await scenario.click(scenario.aTitle, editorLoses: scenario.subtreeA)
        #expect(await gateWaitUntil({ rig.events.items.contains("rebuild read") }, iterations: 3000), "A's settle never started its rebuild")
        #expect(await scenario.waitUntilNotesAreResynced(), "A's footnote resync never wrote the Notes")
        let staleNotes = try #require(rig.editorText).contains("GONE-")
        #expect(staleNotes, "precondition: the editor's Notes still hold the deleted section's definitions")

        // The duplicate comes while A's Notes rebuild (read after A's job, before this click) is still out.
        try await scenario.duplicateClick(scenario.bTitle, editorLoses: scenario.subtreeA)
        let copyTitle = scenario.bTitle + " copy"
        let editorAfterClick = try #require(rig.editorText)
        #expect(editorAfterClick.contains("GONE-"), "precondition: the duplicate click left the editor's own Notes alone")
        #expect(editorAfterClick.contains(copyTitle), "precondition: the editor's document holds the copy")
        scenario.mayLand.open()
        #expect(await rig.waitUntilSettled(iterations: 4000), "the delete and the duplicate never settled")
        await rig.editorState.awaitNoRunningRebuilds(label: "test", showsNotice: false)

        #expect(rig.events.items.contains("rebuild push skipped"), "precondition: the click made the rebuild's push stale")
        try scenario.expectEditorNotesAreTheDatabases("after a delete and a duplicate")
        #expect(!rig.editorState.managedRegionsNeedRepush, "the re-push owed to the editor was made")
        #expect(rig.editorState.pendingEditorFirstJobs == 0)
        #expect(try rig.blocks().filter { $0.textContent == copyTitle }.count == 1, "the copy is in the table exactly once")
        let editorAtEnd = try #require(rig.editorText)
        #expect(editorAtEnd.contains(copyTitle), "the copy is still in the editor's document")
    }

    // MARK: - T4, with a Duplicate as the second operation (round 1e-ii)

    // T4 (duplicate): delete A (footnoted) with its Notes rebuild held, duplicate B (footnote-free), press Cmd-W at once, release the
    // rebuild. The saved document's Notes carry nothing of A, agree with the references, and the saved document holds the copy.
    @Test("T4 (duplicate): Delete a footnoted section, then Duplicate another, then close at once: the saved Notes are right")
    func testCloseRightAfterDeleteAndDuplicateSavesTheRightNotes_article() async throws {
        let scenario = try Scenario()
        let rig = scenario.rig
        scenario.holdSettles(startingRebuildAtFirstSettle: true)
        defer { scenario.mayLand.open() }

        try await scenario.click(scenario.aTitle, editorLoses: scenario.subtreeA)
        #expect(await gateWaitUntil({ rig.events.items.contains("rebuild read") }, iterations: 3000), "A's settle never started its rebuild")
        #expect(await scenario.waitUntilNotesAreResynced(), "A's footnote resync never wrote the Notes")
        try await scenario.duplicateClick(scenario.bTitle, editorLoses: scenario.subtreeA)
        let editorAfterClick = try #require(rig.editorText)
        #expect(editorAfterClick.contains("GONE-"), "precondition: the duplicate click left the editor's own Notes alone")

        // Cmd-W straight away, no wait; the rebuild lands only afterwards.
        let lifecycle = Task { @MainActor in await rig.runLifecycle(.close, bounds: .production) }
        let armed = await gateWaitUntil { rig.editorState.structuralGate.isClosedToNewWork }
        #expect(armed, "the close never reached its step 1")
        scenario.mayLand.open()
        let result = await lifecycle.value

        #expect(result.outcome == .flushed, "the close completed: \(result.outcome)")
        #expect(!result.opStillRunning, "the delete's and the duplicate's follow-up work ended inside the wait")
        #expect(rig.events.items.contains("rebuild push skipped"), "precondition: the click made the rebuild's push stale")
        let saved = try rig.assembledMarkdown()
        scenario.expectReferencesAndNotesAgree(in: saved, "the saved document")
        #expect(saved.contains(scenario.bTitle + " copy"), "the saved document lost the copy")
        #expect(!rig.editorState.managedRegionsNeedRepush, "the closing push was made")
    }
}
