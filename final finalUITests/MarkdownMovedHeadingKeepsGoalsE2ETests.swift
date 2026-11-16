//
//  MarkdownMovedHeadingKeepsGoalsE2ETests.swift
//  final finalUITests
//
//  Real-app proof for t-b097670d: in Markdown mode a heading that is cut and pasted, or deleted and brought back with Cmd-Z, comes
//  back with its status, tags and goals, even when the removal and the return are SEPARATE saves.
//
//  The bug: the Markdown saver deletes a heading's row and inserts a new one (a deleted id is never reused), and the new row started
//  with no status, no tags and the default goals. The fix: inside one save the new heading takes the fields of the removed row with
//  the identical line; across saves the writer remembers the fields of every heading row it deletes and hands them to a later heading
//  with the identical line. The UI driver needs seconds between a cut and a paste, so these tests are the across-saves half in the
//  running app (the same-save half is in `MarkdownBlockDiffMovedHeadingTests` and `MarkdownMovedHeadingMetadataTests`; there is no
//  save-delay switch, by decision). The app runs at its normal speed; the gap between steps is made by polling the DATABASE.
//
//  The methods:
//    1. testCutClickPasteAcrossASaveKeepsAllSix: cut the `# Chapter One` line and the blank line below it in Markdown mode, poll until
//       its heading row is gone (the cut was saved on its own), click at the start of `# Chapter Three`, paste: the six fields on the
//       new row, and the sidebar card after Chapter Two's still showing its status and goal.
//    2. testDeleteHeadingThenCmdZAfterTheSaveKeepsAllSix: delete the same line, poll until its row is gone, Cmd-Z: row and card are back.
//    3. testZoomedDeleteSubheadingThenCmdZKeepsAllSix: the same through the ZOOMED save (a different write path), on a `## Scene A` line.
//    4. testRenumberAfterDeletingAChapterKeepsEachSectionsOwnFields: the guard. Delete the `# Chapter Three` line, then renumber the
//       chapters after it ("Four" to "Three", "Five" to "Four"), one save each: a rename is not a return, so each section keeps its OWN
//       six fields and nobody takes the deleted chapter's.
//
//  Seeding: the app's own first launch parses the seeded markdown into block rows; the test terminates the app, writes the six columns
//  of every heading row with `FixtureDatabase.write`, relaunches, and reads the fields back before it touches the document.
//
//  Driving (each choice is a recorded e2e-verify lesson):
//    - An H1 line is not exposed as a StaticText in Markdown mode, so a heading line is never searched for or clicked: the caret goes
//      to the one-line paragraph under it (exact-value leaf, `placeCaretByClicking` with its probe), then two lines up by keyboard. A
//      wrong selection shows as a wrong database, which every step checks before it goes on.
//    - Every wait is a bounded poll. The page's readiness is NOT the mode badge (it flips first): it is the first of two signals, the
//      app's own log line (needs diagnostics on, see `setUpWithError`) or an element signal that needs no log (the raw `# ` heading
//      line; for the zoom, the zoomed chapter's text without the other chapters'). FIRST VM RUN (run-1794765722-77000): all four
//      methods died at this wait because the test never turned diagnostics on, so no `diagnostic.log` existed; the page itself was in
//      Markdown with every seeded field shown in the sidebar (video frame).
//    - SECOND VM RUN (run-1794766524-86097): methods 2-4 passed; method 1 pasted the cut line (the line alone, no blank line) straight
//      above `# Chapter Three`, and the app saved ONE heading row of two lines, "# Chapter One\n# Chapter Three" (the sidebar showed one
//      card titled with both names and Chapter Three's fields): the moved heading never became a row of its own, so no carry could
//      apply. The cut text reached the app's paste (the app-to-app pasteboard works in the guest; the test process read nothing from it).
//      Hence the selection takes the blank line too. The glued state is existing block splitting, outside this task, and is reported.
//    - CodeMirror draws only the lines near the viewport (1024x678 window): the five-chapter book's last chapters lie below the fold,
//      so the renumbering goes to the document end first.
//    - Stills are attached BEFORE the assertions that can end a method. The sidebar is read from one snapshot of its scroll view.
//
//  Break check (driver): with the writer's memory of removed headings off (or the insert path's copy a no-op) methods 1, 2 and 3 fail
//  with "status: got NULL, expected review"-style differences and method 4 stays green; with a rename taken for a return, method 4 fails.
//

// swiftlint:disable file_length
import XCTest

// MARK: - The six fields, the seeded book

/// The six section columns of a heading row, as the database holds them: the raw column text, "NULL" for an unset column. The encodings
/// are the ones `Block`'s Codable writes (the status raw value, the tags as a JSON array, the goal types by name, the goals as integers).
struct SixFields: Equatable, CustomStringConvertible {
    let status: String
    let tags: String
    let wordGoal: String
    let goalType: String
    let aggregateGoal: String
    let aggregateGoalType: String

    var description: String {
        "status \(status), tags \(tags), wordGoal \(wordGoal), goalType \(goalType), "
            + "aggregateGoal \(aggregateGoal), aggregateGoalType \(aggregateGoalType)"
    }

    /// The assignments of an UPDATE that gives a heading row these values.
    var assignments: String {
        "status = '\(status)', tags = '\(FixtureDatabase.escape(tags))', wordGoal = \(wordGoal), goalType = '\(goalType)', "
            + "aggregateGoal = \(aggregateGoal), aggregateGoalType = '\(aggregateGoalType)'"
    }

    /// One line per column that differs from `expected`: "status: got NULL, expected review". Empty when all six agree.
    func differences(from expected: SixFields) -> [String] {
        var lines: [String] = []
        func compare(_ name: String, _ got: String, _ wanted: String) {
            if got != wanted { lines.append("\(name): got \(got), expected \(wanted)") }
        }
        compare("status", status, expected.status)
        compare("tags", tags, expected.tags)
        compare("wordGoal", wordGoal, expected.wordGoal)
        compare("goalType", goalType, expected.goalType)
        compare("aggregateGoal", aggregateGoal, expected.aggregateGoal)
        compare("aggregateGoalType", aggregateGoalType, expected.aggregateGoalType)
        return lines
    }

