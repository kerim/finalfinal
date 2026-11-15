//
//  DuplicateSectionSortOrderRoomTests.swift
//  final finalTests
//
//  t-bf66e4ee: Duplicate Section, and Version History's "Insert as New Section", put the new rows in the room after the section (or
//  before the Notes) at a step of room / (rows + 1). Done again and again in one session, each copy got about a hundredth of the room the
//  last one had, until saved positions tied and a copy's paragraphs came back in the wrong order after a zoom, a switch to Markdown,
//  a reopen or in a restored version. These drive the REAL entries (`StructuralUndoController.performSectionDuplicate`, and
//  `performRestoreSectionDuplicate` through `EditorFirstRig.performRestore("duplicate", ...)`), the real writer and the real database,
//  with the rig's scripted editor.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite(
    "Repeated Duplicate Section and Insert as New Section keep room between saved positions (t-bf66e4ee)",
    .serialized, .timeLimit(.minutes(6)))
@MainActor
struct DuplicateSectionSortOrderRoomTests: QuickUndoFixtures {
    static let paragraphCount = 100

    static func paragraph(_ number: Int) -> String { String(format: "Paragraph %03d.", number) }
    static var paragraphs: [String] { (1...paragraphCount).map { paragraph($0) } }

    /// A 100-paragraph chapter, then a short one: a copy of the first chapter always has a row after it to crowd against.
    static var longChapterBook: String {
        (["# Chapter One"] + paragraphs + ["# Chapter Two", "Two body."]).joined(separator: "\n\n")
    }

    /// The same with a footnote and Notes at the end: "Insert as New Section" puts the new section after the last block that is not
    /// Notes, so every insert lands in the room before the Notes heading.
    static var longChapterBookWithNotes: String {
        (["# Chapter One"] + paragraphs + ["# Chapter Two", "A cited claim.[^1]", "# Notes", "[^1]: The note."])
            .joined(separator: "\n\n")
    }

    static func copyTitle(_ generation: Int) -> String { "Chapter One" + String(repeating: " copy", count: generation) }

    /// The document after `copies` chained duplicates (each one a duplicate of the copy made just before it), as row texts.
    static func chainedCopies(_ copies: Int) -> [String] {
        var texts = ["Chapter One"] + paragraphs
        for generation in 0..<copies { texts += [copyTitle(generation + 1)] + paragraphs }
        return texts + ["Chapter Two", "Two body."]
    }

    // MARK: - Helpers

    private func texts(_ rig: EditorFirstRig) throws -> [String] {
        BlockParser.assemblySorted(try rig.blocks()).map(\.textContent).filter { !$0.isEmpty }
    }

    private func firstDifference(_ got: [String], _ want: [String]) -> String {
        let shared = min(got.count, want.count)
        let index = (0..<shared).first { got[$0] != want[$0] } ?? shared
        let gotText = index < got.count ? got[index] : "(end)"
        let wantText = index < want.count ? want[index] : "(end)"
        return "row \(index): got \"\(gotText)\", expected \"\(wantText)\" (\(got.count) rows, expected \(want.count))"
    }

