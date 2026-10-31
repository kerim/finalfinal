//
//  WriteQueuePhase4bMarkdownEFE2ETests+FootnoteTimer.swift
//  final finalUITests
//
//  bt task t-f1a22aa7 (Phase 4c, job 1): THE FOOTNOTE TIMER THAT CAME DUE WHILE A MARKDOWN SECTION COMMAND WAS STILL FINISHING, proven
//  in the real app. In Markdown mode a footnote burst timer (3 s after a change of the footnote references) could fire between a section
//  command's click and the end of its settle (Delete, drag, Duplicate, Version History restore). Its renumber then reached the page
//  outside the settle's flag: it became a Cmd-Z step of its own and skipped the Notes sort, and the settle's own renumber, the one that
//  sorts, was skipped as "already done". The fix makes the timer stand aside (write nothing, keep its waiting snapshot, ask again 0.25 s
//  later) while the command has unfinished work, and moves a drag's "forget the committed Notes hash" into the footnote resync itself.
//  The design record is in .claude/superdev/footnote-timer-race-4c1/ (plan-v2.md Step 6 and plan-v2-addendum.md) and in
//  docs/architecture/write-queue-plan/phase4c/footnote-timer/.
//
//  THIS FILE is an extension of `WriteQueuePhase4bMarkdownEFE2ETests` (one class, the sibling +files' helpers: the drag, the sidebar
//  commands, the press loop, the rows, the Save Version round trip). It is the ONE new permanent UI-test file of the branch. It holds two
//  tests; each is a PROOF IN THE REAL APP of the race that no unit or page-level test can reach (the real timer, the real settle, the real
//  Cmd-Z timeline), and each pins an exact press count.
//
//  THE TWO TESTS
//    testMdDeleteFootnoteTimerInsideJob_book6    launch env FF_UI_TESTING_REWRITE_DELAY_SECONDS=30 (the footnote burst waits 30 s, not 3 s),
//        FF_UI_TESTING_EF_SETTLE_HOLD_MS=50000 and ..._FIRST_N=1 (the Delete's settle waits 50 s, a plain suspension, before its footnote
//        resync; the Delete's queued job is NOT held any more). The name is the one the first rounds gave it ("inside the job") and stays.
//        Chapter 2 (nine footnote references) is deleted, then at once a click back into the text and ONE letter. THE TIMING IS THE POINT:
//        the burst's deadline (30 s after the Delete's change reached the app) must come AFTER the letter is typed and still INSIDE the
//        held settle (which ends 50 s after it began). WHY: with the first design (a 1 s delay and a 3.5 s job hold) the break patch BP-A
//        did not fail the test. The app's log of that run: `deadline fixed interval=1000ms` at 10:26:22.022Z, `[FN-STANDASIDE]` and
//        `debounce fired` at 10:26:23.116Z, so the switched-off fix let the timer write about 1.1 s after the click, several seconds
//        BEFORE the letter (a right-click menu choice takes the keyboard focus to the Outline, then the test clicks back into the text).
//        The page folds a footnote renumber that arrives while the document still equals the Delete's saved post-delete copy into the
//        Delete's own undo step (`web/codemirror/src/undo-coordinator.ts`, `maybeAdvanceRegistryOnSyncOriginTx`: it advances the saved
//        copy for a renumber tagged as a correction), so no extra Cmd-Z step existed. The extra step, the original bug, exists only when
//        the letter is typed BEFORE the timer's renumber arrives: the history is [delete, letter, renumber] and the first Cmd-Z undoes the
//        renumber instead of the letter. The test proves the order from the app's log (see THE PREMISE).
//        THE PRESS COUNTS WITH THE FIX: Cmd-Z #1 is a text step (the letter goes), Cmd-Z #2 is the structural undo (the chapter
//        comes back), Cmd-Shift-Z #1 is structural (the chapter is gone), Cmd-Shift-Z #2 is a text step (the letter is back).
//        UNDER BREAK PATCH BP-A (the timer writes inside the command): the timer's renumber (at 30 s, after the letter) is one more Cmd-Z
//        step. Cmd-Z #1 undoes the renumber, not the letter, so the Anchor05 line still carries the letter and the failure reads
//        "Cmd-Z #1 undid something other than the typed letter ..."; Cmd-Z #2 is then the letter (a text step), "Cmd-Z #2 was a text
//        step, expected the structural undo ...". Under BP-AE it fails the same way.
//    testMdDragFootnoteTimerInsideSettle_book12  launch env FF_UI_TESTING_REWRITE_DELAY_SECONDS=2.5, FF_UI_TESTING_EF_SETTLE_HOLD_MS=4000 and
//        FF_UI_TESTING_EF_SETTLE_HOLD_FIRST_N=1 (the drag's settle waits 4 s, a plain suspension, before its footnote resync; the drag's
//        queued job is too short to hold). The 2.5 s delay (it was 1.5 s) lets the burst's deadline land INSIDE the 4 s hold even when the
//        queued job and the section refresh before the hold take a second or two on the VM (see THE PREMISE). Chapter 7 (nine footnote
//        references) is dragged above Chapter 6 and at once ONE letter is typed (the caret travels with the moved text; no click).
//        THE PRESS COUNTS WITH THE FIX: Cmd-Z #1 text, Cmd-Z #2 structural (the drag's
//        queued slow undo), Cmd-Shift-Z #1 structural, Cmd-Shift-Z #2 text. NOTE: under BP-A ALONE THIS TEST PASSES. Once the forget of
//        the committed Notes hash sits in the footnote resync (after the timer's run), a drag's own timer run hits the hash guard and
//        does nothing, so the drag is fixed by EITHER mechanism and fails only with both removed (BP-AE = BP-A plus the old forget site back,
//        which is the original bug): then one more Cmd-Z (the renumber's step) and the Notes unsorted.
//
//  THE PREMISE (read from the app's log, reported as TEST-SETUP and never as a pass): after the command the persisted diagnostic log holds
//  at least one `[FN-STANDASIDE]` line (`DebugLog.alwaysPersisted`, so it reaches diagnostic.log as `[always] [FN-STANDASIDE] ...`). The
//  app writes it, once per burst, the moment a footnote deadline arrives while a section command has unfinished work. It is written in the
//  fixed build and with the stand-aside switched off alike (BP-A only removes the re-arm, not the line), so a break patch fails the
//  press-count assertions and never the premise. The follower `tail` (`Phase4bDelLogTail`) reads diagnostic.log, so no new production hook
//  is used.
//  THE DRAG ADDS AN ORDERING PREMISE (`fnTimerRequireStandAsideInsideHold`): the FIRST `[FN-STANDASIDE]` line since the drag must come
//  AFTER the `[EF-SETTLE-HOLD]` line (written by `TestMode.holdEditorFirstSettle` when the settle's hold begins), else TEST-SETUP, with a
//  distinct message for "no hold line" and "stand-aside before the hold line". Why: under the original bug (BP-AE) the old forget of the
//  committed Notes hash runs at the end of the settle's early part, BEFORE the hold. A timer that comes due before that forget hits the
//  hash guard and writes nothing, the settle then renumbers inside its flag, and the test would go green on the bug; an
//  `[FN-STANDASIDE]` line alone does not catch it, because the line is also written while the queued job is still unfinished. A timer
//  that comes due after the hold began is after the forget. The Delete has no forget, so it needs no hold ordering.
//  THE DELETE ADDS A DIFFERENT ORDERING PREMISE (`fnTimerRequireLetterBeforeBurst`): the letter was typed BEFORE the burst came due. The
//  test reads the log's length the moment `typeNow` returns (`tail.poll()`, `tail.lines.count`: the index the next line will get) and
//  requires the FIRST `[FN-STANDASIDE]` line since the Delete click to sit at or after that index (`tail.indexOfFirstLine`), else a
//  distinct TEST-SETUP failure ("the letter was typed after the footnote burst came due"). Why: a renumber that comes before the letter is
//  folded into the Delete's own undo step by the page, so the run could not show the race and would go green on the original bug (this is
//  what BP-A did in the first design). The order of the two premises: first that a line exists at all (its message names the missing
//  seams), then where it sits. The Delete then waits for its held settle to END (`fnTimerWaitForHeldSettleToEnd`: the `[EF-SETTLE-HOLD]`
//  line's stamp plus the hold, and the saved references running 1...N), because the log is quiet during the hold and the usual
//  "quiet for 3 s" settle would end in the middle of it.
//
//  AFTER EACH STRUCTURAL PRESS (and after the command itself): the saved rows are the hand-worked document, the footnote references run
//  1...N in reading order, the Notes are numbered 1...N once each in order, and File > Save Version (which writes the LIVE editor text into
//  the table) leaves the rows byte for byte as they were: the page's Notes region equals the rows.
//
//  WAITS: every wait is a condition (the app's log, a database row, the sidebar). The steps follow each other at once, as a person would
//  give them: click, type, press. Nothing here needs the user to wait.
//
//  RUNNING (VM only; the vmtest call needs the sandbox off):
//    scripts/vmtest/vmtest run --detach --timeout 1800 \
//      --scope "final finalUITests/WriteQueuePhase4bMarkdownEFE2ETests/testMdDeleteFootnoteTimerInsideJob_book6"
//    (book6 runs take 1800 to 3600 s, the book12 drag 3600 to 7000 s; use --timeout 1200 per wait and loop on exit 124.)
//