    // Every chapter gets values that are not the column defaults and that no other chapter shares, so a carried field cannot be
    // mistaken for a default or for a neighbour's.
    static let chapterOne = SixFields(
        status: "review", tags: "[\"kept\"]", wordGoal: "500", goalType: "min", aggregateGoal: "3000", aggregateGoalType: "max")
    static let chapterTwo = SixFields(
        status: "writing", tags: "[\"two\"]", wordGoal: "800", goalType: "max", aggregateGoal: "4000", aggregateGoalType: "min")
    static let chapterThree = SixFields(
        status: "waiting", tags: "[\"three\"]", wordGoal: "250", goalType: "min", aggregateGoal: "1500", aggregateGoalType: "max")
    static let chapterFour = SixFields(
        status: "review", tags: "[\"four\"]", wordGoal: "400", goalType: "max", aggregateGoal: "2500", aggregateGoalType: "min")
    static let chapterFive = SixFields(
        status: "writing", tags: "[\"five\"]", wordGoal: "600", goalType: "min", aggregateGoal: "3500", aggregateGoalType: "max")
    static let sceneA = SixFields(
        status: "waiting", tags: "[\"scene\"]", wordGoal: "150", goalType: "min", aggregateGoal: "900", aggregateGoalType: "max")
}

/// One block of the seeded book: its markdown line, and for a heading the six fields to set on its row before the document is shown.
struct SeedBlock {
    let fragment: String
    let fields: SixFields?
}

/// The seeded book: blocks in document order, joined by blank lines (the way the app assembles a document).
struct SeedBook {
    let blocks: [SeedBlock]

    var markdown: String { blocks.map(\.fragment).joined(separator: "\n\n") }
    var fragments: [String] { blocks.map(\.fragment) }
    var headings: [SeedBlock] { blocks.filter { $0.fields != nil } }
    /// The first plain paragraph: what the page shows when it is ready.
    var firstParagraph: String { blocks.first { $0.fields == nil }?.fragment ?? "" }
}

enum MovedHeadingSeeds {
    static func heading(_ line: String, _ fields: SixFields) -> SeedBlock { SeedBlock(fragment: line, fields: fields) }
    static func text(_ line: String) -> SeedBlock { SeedBlock(fragment: line, fields: nil) }

    /// Three chapters of two one-line paragraphs each; every paragraph is one exact-value text leaf under its heading.
    static let threeChapters = SeedBook(blocks: [
        heading("# Chapter One", .chapterOne), text("Alpha paragraph one."), text("Alpha paragraph two."),
        heading("# Chapter Two", .chapterTwo), text("Beta paragraph one."), text("Beta paragraph two."),
        heading("# Chapter Three", .chapterThree), text("Gamma paragraph one."), text("Gamma paragraph two.")
    ])

    /// Chapter One holds a sub-heading, for the zoomed method.
    static let withSubheading = SeedBook(blocks: [
        heading("# Chapter One", .chapterOne), text("Alpha paragraph one."),
        heading("## Scene A", .sceneA), text("Scene A paragraph."),
        heading("# Chapter Two", .chapterTwo), text("Beta paragraph one."), text("Beta paragraph two."),
        heading("# Chapter Three", .chapterThree), text("Gamma paragraph one."), text("Gamma paragraph two.")
    ])

    /// Five chapters, for the renumbering method.
    static let fiveChapters = SeedBook(blocks: [
        heading("# Chapter One", .chapterOne), text("Alpha paragraph one."), text("Alpha paragraph two."),
        heading("# Chapter Two", .chapterTwo), text("Beta paragraph one."), text("Beta paragraph two."),
        heading("# Chapter Three", .chapterThree), text("Gamma paragraph one."), text("Gamma paragraph two."),
        heading("# Chapter Four", .chapterFour), text("Delta paragraph one."), text("Delta paragraph two."),
        heading("# Chapter Five", .chapterFive), text("Epsilon paragraph one."), text("Epsilon paragraph two.")
    ])
}

/// A heading row as read from the database.
struct HeadingRow {
    let id: String
    let fields: SixFields
}

/// A heading that must still hold its own six fields after the move.
struct NeighbourCheck {
    let fragment: String
    let fields: SixFields
}

/// One node of the Outline sidebar's accessibility subtree.
struct SidebarNode: CustomStringConvertible {
    let type: XCUIElement.ElementType
    let label: String
    let value: String
    let frame: CGRect

    var description: String {
        "type \(type.rawValue) label \"\(label)\" value \"\(value)\" y \(Int(frame.minY))-\(Int(frame.maxY)) x \(Int(frame.minX))"
    }

    func shows(_ text: String) -> Bool { label == text || value == text }
}

private struct MovedHeadingStop: Error {}

// MARK: - The tests

final class MarkdownMovedHeadingKeepsGoalsE2ETests: XCTestCase {
    var app: XCUIApplication!

