//
//  WriteQueuePhase4cMdSpeedE2ETests.swift
//  final finalUITests
//
//  PERFORMANCE JOB, ROUND C3 (t-2fbe4c9b): the PERMANENT real-app proof of the writer's parse memo (ViewState/MarkdownParseCache.swift) and
//  of the "Finishing the last change..." notice that now stays up for the whole Delete and drag click. Plan: plan-v2.md section 5(c);
//  ceilings and must-fail table: plan-v3-amendments.md A3 and A5. The report block, the log reading and the click drivers are the ones of
//  WriteQueuePhase4cMdSpeedMeasureE2ETests.swift (`launchBook`, `mdDeleteOnce`, `mdDuplicateOnce`, `mdDragOnce`, `report`, ...), so every run
//  folder carries the same `RESULT MEASURE <command> #<n>:` table next to the verdict.
//
//  THE TESTS (one at a time; the twelve-chapter book is 699,139 characters; scope `final finalUITests/WriteQueuePhase4cMdSpeedE2ETests/<method>`)
//    testMdDeleteFast_book12                two Deletes (Chapter 6, then Chapter 4), the app's own trigger, no typing
//    testMdDuplicateFast_book12             two Duplicates ("3.6 Conclusion", "8.6 Conclusion"), by the menu click, no typing
//    testMdDragFast_book12                  two Option-drags (Chapter 9, then Chapter 11, with their sub-sections), no typing
//    testMdSwitchToMarkdownThenDelete_book12  Rich Text launch, Cmd-/, then a Delete at once: the load prewarm must survive the mode switch
//    testMdTypingPausesDebounceHits_book12  five typed words, each followed by the re-parse debounce fire: five memo hits in a row
//    testMdDeleteNoticeWholeClick_book6     the notice shows 1 s into a held click and goes only when the click returns
//    testMdDragNoticeWholeClick_book6       the same for the Outline drag
//    testMdDupNoticeWholeClick_book6        CONTROL: the same for Duplicate, which already worked that way
//    testSpeedHelpers_handWorkedExample     the pure field readers, figures and ceilings of this file on canned lines (no app launch)
//    testSpeedJudges_handWorkedExample      the pure judges on canned lines: cache check, notice, validity gate, failure-before-skip order
//
//  THE THREE `...Fast` TESTS judge in this order. (1) DETERMINISTIC, never gated and NEVER skipped: every `[MdWrite] mode=` line of every
//  click window says `cache=hit parse=0.0ms guard=0.0ms`, and the calls that must be there were there (click, step 8, bibliography flush, and
//  for Delete and drag the re-parse debounce fire). When any of that fails the test FAILS and returns; the gate is not even evaluated.
//  (2) VALIDITY GATE, only when nothing has failed: three steps the change does not touch (`fetchBlocks`, `pageCall`, `replyDecode`; `adopt` is
//  printed but not gated, since the change runs background work during it) are measured in both clicks (six measurements) and divided by their
//  reference (the constants block below). The run is INVALID when the MEDIAN of the six ratios is above 1.5 OR any single ratio is above 3.0:
//  the test prints `RESULT SPEED <command>: VALIDITY INVALID (...)` and ends with `XCTSkip` whose message begins
//  `INVALID RUN - host too loaded, rerun`. Otherwise `VALIDITY OK median ratio <r>`. (3) The committed CEILINGS, asserted only on a valid run
//  and never scaled or loosened; a miss there is a real failure. Per click the test also prints `RESULT SPEED <command> #<n>: GATED ...`
//  with the measured steps, their ratios and the median of the three, whatever the verdict.
//
//  EVERY NUMBER A TEST COMPARES WITH IS IN THE CONSTANTS BLOCK BELOW (`MdSpeedLimits`), none in a test body.
//
//  NOT IN THE SMOKE SET. Run one test per vmtest run, the sandbox off, for example:
//    scripts/vmtest/vmtest run --detach --timeout 4800 \
//      --scope "final finalUITests/WriteQueuePhase4cMdSpeedE2ETests/testMdDeleteFast_book12"
//

import XCTest

// MARK: - The constants block

/// EVERY threshold and reference of this file. Ceilings are milliseconds, `[click #1, click #2]`. A change of a number touches this block only.
enum MdSpeedLimits {
    // MARK: Committed ceilings (plan-v3-amendments.md A3 and the C3 brief)

    /// Delete: first `[SidebarBody]` render after the hold was raised (`clickToOutlineMs`). A3 "Delete / Outline reacts".
    static let deleteOutlineMs = [230, 370]
    /// Delete: click to `[MdWrite] structural hold released`. A3 "Delete / Hold released".
    static let deleteReleasedMs = [1_400, 1_450]
    /// Delete: sum of the click window's `main-stall` lines. A3 "Delete / Total time stalled".
    static let deleteStalledMs = [2_350, 2_150]
    /// Delete: the longest single `main-stall`. A3 "Delete / Longest stall".
    static let deleteLongestMs = [670, 720]

    /// Duplicate, from click-start: end of the `duplicate sidebar` span (the copy's card appears). C3 brief (A3's table: 240 for click #1).
    /// Click #2 moved from 270 to 290 by the plan judge (2026-11-01), after the valid run run-1793530950-8659 measured 285 / 282 ms: the two
    /// clicks are structurally the same (a page round trip of about 185 ms from click-start, then align+diff about 36 ms, adopt 20 to 45 ms,
    /// the sidebar), and the 270 came from subtracting that click's own parse and guard while ignoring the shared work. 290 is about 40
    /// percent under today's ~490 ms and inside floor line F1. The last ceiling correction the judge accepts.
    static let duplicateCardMs = [290, 290]
    /// Duplicate, from the app's click-start: hold released. A3 "Duplicate / Hold released".
    static let duplicateReleasedMs = [1_320, 1_360]
    /// Duplicate: sum of the `main-stall` lines. A3 "Duplicate / Total time stalled".
    static let duplicateStalledMs = [880, 880]
    /// Duplicate: the longest single `main-stall`. A3 "Duplicate / Longest stall".
    static let duplicateLongestMs = [500, 480]

    /// Drag: first `[SidebarBody]` render after the hold was raised. A3 "Drag / Outline reacts". PROVISIONAL: the judge may re-set it (C3 brief).
    static let dragOutlineMs = [185, 280]
    /// Drag: hold released. A3 "Drag / Hold released". PROVISIONAL (C3 brief).
    static let dragReleasedMs = [990, 815]
    /// Drag: sum of the `main-stall` lines. A3 "Drag / Total time stalled". PROVISIONAL (C3 brief).
    static let dragStalledMs = [1_640, 1_120]
    /// Drag: the longest single `main-stall`; A3 says "no worse than today" (429 / 402). PROVISIONAL (C3 brief).
    static let dragLongestMs = [429, 402]