import AppKit
import XCTest

// MARK: - Shared pieces

extension WriteQueuePhase4bMarkdownEFE2ETests {
    /// The line the app persists ONCE PER BURST when a footnote deadline arrives while a section command has unfinished work
    /// (`FootnoteSyncService+Diagnostics.swift`, `noteBurstDueDuringStructuralWork`).
    static let fnTimerStandAsideTag = "[FN-STANDASIDE]"
    /// The line the app persists the moment the drag's held settle begins its hold (`TestMode.holdEditorFirstSettle`; UI-test-only).
    static let fnTimerSettleHoldTag = "[EF-SETTLE-HOLD]"
    /// The launch seams of these tests (`App/TestMode.swift`; inert unless FF_UI_TESTING=1).
    static let fnTimerRewriteDelayKey = "FF_UI_TESTING_REWRITE_DELAY_SECONDS"
    static let fnTimerSettleHoldKey = "FF_UI_TESTING_EF_SETTLE_HOLD_MS"
    static let fnTimerSettleHoldFirstKey = "FF_UI_TESTING_EF_SETTLE_HOLD_FIRST_N"
    /// The one letter typed after the command: a character the editor does not transform, and exactly one undo step.
    static let fnTimerLetter = "Z"
    /// The Delete test's seams: the footnote burst waits 30 s and the Delete's settle is held 50 s. The burst's deadline is fixed when the
    /// Delete's change reaches the app (a fraction of a second after the click), so it comes due 30 s after the click; the letter needs
    /// a right-click menu choice, a click back into the text and the typing, which took a few seconds and up to about 10 s on the six-chapter
    /// book, so 30 s leaves 20 s to spare before the deadline. The hold begins when the Delete's job has applied (about a second after the
    /// click) and lasts 50 s, so the deadline lands 20 s before the hold ends even on a slow run.
    static let fnTimerDeleteRewriteDelaySeconds = 30
    static let fnTimerDeleteSettleHoldMs = 50_000
    /// The sentence the drag test adds to its "Cmd-Z #2 was a text step, expected the structural undo" failure when the press and all three
    /// retries were text steps (measured under BP-AE: the typed letter and the timer's renumber were undone, then Cmd-Z found nothing
    /// left to undo). The test stops right after it is recorded (see the guard after Cmd-Z #2 of the drag test).
    static let fnTimerDragUndoGoneNote = "When the retries find nothing left to undo, the drag can no longer be undone: the structural undo is "
        + "gone, which is the original bug. The steps that depend on that undo (the document checks after it, the Save Version round trip and the "
        + "Cmd-Shift-Z presses) were NOT run: the test stops here instead of waiting for a heading order that can never come back."