    /// The bound on every wait for a save or for the page: a save the app owes lands within a second or two; the rest is the VM.
    static let saveBound: TimeInterval = 30

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.targetApp()
        app.terminate()
        try TestFixtureHelper.setupFixture(from: self)
        // macOS inline predictive text can swallow keystrokes (e2e-verify, "Runner environment").
        app.launchArguments += ["-NSAutomaticInlinePredictionEnabled", "NO"]
        // The page-ready and zoom-done lines reach `diagnostic.log` only with diagnostics on; the environment variable bypasses the UI-test
        // defaults wipe (the same two settings the Phase 4b harness launches with). Set before launchForTesting, which keeps them.
        app.launchArguments += ["-com.kerim.final-final.diagnosticsLoggingEnabled", "YES"]
        app.launchEnvironment["FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING"] = "1"
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }

    // MARK: 1. Cut, click elsewhere, paste

    func testCutClickPasteAcrossASaveKeepsAllSix() throws {
        let book = MovedHeadingSeeds.threeChapters
        let one = "# Chapter One"
        try openInMarkdown(book)
        let before = try unwrap(headingRow(one), "TEST-SETUP: no \"\(one)\" heading row after the switch to Markdown\n\(rowsReport())")
        // The positive control of the sidebar reading: before anything is done, Chapter One's card shows its status and goal.
        let premise = sidebarFailuresAfterWaiting(of: "Chapter One", status: "Review", goalLimit: 3000, above: nil, below: "Chapter Two")
        attachEvidenceScreenshot(app.screenshot(), name: "1-before-the-cut")

        // Cut the heading line WITH the blank line below it, so the paste below lands as a block of its own (the line alone, pasted
        // above another heading line, is glued to it: one heading row of two lines, see the header).
        try selectHeadingLine(aboveParagraph: "Alpha paragraph one.", includingBlankLine: true)
        attachEvidenceScreenshot(app.screenshot(), name: "2-heading-line-selected")
        pressChord("x", .command)
        // Informational only: the runner process may not see the app's pasteboard in the guest (run 2 read nothing here, yet the app's
        // own paste inserted the cut text). The paste is checked in the database below.
        let clipboard = NSPasteboard.general.string(forType: .string) ?? "(nothing seen by the test process)"
        attachText("clipboard as seen by the test process after the cut: \(clipboard.debugDescription)", name: "3-clipboard-seen-by-the-test")
        // The gap that matters: the cut must be SAVED on its own, so the paste below is a second, later save.
        try requireRemovalSaved(of: one, from: book, after: "cut")

        // Click at the start of Chapter Three's heading line and paste.
        try placeCaretAtHeadingStart(aboveParagraph: "Gamma paragraph one.")
        pressChord("v", .command)
        let landed = pollUntilTrue(timeout: Self.saveBound) { headingRow(one) != nil }
        attachEvidenceScreenshot(app.screenshot(), name: "4-after-the-paste")
        attachText(rowsReport(), name: "4-rows-after-the-paste")
        let glued = savedRows().first { $0.hasPrefix("#") && $0.contains("\n") }
        let gluedNote = glued.map { " A heading row holds two lines (\($0.debugDescription)): the pasted heading was glued to the next line." } ?? ""
        try require(
            landed,
            "No \"\(one)\" heading row of its own came back within \(Self.saveBound) s of the paste.\(gluedNote)\n\(rowsReport())"
        )
        let expectedRows = [
            "Alpha paragraph one.", "Alpha paragraph two.", "# Chapter Two", "Beta paragraph one.", "Beta paragraph two.",
            one, "# Chapter Three", "Gamma paragraph one.", "Gamma paragraph two."
        ]
        _ = pollUntilTrue(timeout: 10) { savedRows() == expectedRows }
        let sidebar = sidebarFailuresAfterWaiting(
            of: "Chapter One", status: "Review", goalLimit: 3000, above: "Chapter Two", below: "Chapter Three")
        attachEvidenceScreenshot(app.screenshot(), name: "5-sidebar-after-the-paste")
        attachText((sidebarNodes() ?? []).map(\.description).joined(separator: "\n"), name: "5-sidebar-nodes")
        let moved = try unwrap(headingRow(one), "the moved heading row vanished again\n\(rowsReport())")

        var failures: [String] = []
        failures += moved.fields.differences(from: before.fields).map { "[moved heading: \($0)] the six fields did not follow the heading" }
        if moved.id == before.id {
            failures.append("[moved heading] the heading kept its row id: the premise 'a moved heading is a new row' no longer holds")
        }
        if savedRows() != expectedRows {
            failures.append("[rows] the saved order is not the pasted one:\n\(rowsReport())\nexpected:\n\(expectedRows.joined(separator: "\n"))")
        }
        failures += neighbourFailures([
            NeighbourCheck(fragment: "# Chapter Two", fields: .chapterTwo),
            NeighbourCheck(fragment: "# Chapter Three", fields: .chapterThree)
        ])
        if !premise.isEmpty { failures.append("TEST-SETUP: the sidebar positive control failed before the cut: \(premise)") }
        if !sidebar.isEmpty { failures.append("[sidebar] after the paste: \(sidebar)") }
        softly { failures.forEach { XCTFail($0) } }
    }

    // MARK: 2. Delete, then Cmd-Z after the save

    func testDeleteHeadingThenCmdZAfterTheSaveKeepsAllSix() throws {
        let book = MovedHeadingSeeds.threeChapters
        let one = "# Chapter One"
        try openInMarkdown(book)
        let before = try unwrap(headingRow(one), "TEST-SETUP: no \"\(one)\" heading row after the switch to Markdown\n\(rowsReport())")
        let premise = sidebarFailuresAfterWaiting(of: "Chapter One", status: "Review", goalLimit: 3000, above: nil, below: "Chapter Two")

        try selectHeadingLine(aboveParagraph: "Alpha paragraph one.")
        attachEvidenceScreenshot(app.screenshot(), name: "1-heading-line-selected")
        pressKey(.delete)
        // The row is gone and the delete was saved on its own: only then Cmd-Z.
        try requireRemovalSaved(of: one, from: book, after: "delete")
        pressChord("z", .command)
        let back = pollUntilTrue(timeout: Self.saveBound) { headingRow(one) != nil }
        attachEvidenceScreenshot(app.screenshot(), name: "2-after-cmd-z")
        attachText(rowsReport(), name: "2-rows-after-cmd-z")
        try require(back, "No \"\(one)\" heading row came back within \(Self.saveBound) s of Cmd-Z\n\(rowsReport())")
        _ = pollUntilTrue(timeout: 10) { savedRows() == book.fragments }
        let sidebar = sidebarFailuresAfterWaiting(of: "Chapter One", status: "Review", goalLimit: 3000, above: nil, below: "Chapter Two")
        attachEvidenceScreenshot(app.screenshot(), name: "3-sidebar-after-cmd-z")
        attachText((sidebarNodes() ?? []).map(\.description).joined(separator: "\n"), name: "3-sidebar-nodes")
        let restored = try unwrap(headingRow(one), "the restored heading row vanished again\n\(rowsReport())")

        var failures: [String] = []
        failures += restored.fields.differences(from: before.fields).map { "[restored heading: \($0)] the six fields did not come back" }
        if restored.id == before.id {
            failures.append("[restored heading] the heading kept its row id: the premise 'a restored heading is a new row' no longer holds")
        }
        if savedRows() != book.fragments {
            failures.append("[rows] the saved rows are not the original book after Cmd-Z:\n\(rowsReport())")
        }
        failures += neighbourFailures([
            NeighbourCheck(fragment: "# Chapter Two", fields: .chapterTwo),
            NeighbourCheck(fragment: "# Chapter Three", fields: .chapterThree)
        ])
        if !premise.isEmpty { failures.append("TEST-SETUP: the sidebar positive control failed before the delete: \(premise)") }
        if !sidebar.isEmpty { failures.append("[sidebar] after Cmd-Z: \(sidebar)") }
        softly { failures.forEach { XCTFail($0) } }
    }

    // MARK: 3. The same, zoomed

    func testZoomedDeleteSubheadingThenCmdZKeepsAllSix() throws {
        let book = MovedHeadingSeeds.withSubheading
        let scene = "## Scene A"
        try openInMarkdown(book)
        try zoomIntoChapterOne()
        let before = try unwrap(headingRow(scene), "TEST-SETUP: no \"\(scene)\" heading row after the zoom\n\(rowsReport())")
        try require(
            before.fields == .sceneA,
            "TEST-SETUP: \"\(scene)\" lost its fields on the way to the zoomed page: \(before.fields.differences(from: .sceneA))"
        )
        attachEvidenceScreenshot(app.screenshot(), name: "1-zoomed-into-chapter-one")

        try selectHeadingLine(aboveParagraph: "Scene A paragraph.")
        attachEvidenceScreenshot(app.screenshot(), name: "2-sub-heading-line-selected")
        pressKey(.delete)
        try requireRemovalSaved(of: scene, from: book, after: "zoomed delete")
        pressChord("z", .command)
        let back = pollUntilTrue(timeout: Self.saveBound) { headingRow(scene) != nil }
        _ = pollUntilTrue(timeout: 10) { savedRows() == book.fragments }
        attachEvidenceScreenshot(app.screenshot(), name: "3-after-cmd-z")
        attachText(rowsReport(), name: "3-rows-after-cmd-z")
        try require(back, "No \"\(scene)\" heading row came back within \(Self.saveBound) s of Cmd-Z in the zoomed page\n\(rowsReport())")
        let restored = try unwrap(headingRow(scene), "the restored sub-heading row vanished again\n\(rowsReport())")

        var failures: [String] = []
        failures += restored.fields.differences(from: .sceneA).map { "[restored sub-heading: \($0)] the six fields did not come back" }
        if savedRows() != book.fragments {
            failures.append("[rows] the saved rows are not the original book after Cmd-Z:\n\(rowsReport())")
        }
        failures += fieldFailures("# Chapter One", expected: .chapterOne, stage: "zoom root")
        failures += neighbourFailures([
            NeighbourCheck(fragment: "# Chapter Two", fields: .chapterTwo),
            NeighbourCheck(fragment: "# Chapter Three", fields: .chapterThree)
        ])
        softly { failures.forEach { XCTFail($0) } }
    }

    // MARK: 4. The renumber guard

    func testRenumberAfterDeletingAChapterKeepsEachSectionsOwnFields() throws {
        let book = MovedHeadingSeeds.fiveChapters
        let three = "# Chapter Three"
        let four = "# Chapter Four"
        try openInMarkdown(book)

        // Delete Chapter Three's heading line and wait until that is saved on its own.
        try selectHeadingLine(aboveParagraph: "Gamma paragraph one.")
        attachEvidenceScreenshot(app.screenshot(), name: "1-chapter-three-selected")
        pressKey(.delete)
        try requireRemovalSaved(of: three, from: book, after: "delete")

        // Renumber the chapters after it, one at a time, each its own save: Four becomes Three, then Five becomes Four.
        var failures: [String] = []
        try renameHeading(aboveParagraph: "Delta paragraph one.", replacing: "Four", with: "Three")
        let firstRename = pollUntilTrue(timeout: Self.saveBound) { headingCount(three) == 1 && headingCount(four) == 0 }
        attachText(rowsReport(), name: "2-rows-after-the-first-rename")
        try require(firstRename, "The first rename (\"Four\" to \"Three\") never reached the database within \(Self.saveBound) s\n\(rowsReport())")
        failures += fieldFailures(three, expected: .chapterFour, stage: "right after the first rename")

        try renameHeading(aboveParagraph: "Epsilon paragraph one.", replacing: "Five", with: "Four")
        let secondRename = pollUntilTrue(timeout: Self.saveBound) { headingCount(four) == 1 && headingCount("# Chapter Five") == 0 }
        let expectedRows = Self.renumbered(book)
        _ = pollUntilTrue(timeout: 10) { savedRows() == expectedRows }
        attachEvidenceScreenshot(app.screenshot(), name: "3-after-the-renumbering")
        attachText(rowsReport(), name: "3-rows-after-the-renumbering")
        try require(secondRename, "The second rename (\"Five\" to \"Four\") never reached the database within \(Self.saveBound) s\n\(rowsReport())")

        failures += fieldFailures(three, expected: .chapterFour, stage: "former Chapter Four, now Three")
        failures += fieldFailures(four, expected: .chapterFive, stage: "former Chapter Five, now Four")
        failures += fieldFailures("# Chapter One", expected: .chapterOne, stage: "untouched Chapter One")
        failures += fieldFailures("# Chapter Two", expected: .chapterTwo, stage: "untouched Chapter Two")
        if headingCount("# Chapter Five") != 0 { failures.append("[rows] a \"# Chapter Five\" heading row is still there") }
        let resurrected = rowsCarrying(.chapterThree)
        if resurrected != 0 {
            failures.append(
                "[deleted chapter's fields] \(resurrected) heading row(s) carry the deleted Chapter Three's six fields: "
                    + "a rename was taken for its return"
            )
        }
        if savedRows() != expectedRows {
            failures.append("[rows] the saved rows are not the renumbered book:\n\(rowsReport())\nexpected:\n\(expectedRows.joined(separator: "\n"))")
        }
        softly { failures.forEach { XCTFail($0) } }
    }

    /// The five-chapter book after Chapter Three's heading is deleted and Four and Five are renumbered.
    static func renumbered(_ book: SeedBook) -> [String] {
        let renames = ["# Chapter Four": "# Chapter Three", "# Chapter Five": "# Chapter Four"]
        return book.fragments.filter { $0 != "# Chapter Three" }.map { renames[$0] ?? $0 }
    }
}

