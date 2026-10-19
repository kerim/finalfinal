//
//  EditorFirstSectionRestoreTests.swift
//  final finalTests
//
//  Tier 2 (t-18b7fa48 Phase 4b slice 2, round 2d-ii; plan-v3 tests U-S2-1, U-S2-2, U-S2-4, U-S2-5, U-S2-5d, D8 and the A1 case): the two
//  SECTION Version History restores, editor first. "Replace Current Section" replaces the target heading's FLAT range (its own text,
//  never its sub-sections); "Restore as Duplicate" inserts the version's section after the last section. Driven with `EditorFirstRig`
//  (EditorFirstDeleteTests.swift); the editor's answers (`replaceRangeEditorFirst`, modes "section" and "insertAfter") are in
//  EditorFirstRig+Restore.swift, the shared helpers (and how a test sets a restore up) in EditorFirstSectionRestoreFixtures.swift. A
//  failed job, the rebuild guard, the quick undo and redo and the sidebar are EditorFirstSectionRestoreUndoTests.swift; the whole-project
//  restore is EditorFirstRestoreTests.swift.
//
//  Every typing test types into a block that holds NO footnote reference (a footnote renumber heals typing in a footnoted block and
//  would mask a loss, round 2a verdict, fidelity item 4).
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Editor-first section restores (t-18b7fa48 slice 2, round 2d-ii, Tier 2)", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct EditorFirstSectionRestoreTests: QuickUndoFixtures {

    // MARK: - U-S2-1, U-S2-2: Replace Current Section

    // U-S2-1: the flat range. A chapter's own text is restored; its sub-sections (the H2s under the H1) are not touched.
    @Test("U-S2-1: replacing a chapter restores its own text and keeps its sub-sections")
    func testSectionReplaceKeepsSubSections() async throws {
        let (rig, version) = try await makeSectionRigWithVersion()
        defer { unpinAllVersions(rig) }
        let body = try blockWithText(rig, "The chapter body.")
        try rig.rewriteText(ofBlock: body.id, to: "Changed.")
        try await rig.fillSectionTable()
        let subSectionIds = try ["Section A", "Section B", "Section C"].map { try rig.heading($0).id }

        #expect(await rig.performRestore("replace", from: version, section: "Chapter") == .performed)
        _ = await rig.waitUntilSettled()

        let all = try documentTexts(rig)
        #expect(all.contains("The chapter body.") && !all.contains("Changed."), "the chapter's text was not restored: \(all)")
        #expect(["Section A", "Section B", "Section C"].allSatisfy(all.contains), "a section restore removed sub-sections: \(all)")
        let rowIds = Set(try rig.blocks().map(\.id))
        #expect(subSectionIds.allSatisfy(rowIds.contains), "a sub-section's heading was given another id")
        let entry = try #require(rig.unifiedUndo.undoStack.last, "the restore was not recorded")
        #expect(entry.kind == .restoreSectionReplace && entry.isEditorFirst && entry.title == "Restore Section", "got \(entry)")
        #expect(restoreRanEditorFirst(rig), "the editor-first path ran (no fallback): \(rig.persistedLog)")
        #expect(rig.alerts.isEmpty, "an alert was raised: \(rig.alerts)")
    }

    // U-S2-2: ids outside the section are kept (a restore of Section B re-mints Section B's body, and nothing else).
    @Test("U-S2-2: replacing a section keeps the ids of every block outside it")
    func testSectionReplaceKeepsOtherIds() async throws {
        let (rig, version) = try await makeSectionRigWithVersion()
        defer { unpinAllVersions(rig) }
        let others = try rig.blocks().filter { !["Section B", "The B body."].contains($0.textContent) }.map(\.id)
        let headingB = try rig.heading("Section B")

        #expect(await rig.performRestore("replace", from: version, section: "Section B") == .performed)
        _ = await rig.waitUntilSettled()

        let ids = Set(try rig.blocks().map(\.id))
        #expect(others.allSatisfy(ids.contains), "a section restore re-minted ids outside the section")
        #expect(ids.contains(headingB.id), "the replaced section's heading got another id")
        #expect(restoreRanEditorFirst(rig), "no editor-first restore: \(rig.persistedLog)")
    }

    // The restored heading keeps the target's sidebar metadata (D3), whatever the version's section says.
    @Test("A replaced section keeps its status, and the restored text is what the version held")
    func testSectionReplaceKeepsTheTargetsStatus() async throws {
        let (rig, version) = try await makeSectionRigWithVersion()
        defer { unpinAllVersions(rig) }
        let headingC = try rig.heading("Section C")
        try setStatus(rig, ofBlock: headingC.id, to: .final_)
        let cBody = try blockWithText(rig, "The C body.")
        try rig.rewriteText(ofBlock: cBody.id, to: Self.editedBody)
        try await rig.fillSectionTable()

        #expect(await rig.performRestore("replace", from: version, section: "Section C") == .performed)
        _ = await rig.waitUntilSettled()

        #expect(try rig.heading("Section C").status == .final_, "the replace reverted the status set on the heading")
        let all = try documentTexts(rig)
        #expect(all.contains("The C body.") && !all.contains(Self.editedBody), "the version's text was not restored: \(all)")
        #expect(restoreRanEditorFirst(rig), "no editor-first restore: \(rig.persistedLog)")
    }

    // MARK: - U-S2-4: Restore as Duplicate

    // U-S2-4 (N5, D17): a change the section TABLE has not caught up with is not dropped by the restore. (Fix round F1, review C9c: this
    // test used to be named "text typed while Version History was open", but `rewriteText` writes the DATABASE, so what is behind is the
    // section table only; text that only the editor holds is covered by the VM test `testTypeWhileVersionHistoryOpenThenReplace`.)
    @Test("U-S2-4: restoring as a duplicate keeps a change the section table is behind on")
    func testRestoreAsDuplicateKeepsAChangeTheSectionTableIsBehindOn() async throws {
        let (rig, version) = try await makeSectionRigWithVersion()
        defer { unpinAllVersions(rig) }
        let cBody = try blockWithText(rig, "The C body.")
        try rig.rewriteText(ofBlock: cBody.id, to: "The C body typed.")   // the table is NOT filled again: it is behind the document

        #expect(await rig.performRestore("duplicate", from: version, section: "Section A") == .performed)
        _ = await rig.waitUntilSettled()

        let all = try documentTexts(rig)
        #expect(all.contains("The C body typed."), "restore as duplicate dropped unsynced typing: \(all)")
        #expect(all.filter { $0 == "Section A" }.count == 2, "the version's section was not added: \(all)")
        #expect(all.last == "The A body.", "the new section is not the last one: \(all)")
        let entry = try #require(rig.unifiedUndo.undoStack.last)
        #expect(
            entry.kind == .restoreSectionDuplicate && entry.isEditorFirst && entry.title == "Restore Section as Duplicate", "got \(entry)")
        #expect(restoreRanEditorFirst(rig), "no editor-first restore: \(rig.persistedLog)")
    }

    // The new section goes above the Notes, and every row of it is new.
    @Test("A restored duplicate lands above the Notes with ids of its own")
    func testRestoreAsDuplicateLandsAboveTheNotes() async throws {
        let markdown = Self.fourSections + "\n\nA cited claim.[^1]\n\n# Notes\n\n[^1]: The note."
        let rig = try EditorFirstRig(markdown: markdown)
        defer { unpinAllVersions(rig) }
        try await rig.fillSectionTable()
        let version = try saveVersion(rig)
        let before = Set(try rig.blocks().map(\.id))

        #expect(await rig.performRestore("duplicate", from: version, section: "Section B") == .performed)
        _ = await rig.waitUntilSettled()

        let rows = BlockParser.assemblySorted(try rig.blocks())
        let notesIndex = try #require(rows.firstIndex { $0.isNotes }, "the fixture has no Notes")
        let copyIndices = rows.indices.filter { rows[$0].textContent == "Section B" }
        #expect(copyIndices.count == 2, "the version's section was not added")
        #expect(copyIndices.allSatisfy { $0 < notesIndex }, "the new section went below the Notes")
        let newRows = rows.filter { !before.contains($0.id) }
        #expect(newRows.map(\.textContent) == ["Section B", "The B body."], "got \(newRows.map(\.textContent))")
        #expect(restoreRanEditorFirst(rig), "no editor-first restore: \(rig.persistedLog)")
    }

    // MARK: - U-S2-5, U-S2-5d: parity with the old restores

    // U-S2-5: the editor-first restores give the document the old restores give, on the article and on the six-chapter book. The document
    // is changed after the version (a paragraph edited, a status set), and the table follows it (as the window's opening does).
    @Test(
        "U-S2-5: editor-first and old restores give the same document",
        arguments: ["article", "book6"], ["project", "replace", "duplicate"])
    func testRestoreParityWithLegacy(_ doc: String, _ mode: String) async throws {
        let legacy = try makeRestoreRig(doc)
        legacy.controller.testForceLegacyStructural = true
        let fresh = try makeRestoreRig(doc)
        defer { unpinAllVersions(legacy); unpinAllVersions(fresh) }
        for rig in [legacy, fresh] {
            try await rig.fillSectionTable()
            let version = try saveVersion(rig)
            let chapters = try rig.chapterHeadings()
            let target = try #require(chapters.dropFirst().first ?? chapters.first)
            try editAParagraph(rig)
            try setStatus(rig, ofBlock: target.id, to: .final_)
            try await rig.fillSectionTable()
            #expect(await rig.performRestore(mode, from: version, section: target.textContent) == .performed)
            _ = await rig.waitUntilSettled()
        }
        #expect(restoreRanEditorFirst(fresh), "the editor-first \(mode) restore fell back or did not run: \(fresh.persistedLog)")
        let problem = EditorFirstRig.parityProblem(try legacy.blocks(), try fresh.blocks())
        #expect(problem == nil, "editor-first \(mode) restore on \(doc) differs from the old one: \(problem ?? "")")
    }

    // U-S2-5d: Duplicate Section (slice 1) against its old body, article and book6.
    @Test("U-S2-5d: editor-first and old Duplicate Section give the same document", arguments: ["article", "book6"])
    func testDuplicateParityWithLegacy(_ doc: String) async throws {
        let legacy = try makeRestoreRig(doc)
        legacy.controller.testForceLegacyStructural = true
        let fresh = try makeRestoreRig(doc)
        for rig in [legacy, fresh] {
            let chapters = try rig.chapterHeadings()
            let root = try #require(chapters.dropFirst().first ?? chapters.first)
            #expect(await rig.controller.performSectionDuplicate(rootId: root.id) == .performed)
            _ = await rig.waitUntilSettled()
        }
        #expect(!fresh.scripts(containing: "duplicateSectionEditorFirst").isEmpty, "the editor-first duplicate did not run")
        let problem = EditorFirstRig.parityProblem(try legacy.blocks(), try fresh.blocks())
        #expect(problem == nil, "editor-first duplicate on \(doc) differs from the old one: \(problem ?? "")")
    }

    // MARK: - D8: a target that cannot be told apart takes the old restore

    @Test("D8: a target the document cannot confirm takes the old restore, with the unresolved line in the log")
    func testUnresolvedTargetFallsBackToTheOldRestore() async throws {
        let (rig, version) = try await makeSectionRigWithVersion()
        defer { unpinAllVersions(rig) }
        let bBody = try blockWithText(rig, "The B body.")
        try rig.rewriteText(ofBlock: bBody.id, to: "The B body CHANGED.")
        try await rig.fillSectionTable()
        // The heading is renamed in the database after the table was filled: the table is behind the document.
        let headingB = try rig.heading("Section B")
        try renameHeadingInDatabase(rig, headingB.id, to: "Section B renamed")

        let outcome = await rig.performRestore("replace", from: version, section: "Section B")
        _ = await rig.waitUntilSettled()

        #expect(outcome == .performed, "the press was refused: \(outcome)")
        #expect(
            rig.persistedLog.contains { $0.contains("[EF-STRUCT] restoreSectionReplace target unresolved:") },
            "no unresolved line in this rig's log: \(rig.persistedLog)")
        #expect(rig.scripts(containing: "replaceRangeEditorFirst").isEmpty, "the editor was asked although the target was unresolved")
        let all = try documentTexts(rig)
        #expect(all.contains("The B body.") && !all.contains("The B body CHANGED."), "the old restore did not restore the section: \(all)")
        #expect(rig.alerts.isEmpty, "an alert was raised: \(rig.alerts)")
    }

    // A1 (slice-1 lesson (a)): a restore aimed at a section that only the editor and the sidebar overlay have (the copy of a duplicate whose
    // job has not run) is not refused. D8 cannot find it in the document, so the old restore carries it out once the copy's job has
    // committed.
    @Test("A1: a restore whose target exists only in the editor is not refused")
    func testRestoreOfASectionOnlyTheEditorHasIsNotRefused() async throws {
        let (rig, version) = try await makeSectionRigWithVersion()
        defer { unpinAllVersions(rig) }
        let hold = try rig.holdQueue()   // the copy is on the screen and its job has not run
        defer { rig.release(hold) }
        let sectionA = try rig.heading("Section A")
        #expect(await rig.controller.performSectionDuplicate(rootId: sectionA.id) == .performed)
        try await rig.fillSectionTable(fromEditor: true)   // the window opens now: the table lists "Section A copy", the database does not
        Task { @MainActor in
            // The old restore waits for the copy's job; the job is let go while it waits.
            try? await Task.sleep(for: .milliseconds(300))
            rig.release(hold)
        }

        let outcome = await rig.performRestore("replace", from: version, section: "Section A", target: "Section A copy")
        _ = await rig.waitUntilSettled()

        #expect(outcome == .performed, "the restore was refused for a target only the editor holds: \(outcome)")
        #expect(
            rig.persistedLog.contains { $0.contains("[EF-STRUCT] restoreSectionReplace target unresolved:") },
            "no unresolved line in this rig's log: \(rig.persistedLog)")
        let all = try documentTexts(rig)
        #expect(all.filter { $0 == "Section A" }.count == 2 && !all.contains("Section A copy"), "the copy was not restored over: \(all)")
    }
}