    // MARK: The validity gate (judge ruling of round C6)

    /// INVALID when the MEDIAN of the gated ratios (measured / reference, three steps x two clicks = six) is above this. Judge ruling (C6).
    static let validityMedianLimit = 1.5
    /// The run is INVALID when ANY ONE gated ratio is above this. Judge ruling (C6).
    static let validitySingleLimit = 3.0
    /// A floor for the REFERENCE in a ratio (`measured / max(reference, floor)`), so a tiny reference cannot make a ratio unstable: the drag's
    /// `replyDecode` reference is 5 ms, so 16 ms alone (3.2 x) would call the run invalid. NOT in the ruling: the value here is 0 (no floor, the
    /// ruling exactly) and the judge decides; the C6 coder PROPOSES 10.0 (ms). Quiet runs show no ratio above 2 with no floor (40 / 20.0).
    static let validityReferenceFloorMs = 0.0

    // MARK: The validity references (median of the quiet runs)

    /// Three steps the change does not touch are gated: `fetchBlocks`, `pageCall`, `replyDecode`. (`adopt` is NOT gated since the change: the
    /// memo's background work runs during it; it is printed only.) Each number is the median over the quiet clicks of the runs listed in its
    /// trailing comment, taken from their `RESULT MEASURE` blocks: the old-code runs 89378 / 19838 (Delete), 91723 / 22279 (Duplicate) and
    /// 95087 / 53623 (Drag), and the final-code runs 3821, 6349, 54153, 59088 (Delete), 8659, 11199, 52366 (Duplicate) and 50434 (Drag)
    /// (run id suffixes). "Quiet" means the click's gated median ratio was at most 1.25 against the earlier references. The values behind each
    /// number are in its comment, old runs first, then the final-code runs: a pair is click #1 and click #2 of the run named after it, and a
    /// single value carries its click (`11199 #2`).
    static let deleteFetchBlocksMs = 20.0     // median: 20, 40 (89378), 21, 19 (19838), 23, 20 (3821), 22, 20 (6349), 11, 10 (54153), 19, 20 (59088)
    static let deletePageCallMs = 26.0        // median: 28, 46 (89378), 35, 30 (19838), 32, 23 (3821), 25, 17 (6349), 20, 12 (54153), 27, 14 (59088)
    static let deleteReplyDecodeMs = 8.5      // median: 9, 15 (89378), 9, 7 (19838), 10, 8 (3821), 9, 7 (6349), 6, 5 (54153), 10, 7 (59088)
    static let duplicateFetchBlocksMs = 23.0  // median: 21, 25 (91723), 21, 26 (22279), 28, 25 (8659), 23 (11199 #2), 12, 11 (52366)
    static let duplicatePageCallMs = 31.0     // median: 31, 35 (91723), 28, 25 (22279), 42, 31 (8659), 34 (11199 #2), 12, 13 (52366)
    static let duplicateReplyDecodeMs = 10.0  // median: 9, 10 (91723), 9, 11 (22279), 11, 11 (8659), 10 (11199 #2), 5, 5 (52366)
    static let dragFetchBlocksMs = 13.0       // median: 12, 13 (95087), 11, 14 (53623), 13, 13 (50434)
    static let dragPageCallMs = 19.0          // median: 19, 19 (95087), 26, 18 (53623), 16, 19 (50434)
    static let dragReplyDecodeMs = 5.0        // median: 6, 5 (95087), 5, 5 (53623), 5, 5 (50434)

    // MARK: The notice tests (plan-v2.md 5(c); DelayedProgressToast.defaultDelay is one second)

    /// The notice must show at least this long after the click's start. One second minus 100 ms for the 1 ms log stamps and the Task hop.
    static let noticeMinDelayMs = 900
    /// The dismissal may come this long BEFORE the `md-speed <command> click` span's end line (the `defer`s run in reverse, so the notice is
    /// taken down microseconds before that span ends); 150 ms covers the log stamps.
    static let noticeDismissEarlyToleranceMs = 150
    /// The dismissal may come this long AFTER the click span's end line (it is the click's own last `defer`); a dismissal later than this was not
    /// the click's.
    static let noticeDismissLateToleranceMs = 500
    /// The page-preparation hold of the notice tests (`FF_UI_TESTING_MD_PAGE_PREPARE_HOLD_MS`), long enough to pass the one-second delay.
    static let noticeHoldMs = 1_500

    /// The gated steps and their references for `command`, in the order they are printed and checked.
    static func references(for command: MdSpeedCommand) -> [(step: String, ms: Double)] {
        switch command {
        case .delete:
            return [("fetchBlocks", deleteFetchBlocksMs), ("pageCall", deletePageCallMs), ("replyDecode", deleteReplyDecodeMs)]
        case .duplicate:
            return [("fetchBlocks", duplicateFetchBlocksMs), ("pageCall", duplicatePageCallMs), ("replyDecode", duplicateReplyDecodeMs)]
        case .drag:
            return [("fetchBlocks", dragFetchBlocksMs), ("pageCall", dragPageCallMs), ("replyDecode", dragReplyDecodeMs)]
        }
    }

    /// The four ceilings of `command`.
    static func ceilings(for command: MdSpeedCommand) -> MdSpeedCeilings {
        switch command {
        case .delete:
            return MdSpeedCeilings(
                outline: deleteOutlineMs, released: deleteReleasedMs, stalled: deleteStalledMs, longest: deleteLongestMs,
                outlineName: "Outline reacts")
        case .duplicate:
            return MdSpeedCeilings(
                outline: duplicateCardMs, released: duplicateReleasedMs, stalled: duplicateStalledMs, longest: duplicateLongestMs,
                outlineName: "copy's card appears")
        case .drag:
            return MdSpeedCeilings(
                outline: dragOutlineMs, released: dragReleasedMs, stalled: dragStalledMs, longest: dragLongestMs, outlineName: "Outline reacts")
        }
    }
}

// MARK: - The pure judging

/// The four ceilings of one command, `[click #1, click #2]`.
struct MdSpeedCeilings {
    let outline: [Int]
    let released: [Int]
    let stalled: [Int]
    let longest: [Int]
    let outlineName: String
}

/// The figures of one click, counted from the app's click-start.
struct MdSpeedFigures: Equatable {
    let outlineMs: Int?
    let releasedMs: Int?
    let stalledMs: Int
    let longestMs: Int
}

/// The three numbers of the validity rule: the floor under a reference, the limit for the median ratio and the limit for a single ratio.
struct MdSpeedGateRule {
    var floorMs: Double
    var medianLimit: Double
    var singleLimit: Double