// MARK: - Opening the book

extension MarkdownMovedHeadingKeepsGoalsE2ETests {
    /// Seeds the book, lets the app parse it into block rows (first launch), writes the six fields onto each heading row with the app
    /// terminated, relaunches, and switches to Markdown. Ends with the six fields read back from the database on the Markdown page.
    func openInMarkdown(_ book: SeedBook) throws {
        let path = TestFixtureHelper.fixturePath
        FixtureDatabase.seedMarkdown(fixturePath: path, markdown: book.markdown)
        app.launchForTesting(fixturePath: path)
        try require(app.editorArea.waitForExistence(timeout: 15), "TEST-SETUP: the editor area did not appear on the first launch")
        // The app makes the block rows from the seeded markdown itself. Wait until all of them are saved and two reads agree.
        var last: [String] = []
        let parsed = pollUntilTrue(timeout: 60, pollInterval: 0.7) {
            let now = savedRows()
            defer { last = now }
            return now == book.fragments && last == now
        }
        try require(parsed, "TEST-SETUP: the first launch never saved the seeded book as block rows. Rows now:\n\(rowsReport())")
        app.terminate()

        let sql = book.headings.compactMap { block -> String? in
            guard let fields = block.fields else { return nil }
            return "UPDATE block SET \(fields.assignments) WHERE blockType = 'heading' "
                + "AND \(Self.trimmedFragment) = '\(FixtureDatabase.escape(block.fragment))';"
        }.joined(separator: "\n")
        FixtureDatabase.write(fixturePath: path, sql: sql)
        try requireSeededFields(book, when: "after the sqlite3 UPDATE, before the relaunch")

        app.launchForTesting(fixturePath: path)
        try require(app.editorArea.waitForExistence(timeout: 15), "TEST-SETUP: the editor area did not appear on the relaunch")
        let first = book.firstParagraph
        try require(
            app.editorStaticText(startingWith: first, exactLine: first, timeout: 45) != nil,
            "TEST-SETUP: the paragraph \"\(first)\" never appeared in the editor after the relaunch"
        )
        try switchToMarkdown(waitingFor: first, rawHeadingLine: book.blocks.first?.fragment ?? "")
        try requireSeededFields(book, when: "after the switch to Markdown")
    }