    /// THE PREMISE: the footnote timer came due while the command was unfinished, read from the app's persisted log since `index` (the
    /// log index just before the command's click). A missing line is a TEST-SETUP failure (the race never happened, so the press counts
    /// below would prove nothing), never an app failure and never a pass. False after a reported failure. `timeout` is how long the line
    /// may take to appear (the Delete test's burst waits 30 s, so it asks for 90).
    func fnTimerRequirePremise(from index: Int, command: String, timeout: TimeInterval = 20) -> Bool {
        let seen = waitForLog(containing: Self.fnTimerStandAsideTag, from: index, timeout: timeout)
        let lines = logLines(containing: Self.fnTimerStandAsideTag, from: index).map { String($0.text.suffix(150)) }
        result("PREMISE: \(lines.count) `\(Self.fnTimerStandAsideTag)` line(s) in the persisted log since the \(command) click "
            + "(at least 1 expected, written once per burst): \(lines.prefix(2))")
        guard seen else {
            fail("TEST-SETUP: no `\(Self.fnTimerStandAsideTag)` line in the app's persisted log since the \(command) click: the footnote "
                + "timer never came due while the command was unfinished, so the race this test is about did not happen and its press counts "
                + "would prove nothing (the seams FF_UI_TESTING_REWRITE_DELAY_SECONDS and the hold may not have reached the app, or the page's "
                + "content change reached the app too late). Not an app failure.")
            return false
        }
        return true
    }

    /// THE DRAG'S ORDERING PREMISE (checked after `fnTimerRequirePremise`, so a stand-aside line exists): the FIRST `[FN-STANDASIDE]` line
    /// since `index` comes AFTER the `[EF-SETTLE-HOLD]` line in the persisted log. Why: under the original bug the old "forget the
    /// committed Notes hash" runs at the end of the settle's early part (`settleReorderOverlay`), BEFORE the hold begins. A footnote timer
    /// that comes due before the forget hits the hash guard and writes nothing, so the settle's own renumber then runs inside its flag and
    /// the test would go green on the bug (a slow VM can take the job and `refreshSectionsAwaiting` past the burst's delay). A timer that
    /// comes due after the hold began is after the forget, which is the race this test is about. Both lines are read with the follower
    /// the test already uses (`waitForLog(containing:from:timeout:)`, then `tail.indexOfFirstLine(containing:from:)`), from the same
    /// starting `index`. TEST-SETUP failure (distinct message per cause), never an app failure and never a pass. False after a failure.
    func fnTimerRequireStandAsideInsideHold(from index: Int, command: String) -> Bool {
        let holdSeen = waitForLog(containing: Self.fnTimerSettleHoldTag, from: index, timeout: 20)
        tail.poll()
        let holdIndex = tail.indexOfFirstLine(containing: Self.fnTimerSettleHoldTag, from: index)
        let standAsideIndex = tail.indexOfFirstLine(containing: Self.fnTimerStandAsideTag, from: index)
        result("PREMISE ORDER: first `\(Self.fnTimerSettleHoldTag)` line at log index \(holdIndex.map(String.init) ?? "none"), first "
            + "`\(Self.fnTimerStandAsideTag)` line at log index \(standAsideIndex.map(String.init) ?? "none") (the hold line must come first)")
        guard holdSeen, let holdIndex else {
            fail("TEST-SETUP: no `\(Self.fnTimerSettleHoldTag)` line in the app's persisted log since the \(command) click: the settle's "
                + "hold never began, so the footnote timer cannot have come due inside it (the seams FF_UI_TESTING_EF_SETTLE_HOLD_MS and "
                + "FF_UI_TESTING_EF_SETTLE_HOLD_FIRST_N may not have reached the app, or the \(command)'s settle never got to its hold). "
                + "Not an app failure.")
            return false
        }
        guard let standAsideIndex, holdIndex < standAsideIndex else {
            fail("TEST-SETUP: the first `\(Self.fnTimerStandAsideTag)` line (log index \(standAsideIndex.map(String.init) ?? "none")) came "
                + "BEFORE the `\(Self.fnTimerSettleHoldTag)` line (log index \(holdIndex)): the footnote timer came due before the settle's "
                + "early part had finished (a slow run), so it may have been stopped by the hash guard before the old forget ran, and this "
                + "test would not distinguish the fix from the original bug. Not an app failure.")
            return false
        }
        return true
    }

    /// THE DELETE'S ORDERING PREMISE (checked after `fnTimerRequirePremise`, so a stand-aside line exists): the letter was typed BEFORE the
    /// footnote burst came due. `letterTypedAt` is the log's length read the moment `typeNow` returned (`tail.poll()`, then
    /// `tail.lines.count`: the index the next log line gets), so a line at that index or later was written after the letter was typed. The
    /// FIRST `[FN-STANDASIDE]` line since `index` (found with `tail.indexOfFirstLine(containing:from:)`, from the same starting index as the
    /// premise before it) must be such a line. Why: the page folds a footnote renumber that arrives while the document still equals the
    /// Delete's saved copy into the Delete's own undo step, so a timer that came due BEFORE the letter leaves no extra Cmd-Z step even
    /// with the fix switched off, and the test would go green on the original bug (what the first design did under BP-A). TEST-SETUP
    /// failure, never an app failure and never a pass. False after a reported failure.
    func fnTimerRequireLetterBeforeBurst(from index: Int, letterTypedAt: Int, command: String) -> Bool {
        tail.poll()
        let standAsideIndex = tail.indexOfFirstLine(containing: Self.fnTimerStandAsideTag, from: index)
        result("PREMISE ORDER (letter): the letter was typed when the log held \(letterTypedAt) line(s); the first "
            + "`\(Self.fnTimerStandAsideTag)` line since the \(command) click is at log index \(standAsideIndex.map(String.init) ?? "none") "
            + "(it must be \(letterTypedAt) or later)")
        guard let standAsideIndex, standAsideIndex >= letterTypedAt else {
            fail("TEST-SETUP: the letter was typed after the footnote burst came due: the first `\(Self.fnTimerStandAsideTag)` line since the "
                + "\(command) click is at log index \(standAsideIndex.map(String.init) ?? "none"), but the letter was typed when the log held "
                + "only \(letterTypedAt) line(s). The timer's renumber therefore reached the page BEFORE the letter, and the page folds such a "
                + "renumber into the \(command)'s own undo step, so the press counts below could not show the race (the original bug would "
                + "pass). The right-click, the click back into the text and the typing took longer than the burst's "
                + "\(Self.fnTimerDeleteRewriteDelaySeconds) s delay on this run, or the delay seam is not the one that reached the app. "
                + "Not an app failure.")
            return false
        }
        return true
    }