    /// The ruling of round C6, from the constants block.
    static let committed = MdSpeedGateRule(
        floorMs: MdSpeedLimits.validityReferenceFloorMs, medianLimit: MdSpeedLimits.validityMedianLimit,
        singleLimit: MdSpeedLimits.validitySingleLimit)
}

/// One gated measurement: a gated step of one click against its reference. `ratio` is `measuredMs / max(referenceMs, floor)`.
struct MdSpeedRatio: Equatable {
    let click: Int
    let step: String
    let measuredMs: Int
    let referenceMs: Double
    let ratio: Double
}

/// The validity gate's reading of a run: the ratios of its gated measurements (three steps x two clicks), their median, and the verdict.
struct MdSpeedGate: Equatable {
    let ratios: [MdSpeedRatio]
    let median: Double
    let worst: MdSpeedRatio?
    let isInvalid: Bool

    /// The skip message's tail: the median ratio and the worst step.
    var explanation: String {
        let worstText = worst.map {
            "worst step \($0.step) click #\($0.click) \($0.measuredMs) ms vs \(String(format: "%.1f", $0.referenceMs)) ms "
                + "(\(String(format: "%.2f", $0.ratio))x)"
        } ?? "no gated step was measured"
        return "median ratio \(String(format: "%.2f", median)) (limit \(MdSpeedLimits.validityMedianLimit)), \(worstText) "
            + "(single limit \(MdSpeedLimits.validitySingleLimit))"
    }
}

/// What a `...Fast` test does after its checks: fail (the deterministic checks come first and are never skipped), skip (an invalid run) or go on.
enum MdSpeedVerdict: Equatable {
    case failed([String])
    case invalid(String)
    case valid(median: Double)
}

enum MdSpeedJudge {
    /// Pure: the figures of `analysis`, counted from the app's click-start (the event's age taken off). Delete and drag: the first Outline
    /// render after the hold was raised; Duplicate: the end of the `duplicate sidebar` span, the moment the copy's card is on screen.
    static func figures(command: MdSpeedCommand, analysis: MdSpeedClickAnalysis) -> MdSpeedFigures {
        let outline: Int?
        switch command {
        case .delete, .drag: outline = analysis.fromAppClick(analysis.outlineFromEventMs)
        case .duplicate: outline = analysis.fromAppClick(analysis.span("duplicate", "sidebar")?.endMs)
        }
        return MdSpeedFigures(
            outlineMs: outline, releasedMs: analysis.fromAppClick(analysis.releasedFromEventMs),
            stalledMs: analysis.stalledTotalMs, longestMs: analysis.stalledLongestMs)
    }

    /// Pure: the ceilings a click broke, one sentence each. `index` is 0 for click #1, 1 for click #2.
    static func ceilingFailures(command: MdSpeedCommand, figures: MdSpeedFigures, ceilings: MdSpeedCeilings, index: Int) -> [String] {
        let label = "\(command.word) click #\(index + 1)"
        func check(_ name: String, _ value: Int?, _ ceiling: Int) -> String? {
            guard let value else { return "\(label): \(name) was not measured (no such line in the log)" }
            return value > ceiling ? "\(label): \(name) \(value) ms is over the ceiling of \(ceiling) ms" : nil
        }
        return [
            check(ceilings.outlineName, figures.outlineMs, ceilings.outline[index]),
            check("hold released", figures.releasedMs, ceilings.released[index]),
            check("total time stalled", figures.stalledMs, ceilings.stalled[index]),
            check("longest stall", figures.longestMs, ceilings.longest[index])
        ].compactMap { $0 }
    }

    /// Pure: the one-line summary of a click, every figure next to its ceiling.
    static func summaryLine(figures: MdSpeedFigures, ceilings: MdSpeedCeilings, index: Int, prepare: [MdSpeedPrepareLine]) -> String {
        func show(_ value: Int?) -> String { value.map(String.init) ?? "n/a" }
        let clean = prepare.filter(\.isCleanHit).count
        return "\(ceilings.outlineName) \(show(figures.outlineMs)) ms (ceiling \(ceilings.outline[index])); "
            + "hold released \(show(figures.releasedMs)) ms (ceiling \(ceilings.released[index])); "
            + "total stalled \(figures.stalledMs) ms (ceiling \(ceilings.stalled[index])); "
            + "longest stall \(figures.longestMs) ms (ceiling \(ceilings.longest[index])); "
            + "[MdWrite] lines \(prepare.count), clean cache hits \(clean)"
    }

    /// Pure: the median of `values` (the mean of the two middle ones for an even count), 0 for none.
    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Pure: the ratio of one measurement to its reference, the reference never taken as less than `floorMs`.
    static func ratio(measuredMs: Int, referenceMs: Double, floorMs: Double) -> Double {
        Double(measuredMs) / max(referenceMs, floorMs, 0.001)
    }

    /// Pure: the validity gate. One ratio per gated step per click (a step with no finished span is left out and reported by `missingSteps`).
    /// The run is INVALID when the median of the ratios is above `medianLimit` OR any single ratio is above `singleLimit`.
    static func gate(
        command: MdSpeedCommand, analyses: [MdSpeedClickAnalysis], references: [(step: String, ms: Double)], rule: MdSpeedGateRule
    ) -> MdSpeedGate {
        let floorMs = rule.floorMs
        let medianLimit = rule.medianLimit
        let singleLimit = rule.singleLimit
        var ratios: [MdSpeedRatio] = []
        for (index, analysis) in analyses.enumerated() {
            for (step, reference) in references {
                guard let took = analysis.span(command.word, step)?.tookMs else { continue }
                ratios.append(MdSpeedRatio(
                    click: index + 1, step: step, measuredMs: took, referenceMs: reference,
                    ratio: ratio(measuredMs: took, referenceMs: reference, floorMs: floorMs)))
            }
        }
        let middle = median(ratios.map(\.ratio))
        return MdSpeedGate(
            ratios: ratios, median: middle, worst: ratios.max { $0.ratio < $1.ratio },
            isInvalid: middle > medianLimit || ratios.contains { $0.ratio > singleLimit })
    }

    /// Pure: what a `...Fast` test does after it has measured. The deterministic failures decide FIRST: when there is one, the verdict is
    /// `failed` and `gate` is never called (an invalid-looking run must not hide a real failure behind a skip). Only without a failure is the
    /// gate evaluated: `invalid` for a loaded host, `valid` otherwise.
    static func verdict(deterministicFailures: [String], gate: () -> MdSpeedGate) -> MdSpeedVerdict {
        guard deterministicFailures.isEmpty else { return .failed(deterministicFailures) }
        let reading = gate()
        return reading.isInvalid ? .invalid("INVALID RUN - host too loaded, rerun: \(reading.explanation)") : .valid(median: reading.median)
    }