    /// Every heading row of the book holds the fields it was seeded with.
    func requireSeededFields(_ book: SeedBook, when moment: String) throws {
        for block in book.headings {
            guard let fields = block.fields else { continue }
            let row = try unwrap(headingRow(block.fragment), "TEST-SETUP: no \"\(block.fragment)\" heading row \(moment)\n\(rowsReport())")
            try require(
                row.fields == fields,
                "TEST-SETUP: \"\(block.fragment)\" does not hold its seeded fields \(moment): \(row.fields.differences(from: fields))"
            )
        }
    }

    /// Cmd-/ to the Markdown page. The status-bar badge flips before the page exists, so readiness is the first of two signals (bounded):
    /// the app's own log line (the follower is made BEFORE the key, and only lines after it count), or the raw `# ` heading line
    /// `rawHeadingLine` showing in the editor's accessibility tree (a Markdown-only element: Rich Text shows the heading without its `#`).
    /// The element signal is used only when the line is NOT already visible before the key (a positive control, else it proves nothing).
    func switchToMarkdown(waitingFor paragraph: String, rawHeadingLine: String) throws {
        let mode = app.buttons["status-bar-editor-mode"]
        try require(mode.waitForExistence(timeout: 10), "TEST-SETUP: the editor-mode button never appeared")
        try require(
            mode.waitForLabel("== 'Rich Text'", timeout: 10),
            "TEST-SETUP: the document must open in Rich Text mode (the badge reads \"\(mode.label)\")"
        )
        let elementSignalUsable = !rawHeadingLine.isEmpty && !editorShowsText(rawHeadingLine)
        let tail = Phase4bDelLogTail()
        tail.poll()
        let from = tail.lines.count
        // The keystroke can drop when the app is not reliably in front (a proven pattern): press, and press again only if neither the
        // badge has flipped nor the app's log shows it received the toggle, after a long bounded wait (`toggleEditorModeUntilReceived`).
        let toggle = toggleEditorModeUntilReceived(app, to: "Markdown", maxPresses: 2, receiptWindow: 20) { self.pressChord("/", .command) }
        try require(toggle.flipped, "Cmd-/ did not switch the editor to Markdown (the badge reads \"\(mode.label)\")")
        let needle = Phase4bDelHarness.markdownPageReadyLogLine
        var signal = "none"
        let ready = pollUntilTrue(timeout: Self.saveBound, pollInterval: 0.25) {
            tail.poll()
            if tail.indexOfFirstLine(containing: needle, from: from) != nil {
                signal = "the app's log line"
                return true
            }
            if elementSignalUsable, editorShowsText(rawHeadingLine) {
                signal = "the raw heading line \"\(rawHeadingLine)\" in the accessibility tree"
                return true
            }
            return false
        }
        attachText("Markdown page ready via: \(signal); element signal usable: \(elementSignalUsable); log lines followed: \(tail.lines.count)",
                   name: "markdown-page-ready")
        try require(
            ready,
            "The Markdown page never finished loading within \(Self.saveBound) s of the switch: no \"\(needle)\" line in the app's log "
                + "(\(tail.lines.count - from) new line(s) read) and the raw heading line \"\(rawHeadingLine)\" never showed "
                + "(element signal usable: \(elementSignalUsable))"
        )
        try require(
            app.editorStaticText(startingWith: paragraph, exactLine: paragraph, timeout: 45) != nil,
            "TEST-SETUP: the paragraph \"\(paragraph)\" never appeared on the Markdown page"
        )
    }

