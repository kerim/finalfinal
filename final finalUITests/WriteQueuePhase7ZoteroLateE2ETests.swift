//
//  WriteQueuePhase7ZoteroLateE2ETests.swift
//  final finalUITests
//
//  PHASE 7 of the write-queue redesign (board t-a54c1950, parent t-94369a83): the first bibliography check after a book opens used to be
//  lost, without a trace, when Zotero was not yet marked connected. The check returned at its `isConnected` guard and nothing retried
//  it, so the book opened with no Bibliography until the first edit. Phase 6 found it on the twelve-chapter book (a 33 ms race between
//  the check's 1 s debounce and the open-time connection) and only moved the connection earlier. The fix makes the order irrelevant: a
//  check that finds Zotero not connected asks Zotero itself.
//
//  WHAT THIS TEST DOES, WITHOUT A CLOCK WINDOW. The app is launched with the Zotero mock and `FF_UI_TESTING_ZOTERO_HOLD_CONNECT=1`
//  (`TestMode.isUITestingZoteroConnectHeld`): the open-time connection (`ContentView.connectToZotero`) waits
//  until the first bibliography check has made its attempt, so EVERY run has the losing order (check first, connection second), however
//  fast or slow the machine is. Nothing is typed and nothing is clicked: the generated Bibliography must appear by itself.
//    - On the old code the check returns silently at the guard, the connection is then released, nothing retries, and the Bibliography
//      is never generated (the test fails after the size's bibliography wait).
//    - On the fix the check asks Zotero, which answers, and the Bibliography is generated.
//  The test also reads three lines of the app's own log: the hold began, the check found Zotero not connected and asked, and the hold was
//  released after the check (so the losing order really happened and the fix path really ran). The existing real-app test
//  `WriteQueuePhase4bStructuralQueueE2ETests/testReplaceSectionThenType_book12`, which found the race, is the regression partner.
//
//  Run (VM, sandbox off): scripts/vmtest/vmtest run --detach --timeout 3600 \
//      --scope "final finalUITests/WriteQueuePhase7ZoteroLateE2ETests/testFirstCheckBeforeZoteroConnects_article"
//

import XCTest

final class WriteQueuePhase7ZoteroLateE2ETests: Phase4bDelHarness {
    /// The most seconds the Bibliography may take once the editor is ready (the fixed code needs about 3; the VM swings about 3 times).
    static let latestReadySeconds: TimeInterval = 40

    func testFirstCheckBeforeZoteroConnects_article() { runFirstCheckBeforeZoteroConnects(.article, method: #function) }
    func testFirstCheckBeforeZoteroConnects_book12() { runFirstCheckBeforeZoteroConnects(.book12, method: #function) }

    func runFirstCheckBeforeZoteroConnects(_ size: Phase4bDelSize, method: String) {
        begin(method: method, size: size)
        app.launchEnvironment["FF_UI_TESTING_ZOTERO_HOLD_CONNECT"] = "1"
        guard launchScenario() else { return }

        let held = waitForLog(containing: "[ZoteroHold] the open-time connection waits for the first bibliography check", timeout: capped(30))
        let asked = waitForLog(containing: "Zotero is not marked connected at the bibliography check; asking it now", timeout: capped(30))
        let released = waitForLog(containing: "[ZoteroHold] released: the first bibliography check has been made", timeout: capped(30))
        let gaveUp = tail.indexOfFirstLine(containing: "Zotero did not answer; the bibliography check ends") != nil
        let bibliography = dbText("SELECT markdownContent FROM section WHERE isBibliography = 1;")
        note("RESULT the hold began: \(Self.yesNo(held)); the check asked Zotero: \(Self.yesNo(asked)); the hold was released after the check: "
            + "\(Self.yesNo(released)); the check gave up: \(Self.yesNo(gaveUp)); generated bibliography: \(bibliography.count) characters")

        assertCheck(held, "the open-time Zotero connection was held back (the test's precondition: without it this run proves nothing)")
        assertCheck(asked, "the first bibliography check found Zotero not marked connected and asked it (the fix's own path ran)")
        assertCheck(released, "the held connection was released after the first check")
        assertCheck(!gaveUp, "the mock Zotero answered: the check did not give up")
        assertCheck(bibliography.count > 200,
                    "the Bibliography was generated at open, with no edit, although Zotero connected only after the first check "
                    + "(\(bibliography.count) characters in the section table)")
        // On the old code the small article could still get its Bibliography from a later change (62 s after the open in one run), so
        // "it appeared" is not enough: it must appear soon after the open, from the first check itself. The fixed code takes about
        // 3 s on both documents once the editor is ready.
        let ready = bibliographyReadySeconds
        note("RESULT the generated bibliography was ready \(ready.map { Self.seconds($0) } ?? "never") s after the editor was ready")
        assertCheck(ready != nil && ready! <= Self.latestReadySeconds,
                    "the Bibliography was ready within \(Int(Self.latestReadySeconds)) s of the editor being ready (it took "
                    + "\(ready.map { Self.seconds($0) } ?? "more than the size's wait") s)")
    }
}