    /// The Delete test waits for its HELD settle to end and for the settle's renumber to reach the saved rows. Both are conditions: (1) the
    /// `[EF-SETTLE-HOLD]` line (persisted by `TestMode.holdEditorFirstSettle` the moment the hold begins) must exist, else TEST-SETUP (the
    /// seam never reached the app); (2) the hold is a plain `Task.sleep` of `holdMs` after that line, so the settle's resync cannot begin
    /// before the line's stamp plus `holdMs` (the app and the test share one clock inside the VM); (3) the settle's footnote resync
    /// renumbers the references, and with the timer standing aside nothing else does, so the saved rows run 1...`refCount` only after it
    /// (under a break patch the timer's own renumber satisfies this earlier, which step (2) has already held back). The app's log is quiet
    /// during the whole hold (the stand-aside line is written once per burst), so the usual "quiet for 3 s" settle alone would end in the
    /// middle of it. A rows wait that never succeeds is a soft failure (the settle's renumber never reached the rows), not a hang.
    func fnTimerWaitForHeldSettleToEnd(
        from index: Int, holdMs: Int, refCount: Int, soft: inout Phase4bFlowSoftChecks
    ) -> Bool {
        guard waitForLog(containing: Self.fnTimerSettleHoldTag, from: index, timeout: 60) else {
            fail("TEST-SETUP: no `\(Self.fnTimerSettleHoldTag)` line in the app's persisted log since the Delete Section click: the settle's "
                + "hold never began (the seams FF_UI_TESTING_EF_SETTLE_HOLD_MS and FF_UI_TESTING_EF_SETTLE_HOLD_FIRST_N may not have reached "
                + "the app), so there is no held settle to wait for. Not an app failure.")
            return false
        }
        tail.poll()
        let holdSeconds = Double(holdMs) / 1000
        let began = tail.indexOfFirstLine(containing: Self.fnTimerSettleHoldTag, from: index).flatMap { tail.lines[$0].date }
        // The hold is over at the line's stamp plus the hold; never wait longer than the hold plus 10 s from now (a stamp that cannot be read).
        let holdEnd = min(began?.addingTimeInterval(holdSeconds) ?? Date(), Date(timeIntervalSinceNow: holdSeconds + 10))
        while Date() < holdEnd { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5)) }
        let wanted = Array(stride(from: 1, through: refCount, by: 1))
        let deadline = Date(timeIntervalSinceNow: 120)
        var refs = Phase4bFlowWalk(rows: readRows()).refs
        while refs != wanted, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
            refs = Phase4bFlowWalk(rows: readRows()).refs
        }
        result("SETTLE END: the \(holdMs) ms hold began at \(began.map { WriteQueuePhase4bTraceE2ETests.stamp($0) } ?? "an unreadable stamp"); "
            + "the saved references read [\(Self.ascendingRuns(refs))] (expected 1...\(refCount))")
        soft.check(refs == wanted,
            "the saved footnote references still read [\(Self.ascendingRuns(refs))] 120 s after the Delete's held settle should have ended, "
            + "expected 1...\(refCount): the settle's renumber never reached the rows")
        return true
    }

    /// How many log lines at index `index` up to (not including) `end` contain `needle`; `end` is a log length read earlier.
    func fnTimerCount(_ needle: String, from index: Int, upTo end: Int) -> Int {
        tail.poll()
        guard index < end, end <= tail.lines.count else { return 0 }
        return tail.lines[index..<end].filter { $0.text.contains(needle) }.count
    }

    /// What a press was, in the words of a failure message.
    func fnTimerKind(_ press: Phase4bMdPress, redo: Bool) -> String {
        if press.structural { return "the structural \(redo ? "redo" : "undo")" }
        return press.decision == "fallthrough" ? "a text step" : "decided \(press.decision)"
    }

    /// A press that must be the STRUCTURAL one. When it was a text step (the defect: the timer's renumber is a step of its own) up to three
    /// more presses find where the structural one comes, so the failure message says how many extra text steps stood in the way and the run
    /// still reaches its document checks. The message of the defect is "<label> was a text step, expected <expected>".
    /// `whenNothingLeft` (empty for every caller but the drag test's Cmd-Z #2) is one more sentence for the failure when the presses never
    /// reached the structural step and EVERY press, the retries included, was a text step: the caller then stops the test, because what
    /// follows depends on the step that is gone.
    func fnTimerStructuralPress(
        redo: Bool, number: Int, label: String, expected: String, whenNothingLeft: String = "", soft: inout Phase4bFlowSoftChecks
    ) -> Phase4bMdPress {
        var press = pressStepRefocusing(redo: redo, number: number, watchToasts: false, what: label, soft: &soft)
        let firstKind = fnTimerKind(press, redo: redo)
        var trail = [press.decision]
        var extra = 0
        while !press.structural, press.decision == "fallthrough", extra < 3 {
            extra += 1
            press = pressStepRefocusing(
                redo: redo, number: number + 10 * extra, watchToasts: false, what: "\(label), extra press \(extra)", soft: &soft)
            trail.append(press.decision)
        }
        let onlyTextSteps = !press.structural && trail.allSatisfy { $0 == "fallthrough" }
        soft.check(extra == 0 && press.structural,
            "\(label) was \(firstKind), expected \(expected)"
            + (extra > 0 ? " (\(extra) text step(s) stood in the way; the editor's decisions, press by press, were \(trail))" : "")
            + (onlyTextSteps && !whenNothingLeft.isEmpty ? " " + whenNothingLeft : ""))
        return press
    }

    /// The Notes region of the saved rows: no label out of order (the defect left the Notes relabelled in place, unsorted) and no jump back
    /// in the references. A failure names the labels it found.
    func fnTimerAddNotesChecks(_ what: String, rows: [Phase4bFlowRow], count: Int, to soft: inout Phase4bFlowSoftChecks) {
        let walk = Phase4bFlowWalk(rows: rows)
        let labels = walk.definitions.map(\.number)
        soft.check(labels == labels.sorted(),
            "\(what): Notes region not sorted: the Notes labels read [\(Self.ascendingRuns(labels))] "
            + "(the timer's renumber relabels in place and skips the sort)")
        addFootnoteOrderCheck(what, rows: rows, count: count, to: &soft)
    }

    /// After a Delete-test state has settled: the rows are `expect`, the footnotes and the Notes run 1...`refCount`, and with `roundTrip`
    /// File > Save Version proves the page's Notes region equals the rows (and the budget clock restarts).
    func fnTimerCheckDocument(
        _ what: String, expect: Phase4bMdExpectation, refCount: Int, roundTrip: Bool, to soft: inout Phase4bFlowSoftChecks
    ) {
        let rows = addDocumentChecks(what, expect: expect, to: &soft)
        fnTimerAddNotesChecks(what, rows: rows, count: refCount, to: &soft)
        guard roundTrip else { return }
        addScreenEqualsDatabaseCheck(before: rows, what: "\(what), the Notes region of the page against the rows", to: &soft)
        newPhase()
    }

    /// The same for a drag-test state: the rows are the hand-worked `arrangement` (with `typed` replacing whole rows); a drag keeps every
    /// footnote reference, so they run 1...(the document's count).
    func fnTimerCheckDrag(
        _ what: String, arrangement: [Phase4bRqRow], typed: [Int: String], roundTrip: Bool, to soft: inout Phase4bFlowSoftChecks
    ) {
        let rows = addDragChecks(what, arrangement: arrangement, typed: typed, bibliographyExact: true, to: &soft)
        fnTimerAddNotesChecks(what, rows: rows, count: Phase4bFlowWalk(rows: pre).refs.count, to: &soft)
        guard roundTrip else { return }
        addScreenEqualsDatabaseCheck(before: rows, what: "\(what), the Notes region of the page against the rows", to: &soft)
        newPhase()
    }
}