    /// Double-click on Chapter One's Outline card (the zoom trigger the suite uses), then waits for the zoom's own tail in the app's log.
    func zoomIntoChapterOne() throws {
        let exitGlyph = app.buttons["status-bar-zoom-exit"]
        try require(!exitGlyph.exists, "TEST-SETUP: the zoom exit glyph already exists before the zoom")
        let card = sidebarCard(titled: "Chapter One")
        try require(card.waitForExistence(timeout: 15), "TEST-SETUP: the Outline sidebar has no card titled \"Chapter One\"")
        let visibleBand = app.groups["outline-sidebar"].scrollViews.firstMatch.frame
        try require(
            visibleBand.contains(card.frame),
            "TEST-SETUP: the \"Chapter One\" card (\(card.frame)) is outside the sidebar's visible band (\(visibleBand))"
        )
        let tail = Phase4bDelLogTail()
        tail.poll()
        let from = tail.lines.count
        app.activateAndWaitForForeground()
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        try require(exitGlyph.waitForExistence(timeout: 20), "The double-click on the \"Chapter One\" card did not zoom into it")
        // The zoom is done at the first of two signals (bounded): the app's log line, or the zoomed page showing Chapter One's text and
        // no longer Chapter Two's (the zoomed page holds only the chapter's range).
        let zoomLine = "[ZoomClick] performUserZoomIn tail complete in"
        let kept = "Scene A paragraph."
        let dropped = "Beta paragraph one."
        var signal = "none"
        let done = pollUntilTrue(timeout: Self.saveBound, pollInterval: 0.25) {
            tail.poll()
            if tail.indexOfFirstLine(containing: zoomLine, from: from) != nil {
                signal = "the app's log line"
                return true
            }
            if editorHasLeaf(kept), !editorHasLeaf(dropped) {
                signal = "the zoomed page holds \"\(kept)\" and no longer \"\(dropped)\""
                return true
            }
            return false
        }
        attachText("Zoom done via: \(signal); log lines followed: \(tail.lines.count)", name: "zoom-done")
        try require(
            done,
            "The zoom into Chapter One never finished within \(Self.saveBound) s: no \"\(zoomLine)\" line in the app's log "
                + "(\(tail.lines.count - from) new line(s) read) and the page still shows \"\(dropped)\" or not \"\(kept)\""
        )
        try require(
            app.editorStaticText(startingWith: kept, exactLine: kept, timeout: 45) != nil,
            "TEST-SETUP: the paragraph \"\(kept)\" never appeared on the zoomed page"
        )
    }

    /// True when a text leaf of the editor has exactly this value (one query, no first match: the sidebar's mirror is out of scope).
    func editorHasLeaf(_ exactValue: String) -> Bool {
        app.editorArea.staticTexts.matching(NSPredicate(format: "value == %@", exactValue)).count > 0
    }

    /// True when any node of the editor's accessibility subtree (one snapshot, any element type) shows `text` in its value, label or
    /// title. For the raw `# ` heading line: only the Markdown page exposes it (the proven source-mode evidence, see
    /// `UnifiedUndoE2ETests.switchToSourceMode`; a heading container in Rich Text carries the heading without its `#`).
    func editorShowsText(_ text: String) -> Bool {
        guard app.editorArea.exists else { return false }
        do {
            return Self.snapshot(try app.editorArea.snapshot(), shows: text)
        } catch {
            print("[MovedHeading] snapshot() of the editor failed: \(error)")
            return false
        }
    }

    static func snapshot(_ snapshot: XCUIElementSnapshot, shows text: String) -> Bool {
        snapshot.children.contains { child in
            ((child.value as? String)?.contains(text) ?? false) || child.label.contains(text) || child.title.contains(text)
                || Self.snapshot(child, shows: text)
        }
    }

    /// A sidebar card by its exact title. The title lives in `value`; the query is scoped to the sidebar's scroll view.
    func sidebarCard(titled title: String) -> XCUIElement {
        let sidebarScrollView = app.groups["outline-sidebar"].scrollViews.firstMatch
        return sidebarScrollView.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", title, title))
            .firstMatch
    }
}

// MARK: - Driving the editor

extension MarkdownMovedHeadingKeepsGoalsE2ETests {
    /// One key at the app, which is brought to the front first (a key pressed while the app is not frontmost is lost).
    func pressKey(_ key: XCUIKeyboardKey, _ flags: XCUIElement.KeyModifierFlags = []) {
        app.activateAndWaitForForeground()
        app.typeKey(key, modifierFlags: flags)
    }

    /// One character chord (Cmd-X, Cmd-V, Cmd-Z, Cmd-/) at the app, which is brought to the front first.
    func pressChord(_ character: String, _ flags: XCUIElement.KeyModifierFlags) {
        app.activateAndWaitForForeground()
        app.typeKey(character, modifierFlags: flags)
    }

    /// The caret at the very start of the heading line that sits two lines above the one-line paragraph `paragraph` (the heading, one
    /// blank line, the paragraph). The paragraph is an exact-value text leaf, found and clicked with the confirmed helper, which also
    /// proves the caret is at the start of that line; the heading itself is never searched for (an H1 line is not exposed as a
    /// StaticText in Markdown mode). Whether the caret really ended on the heading line is checked by the caller through the database.
    func placeCaretAtHeadingStart(aboveParagraph paragraph: String) throws {
        let caret = app.placeCaretByClicking(
            paragraphStartingWith: paragraph, atEnd: false, runProbe: true, findTimeout: 45, exactLine: paragraph
        )
        try require(
            caret.confirmed,
            "TEST-SETUP: the caret could not be placed at the start of \"\(paragraph)\" (probe: \(caret.probe)); attempts: \(caret.attempts)"
        )
        pressKey(.upArrow)
        pressKey(.upArrow)
        pressKey(.leftArrow, .command)
    }