    /// Pure: the per-click evidence line (`GATED fetchBlocks=<ms> pageCall=<ms> replyDecode=<ms> adopt=<ms> ratios=<a,b,c> median=<r>`):
    /// what was measured and the three ratios of this click, so the driver can take medians from run logs. `adopt` is printed, not gated.
    static func gatedEvidenceLine(
        command: MdSpeedCommand, analysis: MdSpeedClickAnalysis, references: [(step: String, ms: Double)], floorMs: Double
    ) -> String {
        func show(_ value: Int?) -> String { value.map(String.init) ?? "n/a" }
        let measured = references.map { "\($0.step)=\(show(analysis.span(command.word, $0.step)?.tookMs))" }
        let ratios = references.compactMap { entry in
            analysis.span(command.word, entry.step)?.tookMs.map { ratio(measuredMs: $0, referenceMs: entry.ms, floorMs: floorMs) }
        }
        let text = ratios.isEmpty ? "n/a" : ratios.map { String(format: "%.2f", $0) }.joined(separator: ",")
        return "GATED " + measured.joined(separator: " ") + " adopt=\(show(analysis.span(command.word, "adopt")?.tookMs)) "
            + "ratios=\(text) median=\(ratios.isEmpty ? "n/a" : String(format: "%.2f", median(ratios)))"
    }

    /// Pure: the gated steps that have no finished span in some click of `analyses` (the gate could not look at them).
    static func missingSteps(command: MdSpeedCommand, analyses: [MdSpeedClickAnalysis], references: [(step: String, ms: Double)]) -> [String] {
        var missing: [String] = []
        for (index, analysis) in analyses.enumerated() {
            for (step, _) in references where analysis.span(command.word, step)?.tookMs == nil {
                missing.append("click #\(index + 1) lacks a finished `md-speed \(command.word) \(step)` span")
            }
        }
        return missing
    }

    /// Pure: what is wrong with the `[MdWrite] mode=` lines of one click window. Every line must be `cache=hit parse=0.0ms guard=0.0ms`, and
    /// a line from each of `expectedTriggers` must be there. One sentence each, naming the call that wrote the line.
    static func cacheFailures(number: Int, analysis: MdSpeedClickAnalysis, expectedTriggers: [String]) -> [String] {
        guard analysis.found else { return ["click #\(number): the app wrote no timeline, so no `[MdWrite]` line could be matched to a call"] }
        var failures = analysis.prepare.filter { !$0.isCleanHit }.map {
            "click #\(number), the \($0.trigger) call (via \($0.via)): not a clean hit: \($0.text)"
        }
        let seen = Set(analysis.prepare.map(\.trigger))
        for trigger in expectedTriggers where !seen.contains(trigger) {
            failures.append("click #\(number): no `[MdWrite] mode=` line from the \(trigger) call (calls seen: \(seen.sorted()))")
        }
        return failures
    }

    /// Pure: what is wrong with the notice of one click window. The notice must show exactly once, at least `noticeMinDelayMs` after the
    /// click's start line, and be taken down exactly once, within the tolerances around the end of the `md-speed <command> click` span.
    static func noticeFailures(command: MdSpeedCommand, analysis: MdSpeedClickAnalysis) -> [String] {
        guard analysis.found, let startDate = analysis.window[analysis.zeroIndex].date else {
            return ["the click's start line (or its time stamp) is missing from the log"]
        }
        let lines = Array(analysis.window[analysis.zeroIndex...])
        let message = "Finishing the last change"
        let shows = lines.filter { $0.text.contains("[toast] show") && $0.text.contains(message) }
        let dismisses = lines.filter { $0.text.contains("[toast] dismiss") && $0.text.contains(message) }
        let clickEnd = lines.first { $0.text.contains("end md-speed \(command.word) click took=") }
        func ms(_ later: Date, _ earlier: Date) -> Int { Int((later.timeIntervalSince(earlier) * 1000).rounded()) }
        var failures: [String] = []
        if shows.count != 1 { failures.append("expected exactly one `[toast] show` of \"\(message)\", the log has \(shows.count)") }
        if let show = shows.first?.date, ms(show, startDate) < MdSpeedLimits.noticeMinDelayMs {
            failures.append("the notice showed \(ms(show, startDate)) ms after the click's start, before the one-second delay")
        }
        if dismisses.count != 1 { failures.append("expected exactly one `[toast] dismiss` of \"\(message)\", the log has \(dismisses.count)") }
        guard let endDate = clickEnd?.date else { return failures + ["the `end md-speed \(command.word) click` line is missing from the log"] }
        if let gone = dismisses.first?.date {
            let offset = ms(gone, endDate)
            if offset < -MdSpeedLimits.noticeDismissEarlyToleranceMs {
                failures.append("the notice was taken down \(-offset) ms BEFORE the click's end (it must stay until the click returns)")
            } else if offset > MdSpeedLimits.noticeDismissLateToleranceMs {
                failures.append("the notice was taken down \(offset) ms AFTER the click's end")
            }
        }
        return failures
    }
}

// MARK: - The test class

/// Real-app proof of the Markdown parse memo and the whole-click notice. See the file header.
final class WriteQueuePhase4cMdSpeedE2ETests: Phase4bDelHarness {
    /// The block rows after the load, before the first click.
    var blocksBefore = -1

    /// The calls that must write an `[MdWrite]` line in a Delete's or a drag's click window, and in a Duplicate's (which has no debounce fire).
    static let deleteTriggers = ["structuralClick", "structuralFlush", "writeNow", "debounceFire"]
    static let duplicateTriggers = ["structuralClick", "structuralFlush", "writeNow"]