// MARK: - The Delete: the timer comes due after the letter, inside the held settle

extension WriteQueuePhase4bMarkdownEFE2ETests {
    /// CLAIM. On the six-chapter book (nine footnote references per chapter; the unflattened document) the Delete's settle is held 50 s (a
    /// plain suspension, `FF_UI_TESTING_EF_SETTLE_HOLD_MS`; the queued job itself is not held) and the footnote burst waits 30 s, so the
    /// burst's deadline arrives while the Delete is unfinished AND, because the letter below takes a few seconds, after the letter. Chapter
    /// 2 is deleted, then at once (nothing waited for in between) the caret is put back at the end of the Anchor05 line and ONE letter is
    /// typed. Then, once the held settle has ended, Cmd-Z, Cmd-Z, Cmd-Shift-Z, Cmd-Shift-Z, each after the one before has finished:
    ///   Cmd-Z #1        a TEXT step: the letter goes, the chapter stays gone;
    ///   Cmd-Z #2        the STRUCTURAL undo: the chapter comes back (the document is the one as loaded, Notes and Bibliography byte for byte);
    ///   Cmd-Shift-Z #1  the STRUCTURAL redo: the chapter is gone again, the references run 1...45, the Notes 1...45 in order;
    ///   Cmd-Shift-Z #2  a TEXT step: the letter is back (the editor keeps its redo steps aside across the structural undo).
    /// The premises are asserted first as TEST-SETUP: a `[FN-STANDASIDE]` line exists, and the first one sits AFTER the point the log had
    /// reached when the letter was typed (else the timer's renumber came before the letter and the page folded it into the Delete's own
    /// undo step: the run could not show the race). After the Delete and after each structural press the rows are the hand-worked
    /// document, the references run 1...N in reading order, the Notes are sorted and numbered 1...N, and File > Save Version shows the
    /// page's Notes region equals the rows.
    /// MUST FAIL under BP-A (the timer writes while the command is unfinished): the timer's renumber, written at 30 s after the letter, is
    /// one more Cmd-Z step, so Cmd-Z #1 undoes it instead of the letter. The message that names it is "Cmd-Z #1 undid something other than
    /// the typed letter ..." (the Anchor05 line still carries the letter); "Cmd-Z #2 was a text step, expected the structural undo (the
    /// chapter back)" follows. Under BP-AE too. The checks before Cmd-Z #1 (premises, rows, references, Notes) are not expected to fire
    /// first under BP-A: the first design's BP-A run passed every one of them (a Delete has no sort for the timer to skip, and a renumber
    /// in place keeps the Notes in order).
    func testMdDeleteFootnoteTimerInsideJob_book6() {
        let size = Phase4bDelSize.book6
        let title = Self.footnotedTarget(size)
        let env = [
            Self.fnTimerRewriteDelayKey: String(Self.fnTimerDeleteRewriteDelaySeconds),
            Self.fnTimerSettleHoldKey: String(Self.fnTimerDeleteSettleHoldMs), Self.fnTimerSettleHoldFirstKey: "1"
        ]
        guard startScenario(size, method: #function, env: env), let range = requireSection(title), let anchor = requireAnchorRow(),
              placeCaret(), let card = bringSidebarCardIntoView(title) else { return }
        let numbers = footnoteNumbers(in: range)
        let total = Phase4bFlowWalk(rows: pre).refs.count
        let remaining = total - numbers.count
        guard !numbers.isEmpty, remaining > 0 else {
            fail("TEST-SETUP: \"\(title)\" holds \(numbers.count) footnote reference(s) of the document's \(total); the test needs a footnoted "
                + "chapter and others that remain. \(countsLine)")
            return
        }
        let letter = Self.fnTimerLetter
        let typedLine = Self.anchorLine + letter
        var soft = Phase4bFlowSoftChecks()
        note("SCENARIO: \"\(title.prefix(12))...\" holds \(numbers.count) footnote reference(s) \(Self.ascendingRuns(numbers)) "
            + "of \(total); its Delete's settle is held \(Self.fnTimerDeleteSettleHoldMs) ms and the footnote burst waits "
            + "\(Self.fnTimerDeleteRewriteDelaySeconds) s; straight after the click the caret goes back to the Anchor05 line and "
            + "\"\(letter)\" is typed (before the burst comes due); then, once the held settle has ended, Cmd-Z, Cmd-Z, Cmd-Shift-Z, Cmd-Shift-Z")

        // 1. The Delete, then at once a click back into the text and one letter (the right-click took the keyboard focus to the Outline).
        let from = chooseSidebarItem(card, item: "Delete Section")
        _ = clickBackIntoAnchor()
        typeNow(letter)
        // How far the log had got when the letter was typed: the premise below requires the burst's stand-aside line to come after it.
        tail.poll()
        let letterTypedAt = tail.lines.count
        soft.check(waitForCard(title, present: false, timeout: appWait(size.operationTimeout, before: "the card leaves the Outline")),
            "the card \"\(title)\" is still in the Outline after Delete Section")
        guard waitForLine(typedLine, startingWith: Self.anchorPrefix, timeout: 90) else {
            let reads = lineInDatabase(startingWith: Self.anchorPrefix) ?? "nothing"
            fail("TEST-SETUP: the typed letter never reached the Anchor05 line of the block table (it reads \"\(reads)\", expected "
                + "\"\(typedLine)\"): the click back into the text did not put the caret at the end of the line. \(countsLine)")
            return
        }
        // The premises, in this order: a stand-aside line exists (its message names the missing seams), it came after the letter, and then
        // the held settle is waited for (the log is quiet during the hold, so `settle(gone:)` alone would end in the middle of it).
        guard fnTimerRequirePremise(from: from, command: "Delete Section", timeout: 90),
              fnTimerRequireLetterBeforeBurst(from: from, letterTypedAt: letterTypedAt, command: "Delete Section"),
              fnTimerWaitForHeldSettleToEnd(from: from, holdMs: Self.fnTimerDeleteSettleHoldMs, refCount: remaining, soft: &soft)
        else { return }
        soft.check(settle(gone: [title]), "the heading \"\(title)\" is still in the block table once the job should have run")
        fnTimerCheckDocument(
            "after the Delete and the letter (settled)",
            expect: Phase4bMdExpectation(removed: [range], typed: [anchor: typedLine], bibliographyExact: true),
            refCount: remaining, roundTrip: false, to: &soft)
        shot("md-fn-timer-delete-1-after-the-delete")

        // 2. Cmd-Z #1: a text step. The letter goes, the chapter stays gone. With the fix the history is [delete, letter] (the settle's
        // renumber is folded in); with the timer's renumber written after the letter (the original bug) it is [delete, letter, renumber]
        // and this press undoes the renumber, so the letter stays: the line check below is the one that names the defect.
        tail.poll()
        let beforeFirstPress = tail.lines.count
        let first = pressStepRefocusing(redo: false, number: 1, watchToasts: false, what: "Cmd-Z #1", soft: &soft)
        soft.check(first.decision == "fallthrough" && !first.structural,
            "Cmd-Z #1 was \(fnTimerKind(first, redo: false)), expected a text step (the letter goes)")
        let letterGone = waitForLine(Self.anchorLine, startingWith: Self.anchorPrefix, timeout: 60)
        let timerWrites = fnTimerCount("debounce fired", from: from, upTo: beforeFirstPress)
        let timerEvidence = timerWrites > 0
            ? "the app's log has \(timerWrites) `debounce fired` line(s) between the Delete click and this press: the footnote timer ran its "
                + "own write while the Delete was unfinished, and its renumber came after the letter"
            : "the app's log has no `debounce fired` line between the Delete click and this press, so the footnote timer did not write; "
                + "something else took the press"
        soft.check(letterGone,
            "Cmd-Z #1 undid something other than the typed letter: afterwards the Anchor05 line reads "
            + "\"\(lineInDatabase(startingWith: Self.anchorPrefix) ?? "nothing")\", expected \"\(Self.anchorLine)\" (only the letter removed). "
            + "A footnote renumber of its own, recorded after the letter, is the original bug (\(timerEvidence))")
        soft.check(!sidebarCard(title).exists, "Cmd-Z #1 brought \"\(title)\" back: the first press must remove only the letter")

        // 3. Cmd-Z #2: the structural undo. The chapter comes back, the document is the one as loaded.
        _ = fnTimerStructuralPress(
            redo: false, number: 2, label: "Cmd-Z #2", expected: "the structural undo (the chapter back)", soft: &soft)
        soft.check(waitForCard(title, present: true, timeout: appWait(size.operationTimeout, before: "the card comes back")),
            "the card \"\(title)\" did not come back after Cmd-Z #2")
        settle(back: [title])
        fnTimerCheckDocument(
            "after Cmd-Z #2 (settled)", expect: Phase4bMdExpectation(managedExact: true), refCount: total, roundTrip: true, to: &soft)
        shot("md-fn-timer-delete-2-after-cmd-z")
        _ = clickBackIntoAnchor()

        // 4. Cmd-Shift-Z #1: the structural redo. The chapter is gone again, the footnotes and the Notes run 1...N.
        _ = fnTimerStructuralPress(
            redo: true, number: 3, label: "Cmd-Shift-Z #1", expected: "the structural redo (the chapter gone)", soft: &soft)
        soft.check(waitForCard(title, present: false, timeout: appWait(size.operationTimeout, before: "the card leaves again")),
            "the card \"\(title)\" is still in the Outline after Cmd-Shift-Z #1")
        settle(gone: [title])
        fnTimerCheckDocument(
            "after Cmd-Shift-Z #1 (settled)", expect: Phase4bMdExpectation(removed: [range], bibliographyExact: true),
            refCount: remaining, roundTrip: true, to: &soft)
        shot("md-fn-timer-delete-3-after-cmd-shift-z")
        _ = clickBackIntoAnchor()

        // 5. Cmd-Shift-Z #2: a text step. The letter is back.
        let fourth = pressStepRefocusing(redo: true, number: 4, watchToasts: false, what: "Cmd-Shift-Z #2", soft: &soft)
        soft.check(fourth.decision == "fallthrough" && !fourth.structural,
            "Cmd-Shift-Z #2 was \(fnTimerKind(fourth, redo: true)), expected a text step (the letter is back)")
        soft.check(waitForLine(typedLine, startingWith: Self.anchorPrefix, timeout: 60),
            "after Cmd-Shift-Z #2 the Anchor05 line reads \"\(lineInDatabase(startingWith: Self.anchorPrefix) ?? "nothing")\", "
            + "expected \"\(typedLine)\" (the letter back)")
        settle()
        fnTimerCheckDocument(
            "after Cmd-Shift-Z #2 (settled)",
            expect: Phase4bMdExpectation(removed: [range], typed: [anchor: typedLine], bibliographyExact: true),
            refCount: remaining, roundTrip: false, to: &soft)
        // The Delete, its quick undo and its quick redo each raise one hold.
        addMarkdownMechanismChecks(from: from, commands: 3, to: &soft)
        addLogChecks(from: from, checkPushes: false, to: &soft)
        shot("md-fn-timer-delete-4-end")
        assertAll(soft, "Markdown: Delete a footnoted chapter with the footnote timer due after the letter and inside the held settle, "
            + "one letter, Cmd-Z x2, Cmd-Shift-Z x2, on \(size.identifier); \(countsLine)")
    }
}

// MARK: - The drag: the timer comes due inside the held settle

extension WriteQueuePhase4bMarkdownEFE2ETests {
    /// CLAIM. On the twelve-chapter book (nine footnote references per chapter; chapters 1, 3, 5, 6, 7 and 8 flattened so two neighbouring
    /// cards fit on screen) Chapter 7 (references 55...63) is dragged above Chapter 6 (46...54); without a renumber the references would
    /// read 1...45, 55...63, 46...54, 64...108. The drag's SETTLE waits 4 s (a plain suspension, `FF_UI_TESTING_EF_SETTLE_HOLD_MS`) before
    /// its footnote resync and the footnote burst waits 2.5 s, so the burst's deadline arrives while the drag is unfinished AND, on a normal
    /// run, inside the hold (the premise below requires it). At once after the drop ONE letter is typed with no click (the caret was put
    /// at the end of a seeded "Move07 line" in the moved chapter and travels with the text). Then Cmd-Z, Cmd-Z, Cmd-Shift-Z,
    /// Cmd-Shift-Z, each after the one before has finished:
    ///   Cmd-Z #1        a TEXT step: the letter goes, the dragged order stays;
    ///   Cmd-Z #2        the STRUCTURAL undo, the drag's queued slow route (`start (markdown queued undo`): the original order;
    ///   Cmd-Shift-Z #1  the STRUCTURAL redo: the dragged order again;
    ///   Cmd-Shift-Z #2  a TEXT step: the letter is back, inside the moved chapter.
    /// The premise is asserted first as TEST-SETUP: a `[FN-STANDASIDE]` line exists AND the first one comes AFTER the `[EF-SETTLE-HOLD]`
    /// line (the hold began first, so the timer came due after the old forget of the committed Notes hash). After the drag and after each
    /// structural press the rows are the hand-worked document, the references run 1...108 in reading order with no jump back, the Notes
    /// are sorted, and File > Save Version shows the page's Notes region equals the rows.
    /// UNDER BP-A ALONE THIS TEST PASSES: once the forget of the committed Notes hash moved into the footnote resync, a drag's own timer run
    /// hits the hash guard and does nothing. It FAILS under BP-AE (BP-A plus the old forget site back = the original bug): one more Cmd-Z
    /// ("Cmd-Z #2 was a text step, expected the structural undo") and the Notes unsorted ("Notes region not sorted").
    /// FAIL FAST: measured under BP-AE, Cmd-Z #1 and #2 were text steps (the letter and the timer's renumber) and the three retries found
    /// nothing left to undo, so the drag could no longer be undone. When the presses never reach the structural undo, the test records
    /// the Cmd-Z #2 failure (with a sentence saying so), the log checks and the screenshot, and RETURNS: the heading-order wait after
    /// Cmd-Z #2 is 2 x 300 s on this book, longer than the VM's 600 s watchdog, which ended the first version of this run after 24 minutes
    /// with no assertion. The passing path (the structural undo reached, with or without retries) runs exactly as before.
    func testMdDragFootnoteTimerInsideSettle_book12() {
        let size = Phase4bDelSize.book12
        let pair = Self.dragPair(size)
        let moveLine = Self.seededLine("Move07")
        let env = [Self.fnTimerRewriteDelayKey: "2.5", Self.fnTimerSettleHoldKey: "4000", Self.fnTimerSettleHoldFirstKey: "1"]
        let seed = Self.lineSeed([(title: pair.moved, line: moveLine)])
        guard startScenario(size, method: #function, env: env, flat: pair.flat, seed: seed), requireSection(pair.moved) != nil,
              requireSection(pair.target) != nil, requireChildless(pair.moved), let moveRow = requireSeededRow(moveLine),
              let drag = prepareDrag(pair.moved, before: pair.target, level: pair.level, option: false),
              placeCaretInSection(pair.moved, line: moveLine, prefix: "Move07") else { return }
        let original = dragUserRows()
        let originalHeadings = preHeadingFragments
        let arrangement = dragMoving(original, pair.moved, before: pair.target)
        let movedHeadings = dragHeadings(arrangement)
        let total = Phase4bFlowWalk(rows: pre).refs.count
        let movedRefs = section(pair.moved).map { footnoteNumbers(in: $0) } ?? []
        let scrambled = arrangement.flatMap { Phase4bFlow.footnoteRefs(in: $0.row.fragment) }
        guard !movedRefs.isEmpty, total > 0, scrambled != Array(stride(from: 1, through: total, by: 1)) else {
            fail("TEST-SETUP: this drag would not scramble the footnote numbers (the moved section holds \(movedRefs.count) reference(s), "
                + "the document \(total)); the test would prove nothing. \(countsLine)")
            return
        }
        let letter = Self.fnTimerLetter
        let typedLine = moveLine + letter
        var soft = Phase4bFlowSoftChecks()
        note("SCENARIO: \"\(pair.moved.prefix(12))...\" (references \(Self.ascendingRuns(movedRefs)) of \(total)) is dragged to just before "
            + "\"\(pair.target.prefix(12))...\" with its settle held 4000 ms and the footnote burst at 2.5 s; \"\(letter)\" is typed with no click "
            + "straight after the drop; without a renumber the references would read [\(Self.ascendingRuns(scrambled))]; then Cmd-Z, Cmd-Z, "
            + "Cmd-Shift-Z, Cmd-Shift-Z")

        // 1. The drag, then at once one letter (no click: the caret travels with the moved text).
        let dragFrom = performDrag(drag)
        typeNow(letter)
        soft.check(waitForHeadingOrder(movedHeadings, timeout: appWait(size.operationTimeout * 2, before: "the dragged order")),
            "after the job the block table's heading order is not the dragged one (\(orderDifference(movedHeadings)))")
        guard waitForLine(typedLine, startingWith: "Move07", timeout: 90) else {
            fail("TEST-SETUP: the letter typed straight after the drop never reached the Move07 line of the block table (it reads "
                + "\"\(lineInDatabase(startingWith: "Move07") ?? "nothing")\", expected \"\(typedLine)\"). \(countsLine)")
            return
        }
        settle()
        guard fnTimerRequirePremise(from: dragFrom, command: "drag"),
              fnTimerRequireStandAsideInsideHold(from: dragFrom, command: "drag") else { return }
        fnTimerCheckDrag(
            "after the drag and the letter (settled)", arrangement: arrangement, typed: [moveRow: typedLine], roundTrip: false, to: &soft)
        addDragTraceChecks(from: dragFrom, drags: 1, to: &soft)
        newPhase()

        // 2. Cmd-Z #1: a text step. The letter goes, the dragged order stays.
        let first = pressStepRefocusing(redo: false, number: 1, watchToasts: false, what: "Cmd-Z #1", soft: &soft)
        soft.check(first.decision == "fallthrough" && !first.structural,
            "Cmd-Z #1 was \(fnTimerKind(first, redo: false)), expected a text step (the letter goes)")
        soft.check(waitForLine(moveLine, startingWith: "Move07", timeout: 60),
            "after Cmd-Z #1 the Move07 line reads \"\(lineInDatabase(startingWith: "Move07") ?? "nothing")\", expected \"\(moveLine)\" "
            + "(only the letter removed)")
        soft.check(headingFragmentsInDatabase() == movedHeadings,
            "Cmd-Z #1 changed the heading order (\(orderDifference(movedHeadings))): the first press must remove only the letter")

        // 3. Cmd-Z #2: the drag's queued slow undo. The original order and the original numbers.
        let secondFrom = traceLinesCount()
        let second = fnTimerStructuralPress(
            redo: false, number: 2, label: "Cmd-Z #2", expected: "the structural undo (the drag's queued slow undo)",
            whenNothingLeft: Self.fnTimerDragUndoGoneNote, soft: &soft)
        // FAIL FAST. When not even the retries reached the structural undo (measured under BP-AE: every press was a text step, the letter
        // and the timer's renumber went and then Cmd-Z found nothing to undo) the drag can no longer be undone, and every step below waits
        // for the undo that never happened: the heading order of the original document (2 x 300 s on the twelve-chapter book, longer than
        // the VM's 600 s no-progress watchdog, which first ended such a run with no assertion at all), the Save Version round trip and the
        // Cmd-Shift-Z presses. So the failure is recorded as a normal test failure and the test returns; the log checks need no wait.
        guard second.structural else {
            shot("md-fn-timer-drag-1-no-structural-undo")
            addLogChecks(from: dragFrom, checkPushes: false, to: &soft)
            assertAll(soft, "Markdown: drag a footnoted chapter with the footnote timer due inside the held settle, one letter, STOPPED after "
                + "Cmd-Z #2 (not the structural undo) on \(size.identifier); \(countsLine)")
            return
        }
        let secondStart = traceLines(from: secondFrom).first { $0.family == .sequence && $0.label == "undo" && $0.isOpStart }
        soft.check(secondStart?.step.hasPrefix("start (markdown queued undo") == true,
            "Cmd-Z #2 began `\(secondStart?.step ?? "none")`, expected the drag's queued slow undo `start (markdown queued undo)`")
        soft.check(waitForHeadingOrder(originalHeadings, timeout: appWait(size.operationTimeout * 2, before: "the original order")),
            "after Cmd-Z #2 the block table's heading order is not the original one (\(orderDifference(originalHeadings)))")
        settle()
        fnTimerCheckDrag("after Cmd-Z #2 (settled)", arrangement: original, typed: [:], roundTrip: true, to: &soft)
        shot("md-fn-timer-drag-1-after-cmd-z")
        _ = clickBackIntoAnchor()

        // 4. Cmd-Shift-Z #1: the structural redo. The dragged order and the renumbered notes again.
        _ = fnTimerStructuralPress(
            redo: true, number: 3, label: "Cmd-Shift-Z #1", expected: "the structural redo (the dragged order again)", soft: &soft)
        soft.check(waitForHeadingOrder(movedHeadings, timeout: appWait(size.operationTimeout * 2, before: "the dragged order comes back")),
            "after Cmd-Shift-Z #1 the block table's heading order is not the dragged one (\(orderDifference(movedHeadings)))")
        settle()
        fnTimerCheckDrag("after Cmd-Shift-Z #1 (settled)", arrangement: arrangement, typed: [:], roundTrip: true, to: &soft)
        shot("md-fn-timer-drag-2-after-cmd-shift-z")
        _ = clickBackIntoAnchor()

        // 5. Cmd-Shift-Z #2: a text step. The letter is back, at the end of the Move07 line inside the moved chapter.
        let fourth = pressStepRefocusing(redo: true, number: 4, watchToasts: false, what: "Cmd-Shift-Z #2", soft: &soft)
        soft.check(fourth.decision == "fallthrough" && !fourth.structural,
            "Cmd-Shift-Z #2 was \(fnTimerKind(fourth, redo: true)), expected a text step (the letter is back)")
        soft.check(waitForLine(typedLine, startingWith: "Move07", timeout: 90),
            "after Cmd-Shift-Z #2 the Move07 line reads \"\(lineInDatabase(startingWith: "Move07") ?? "nothing")\", expected \"\(typedLine)\" "
            + "(the letter back)")
        settle()
        fnTimerCheckDrag(
            "after Cmd-Shift-Z #2 (settled)", arrangement: arrangement, typed: [moveRow: typedLine], roundTrip: false, to: &soft)
        // The drag, its queued undo and its queued redo each raise one hold.
        addMarkdownMechanismChecks(from: dragFrom, commands: 3, to: &soft)
        addLogChecks(from: dragFrom, checkPushes: false, to: &soft)
        shot("md-fn-timer-drag-3-end")
        assertAll(soft, "Markdown: drag a footnoted chapter with the footnote timer due inside the held settle, one letter, Cmd-Z x2, "
            + "Cmd-Shift-Z x2, on \(size.identifier) (flattened copy, chapters \(pair.flat) flat; \(total) footnote references in all); "
            + countsLine)
    }
}