    /// The heading line above `paragraph` selected, with its newline (the caret at its start, then Shift-Down to the start of the next
    /// line); with `includingBlankLine` a second Shift-Down also takes the blank line below it, so the selection is a whole block.
    func selectHeadingLine(aboveParagraph paragraph: String, includingBlankLine: Bool = false) throws {
        try placeCaretAtHeadingStart(aboveParagraph: paragraph)
        pressKey(.downArrow, .shift)
        if includingBlankLine { pressKey(.downArrow, .shift) }
    }

    /// Waits until a removal of the heading line `fragment` has been SAVED on its own: first its row is gone, then the saved rows are the
    /// book without that one line (a selection that took out more or less shows here as a TEST-SETUP failure, not as a wrong carry).
    /// Both waits are bounded polls of the database; `what` names the act in the failure messages and the attachments.
    func requireRemovalSaved(of fragment: String, from book: SeedBook, after what: String) throws {
        let gone = pollUntilTrue(timeout: Self.saveBound) { headingCount(fragment) == 0 }
        attachEvidenceScreenshot(app.screenshot(), name: "after-the-\(what)")
        attachText(rowsReport(), name: "rows-after-the-\(what)")
        try require(
            gone,
            "The database still holds a \"\(fragment)\" heading row \(Self.saveBound) s after the \(what) (the selection may have missed "
                + "the line, or the save never ran)\n\(rowsReport())"
        )
        let expected = book.fragments.filter { $0 != fragment }
        try require(
            pollUntilTrue(timeout: 10) { savedRows() == expected },
            "TEST-SETUP: the \(what) took out more or less than the heading line. Expected rows:\n\(expected.joined(separator: "\n"))\n"
                + "Rows now:\n\(rowsReport())"
        )
    }

    /// Edits a heading line in place: caret to the end of the heading line above `paragraph`, `replacing.count` Backspaces, then the new
    /// word typed. Each key is its own step, so the save may land between any two of them; the heading stays a rename throughout.
    /// The page is taken to the end of the document first (Cmd-Down): CodeMirror draws only the lines near the viewport, and in the
    /// five-chapter book Chapters Four and Five lie below the fold (first VM run, last video frame), so their paragraphs are not in
    /// the accessibility tree until the editor has scrolled there. The editor holds the focus here (the steps before were typed in it).
    func renameHeading(aboveParagraph paragraph: String, replacing old: String, with new: String) throws {
        pressKey(.downArrow, .command)
        try placeCaretAtHeadingStart(aboveParagraph: paragraph)
        pressKey(.rightArrow, .command)
        for _ in old {
            pressKey(.delete)
        }
        app.activateAndWaitForForeground()
        // e2e-lint: allow raw-typetext -- appended to a heading line that holds other text, where the landing helper's repair would clear the line.
        app.typeText(new)
    }
}

// MARK: - The database

extension MarkdownMovedHeadingKeepsGoalsE2ETests {
    /// `trim` that also strips the newline and tab characters a fragment can carry (plain `trim` strips spaces only).
    static let trimmedFragment = "trim(markdownFragment, ' ' || char(9) || char(10) || char(13))"