    func testMdDeleteFast_book12() throws {
        guard startMarkdownBook(method: #function, size: .book12) else { return }
        var clicks: [MdSpeedDriven] = []
        for (index, title) in [size.deleteTitle, WriteQueuePhase4cMdSpeedMeasureE2ETests.secondDeleteTitle].enumerated() {
            let driven = mdDeleteOnce(number: index + 1, title: title, mode: MdSpeedMode(name: "fast"), sampled: false)
            assertDelivered(driven, what: "Delete #\(index + 1)", effect: "the heading \"\(title)\" is gone from the block table")
            clicks.append(driven)
        }
        try judgeSpeed(command: .delete, clicks: clicks, expectedTriggers: Self.deleteTriggers)
    }

    func testMdDuplicateFast_book12() throws {
        guard startMarkdownBook(method: #function, size: .book12) else { return }
        var clicks: [MdSpeedDriven] = []
        for (index, title) in WriteQueuePhase4cMdSpeedMeasureE2ETests.duplicateTitles.enumerated() {
            guard let driven = mdDuplicateOnce(number: index + 1, title: title, mode: MdSpeedMode(name: "fast"), sampled: false) else { return }
            assertDelivered(driven, what: "Duplicate #\(index + 1)", effect: "the block table holds \"\(title)\" and its copy")
            clicks.append(driven)
        }
        try judgeSpeed(command: .duplicate, clicks: clicks, expectedTriggers: Self.duplicateTriggers)
    }

    func testMdDragFast_book12() throws {
        guard startMarkdownBook(method: #function, size: .book12, flat: WriteQueuePhase4cMdSpeedMeasureE2ETests.flatChapters) else { return }
        var clicks: [MdSpeedDriven] = []
        for (index, drag) in WriteQueuePhase4cMdSpeedMeasureE2ETests.drags.enumerated() {
            guard let driven = mdDragOnce(number: index + 1, drag: drag, mode: MdSpeedMode(name: "fast")) else { return }
            assertDelivered(driven, what: "Drag #\(index + 1)", effect: "\"\(drag.moved)\" is above \"\(drag.before)\" in the block table")
            assertCheck(
                driven.carriedOk,
                "Drag #\(index + 1): the heading after \"\(drag.moved)\" is its own first sub-section (the Option key carried it)")
            clicks.append(driven)
        }
        try judgeSpeed(command: .drag, clicks: clicks, expectedTriggers: Self.deleteTriggers)
    }

    /// The everyday flow: open in Rich Text, switch to Markdown, Delete at once. The memo's load prewarm is requested when the Markdown editor
    /// mounts (trigger (i)); the click's own `[MdWrite]` line must be a hit even though no time was given to it.
    ///
    /// THIS IS A REGRESSION CHECK, NOT PROOF. It shows that the everyday flow still ends in a memo hit; it does not prove that the load prewarm
    /// survives the mode switch, because a real-app flow can reach the same hit through another trigger (the post-click prewarm of an earlier
    /// op does not exist here, but the debounce-arm and the editor's own content push can also fill the memo). The proof of the wiring is the
    /// unit test `testEditorModeChangeRequestsTheLoadPrewarmAfterTheReset`.
    func testMdSwitchToMarkdownThenDelete_book12() {
        guard mdSpeedLaunchBook(method: #function, size: .book12, markdown: false) else { return }
        startedAt = Date()
        let mode = app.buttons["status-bar-editor-mode"]
        guard mode.waitForExistence(timeout: 10) else { fail("the editor-mode button never appeared"); return }
        app.activateAndWaitForForeground()
        tail.poll()
        let switchFrom = tail.lines.count
        app.typeKey("/", modifierFlags: .command)
        guard mode.waitForLabel("== 'Markdown'", timeout: size.operationTimeout * 2) else {
            fail("the editor-mode button never reported Markdown after the toggle keystroke (it reads \(mode.label))")
            return
        }
        // The badge flips before the Markdown page exists; wait for the page itself (not for any quiet), so the click still follows at once.
        guard waitForMarkdownPageReady(from: switchFrom) else { return }
        let driven = mdDeleteOnce(number: 1, title: size.deleteTitle, mode: MdSpeedMode(name: "switch-then-delete"), sampled: false)
        assertDelivered(driven, what: "Delete after the switch", effect: "the heading \"\(size.deleteTitle)\" is gone from the block table")
        tail.poll()
        let prewarmLines = tail.lines[min(switchFrom, tail.lines.count)...].filter { $0.text.contains("parseCache.prewarm") }
        let clickPrewarm = driven.analysis.spans.filter { $0.step.hasPrefix("parseCache.") }
            .map { "\($0.step)@+\($0.startMs)ms took \($0.tookMs.map(String.init) ?? "open")ms" }
        let click = driven.analysis.prepare.first { $0.trigger == "structuralClick" }
        let diagnosis = "prewarm spans in the log since the switch: \(prewarmLines.count) (the memo's spans are written only inside an op's "
            + "30 s window, so none before the click is normal); parseCache spans in the click window: \(clickPrewarm); "
            + "the click's line: \(click?.text ?? "NONE - the editor-first path may not have run, the click fell back to the old sequence")"
        result("SPEED delete after switch: \(diagnosis)")
        assertCheck(
            click?.isCleanHit == true,
            "the Delete right after the switch to Markdown found its parse in the memo (cache=hit parse=0.0ms guard=0.0ms); \(diagnosis)")
    }

    /// Five typed words in Markdown mode with no command: after each, the re-parse debounce fire's `[MdWrite]` line must be a memo hit (the
    /// debounce-arm prewarm, trigger (ii), parsed the typed text in the background during the pause). Closes board item B3.
    func testMdTypingPausesDebounceHits_book12() {
        guard startMarkdownBook(method: #function, size: .book12),
              placeCaretAtAnchorEnd(
                paragraph: Phase4bDelHarness.anchorPrefix, exactLine: WriteQueuePhase4bMarkdownEFE2ETests.anchorLine) else { return }
        var failures: [String] = []
        for round in 1...5 {
            tail.poll()
            let from = tail.lines.count
            // e2e-lint: allow raw-typetext -- the pause after the burst is the measurement; a verified retype would add its own writes and waits.
            app.typeText(" word\(round)")
            let found = waitForLog(containing: "[MdWrite] mode=", from: from, timeout: capped(60))
            _ = waitForLogQuiet(quiet: 3, cap: capped(30))
            let lines = tail.lines[min(from, tail.lines.count)...].filter { $0.text.contains("[MdWrite] mode=") }.map(\.text)
            let first = lines.first.flatMap { text in text.range(of: "[MdWrite]").map { String(text[$0.lowerBound...]) } }
            result("SPEED typing pause #\(round): \(lines.count) `[MdWrite] mode=` line(s) after the burst; the first: \(first ?? "NONE")")
            let line = MdSpeedPrepareLine(trigger: "debounceFire", via: "the re-parse debounce fire", text: first ?? "")
            if !found || !line.isCleanHit { failures.append("pause #\(round): \(first ?? "no `[MdWrite] mode=` line within 60 s of the typing")") }
        }
        assertCheck(failures.isEmpty, "all five debounce fires hit the parse memo (cache=hit parse=0.0ms guard=0.0ms); not so: \(failures)")
    }

    func testMdDeleteNoticeWholeClick_book6() {
        guard startNoticeBook(method: #function, flat: []) else { return }
        let driven = mdDeleteOnce(number: 1, title: size.deleteTitle, mode: MdSpeedMode(name: "notice"), sampled: false)
        assertDelivered(driven, what: "Delete", effect: "the heading \"\(size.deleteTitle)\" is gone from the block table")
        assertNotice(command: .delete, driven: driven)
    }

    func testMdDragNoticeWholeClick_book6() {
        guard startNoticeBook(method: #function, flat: [1, 3, 5, 6]) else { return }
        let measure = WriteQueuePhase4cMdSpeedMeasureE2ETests.self
        let drag = MdSpeedDrag(
            moved: measure.chapter(4), before: measure.chapter(3), dropOn: "2.6 Conclusion", dropOnLevel: 2,
            firstSubSection: "4.1 Ledgers and Their Keepers")
        guard let driven = mdDragOnce(number: 1, drag: drag, mode: MdSpeedMode(name: "notice")) else { return }
        assertDelivered(driven, what: "Drag", effect: "\"\(drag.moved)\" is above \"\(drag.before)\" in the block table")
        assertNotice(command: .drag, driven: driven)
    }

    /// CONTROL: Duplicate already kept the notice for the whole click, so this passes on the old code and on the new.
    func testMdDupNoticeWholeClick_book6() {
        guard startNoticeBook(method: #function, flat: []) else { return }
        guard let driven = mdDuplicateOnce(number: 1, title: "3.6 Conclusion", mode: MdSpeedMode(name: "notice"), sampled: false) else { return }
        assertDelivered(driven, what: "Duplicate", effect: "the block table holds \"3.6 Conclusion\" and its copy")
        assertNotice(command: .duplicate, driven: driven)
    }

    /// The pure helpers of this file on canned lines: the field readers, a clean hit and a miss, the ceilings, the validity gate and the notice.
    func testSpeedHelpers_handWorkedExample() {
        let hit = "[MdWrite] mode=rows parse=0.0ms align=0.0ms guard=0.0ms diff=3.1ms mainThread=3.3ms apply=9.0ms "
            + "u/i/d=0/0/0 filtered=0 blocks=2 chars=9 outcome=ok cache=hit"
        let miss = hit.replacingOccurrences(of: "parse=0.0ms", with: "parse=212.4ms").replacingOccurrences(of: "cache=hit", with: "cache=miss")
        XCTAssertEqual(MdSpeedReport.number("parse=", in: miss), 212.4)
        XCTAssertEqual(MdSpeedReport.word("cache=", in: miss), "miss")
        XCTAssertTrue(MdSpeedPrepareLine(trigger: "structuralClick", via: "x", text: hit).isCleanHit)
        XCTAssertFalse(MdSpeedPrepareLine(trigger: "structuralClick", via: "x", text: miss).isCleanHit)
        let slowGuard = hit.replacingOccurrences(of: "guard=0.0ms", with: "guard=4.0ms")
        XCTAssertFalse(MdSpeedPrepareLine(trigger: "writeNow", via: "x", text: slowGuard).isCleanHit)

        func trace(_ time: Int, _ step: String) -> Phase4bDelTraceLine? {
            Phase4bDelTraceLine(Phase4bLogLine(
                stamp: "2026-11-01T10:00:00.000Z", text: "[STRUCT-TRACE] t=\(time)ms +timeline=0ms sectionDelete op=ABCD1234 \(step)"))
        }
        let lines = [
            trace(1_000, "click-start type=none"),
            trace(1_010, "start md-speed delete fetchBlocks"), trace(1_050, "end md-speed delete fetchBlocks took=40ms"),
            trace(1_100, "start md-speed delete adopt"), trace(1_130, "end md-speed delete adopt took=30ms"),
            trace(1_200, "main-stall 300ms"), trace(1_900, "main-stall 800ms")
        ].compactMap { $0 }
        var analysis = MdSpeedClickAnalysis(window: [])
        analysis.spans = MdSpeedReport.spanRows(lines, zero: 1_000)
        analysis.events = MdSpeedReport.events(lines, zero: 1_000)
        analysis.outlineFromEventMs = 240
        analysis.releasedFromEventMs = 1_500
        analysis.ageMs = 40
        let figures = MdSpeedJudge.figures(command: .delete, analysis: analysis)
        XCTAssertEqual(figures, MdSpeedFigures(outlineMs: 200, releasedMs: 1_460, stalledMs: 1_100, longestMs: 800))
        // Click #1 of a Delete: the Outline at 200 ms (ceiling 230) and the stall total 1,100 ms (ceiling 2,350) are inside; the hold at 1,460 ms
        // (ceiling 1,400) and the longest stall at 800 ms (ceiling 670) are over.
        XCTAssertEqual(
            MdSpeedJudge.ceilingFailures(command: .delete, figures: figures, ceilings: MdSpeedLimits.ceilings(for: .delete), index: 0),
            [
                "delete click #1: hold released 1460 ms is over the ceiling of 1400 ms",
                "delete click #1: longest stall 800 ms is over the ceiling of 670 ms"
            ])
        // A gated step with no finished span is reported (here pageCall has none).
        XCTAssertEqual(MdSpeedJudge.missingSteps(command: .delete, analyses: [analysis], references: [("pageCall", 28)]).count, 1)
        // The per-click evidence line: fetchBlocks 40 ms against 20 is 2.00, pageCall is missing (n/a), adopt 30 ms is printed, not gated.
        XCTAssertEqual(
            MdSpeedJudge.gatedEvidenceLine(command: .delete, analysis: analysis, references: [("fetchBlocks", 20), ("pageCall", 30)], floorMs: 0),
            "GATED fetchBlocks=40 pageCall=n/a adopt=30 ratios=2.00 median=2.00")
    }

    /// The judges on canned lines: the cache check (a clean case, a miss, a parse above zero, a missing call), the notice (a clean case, shown
    /// twice, shown too early, never shown, taken down too early and too late), the validity gate (median above 1.5, one ratio above 3.0,
    /// exactly on the limits, all fine) and the order of the verdict (a failure is never turned into a skip, and the gate is not evaluated then).
    func testSpeedJudges_handWorkedExample() {
        checkCacheJudge()
        checkNoticeJudge()
        checkGateJudge()
    }

    private func checkCacheJudge() {
        func line(_ trigger: String, _ edit: (String) -> String = { $0 }) -> MdSpeedPrepareLine {
            let text = "[MdWrite] mode=rows parse=0.0ms align=0.0ms guard=0.0ms diff=3.1ms mainThread=3.3ms apply=9.0ms "
                + "u/i/d=0/0/0 filtered=0 blocks=2 chars=9 outcome=ok cache=hit"
            return MdSpeedPrepareLine(trigger: trigger, via: "x", text: edit(text))
        }
        func analysis(_ prepare: [MdSpeedPrepareLine], found: Bool = true) -> MdSpeedClickAnalysis {
            var made = MdSpeedClickAnalysis(window: [])
            made.found = found
            made.prepare = prepare
            return made
        }
        let triggers = ["structuralClick", "structuralFlush", "writeNow", "debounceFire"]
        let clean = triggers.map { line($0) }
        XCTAssertEqual(MdSpeedJudge.cacheFailures(number: 1, analysis: analysis(clean), expectedTriggers: triggers), [], "a clean click")
        func replacing(_ trigger: String, _ old: String, _ new: String) -> [MdSpeedPrepareLine] {
            clean.map { entry in
                entry.trigger == trigger ? line(trigger) { text in text.replacingOccurrences(of: old, with: new) } : entry
            }
        }
        let miss = replacing("writeNow", "cache=hit", "cache=miss")
        let missed = MdSpeedJudge.cacheFailures(number: 2, analysis: analysis(miss), expectedTriggers: triggers)
        XCTAssertEqual(missed.count, 1, "a miss line: \(missed)")
        XCTAssertTrue(missed[0].contains("click #2, the writeNow call"), missed[0])
        let slow = replacing("debounceFire", "parse=0.0ms", "parse=3.0ms")
        let slowed = MdSpeedJudge.cacheFailures(number: 1, analysis: analysis(slow), expectedTriggers: triggers)
        XCTAssertEqual(slowed.count, 1, "a hit that still parsed: \(slowed)")
        XCTAssertTrue(slowed[0].contains("the debounceFire call"), slowed[0])
        for gone in triggers {
            let without = clean.filter { $0.trigger != gone }
            let absent = MdSpeedJudge.cacheFailures(number: 1, analysis: analysis(without), expectedTriggers: triggers)
            XCTAssertEqual(absent.count, 1, "no line from the \(gone) call: \(absent)")
            XCTAssertTrue(absent[0].contains("from the \(gone) call"), absent[0])
        }
        let noTimeline = MdSpeedJudge.cacheFailures(number: 1, analysis: analysis(clean, found: false), expectedTriggers: triggers)
        XCTAssertEqual(noTimeline.count, 1, "no timeline")
    }

    private func checkNoticeJudge() {
        let message = "Finishing the last change\u{2026}"
        func log(_ time: String, _ text: String) -> Phase4bLogLine { Phase4bLogLine(stamp: "2026-11-01T10:00:\(time)Z", text: text) }
        let start = log("00.000", "[STRUCT-TRACE] t=1000ms +timeline=0ms sectionDelete op=-------- click-start type=none")
        let end = log("03.000", "[STRUCT-TRACE] t=4000ms +timeline=3000ms sectionDelete op=ABCD1234 end md-speed delete click took=3000ms")
        func shown(_ time: String) -> Phase4bLogLine { log(time, "[toast] show style=progress message=\(message)") }
        func gone(_ time: String) -> Phase4bLogLine { log(time, "[toast] dismiss message=\(message) reason=dismissed") }
        func failures(_ lines: [Phase4bLogLine]) -> [String] {
            var analysis = MdSpeedClickAnalysis(window: [start] + lines + [end])
            analysis.found = true
            return MdSpeedJudge.noticeFailures(command: .delete, analysis: analysis)
        }
        XCTAssertEqual(failures([shown("01.050"), gone("02.990")]), [], "a clean click: shown 1,050 ms in, taken down 10 ms before the end")
        XCTAssertEqual(failures([shown("01.050"), gone("03.200")]), [], "taken down 200 ms after the end is inside the tolerance")
        XCTAssertEqual(failures([shown("01.050"), shown("01.900"), gone("03.000")]).count, 1, "shown twice")
        XCTAssertEqual(failures([shown("00.500"), gone("03.000")]).count, 1, "shown 500 ms in, before the one-second delay")
        XCTAssertEqual(failures([gone("03.000")]).count, 1, "never shown")
        let early = failures([shown("01.050"), gone("02.500")])
        XCTAssertEqual(early.count, 1, "taken down 500 ms before the end: \(early)")
        XCTAssertTrue(early[0].contains("BEFORE the click's end"), early[0])
        let late = failures([shown("01.050"), gone("03.800")])
        XCTAssertEqual(late.count, 1, "taken down 800 ms after the end: \(late)")
        XCTAssertTrue(late[0].contains("AFTER the click's end"), late[0])
        XCTAssertEqual(failures([shown("01.050")]).count, 1, "never taken down")
    }

    private func checkGateJudge() {
        let references: [(step: String, ms: Double)] = [("fetchBlocks", 20), ("pageCall", 30), ("replyDecode", 10)]
        func analysis(_ fetch: Int, _ page: Int, _ decode: Int) -> MdSpeedClickAnalysis {
            var made = MdSpeedClickAnalysis(window: [])
            made.spans = [
                MdSpeedSpanRow(name: "delete fetchBlocks", startMs: 0, tookMs: fetch, detail: ""),
                MdSpeedSpanRow(name: "delete pageCall", startMs: 0, tookMs: page, detail: ""),
                MdSpeedSpanRow(name: "delete replyDecode", startMs: 0, tookMs: decode, detail: "")
            ]
            return made
        }
        func gate(_ first: MdSpeedClickAnalysis, _ second: MdSpeedClickAnalysis) -> MdSpeedGate {
            MdSpeedJudge.gate(command: .delete, analyses: [first, second], references: references, rule: MdSpeedGateRule.committed)
        }
        let exact = gate(analysis(20, 30, 10), analysis(20, 30, 10))
        XCTAssertEqual(exact.ratios.count, 6)
        XCTAssertEqual(exact.median, 1.0)
        XCTAssertFalse(exact.isInvalid, "every step on its reference")
        XCTAssertFalse(gate(analysis(30, 45, 15), analysis(30, 45, 15)).isInvalid, "median exactly 1.5 is valid (the limit is a strict 'above')")
        XCTAssertTrue(gate(analysis(32, 48, 16), analysis(32, 48, 16)).isInvalid, "median 1.6")
        // One ratio at 3.5 and five at 1.0: the median is 1.0, but the single limit catches it.
        let outlier = gate(analysis(70, 30, 10), analysis(20, 30, 10))
        XCTAssertEqual(outlier.median, 1.0)
        XCTAssertTrue(outlier.isInvalid, "one ratio above 3.0")
        XCTAssertEqual(outlier.worst?.step, "fetchBlocks")
        XCTAssertEqual(outlier.worst?.click, 1)
        XCTAssertFalse(gate(analysis(60, 30, 10), analysis(20, 30, 10)).isInvalid, "one ratio of exactly 3.0 is valid")
        // The reference floor (proposed 10 ms, off by default): a 5 ms reference with a 16 ms measurement is 3.2x without it, 1.6x with it.
        let tiny: [(step: String, ms: Double)] = [("fetchBlocks", 20), ("pageCall", 30), ("replyDecode", 5)]
        func tinyGate(_ floorMs: Double) -> MdSpeedGate {
            var rule = MdSpeedGateRule.committed
            rule.floorMs = floorMs
            return MdSpeedJudge.gate(command: .delete, analyses: [analysis(20, 30, 16)], references: tiny, rule: rule)
        }
        XCTAssertTrue(tinyGate(0).isInvalid, "3.2x on one tiny reference alone")
        XCTAssertFalse(tinyGate(10).isInvalid, "1.6x with the floor, and the median stays 1.0")

        // The verdict: a deterministic failure comes first and the gate is not evaluated; without one the gate decides.
        var evaluated = false
        let loaded = gate(analysis(80, 120, 40), analysis(80, 120, 40))
        let failed = MdSpeedJudge.verdict(deterministicFailures: ["a miss"]) { evaluated = true; return loaded }
        XCTAssertEqual(failed, .failed(["a miss"]), "a failure is never turned into a skip, even on a loaded host")
        XCTAssertFalse(evaluated, "the gate is not evaluated when something has failed")
        guard case .invalid(let message) = MdSpeedJudge.verdict(deterministicFailures: [], gate: { loaded }) else {
            return XCTFail("a loaded run without a failure is invalid")
        }
        XCTAssertTrue(message.hasPrefix("INVALID RUN - host too loaded, rerun: median ratio 4.00"), message)
        XCTAssertEqual(MdSpeedJudge.verdict(deterministicFailures: [], gate: { exact }), .valid(median: 1.0))
    }
}

// MARK: - Helpers of the tests

extension WriteQueuePhase4cMdSpeedE2ETests {
    /// The twelve-chapter or six-chapter book, launched with the extra launch environment and switched to Markdown. False after a failure.
    func startMarkdownBook(method: String, size: Phase4bDelSize, flat: [Int] = [], env: [String: String] = [:]) -> Bool {
        guard mdSpeedLaunchBook(method: method, size: size, flat: flat, env: env, markdown: true) else { return false }
        blocksBefore = dbInt("SELECT count(*) FROM block;") ?? -1
        startedAt = Date()
        return true
    }

    /// The six-chapter book with the first Markdown page preparation held `noticeHoldMs` (the click then outlasts the notice's one second).
    func startNoticeBook(method: String, flat: [Int]) -> Bool {
        startMarkdownBook(
            method: method, size: .book6, flat: flat,
            env: [
                "FF_UI_TESTING_MD_PAGE_PREPARE_HOLD_MS": String(MdSpeedLimits.noticeHoldMs),
                "FF_UI_TESTING_MD_PAGE_PREPARE_HOLD_FIRST_N": "1"
            ])
    }

    /// The sanity every driven click owes: the hold was released, the settle ended and the command's effect is in the block table.
    func assertDelivered(_ driven: MdSpeedDriven, what: String, effect: String) {
        assertCheck(driven.done.released, "\(what): the writer's hold was released")
        assertCheck(driven.done.settled, "\(what): the settle after the hold ended")
        assertCheck(driven.effectOk, "\(what): \(effect)")
    }

    /// The notice of a click that outlasts one second: shown once, at least a second in, and gone only when the click returns. Also proves the
    /// hold knob took effect (a `[MD-PREPARE-HOLD]` line), so a missing notice cannot be put down to a click that was never slow.
    func assertNotice(command: MdSpeedCommand, driven: MdSpeedDriven) {
        let held = driven.analysis.window.contains { $0.text.contains("[MD-PREPARE-HOLD]") }
        assertCheck(held, "TEST-SETUP: the page-preparation hold began (an `[MD-PREPARE-HOLD]` line is in the click window)")
        let failures = MdSpeedJudge.noticeFailures(command: command, analysis: driven.analysis)
        let verdict = failures.isEmpty ? "shown once after at least one second and taken down with the click" : failures.joined(separator: "; ")
        result("SPEED \(command.word) notice: \(verdict)")
        assertCheck(failures.isEmpty, "\(command.word): the \"Finishing the last change\" notice stays up for the whole click: \(verdict)")
    }

    /// Judges the clicks of a `...Fast` test in the order of the file header: the deterministic cache checks FIRST (a failure there fails the
    /// test and is never turned into a skip), then the validity gate, then the ceilings.
    func judgeSpeed(command: MdSpeedCommand, clicks: [MdSpeedDriven], expectedTriggers: [String]) throws {
        // A failure recorded earlier in the test (the sanity checks of the clicks) ends the judging: the gate is not even evaluated.
        guard (testRun?.totalFailureCount ?? 0) == 0 else { return }
        let analyses = clicks.map(\.analysis)
        let word = command.word
        let references = MdSpeedLimits.references(for: command)
        // The evidence first, whatever the verdict: what each click measured and its ratios (the driver takes medians from these lines).
        for (index, analysis) in analyses.enumerated() {
            let evidence = MdSpeedJudge.gatedEvidenceLine(
                command: command, analysis: analysis, references: references, floorMs: MdSpeedLimits.validityReferenceFloorMs)
            result("SPEED \(word) #\(index + 1): \(evidence)")
        }
        // (1) Deterministic, never gated and never skipped. A gated step with no span is a set-up failure of the same kind.
        let missing = MdSpeedJudge.missingSteps(command: command, analyses: analyses, references: references)
        let cacheFailures = analyses.enumerated().flatMap {
            MdSpeedJudge.cacheFailures(number: $0.offset + 1, analysis: $0.element, expectedTriggers: expectedTriggers)
        }
        result("SPEED \(word): cache check \(cacheFailures.isEmpty ? "OK, every [MdWrite] line is a clean hit" : "FAILED: \(cacheFailures)")")
        // (2) The validity gate: evaluated only when nothing above has failed.
        let verdict = MdSpeedJudge.verdict(deterministicFailures: cacheFailures + missing.map { "TEST-SETUP: \($0)" }) {
            MdSpeedJudge.gate(command: command, analyses: analyses, references: references, rule: MdSpeedGateRule.committed)
        }
        switch verdict {
        case .failed(let failures):
            assertCheck(false, "\(word): every `[MdWrite] mode=` line of every click is `cache=hit parse=0.0ms guard=0.0ms`: \(failures)")
            return
        case .invalid(let message):
            result("SPEED \(word): VALIDITY INVALID (\(message))")
            throw XCTSkip(message)
        case .valid(let median):
            result("SPEED \(word): VALIDITY OK median ratio \(String(format: "%.2f", median))")
        }
        // (3) The committed ceilings, on a valid run.
        let ceilings = MdSpeedLimits.ceilings(for: command)
        var failures: [String] = []
        for (index, analysis) in analyses.enumerated() {
            let figures = MdSpeedJudge.figures(command: command, analysis: analysis)
            let summary = MdSpeedJudge.summaryLine(figures: figures, ceilings: ceilings, index: index, prepare: analysis.prepare)
            result("SPEED \(word) #\(index + 1): \(summary)")
            failures += MdSpeedJudge.ceilingFailures(command: command, figures: figures, ceilings: ceilings, index: index)
        }
        assertCheck(failures.isEmpty, "\(word): every click is inside the committed ceilings: \(failures)")
    }
}