    /// Every saved position is above the one before it by at least the room the writer keeps (2^-30).
    private func expectRoomBetweenPositions(
        _ rig: EditorFirstRig, _ stage: String, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let positions = BlockParser.assemblySorted(try rig.blocks()).map(\.sortOrder)
        let tight = zip(positions, positions.dropFirst()).filter { $1 - $0 < ProjectDatabase.crowdedSortOrderGap }
        let first = String(describing: tight.first)
        #expect(
            tight.isEmpty,
            "\(stage): saved positions do not strictly increase with room between them: \(tight.count) tight pair(s), first \(first)",
            sourceLocation: sourceLocation)
    }

    /// Every row's saved position, by id.
    private func positions(_ rig: EditorFirstRig) throws -> [String: Double] {
        Dictionary(try rig.blocks().map { ($0.id, $0.sortOrder) }, uniquingKeysWith: { first, _ in first })
    }

    /// Where two id-to-position maps differ, as one short sentence (rows missing, rows extra, rows at another position, one example);
    /// nil when they are equal.
    private func positionDifference(_ got: [String: Double], _ want: [String: Double]) -> String? {
        let missing = want.keys.filter { got[$0] == nil }.count
        let extra = got.keys.filter { want[$0] == nil }.count
        let moved = want.filter { got[$0.key] != nil && got[$0.key] != $0.value }
        guard missing > 0 || extra > 0 || !moved.isEmpty else { return nil }
        var text = "\(missing) row(s) missing, \(extra) row(s) extra, \(moved.count) row(s) at another position"
        if let example = moved.first {
            text += "; e.g. row \(example.key.prefix(8)) is at \(got[example.key] ?? .nan), expected \(example.value)"
        }
        return text
    }

    /// Duplicates the copy made last (generation - 1; generation 1 duplicates the original), through the real controller entry.
    private func duplicate(_ rig: EditorFirstRig, generation: Int) async throws {
        let root = try rig.heading(Self.copyTitle(generation - 1))
        let outcome = await rig.controller.performSectionDuplicate(rootId: root.id)
        #expect(outcome == .performed, "duplicate \(generation) ended \(outcome)")
        _ = await rig.waitUntilSettled()
    }

    // MARK: - T1

    @Test("T1: ten Duplicate Sections of a 100-paragraph chapter keep every copy in order, with room between positions")
    func tenDuplicatesKeepOrder() async throws {
        let rig = try EditorFirstRig(markdown: Self.longChapterBook)
        let log = rig.db.sortOrderRenumberLog
        let generationBefore = log.generation
        // A range on Chapter Two taken before the duplicates, as a zoom takes one: through the log it must still pick Chapter Two.
        let chapterTwo = try rig.heading("Chapter Two")
        let anchored = AnchoredSortOrderRange(range: (start: chapterTwo.sortOrder, end: nil), log: log)

        for generation in 1...10 { try await duplicate(rig, generation: generation) }

        #expect(rig.duplicateScripts.count == 10, "not every duplicate reached the editor: \(rig.duplicateScripts.count)")
        let got = try texts(rig)
        let want = Self.chainedCopies(10)
        #expect(got == want, "the copies do not read back in order: \(firstDifference(got, want))")
        try expectRoomBetweenPositions(rig, "after ten duplicates")
        #expect(log.generation > generationBefore, "no duplicate re-spaced the saved positions (or the re-spacing was not logged)")
        let range = anchored.current
        let picked = BlockParser.assemblySorted(try rig.blocks())
            .filter { block in block.sortOrder >= range.start && (range.end.map { end in block.sortOrder < end } ?? true) }
            .map(\.textContent).filter { !$0.isEmpty }
        #expect(picked == ["Chapter Two", "Two body."], "a range taken before the duplicates no longer picks Chapter Two: \(picked.prefix(4))")
    }

    // MARK: - T2

    @Test("T2: ten Insert as New Section restores of a 100-paragraph chapter keep every new section in order above the Notes")
    func tenInsertsAsNewSectionKeepOrder() async throws {
        let rig = try EditorFirstRig(markdown: Self.longChapterBookWithNotes)
        defer { unpinAllVersions(rig) }
        try await rig.fillSectionTable()
        let version = try saveVersion(rig)
        let generationBefore = rig.db.sortOrderRenumberLog.generation

        for round in 1...10 {
            let outcome = await rig.performRestore("duplicate", from: version, section: "Chapter One")
            #expect(outcome == .performed, "insert \(round) ended \(outcome)")
            _ = await rig.waitUntilSettled()
        }

        #expect(restoreRanEditorFirst(rig), "no editor-first restore: \(rig.persistedLog)")
        let rows = BlockParser.assemblySorted(try rig.blocks()).filter { !$0.markdownFragment.isEmpty }
        let user = rows.filter { !$0.isNotes && !$0.isBibliography }.map(\.markdownFragment)
        let chapter = ["# Chapter One"] + Self.paragraphs
        var want = chapter + ["# Chapter Two", "A cited claim.[^1]"]
        for _ in 1...10 { want += chapter }
        #expect(user == want, "the inserted sections do not read back in order: \(firstDifference(user, want))")
        let notesIndex = try #require(rows.firstIndex { $0.isNotes }, "the Notes are gone")
        #expect(rows[notesIndex...].allSatisfy { $0.isNotes || $0.isBibliography }, "an inserted section went below the Notes")
        try expectRoomBetweenPositions(rig, "after ten inserts")
        #expect(
            rig.db.sortOrderRenumberLog.generation > generationBefore,
            "no insert re-spaced the saved positions (or the re-spacing was not logged)")
    }

    // MARK: - T3

    @Test("T3: Cmd-Z and Cmd-Shift-Z of the duplicate that re-spaced the positions give back exactly the rows before and after it")
    func undoAndRedoOfARespacingDuplicate() async throws {
        let rig = try EditorFirstRig(markdown: Self.longChapterBook)
        let log = rig.db.sortOrderRenumberLog
        // Every row's id and saved position, taken just before each duplicate: the one that matters is the one taken before the
        // duplicate after which the log first grew (the one that re-spaced).
        var before: [String: Double] = [:]
        var copies = 0
        while log.generation == 0 && copies < 12 {
            before = try positions(rig)
            copies += 1
            try await duplicate(rig, generation: copies)
        }
        try #require(log.generation > 0, "twelve duplicates never re-spaced the saved positions")
        let afterDuplicate = try positions(rig)
        let copyIds = Set(afterDuplicate.keys).subtracting(before.keys)
        #expect(copyIds.count == Self.paragraphCount + 1, "premise: the duplicate added \(copyIds.count) rows, expected 101")

        let entry = try #require(rig.unifiedUndo.undoStack.last, "the duplicate was not recorded")
        #expect(await rig.pressAndSettle(entry, .undo), "the Cmd-Z did not end and settle")
        _ = await rig.waitUntilSettled()
        let afterUndo = try texts(rig)
        let undoDifference = firstDifference(afterUndo, Self.chainedCopies(copies - 1))
        #expect(afterUndo == Self.chainedCopies(copies - 1), "Cmd-Z did not give back the document before the last duplicate: \(undoDifference)")
        // The rows AND their saved positions are exactly what they were before the duplicate (the copy's rows gone, every other row at
        // the number it had before the re-spacing), not just the same texts in the same order.
        let positionProblem = positionDifference(try positions(rig), before)
        #expect(
            positionProblem == nil,
            "Cmd-Z did not put every row back at the position it had before the duplicate: \(positionProblem ?? "")")
        try expectRoomBetweenPositions(rig, "after Cmd-Z")
        #expect(rig.quickUndoScripts.count == 1, "the Cmd-Z did not take the quick path: \(rig.quickUndoScripts.count)")

        let redo = try #require(rig.unifiedUndo.redoStack.last, "the undo left nothing to redo")
        #expect(await rig.pressAndSettle(redo, .redo), "the Cmd-Shift-Z did not end and settle")
        _ = await rig.waitUntilSettled()
        let afterRedo = try texts(rig)
        let redoDifference = firstDifference(afterRedo, Self.chainedCopies(copies))
        #expect(afterRedo == Self.chainedCopies(copies), "Cmd-Shift-Z did not put the copy back in order: \(redoDifference)")
        // The copy's rows are the ones the first click made (the redo reuses the editor's ids), and no other row came or went.
        let redoneIds = Set(try positions(rig).keys)
        let copyRowsMissing = copyIds.subtracting(redoneIds).count
        let rowsNew = redoneIds.subtracting(afterDuplicate.keys).count
        #expect(
            copyRowsMissing == 0 && rowsNew == 0,
            "Cmd-Shift-Z did not bring back the first duplicate's rows: \(copyRowsMissing) copy rows missing, \(rowsNew) rows new")
        try expectRoomBetweenPositions(rig, "after Cmd-Shift-Z")
    }

    // MARK: - T6

    @Test("T6: typing queued behind the duplicate that re-spaces lands on the right rows, and the positions have room")
    func typingBehindARespacingDuplicate() async throws {
        let rig = try EditorFirstRig(markdown: Self.longChapterBook)
        let log = rig.db.sortOrderRenumberLog
        // The step after k duplicates of this 101-row chapter is 102^-k: the fifth is the first below 2^-30, so it is the one that re-spaces.
        for generation in 1...4 { try await duplicate(rig, generation: generation) }
        try #require(log.generation == 0, "premise: four duplicates already re-spaced the saved positions")

        // The fifth duplicate, with its job parked in its body: the copy is on the screen, the rows are not in the table yet.
        let jobMayRun = DispatchSemaphore(value: 0)
        defer { jobMayRun.signal() }
        rig.controller.testEFJobBodyHold = { jobMayRun.wait() }
        let outcome = await rig.controller.performSectionDuplicate(rootId: try rig.heading(Self.copyTitle(4)).id)
        rig.controller.testEFJobBodyHold = nil
        #expect(outcome == .performed, "the fifth duplicate ended \(outcome)")
        try #require(log.generation == 0, "premise: the parked job has already run")

        // The user types straight after the click, at the end of "Two body.": the page's report is received now, behind the parked job.
        let twoBody = try #require(try rig.blocks().first { $0.textContent == "Two body." }, "the seeded paragraph is missing")
        rig.queueTyping(twoBody, appending: " More")
        let first = rig.postQueuedTyping()
        jobMayRun.signal()
        let firstDecided = await rig.sync.reportApplier.waitDecided(session: EditorFirstRig.reportSession, through: first, timeout: 30)
        #expect(firstDecided, "the report queued behind the duplicate was never decided")
        _ = await rig.waitUntilSettled()

        // Looked at before anything else is typed. A report with no insert in it re-spaces nothing by itself, so what is checked here is
        // the duplicate job's own re-spacing: the copy has room, and the log grew.
        var expected = Self.chainedCopies(5)
        expected[expected.count - 1] = "Two body. More"
        let afterTyping = try texts(rig)
        let typingDifference = firstDifference(afterTyping, expected)
        #expect(afterTyping == expected, "the typing queued behind the duplicate did not land on \"Two body.\": \(typingDifference)")
        try expectRoomBetweenPositions(rig, "after the duplicate and the typing queued behind it")
        #expect(log.generation > 0, "the duplicate did not re-space the saved positions (or the re-spacing was not logged)")

        // Then a new paragraph "Typed." after it (an Enter and a few words): placed from the numbers as they are now.
        let anchor = try #require(try rig.blocks().first { $0.textContent == "Two body. More" }, "the typed text is not in the table")
        rig.typingQueue.append(BlockChanges(inserts: [BlockInsert(
            tempId: "typed-after-duplicate", blockType: BlockType.paragraph.rawValue, textContent: "Typed.", markdownFragment: "Typed.",
            headingLevel: nil, afterBlockId: anchor.id)]))
        let second = rig.postQueuedTyping()
        let secondDecided = await rig.sync.reportApplier.waitDecided(session: EditorFirstRig.reportSession, through: second, timeout: 30)
        #expect(secondDecided, "the report with the new paragraph was never decided")
        _ = await rig.waitUntilSettled()

        expected.append("Typed.")
        let afterInsert = try texts(rig)
        let insertDifference = firstDifference(afterInsert, expected)
        #expect(afterInsert == expected, "the new paragraph is not after \"Two body.\": \(insertDifference)")
        try expectRoomBetweenPositions(rig, "after the new paragraph")
    }
}