    func read(_ sql: String) -> String {
        FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The rows' markdown in the order the app assembles them: saved position, a heading before a paragraph at the same position, then
    /// insertion order. Blank rows are left out.
    func savedRows() -> [String] {
        let sentinel = "###ROWEND###"
        let sql = "SELECT markdownFragment || '\(sentinel)' FROM block "
            + "ORDER BY sortOrder, CASE WHEN blockType = 'heading' THEN 0 ELSE 1 END, rowid;"
        let output = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
        return output.components(separatedBy: "\(sentinel)\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func rowsReport() -> String {
        let rows = savedRows()
        guard !rows.isEmpty else { return "(the block table is empty)" }
        return rows.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    /// The first heading row whose line is exactly `fragment`, with its six fields. Nil when there is none.
    func headingRow(_ fragment: String) -> HeadingRow? {
        let sql = "SELECT id || '|' || COALESCE(status, 'NULL') || '|' || COALESCE(tags, 'NULL') || '|' || COALESCE(wordGoal, 'NULL') "
            + "|| '|' || goalType || '|' || COALESCE(aggregateGoal, 'NULL') || '|' || aggregateGoalType FROM block "
            + "WHERE blockType = 'heading' AND \(Self.trimmedFragment) = '\(FixtureDatabase.escape(fragment))' ORDER BY sortOrder LIMIT 1;"
        let parts = read(sql).components(separatedBy: "|")
        guard parts.count == 7 else { return nil }
        return HeadingRow(
            id: parts[0],
            fields: SixFields(
                status: parts[1], tags: parts[2], wordGoal: parts[3], goalType: parts[4], aggregateGoal: parts[5], aggregateGoalType: parts[6]
            )
        )
    }

    /// How many heading rows have exactly this line. A read that fails counts as -1, never as "none".
    func headingCount(_ fragment: String) -> Int {
        let sql = "SELECT count(*) FROM block WHERE blockType = 'heading' "
            + "AND \(Self.trimmedFragment) = '\(FixtureDatabase.escape(fragment))';"
        return Int(read(sql)) ?? -1
    }

    /// How many heading rows hold all six of these values.
    func rowsCarrying(_ fields: SixFields) -> Int {
        let sql = "SELECT count(*) FROM block WHERE blockType = 'heading' AND status = '\(fields.status)' "
            + "AND tags = '\(FixtureDatabase.escape(fields.tags))' AND wordGoal = \(fields.wordGoal) AND goalType = '\(fields.goalType)' "
            + "AND aggregateGoal = \(fields.aggregateGoal) AND aggregateGoalType = '\(fields.aggregateGoalType)';"
        return Int(read(sql)) ?? -1
    }

    /// The failures (empty when none) of "the heading row `fragment` holds exactly `expected`".
    func fieldFailures(_ fragment: String, expected: SixFields, stage: String) -> [String] {
        guard let row = headingRow(fragment) else { return ["[\(stage)] no heading row \"\(fragment)\" in the database"] }
        return row.fields.differences(from: expected).map { "[\(stage): \(fragment): \($0)] the section lost or changed its own field" }
    }

    /// The neighbours of the moved heading keep their own six fields (the promise is the fields, not the row id).
    func neighbourFailures(_ neighbours: [NeighbourCheck]) -> [String] {
        neighbours.flatMap { fieldFailures($0.fragment, expected: $0.fields, stage: "neighbour") }
    }
}

// MARK: - The Outline sidebar

extension MarkdownMovedHeadingKeepsGoalsE2ETests {
    /// Every node under the sidebar's scroll view, from ONE snapshot (one accessibility round trip, walked in-process). Nil when the
    /// scroll view cannot be read.
    func sidebarNodes() -> [SidebarNode]? {
        let scroll = app.groups["outline-sidebar"].scrollViews.firstMatch
        guard scroll.exists else { return nil }
        do {
            return Self.flatten(try scroll.snapshot())
        } catch {
            print("[MovedHeading] snapshot() of the sidebar failed: \(error)")
            return nil
        }
    }

    static func flatten(_ snapshot: XCUIElementSnapshot) -> [SidebarNode] {
        snapshot.children.flatMap { child -> [SidebarNode] in
            let node = SidebarNode(
                type: child.elementType, label: child.label, value: (child.value as? String) ?? "", frame: child.frame
            )
            return [node] + flatten(child)
        }
    }

    /// What is wrong with the card titled `title` (empty: nothing). It must sit below the card titled `above` and above the one titled
    /// `below` (nil: no neighbour on that side), show the status badge text `status`, and show an aggregate goal text "Σ <symbol><n>/<limit>"
    /// (the card shows the aggregate form while an aggregate goal is set). The badge and the goal are found by their text and by lying
    /// vertically between the neighbours' titles (or within a card's height of its own title), so only this card's own can match: the
    /// other cards show other statuses and limits.
    func sidebarFailures(of title: String, status: String, goalLimit: Int, above: String?, below: String?) -> [String] {
        guard let nodes = sidebarNodes() else { return ["the Outline sidebar's scroll view could not be read"] }
        func titleY(_ name: String) -> CGFloat? { nodes.first { $0.type == .staticText && $0.shows(name) }?.frame.minY }
        guard let own = titleY(title) else { return ["no sidebar card is titled \"\(title)\""] }
        var failures: [String] = []
        // With no neighbour on a side, the card's own status row (about 20 pt above its title) and goal row (below it) bound the window.
        var lower = own - 60
        var upper = own + 120
        if let above {
            if let aboveY = titleY(above) {
                lower = aboveY
                if own <= aboveY { failures.append("the \"\(title)\" card is not below the \"\(above)\" card") }
            } else {
                failures.append("no sidebar card is titled \"\(above)\"")
            }
        }
        if let below {
            if let belowY = titleY(below) {
                upper = belowY
                if own >= belowY { failures.append("the \"\(title)\" card is not above the \"\(below)\" card") }
            } else {
                failures.append("no sidebar card is titled \"\(below)\"")
            }
        }
        let pattern = "^\u{03A3}\\s*\u{2264}\\s*\\d+\\s*/\\s*\(goalLimit)$"
        let statusShown = nodes.contains { $0.shows(status) && $0.frame.minY > lower && $0.frame.minY < upper }
        let goalShown = nodes.contains { node in
            [node.value, node.label].contains { $0.range(of: pattern, options: .regularExpression) != nil }
                && node.frame.minY > lower && node.frame.minY < upper
        }
        if !statusShown { failures.append("the \"\(title)\" card does not show its status \"\(status)\"") }
        if !goalShown { failures.append("the \"\(title)\" card does not show its goal (a text matching \(pattern))") }
        return failures
    }

    /// `sidebarFailures`, polled (bounded) until it is empty: the sidebar is redrawn from a snapshot of the saved rows, a moment after
    /// them. Returns the last answer.
    func sidebarFailuresAfterWaiting(of title: String, status: String, goalLimit: Int, above: String?, below: String?) -> [String] {
        var failures: [String] = []
        _ = pollUntilTrue(timeout: Self.saveBound) {
            failures = sidebarFailures(of: title, status: status, goalLimit: goalLimit, above: above, below: below)
            return failures.isEmpty
        }
        return failures
    }
}

// MARK: - Plumbing

extension MarkdownMovedHeadingKeepsGoalsE2ETests {
    /// Fails the test with `message` and ends it: for a step the rest of the test cannot meaningfully run without.
    func require(_ condition: Bool, _ message: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) throws {
        if condition { return }
        XCTFail(message(), file: file, line: line)
        throw MovedHeadingStop()
    }

    func unwrap<T>(_ value: T?, _ message: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        if let value { return value }
        XCTFail(message(), file: file, line: line)
        throw MovedHeadingStop()
    }

    /// Runs `body` so that failed assertions inside it are recorded without ending the test (all of them are reported together).
    func softly(_ body: () -> Void) {
        let previous = continueAfterFailure
        continueAfterFailure = true
        defer { continueAfterFailure = previous }
        body()
    }

    /// Polls `probe` every `pollInterval` until it returns true or `timeout` passes; returns the last answer.
    func pollUntilTrue(timeout: TimeInterval, pollInterval: TimeInterval = 0.5, _ probe: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if probe() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: pollInterval))
        } while Date() < deadline
        return probe()
    }

    /// Waits (bounded) until a line of the app's log, written after `tail` was made, contains `needle`.
    func waitForLog(_ tail: Phase4bDelLogTail, containing needle: String, timeout: TimeInterval) -> Bool {
        pollUntilTrue(timeout: timeout, pollInterval: 0.25) {
            tail.poll()
            return tail.indexOfFirstLine(containing: needle) != nil
        }
    }

    func attachText(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
