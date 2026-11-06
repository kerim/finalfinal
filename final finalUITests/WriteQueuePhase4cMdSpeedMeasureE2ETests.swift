//
//  WriteQueuePhase4cMdSpeedMeasureE2ETests.swift
//  final finalUITests
//
//  PERFORMANCE JOB, ROUNDS M1 AND M2: MEASUREMENT ONLY. Report tests, one per Markdown section command, on the generated twelve-chapter
//  book (699,139 characters): Delete Section, the Outline drag, Duplicate Section. Each launches the app fresh, switches to Markdown, does
//  the command TWICE (the first click is the cold one, the second the warm one, on a different section), and after each click follows the
//  app's own diagnostic log until the writer's hold is released AND the settle after it has ended, then prints ONE block of
//  `RESULT MEASURE <command> #1:` / `#2:` lines. NOTHING IS ASSERTED ABOUT TIME: the only assertions are that each click completed, the
//  document is intact, and the hold was released and the settle ended.
//
//  PLAIN VS SAMPLED: the three plain tests start nothing next to the app. `testMeasureMdDeleteSampled_book12` and
//  `testMeasureMdDuplicateSampled_book12` are their twins with `/usr/bin/sample` running against the app for each click (5 s at 2 ms,
//  `Phase4bMainThreadSample`, wiki: "Finding Main-Thread Stalls With a Stack Sample Taken From the UI Test"); the samples are attached as
//  `main-thread-sample-MEASURE-<command>-<n>-sampled.txt` and `...-top-of-stack.txt`. `sample` slows the app and its start costs time
//  inside the click, so compare the plain run's figures with the sampled run's, never the sampled run's alone. Delete is started by the
//  app's own UI-testing trigger (no menu click); Duplicate is the menu click, with the sampler started just before the click on the
//  already-found menu item; the drag is never sampled.
//
//  WHAT THE APP EMITS (Services/MdSpeed.swift): `start md-speed <command> <step>` and `end md-speed <command> <step> took=<n>ms` timeline
//  lines on the app's clock (milliseconds since system start, the `t=` of every `[STRUCT-TRACE]` line), plus plain marker lines
//  (`job task started`, `onReserved fired`, `md-speed <command> entered`, ...). The timeline starts at the click: Delete and Duplicate at the
//  `click-start` line (the in-app Delete trigger has no event: `click-start type=none`, timed when the trigger arrived), the drag at the
//  drop (`md-speed drag drop-received`). Every offset below is `t` minus that zero.
//
//  THE REPORT, per click (each line starts with `RESULT MEASURE <command> #<n>:`):
//    MODE      plain or sampled, with the writer's parse memo ON or OFF (`plain, memo OFF (FF_UI_TESTING_NO_PARSE_MEMO=1)` for the
//              `...NoMemo_book12` A/B twins), and for a sampled Duplicate how long before the click call the sampler was started
//    (besides the block: per click `RESULT SPEED <command>-memo|<command>-nomemo #<n>: GATED fetchBlocks=.. pageCall=.. replyDecode=..
//    adopt=..`, the Fast class's evidence line, so the untouched steps can be compared memo ON versus OFF from the log)
//    ZERO      the line the offsets count from (its text, so the click event's type and age are visible)
//    STEP      every `md-speed` span in start order: start offset, duration, a tag [main] (synchronous main-thread work), [await] (the main
//              thread is free while it waits), [off-main] (runs on another thread) or [mixed], and its detail (counts, never text)
//    SPAN      the app's older, differently named spans in the same window (contentPush, snapshot.*, sectionSync.syncNow, ...)
//    NOTE      every plain marker line, with its offset
//    GAP       differences worked out from the spans and markers above: where the job start, the job end, step 8 and the click-to-first-line
//              time went
//    FIGURES   the three figures `testMdTiming_book12` computes from the log stamps, and the first Outline render after ZERO
//    STALL     every `main-stall`, `wake-work` and `ui-update` line: when it ENDED (offset) and how long it lasted
//    SPELL     the spell-check calls: how many, how long, and how many began before the click returned
//    MESSAGES  the editor's content messages by type: how many, how long
//    PREPARE   the writer's parse and diff calls (who called) and the `[MdWrite] mode=...` lines, each matched to the latest unclaimed call
//    NOTICES   how many "Finishing the last change" notices were shown
//
//  CLASS NAME: after the round (vmtest's retry-refusal streak is keyed by class and method name). The class inherits the harness of
//  WriteQueuePhase4bDeleteE2ETests.swift (`Phase4bDelHarness`) and copies the few instance helpers it needs from the behaviour classes
//  (those live in `final` classes and cannot be inherited); the helpers of this file that other classes use now live in
//  `extension Phase4bDelHarness` below (prefix `mdSpeed`), and the click drivers `mdDeleteOnce`, `mdDuplicateOnce`, `mdDragOnce` too.
//
//  WHAT THIS FILE IS, AND IS NOT: the PERMANENT assertions of the speed job (cache hits, ceilings, the whole-click notice) live in
//  WriteQueuePhase4cMdSpeedE2ETests.swift. This class is REPORT-ONLY: job 3's before/after evidence (the `RESULT MEASURE` table with the
//  step spans, the stalls, who called the writer's parse, and the optional stack sample) and the shared helpers above; it asserts nothing about
//  time. It is the SECOND new UI-test file of the branch, which scripts/e2e-hygiene.sh allows only with an `e2e-cap: allow` trailer on a
//  commit in the range; the wrap-up carries that trailer. Reason: the helpers and the report are shared by the permanent class, so folding
//  them into it would make one very large file with report-only tests that are run on their own, for a different purpose.
//
//  RUNNING (VM only; every vmtest call needs the sandbox off; run ONE method per run on a quiet VM, the numbers are the point):
//    scripts/vmtest/vmtest run --detach --timeout 2400 \
//      --scope "final finalUITests/WriteQueuePhase4cMdSpeedMeasureE2ETests/testMeasureMdDelete_book12"
//

// swiftlint:disable file_length - the shared helpers and this report live in one file: splitting it would add a third new UI-test file
import AppKit
import XCTest

// MARK: - The report, pure

/// The three commands of the round: how the app's timeline names them.
enum MdSpeedCommand {
    case delete
    case drag
    case duplicate

    /// The word in the app's step names (`md-speed <word> <step>`).
    var word: String {
        switch self {
        case .delete: return "delete"
        case .drag: return "drag"
        case .duplicate: return "duplicate"
        }
    }

    /// The label the app's timeline lines carry.
    var timelineLabel: String {
        switch self {
        case .delete: return "sectionDelete"
        case .drag: return "sectionReorder"
        case .duplicate: return "sectionDuplicate"
        }
    }

    /// The step text of the line the offsets count from.
    func isZeroStep(_ step: String) -> Bool {
        switch self {
        case .delete, .duplicate: return step.hasPrefix("click-start")
        case .drag: return step == "md-speed drag drop-received"
        }
    }
}

/// One span as the report shows it. `startMs` counts from the report's zero; `name` is `<command> <step>` for an `md-speed` span.
struct MdSpeedSpanRow: Equatable {
    let name: String
    let startMs: Int
    let tookMs: Int?
    let detail: String

    var endMs: Int? { tookMs.map { startMs + $0 } }
    /// The step without the command word.
    var step: String { name.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? name }
}

/// A `main-stall`, `wake-work` or `ui-update` line: `endMs` is when it ENDED (the app writes the line when the stall is over).
struct MdSpeedEvent: Equatable {
    let kind: String
    let endMs: Int
    let durationMs: Int
}

/// A plain timeline line that is neither a span nor an event.
struct MdSpeedMark: Equatable {
    let step: String
    let atMs: Int
}

/// One `[MdWrite] mode=...` line of a click window, with the call that wrote it (matched by `prepareLines`).
struct MdSpeedPrepareLine: Equatable {
    /// `structuralClick`, `structuralFlush`, `writeNow`, `debounceFire`, or `?` when no call span precedes the line.
    let trigger: String
    /// The call site: for example `prepareStructuralClick (the reply turn)` or `writer.writeNow.bibliographyFlush`.
    let via: String
    /// The line from `[MdWrite]` on.
    let text: String

    var cache: String? { MdSpeedReport.word("cache=", in: text) }
    var parseMs: Double? { MdSpeedReport.number("parse=", in: text) }
    var guardMs: Double? { MdSpeedReport.number("guard=", in: text) }
    /// True for a line that came from the parse memo and cost the main thread nothing to parse or check (`cache=hit parse=0.0ms guard=0.0ms`).
    var isCleanHit: Bool { cache == "hit" && parseMs == 0 && guardMs == 0 }
}

/// Everything one driven click's log window says (see `report`): the printed block, the spans, events and marks, the `[MdWrite]` lines and
/// the figures the committed ceilings are about. Figures named `...FromEventMs` count from the click EVENT; subtract `ageMs` for the app's
/// click-start (zero for the in-app Delete trigger and for the drag).
struct MdSpeedClickAnalysis {
    let window: [Phase4bLogLine]
    var zeroIndex = 0
    var found = false
    var ageMs = 0
    var block: [String] = []
    var spans: [MdSpeedSpanRow] = []
    var events: [MdSpeedEvent] = []
    var marks: [MdSpeedMark] = []
    var prepare: [MdSpeedPrepareLine] = []
    var holdRaisedFromEventMs: Int?
    var outlineFromEventMs: Int?
    var releasedFromEventMs: Int?

    /// Milliseconds that count from the app's own click-start: the figure minus the event's age.
    func fromAppClick(_ value: Int?) -> Int? { value.map { $0 - ageMs } }
    /// The first span named `<command> <step>`.
    func span(_ command: String, _ step: String) -> MdSpeedSpanRow? { spans.first { $0.name == "\(command) \(step)" } }
    var stalls: [MdSpeedEvent] { events.filter { $0.kind == "main-stall" } }
    var stalledTotalMs: Int { stalls.reduce(0) { $0 + $1.durationMs } }
    var stalledLongestMs: Int { stalls.map(\.durationMs).max() ?? 0 }
}

enum MdSpeedReport {
    static let spanPrefix = "md-speed "

    /// Pure: the number after `name` in `text` (`number("parse=", in: "x parse=0.0ms y")` is 0.0), nil when `name` is absent.
    static func number(_ name: String, in text: String) -> Double? {
        guard let range = text.range(of: " \(name)") else { return nil }
        return Double(text[range.upperBound...].prefix(while: { $0.isNumber || $0 == "." }))
    }

    /// Pure: the run of non-blank characters after `name` in `text` (`word("cache=", in: "x cache=hit")` is "hit"), nil when absent.
    static func word(_ name: String, in text: String) -> String? {
        guard let range = text.range(of: " \(name)") else { return nil }
        let run = text[range.upperBound...].prefix(while: { !$0.isWhitespace })
        return run.isEmpty ? nil : String(run)
    }

    /// Pure: the `md-speed` spans of `traces` in start order, each with its offset from `zero` (the app-clock `t` of the report's zero).
    static func spanRows(_ traces: [Phase4bDelTraceLine], zero: Int) -> [MdSpeedSpanRow] {
        collectSpans(traces, zero: zero, mdSpeed: true)
    }

    /// Pure: the spans that do NOT carry the `md-speed` prefix (the older ones: contentPush, snapshot.*, sectionSync.syncNow, ...).
    static func otherSpanRows(_ traces: [Phase4bDelTraceLine], zero: Int) -> [MdSpeedSpanRow] {
        collectSpans(traces, zero: zero, mdSpeed: false)
    }

    /// The start is the `start` line's own `t`; a span with only an `end` line starts `took` before it; a span with no `end` is `open`.
    private static func collectSpans(_ traces: [Phase4bDelTraceLine], zero: Int, mdSpeed: Bool) -> [MdSpeedSpanRow] {
        struct Open {
            let name: String
            let startT: Int
        }
        let startMarker = mdSpeed ? "start \(spanPrefix)" : "start "
        let endMarker = mdSpeed ? "end \(spanPrefix)" : "end "
        var open: [Open] = []
        var rows: [MdSpeedSpanRow] = []
        for trace in traces where trace.family == .timeline {
            let step = trace.step
            if step.hasPrefix(startMarker), mdSpeed || !step.hasPrefix("start \(spanPrefix)") {
                var name = String(step.dropFirst(startMarker.count))
                if !mdSpeed { name = name.split(separator: " ", maxSplits: 1).first.map(String.init) ?? name }
                open.append(Open(name: name, startT: trace.t))
            } else if step.hasPrefix(endMarker), mdSpeed || !step.hasPrefix("end \(spanPrefix)") {
                let body = String(step.dropFirst(endMarker.count))
                guard let tookRange = body.range(of: " took=") else { continue }
                let name = String(body[..<tookRange.lowerBound])
                let took = Phase4bDelTypingParser.intAfter("took=", in: body)
                // "took=12ms chars=345": the detail is what follows the "ms".
                let detail = body[tookRange.upperBound...].drop(while: { $0.isNumber }).dropFirst(2).trimmingCharacters(in: .whitespaces)
                let startT: Int
                if let index = open.firstIndex(where: { $0.name == name }) {
                    startT = open.remove(at: index).startT
                } else {
                    startT = trace.t - (took ?? 0)
                }
                rows.append(MdSpeedSpanRow(name: name, startMs: startT - zero, tookMs: took, detail: detail))
            }
        }
        for leftover in open {
            rows.append(MdSpeedSpanRow(name: leftover.name, startMs: leftover.startT - zero, tookMs: nil, detail: "never ended"))
        }
        return rows.enumerated().sorted { ($0.element.startMs, $0.offset) < ($1.element.startMs, $1.offset) }.map(\.element)
    }

    /// Pure: every `main-stall <n>ms`, `wake-work took=<n>ms` and `ui-update took=<n>ms` line of `traces`, in log order.
    static func events(_ traces: [Phase4bDelTraceLine], zero: Int) -> [MdSpeedEvent] {
        var found: [MdSpeedEvent] = []
        for trace in traces where trace.family == .timeline {
            let step = trace.step
            if step.hasPrefix("main-stall "), let lasted = Phase4bDelTypingParser.intAfter("main-stall ", in: step) {
                found.append(MdSpeedEvent(kind: "main-stall", endMs: trace.t - zero, durationMs: lasted))
            } else if step.hasPrefix("wake-work took="), let lasted = Phase4bDelTypingParser.intAfter("took=", in: step) {
                found.append(MdSpeedEvent(kind: "wake-work", endMs: trace.t - zero, durationMs: lasted))
            } else if step.hasPrefix("ui-update took="), let lasted = Phase4bDelTypingParser.intAfter("took=", in: step) {
                found.append(MdSpeedEvent(kind: "ui-update", endMs: trace.t - zero, durationMs: lasted))
            }
        }
        return found
    }

    /// Pure: the plain marker lines (neither a span line, an event, nor the click-start line), in log order.
    static func marks(_ traces: [Phase4bDelTraceLine], zero: Int) -> [MdSpeedMark] {
        let skipped = ["start ", "end ", "main-stall ", "wake-work ", "ui-update ", "click-start"]
        return traces.filter { $0.family == .timeline }.compactMap { trace in
            skipped.contains(where: { trace.step.hasPrefix($0) }) ? nil : MdSpeedMark(step: trace.step, atMs: trace.t - zero)
        }
    }

    // MARK: Tags

    private static let awaitSteps: Set<String> = [
        "holdWait", "inFlightWait", "jobStart.reservedWait", "jobEndedWait", "step8.inFlightWait", "step8.getContentRaw", "step8.flushWait",
        "settle.step8GateWait", "settle.awaitNoRunningRebuilds", "pageCall", "prepare.cancelPendingInsertions", "prepare.closeEditingPopups",
        "pushDescriptor", "sectionSync.detachedWait", "refreshSections.chainWait", "refreshSections.outlineFetch", "refreshSections.wordCounts",
        "bibliography.liveFlush", "settle.refreshSectionsAwaiting"
    ]
    private static let offMainSteps: Set<String> = [
        "job.snapshot", "job.deleteSections", "sectionSync.fetchSnapshot", "sectionSync.parseHeaders", "sectionSync.reconcileApply",
        "sectionSync.saveContent", "parseCache.prewarm", "parseCache.scan"   // the parse memo's background stages (MarkdownParseCache)
    ]
    private static let mainSteps: Set<String> = [
        "fetchBlocks", "leaderMap", "requestJson", "replyDecode", "recordText.pre", "prepareStructuralClick", "adopt", "sidebar", "holdHandOff",
        "jobStart.setup", "job.notifyEnded", "mintCopyIds", "insertedSections+crossCheck", "sidebar.originalsRead", "sidebar.mergeAssign",
        "sidebar.refreshSections", "step8.turn", "step8.recordText", "step8.reserveStructuralFlush", "step8.adopt", "step8.holdRelease",
        "settle.extractCitekeys", "settle.extractFootnoteRefs", "settle.refreshSections", "sectionSync.mainTail", "refreshSections.apply",
        "footnote.computeRenumberMapping", "footnote.pushDefinitionsToEditor", "dropPlan", "gatePlan",
        "onContentChange", "onContentChange.sourceContent", "onContentChange.stripSectionAnchors", "onContentChange.stripBibliographyMarker",
        "onContentChange.contentAssign", "spellcheck.deliver", "parseCache.lookup"
    ]

    /// Pure: how a step spends the main thread. [main] = synchronous work on it, [await] = it is free while the step waits,
    /// [off-main] = the work runs on another thread, [mixed] = a bit of each (a whole phase), "" = not classified.
    static func tag(forStep step: String) -> String {
        if awaitSteps.contains(step) { return "[await]" }
        if offMainSteps.contains(step) || (step.hasPrefix("systemWrite.") && step.hasSuffix(".dbWrite")) { return "[off-main]" }
        if mainSteps.contains(step) || step.hasPrefix("contentChange.") || step.hasPrefix("contentMessage.") || step.hasPrefix("writer.prepare.") {
            return "[main]"
        }
        if step.hasPrefix("systemWrite.") && (step.hasSuffix(".waitForTurn") || step.hasSuffix(".apply")) { return "[await]" }
        if step == "spellcheck.check" { return "[main or await: see the sample]" }
        return "[mixed]"
    }

    // MARK: Lines

    static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: " ", count: max(0, width - text.count)) + text
    }

    static func stepLine(_ row: MdSpeedSpanRow) -> String {
        let took = row.tookMs.map { "\(pad($0, 6)) ms" } ?? "  open    "
        return "STEP  start +\(pad(row.startMs, 6)) ms  took \(took)  \(row.step) \(tag(forStep: row.step))"
            + (row.detail.isEmpty ? "" : "  [\(row.detail)]")
    }

    static func spanLine(_ row: MdSpeedSpanRow) -> String {
        let took = row.tookMs.map { "\(pad($0, 6)) ms" } ?? "  open    "
        return "SPAN  start +\(pad(row.startMs, 6)) ms  took \(took)  \(row.name)" + (row.detail.isEmpty ? "" : "  [\(row.detail)]")
    }

    static func eventLine(_ event: MdSpeedEvent) -> String {
        "STALL \(event.kind): ended +\(pad(event.endMs, 6)) ms, lasted \(pad(event.durationMs, 6)) ms "
            + "(began +\(pad(event.endMs - event.durationMs, 6)) ms)"
    }

    /// Pure: the differences worked out from the spans and marks (see the file header, GAP). A line is left out when a part is missing.
    static func gapLines(command: String, spans: [MdSpeedSpanRow], marks: [MdSpeedMark]) -> [String] {
        func span(_ step: String) -> MdSpeedSpanRow? { spans.first { $0.name == "\(command) \(step)" } }
        func mark(_ step: String) -> Int? { marks.first { $0.step == step }?.atMs }
        var lines: [String] = []
        if let job = span("jobStart"), let started = mark("job task started"), let reserved = mark("onReserved fired"), let end = job.endMs {
            lines.append(
                "GAP jobStart (\(job.tookMs ?? 0) ms) = \(started - job.startMs) ms until the job's Task began (the main thread was doing "
                + "other work) + \(reserved - started) ms of the job's own synchronous steps on the main thread up to `onReserved fired` + "
                + "\(end - reserved) ms until the click's continuation got the main thread back")
        }
        if let wait = span("jobEndedWait"), let perform = span("job.perform"), let waitEnd = wait.endMs, let performEnd = perform.endMs {
            lines.append(
                "GAP jobEndedWait (\(wait.tookMs ?? 0) ms) = \(perform.startMs - wait.startMs) ms before job.perform began + "
                + "\(perform.tookMs ?? 0) ms of job.perform + \(waitEnd - performEnd) ms after it ended "
                + "(the continuation waiting for the main thread)")
        }
        if let gate = span("settle.step8GateWait"), let step8 = span("step8"), let notify = span("job.notifyEnded"),
           let gateEnd = gate.endMs, let step8End = step8.endMs, let notifyEnd = notify.endMs {
            lines.append(
                "GAP settle.step8GateWait (\(gate.tookMs ?? 0) ms) = \(step8.startMs - notifyEnd) ms from job.notifyEnded's end to step 8's "
                + "start + \(step8.tookMs ?? 0) ms of step 8 + \(gateEnd - step8End) ms from step 8's end to the gate's release")
        }
        let first = (spans.map(\.startMs) + marks.filter { $0.step.hasPrefix(spanPrefix) }.map(\.atMs)).min()
        if let first {
            lines.append("GAP click event to the first md-speed line: \(first) ms (the app's own time from the click event to its first line; "
                + "includes the menu action's age and the Task hop)")
        }
        return lines
    }

    /// Pure: how many spans named `<command> <step>` there are, their total and their longest, as one sentence.
    static func summary(of rows: [MdSpeedSpanRow], step: String, command: String) -> MdSpeedSummary {
        let mine = rows.filter { $0.name == "\(command) \(step)" }
        let times = mine.compactMap(\.tookMs)
        return MdSpeedSummary(count: mine.count, totalMs: times.reduce(0, +), longestMs: times.max() ?? 0)
    }
}

// MARK: - The test class

/// What the wait saw.
struct MdSpeedFollow {
    var released = false
    var settled = false
}

/// How the click was run: plain or sampled, and (a sampled Duplicate) how long before the click call the sampler was started.
struct MdSpeedMode {
    /// A file-safe name: part of the attachment's file name.
    let name: String
    var samplerLeadMs: Int?
    /// What the report's MODE line says instead of `name` (for example `plain, memo OFF (FF_UI_TESTING_NO_PARSE_MEMO=1)`).
    var detail: String?
}

/// How many spans of one step there are, their total and their longest.
struct MdSpeedSummary {
    let count: Int
    let totalMs: Int
    let longestMs: Int
}

/// One Option-drag of a chapter with its sub-sections: `moved` goes to just before `before`, the pointer is let go on the card of `dropOn`
/// (the card above `before`; its heading level is `dropOnLevel`), and `firstSubSection` must follow `moved` afterwards.
struct MdSpeedDrag {
    let moved: String
    let before: String
    let dropOn: String
    let dropOnLevel: Int
    let firstSubSection: String
}

/// What one driven click left behind: its log analysis, what the wait saw, and whether the command's effect is in the block table.
struct MdSpeedDriven {
    var analysis: MdSpeedClickAnalysis
    var done: MdSpeedFollow
    /// Delete: the heading is gone. Duplicate: the section and its copy are both there. Drag: the moved chapter is above the one it passed.
    var effectOk = false
    /// Drag only: the heading after the moved chapter is its own first sub-section (the Option key carried the subtree).
    var carriedOk = true
}

/// Delete, drag and Duplicate Section in Markdown mode, timed step by step on the twelve-chapter book. See the file header.
final class WriteQueuePhase4cMdSpeedMeasureE2ETests: Phase4bDelHarness {
    /// The sections duplicated: the one `testMdDupTiming_book12` duplicates (so figures can be compared), then the same kind in chapter 8.
    static let duplicateTitles = ["3.6 Conclusion", "8.6 Conclusion"]
    /// The sections deleted: `size.deleteTitle` (Chapter 6, the one the Delete timing tests use), then Chapter 4.
    static let secondDeleteTitle = "Chapter 4: The Quiet Archive and Its Ledgers"
    /// The drags, both mid-book and both an OPTION-drag of a whole chapter WITH its 16 sub-sections (79 rows, nine footnotes) to just before
    /// its flat neighbour (the pair of the Markdown drag tests' E-D3, `footnoteDragPair`): chapters 8 and 10 are flattened (their
    /// sub-headings turned into plain lines) so the cards of the three chapters of each drag sit next to each other in the sidebar.
    static let flatChapters = [8, 10]
    static let drags = [
        // After chapter 7's closing section, before flat chapter 8: chapter 9 and its sub-sections move up past chapter 8.
        MdSpeedDrag(
            moved: chapter(9), before: chapter(8), dropOn: "7.6 Conclusion", dropOnLevel: 2, firstSubSection: "9.1 Ledgers and Their Keepers"),
        // Chapter 8 is now right before flat chapter 10: chapter 11 and its sub-sections move up past chapter 10.
        MdSpeedDrag(
            moved: chapter(11), before: chapter(10), dropOn: chapter(8), dropOnLevel: 1, firstSubSection: "11.1 Ledgers and Their Keepers")
    ]
    static func chapter(_ number: Int) -> String { "Chapter \(number): The Quiet Archive and Its Ledgers" }

    /// The block rows after the load, before the first click.
    var blocksBefore = -1

    func testMeasureMdDelete_book12() { runDelete(method: #function, sampled: false) }
    func testMeasureMdDeleteSampled_book12() { runDelete(method: #function, sampled: true) }
    func testMeasureMdDrag_book12() { runDrag(method: #function) }
    func testMeasureMdDuplicate_book12() { runDuplicate(method: #function, sampled: false) }
    func testMeasureMdDuplicateSampled_book12() { runDuplicate(method: #function, sampled: true) }

    // The A/B twins: the same plain run with the writer's parse memo OFF (`FF_UI_TESTING_NO_PARSE_MEMO=1`), so one build is measured with the
    // memo ON (the twins above) and OFF back to back on the same host. No cache assertion: the OFF runs must say `cache=miss`.
    func testMeasureMdDeleteNoMemo_book12() { runDelete(method: #function, sampled: false, memo: false) }
    func testMeasureMdDragNoMemo_book12() { runDrag(method: #function, memo: false) }
    func testMeasureMdDuplicateNoMemo_book12() { runDuplicate(method: #function, sampled: false, memo: false) }

    /// The launch environment of the memo-OFF twins (only effective with FF_UI_TESTING, which every launch here sets).
    static let noMemoEnvironment = ["FF_UI_TESTING_NO_PARSE_MEMO": "1"]

    /// The mode of a click: plain or sampled, with the parse memo ON (the default) or OFF. The MODE line of the report says which.
    static func mode(sampled: Bool, memo: Bool) -> MdSpeedMode {
        let kind = sampled ? "sampled" : "plain"
        guard memo else {
            return MdSpeedMode(name: "\(kind)-nomemo", detail: "\(kind), memo OFF (FF_UI_TESTING_NO_PARSE_MEMO=1)")
        }
        return MdSpeedMode(name: kind, detail: "\(kind), memo ON")
    }

    /// The report parser on canned lines (no app launch beyond the harness's set-up): spans, a span with no start, a span never ended, the
    /// older spans, the marks, the three event kinds, the gaps and the offsets from the zero.
    func testReportParser_handWorkedExample() {
        func trace(_ time: Int, _ step: String) -> Phase4bDelTraceLine? {
            Phase4bDelTraceLine(Phase4bLogLine(
                stamp: "2026-11-01T10:00:00.000Z", text: "[STRUCT-TRACE] t=\(time)ms +timeline=0ms sectionDelete op=ABCD1234 \(step)"))
        }
        let lines = [
            trace(1_000, "click-start type=none"),
            trace(1_010, "start md-speed delete fetchBlocks"),
            trace(1_090, "end md-speed delete fetchBlocks took=80ms"),
            trace(1_100, "start md-speed delete pageCall"),
            trace(1_400, "end md-speed delete pageCall took=300ms chars=1400000"),
            trace(1_500, "end md-speed delete adopt took=120ms"),
            trace(1_600, "start md-speed delete never"),
            trace(1_700, "main-stall 250ms"),
            trace(1_800, "wake-work took=700ms"),
            trace(1_900, "ui-update took=90ms"),
            trace(2_000, "start contentPush chars=5"),
            trace(2_030, "end contentPush took=30ms"),
            trace(2_100, "job task started")
        ].compactMap { $0 }
        XCTAssertEqual(lines.count, 13, "every canned line parses")
        let spans = MdSpeedReport.spanRows(lines, zero: 1_000)
        XCTAssertEqual(
            spans,
            [
                MdSpeedSpanRow(name: "delete fetchBlocks", startMs: 10, tookMs: 80, detail: ""),
                MdSpeedSpanRow(name: "delete pageCall", startMs: 100, tookMs: 300, detail: "chars=1400000"),
                MdSpeedSpanRow(name: "delete adopt", startMs: 380, tookMs: 120, detail: ""),
                MdSpeedSpanRow(name: "delete never", startMs: 600, tookMs: nil, detail: "never ended")
            ])
        XCTAssertEqual(spans.first?.step, "fetchBlocks")
        XCTAssertEqual(MdSpeedReport.tag(forStep: "fetchBlocks"), "[main]")
        XCTAssertEqual(MdSpeedReport.tag(forStep: "pageCall"), "[await]")
        XCTAssertEqual(MdSpeedReport.tag(forStep: "systemWrite.sectionDelete.dbWrite"), "[off-main]")
        XCTAssertEqual(MdSpeedReport.tag(forStep: "parseCache.prewarm"), "[off-main]")   // the memo's background parse is not click work
        XCTAssertEqual(MdSpeedReport.tag(forStep: "parseCache.scan"), "[off-main]")
        XCTAssertEqual(MdSpeedReport.tag(forStep: "parseCache.lookup"), "[main]")
        XCTAssertEqual(MdSpeedReport.otherSpanRows(lines, zero: 1_000), [MdSpeedSpanRow(name: "contentPush", startMs: 1_000, tookMs: 30, detail: "")])
        XCTAssertEqual(MdSpeedReport.marks(lines, zero: 1_000), [MdSpeedMark(step: "job task started", atMs: 1_100)])
        XCTAssertEqual(
            MdSpeedReport.events(lines, zero: 1_000),
            [
                MdSpeedEvent(kind: "main-stall", endMs: 700, durationMs: 250),
                MdSpeedEvent(kind: "wake-work", endMs: 800, durationMs: 700),
                MdSpeedEvent(kind: "ui-update", endMs: 900, durationMs: 90)
            ])
        let jobLines = [
            trace(1_000, "click-start type=none"),
            trace(1_100, "start md-speed delete jobStart"),
            trace(1_400, "job task started"),
            trace(1_450, "onReserved fired"),
            trace(1_700, "end md-speed delete jobStart took=600ms")
        ].compactMap { $0 }
        let gaps = MdSpeedReport.gapLines(
            command: "delete", spans: MdSpeedReport.spanRows(jobLines, zero: 1_000), marks: MdSpeedReport.marks(jobLines, zero: 1_000))
        XCTAssertEqual(gaps.count, 2, "the jobStart gap and the click-to-first-line gap; the other gaps lack their spans: \(gaps)")
        XCTAssertTrue(gaps[0].contains("300 ms until the job's Task began"), gaps[0])
        XCTAssertTrue(gaps[0].contains("50 ms of the job's own synchronous steps"), gaps[0])
        XCTAssertTrue(gaps[0].contains("250 ms until the click's continuation"), gaps[0])
    }
}

// MARK: - Starting a scenario

extension WriteQueuePhase4cMdSpeedMeasureE2ETests {
    /// The twelve-chapter book, launched and switched to Markdown, with the block count read. False after a reported failure.
    func startMarkdown(method: String, flat: [Int] = [], memo: Bool = true) -> Bool {
        let env = memo ? [:] : Self.noMemoEnvironment
        guard mdSpeedLaunchBook(method: method, size: .book12, flat: flat, env: env, markdown: true) else { return false }
        blocksBefore = dbInt("SELECT count(*) FROM block;") ?? -1
        startedAt = Date()
        return true
    }
}

extension Phase4bDelHarness {
    /// How long the wait for the hold's release and the settle may take. It only bounds a failing run.
    static let mdSpeedSettleTimeout: TimeInterval = 300
    /// The app writes timeline lines for 30 s after the op starts and watches stalls for 10 s; the log is read at least this long.
    static let mdSpeedMinimumWatchSeconds: TimeInterval = 14

    /// Seeds the generated book of `size` (with the sub-headings of `flat` chapters turned into plain lines), launches it with the extra
    /// launch environment `env`, waits for the load and, for `markdown`, switches to Markdown (waiting for the Markdown page to finish loading,
    /// then for the log to go quiet after the switch). The log follower's start is noted in `evidenceLogStart`. False after a reported failure.
    func mdSpeedLaunchBook(
        method: String, size: Phase4bDelSize, flat: [Int] = [], env: [String: String] = [:], markdown: Bool
    ) -> Bool {
        begin(method: method, size: size)
        if !flat.isEmpty, let generated = doc {
            let flattened = WriteQueuePhase4bMarkdownEFE2ETests.flattening(generated, chapters: flat)
            doc = flattened
            note("SEED: chapters \(flat) flattened (no sub-headings); \(flattened.counts.reportLine)")
        } else {
            note("SEED: the generated document, NOT flattened (the full outline)")
        }
        for (key, value) in env.sorted(by: { $0.key < $1.key }) {
            app.launchEnvironment[key] = value
            note("SEAM \(key)=\(value)")
        }
        guard launchScenario(), requireSectionRows() != nil else { return false }
        tail.poll()
        evidenceLogStart = tail.lines.count
        guard !markdown || mdSpeedSwitchToMarkdown() else { return false }
        return true
    }

    // `markdownPageReadyLogLine` and `waitForMarkdownPageReady(from:)` moved to the shared harness (`Phase4bDelHarness`,
    // WriteQueuePhase4bDeleteE2ETests.swift) in Phase 5 job A5, so every class that switches to Markdown can wait for the page (t-55b63c87).

    /// Switches the editor to Markdown with Cmd-/ (the View menu's "Switch to Markdown"), pressed ONCE, then waits for the badge and for the
    /// Markdown page to finish loading (`waitForMarkdownPageReady`).
    func mdSpeedSwitchToMarkdown() -> Bool {
        let mode = app.buttons["status-bar-editor-mode"]
        guard mode.waitForExistence(timeout: 10) else { fail("the editor-mode button never appeared"); return false }
        if mode.label != "Markdown" {
            app.activateAndWaitForForeground()
            tail.poll()
            let switchFrom = tail.lines.count
            app.typeKey("/", modifierFlags: .command)
            guard mode.waitForLabel("== 'Markdown'", timeout: size.operationTimeout * 2) else {
                fail("the editor-mode button never reported Markdown after the toggle keystroke (it reads \(mode.label))")
                return false
            }
            guard waitForMarkdownPageReady(from: switchFrom) else { return false }
        }
        let quiet = waitForLogQuiet(quiet: 3, cap: capped(60))
        note("MODE: Markdown; the app's log was quiet for 3 s after the switch: \(Self.yesNo(quiet))")
        return true
    }

    /// The app's UI-testing Delete trigger (`UITestingDeleteTrigger`): the same entry point the menu action runs, with no menu click.
    func mdSpeedPostDeleteTrigger(title: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.kerim.final-final.uitest.deleteSection"), object: nil, userInfo: ["title": title], deliverImmediately: true)
    }

    /// The sidebar card titled exactly `title` (scoped to the Outline's scroll view, never the editor's mirror of a heading).
    func mdSpeedCard(_ title: String) -> XCUIElement {
        app.groups["outline-sidebar"].scrollViews.firstMatch.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", title, title)).firstMatch
    }

    /// Scrolls the sidebar so the union of the cards sits about 30 percent down the visible band. The wheel's sign is checked by where the
    /// card went and corrected once, as `bringSidebarCardIntoView` does. False (reported) when the cards do not all fit inside the band.
    func mdSpeedBringIntoView(_ titles: [String]) -> [XCUIElement]? {
        guard let first = bringSidebarCardIntoView(titles[0]) else { return nil }
        var cards = [first]
        for title in titles.dropFirst() {
            let other = mdSpeedCard(title)
            guard other.waitForExistence(timeout: 10) else { fail("TEST-SETUP: the sidebar has no card \"\(title)\""); return nil }
            cards.append(other)
        }
        let scroll = app.groups["outline-sidebar"].scrollViews.firstMatch
        let band = scroll.frame.insetBy(dx: 0, dy: 20)
        func union() -> CGRect { cards.map(\.frame).reduce(cards[0].frame) { $0.union($1) } }
        if !band.contains(union()) {
            let wanted = union().midY - scroll.frame.midY
            let before = cards[0].frame.midY
            scroll.scroll(byDeltaX: 0, deltaY: -wanted)
            app.waitForStableFrame(cards[0])
            if cards[0].exists, (cards[0].frame.midY - before) * (-wanted) < 0 {
                scroll.scroll(byDeltaX: 0, deltaY: wanted * 2)
                app.waitForStableFrame(cards[0])
            }
        }
        note("SIDEBAR: cards \(titles.map { "\"\($0.prefix(30))\"" }) span \(Self.describeFrame(union())); band \(Self.describeFrame(band)); "
            + "all inside: \(Self.yesNo(band.contains(union())))")
        guard band.contains(union()) else {
            fail("TEST-SETUP: the cards \(titles) are not all inside the sidebar's visible band, so one drag cannot reach from one to the other")
            return nil
        }
        return cards
    }

    /// Scrolls the sidebar so `card` sits 30 percent down the visible band (room for the menu). Checked once, as above.
    func mdSpeedPlaceCardHigh(_ card: XCUIElement) {
        let scroll = app.groups["outline-sidebar"].scrollViews.firstMatch
        let band = scroll.frame
        guard let start = (try? card.snapshot())?.frame else { return }
        let wanted = start.midY - (band.minY + band.height * 0.3)
        guard abs(wanted) > 20 else { return }
        scroll.scroll(byDeltaX: 0, deltaY: -wanted)
        app.waitForStableFrame(card)
        if card.exists, (card.frame.midY - start.midY) * (-wanted) < 0 {
            scroll.scroll(byDeltaX: 0, deltaY: wanted * 2)
            app.waitForStableFrame(card)
        }
    }
}

// MARK: - The three commands

extension WriteQueuePhase4cMdSpeedMeasureE2ETests {
    /// Delete Section twice (Chapter 6, then Chapter 4), each started by the app's own trigger.
    func runDelete(method: String, sampled: Bool, memo: Bool = true) {
        guard startMarkdown(method: method, memo: memo) else { return }
        var blocksPrevious = blocksBefore
        for (index, title) in [size.deleteTitle, Self.secondDeleteTitle].enumerated() {
            let number = index + 1
            let driven = mdDeleteOnce(number: number, title: title, mode: Self.mode(sampled: sampled, memo: memo), sampled: sampled)
            mdSpeedPrintGated(command: .delete, number: number, analysis: driven.analysis, memo: memo)
            let done = driven.done
            let gone = driven.effectOk
            let blocksAfter = waitForBlocksToSettle()
            assertCheck(done.released, "Delete #\(number): the writer's hold was released")
            assertCheck(done.settled, "Delete #\(number): the settle after the hold ended")
            assertCheck(gone, "Delete #\(number): the heading \"\(title)\" is gone from the block table")
            assertCheck(blocksPrevious > 0 && blocksAfter > 0 && blocksAfter < blocksPrevious,
                        "Delete #\(number): the document is intact: \(blocksPrevious) block rows before, \(blocksAfter) after (fewer, not empty)")
            blocksPrevious = blocksAfter
        }
    }

    /// Duplicate Section twice ("3.6 Conclusion", then "8.6 Conclusion"), each by the menu click.
    func runDuplicate(method: String, sampled: Bool, memo: Bool = true) {
        guard startMarkdown(method: method, memo: memo) else { return }
        var blocksPrevious = blocksBefore
        for (index, title) in Self.duplicateTitles.enumerated() {
            let number = index + 1
            guard let driven = mdDuplicateOnce(number: number, title: title, mode: Self.mode(sampled: sampled, memo: memo), sampled: sampled)
            else { return }
            mdSpeedPrintGated(command: .duplicate, number: number, analysis: driven.analysis, memo: memo)
            let done = driven.done
            let twice = driven.effectOk
            let blocksAfter = waitForBlocksToSettle()
            assertCheck(done.released, "Duplicate #\(number): the writer's hold was released")
            assertCheck(done.settled, "Duplicate #\(number): the settle after the hold ended")
            assertCheck(twice, "Duplicate #\(number): the block table holds \"\(title)\" and its copy (two headings containing it)")
            assertCheck(
                blocksAfter > blocksPrevious,
                "Duplicate #\(number): the document is intact: \(blocksPrevious) block rows before, \(blocksAfter) after (more)")
            blocksPrevious = blocksAfter
        }
    }

    /// The Outline drag twice (an Option-drag of Chapter 9 with its sub-sections, then of Chapter 11), neither sampled.
    func runDrag(method: String, memo: Bool = true) {
        guard startMarkdown(method: method, flat: Self.flatChapters, memo: memo) else { return }
        for (index, drag) in Self.drags.enumerated() {
            let number = index + 1
            guard let driven = mdDragOnce(number: number, drag: drag, mode: Self.mode(sampled: false, memo: memo)) else { return }
            mdSpeedPrintGated(command: .drag, number: number, analysis: driven.analysis, memo: memo)
            let done = driven.done
            let before = driven.effectOk
            let carried = driven.carriedOk
            let blocksAfter = waitForBlocksToSettle()
            assertCheck(done.released, "Drag #\(number): the writer's hold was released")
            assertCheck(done.settled, "Drag #\(number): the settle after the hold ended")
            assertCheck(before, "Drag #\(number): \"\(drag.moved)\" is now above \"\(drag.before)\" in the block table")
            assertCheck(
                carried, "Drag #\(number): the heading after \"\(drag.moved)\" is its own first sub-section (the Option key carried the subtree)")
            assertCheck(
                blocksBefore > 0 && blocksAfter == blocksBefore,
                "Drag #\(number): the document is intact: \(blocksBefore) block rows before, \(blocksAfter) after")
        }
    }

}

// MARK: - One driven click (shared with WriteQueuePhase4cMdSpeedE2ETests)

extension Phase4bDelHarness {
    /// Delete Section of the card titled `title`, started by the app's own UI-testing trigger (no menu click), followed to the settle's end
    /// and reported. With `sampled` the stack sampler is started right after the trigger.
    func mdDeleteOnce(number: Int, title: String, mode: MdSpeedMode, sampled: Bool) -> MdSpeedDriven {
        let command = MdSpeedCommand.delete
        app.activateAndWaitForForeground()
        tail.poll()
        let from = tail.lines.count
        if firstTriggerIndex == nil { firstTriggerIndex = from }
        let sampleLabel = "MEASURE \(command.word) \(number) sampled"
        let sample = sampled ? Phase4bMainThreadSample(label: sampleLabel) : nil
        if let sample { mainThreadSamples[sampleLabel] = sample }
        let triggered = Date()
        mdSpeedPostDeleteTrigger(title: title)
        sample?.start()
        let done = mdSpeedFollowUntilSettled(command: command, from: from, triggered: triggered)
        if sampled { mdSpeedAttachSample(label: sampleLabel) }
        let gone = waitForHeadingRows(title, equalTo: 0, timeout: capped(size.operationTimeout)) == 0
        let analysis = mdSpeedReport(command: command, number: number, from: from, followed: done, mode: mode)
        return MdSpeedDriven(analysis: analysis, done: done, effectOk: gone)
    }

    /// Duplicate Section of the card titled `title`, by the menu click, followed to the settle's end and reported. With `sampled` the stack
    /// sampler is started just before the click on the already-found menu item. Nil after a reported set-up failure.
    func mdDuplicateOnce(number: Int, title: String, mode: MdSpeedMode, sampled: Bool) -> MdSpeedDriven? {
        let command = MdSpeedCommand.duplicate
        guard let target = bringSidebarCardIntoView(title) else { return nil }
        mdSpeedPlaceCardHigh(target)
        app.activateAndWaitForForeground()
        tail.poll()
        let from = tail.lines.count
        if firstTriggerIndex == nil { firstTriggerIndex = from }
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        let item = app.menuItem(titleStartingWith: "Duplicate Section")
        let sampleLabel = "MEASURE \(command.word) \(number) sampled"
        let sample = sampled ? Phase4bMainThreadSample(label: sampleLabel) : nil
        if let sample { mainThreadSamples[sampleLabel] = sample }
        let samplerStarted = Date()
        sample?.start()
        let triggered = Date()
        item.click()
        var shown = mode
        if sampled { shown.samplerLeadMs = Int((triggered.timeIntervalSince(samplerStarted) * 1000).rounded()) }
        let done = mdSpeedFollowUntilSettled(command: command, from: from, triggered: triggered)
        if sampled { mdSpeedAttachSample(label: sampleLabel) }
        let twice = waitForHeadingRows(title, equalTo: 2, timeout: capped(size.operationTimeout)) == 2
        let analysis = mdSpeedReport(command: command, number: number, from: from, followed: done, mode: shown)
        return MdSpeedDriven(analysis: analysis, done: done, effectOk: twice)
    }

    /// One Option-drag of `drag.moved` (with its sub-sections) to just before `drag.before`, followed to the settle's end and reported.
    /// Nil after a reported set-up failure.
    func mdDragOnce(number: Int, drag: MdSpeedDrag, mode: MdSpeedMode) -> MdSpeedDriven? {
        let command = MdSpeedCommand.drag
        let scroll = app.groups["outline-sidebar"].scrollViews.firstMatch
        guard let cards = mdSpeedBringIntoView([drag.moved, drag.dropOn]) else { return nil }
        let zones = CGFloat(drag.dropOnLevel + 1)
        let screenX = scroll.frame.minX + 0.5 * scroll.frame.width / zones   // level 1: the first of the card's horizontal zones
        let dropPoint = cards[1].coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: screenX - cards[1].frame.minX, dy: 0))
        guard scroll.frame.contains(dropPoint.screenPoint) else {
            fail("TEST-SETUP: the drop point \(dropPoint.screenPoint) lies outside the sidebar \(Self.describeFrame(scroll.frame))")
            return nil
        }
        note("DRAG \(number): \"\(drag.moved.prefix(40))\" with its sub-sections (Option) to just before "
            + "\"\(drag.before.prefix(40))\", dropped on \"\(drag.dropOn)\"; pointer ends at \(dropPoint.screenPoint)")
        app.activateAndWaitForForeground()
        tail.poll()
        let from = tail.lines.count
        if firstTriggerIndex == nil { firstTriggerIndex = from }
        let triggered = Date()
        let grab = cards[0].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        XCUIElement.perform(withKeyModifiers: .option) {
            grab.press(forDuration: 0.5, thenDragTo: dropPoint, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        let done = mdSpeedFollowUntilSettled(command: command, from: from, triggered: triggered)
        let before = mdSpeedWaitForHeading(drag.moved, above: drag.before, timeout: capped(size.operationTimeout))
        let carried = mdSpeedWaitForHeadingAfter(drag.moved, contains: drag.firstSubSection, timeout: capped(size.operationTimeout))
        let analysis = mdSpeedReport(command: command, number: number, from: from, followed: done, mode: mode)
        return MdSpeedDriven(analysis: analysis, done: done, effectOk: before, carriedOk: carried)
    }

    /// True once the heading right after the one titled `title` in the block table contains `next` (a condition, polled).
    func mdSpeedWaitForHeadingAfter(_ title: String, contains next: String, timeout: TimeInterval) -> Bool {
        let escaped = FixtureDatabase.escape(title)
        let sql = "SELECT markdownFragment FROM block WHERE blockType = 'heading' AND sortOrder > "
            + "(SELECT sortOrder FROM block WHERE blockType = 'heading' AND instr(markdownFragment, '# \(escaped)') > 0 LIMIT 1) "
            + "ORDER BY sortOrder LIMIT 1;"
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if dbText(sql).contains(next) { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return false
    }

    /// True once the heading titled `upper` sorts before the one titled `lower` in the block table (a condition, polled).
    func mdSpeedWaitForHeading(_ upper: String, above lower: String, timeout: TimeInterval) -> Bool {
        func order(_ title: String) -> String {
            "(SELECT sortOrder FROM block WHERE blockType = 'heading' AND instr(markdownFragment, '# \(FixtureDatabase.escape(title))') > 0 LIMIT 1)"
        }
        let sql = "SELECT \(order(upper)) < \(order(lower));"
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if dbText(sql) == "1" { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return false
    }
}

// MARK: - Following the log

extension Phase4bDelHarness {
    /// Reads only the app's log (no accessibility query) until the writer's hold is released AND the command's settle span has ended, then
    /// until the log has been quiet for 3 s and the app's 30 s-window trace has had `minimumWatchSeconds` since `triggered`.
    func mdSpeedFollowUntilSettled(command: MdSpeedCommand, from: Int, triggered: Date) -> MdSpeedFollow {
        var seen = MdSpeedFollow()
        let deadline = Date(timeIntervalSinceNow: Self.mdSpeedSettleTimeout)
        repeat {
            tail.poll()
            let window = tail.lines[min(from, tail.lines.count)...]
            seen.released = window.contains { $0.text.contains("[MdWrite] structural hold released") }
            seen.settled = window.contains { $0.text.contains("end md-speed \(command.word) settle took=") }
            if seen.released, seen.settled,
               Date().timeIntervalSince(triggered) >= Self.mdSpeedMinimumWatchSeconds,
               Date().timeIntervalSince(tail.lastIngest) >= 3 {
                return seen
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        note("FOLLOW: gave up after \(Int(Self.mdSpeedSettleTimeout)) s: hold released \(Self.yesNo(seen.released)), "
            + "settle ended \(Self.yesNo(seen.settled))")
        return seen
    }

    /// Finishes the click's stack sample (its 5 s are long over), attaches its output and reports where it went. Never fails the test.
    func mdSpeedAttachSample(label: String) {
        guard let sample = mainThreadSamples.removeValue(forKey: label) else {
            result("\(label): SAMPLE not taken (no sample was started)")
            return
        }
        switch sample.finish() {
        case .taken(let attachments):
            let name = Phase4bSampleFile.attachmentName(label: label, topOfStackOnly: false)
            attachText(name, attachments.main)
            var line = "\(label): SAMPLE \(attachments.main.utf8.count) bytes in the attachment \(name)"
            if let topOfStack = attachments.topOfStack {
                let topName = Phase4bSampleFile.attachmentName(label: label, topOfStackOnly: true)
                attachText(topName, topOfStack)
                line += "; \(topOfStack.utf8.count) bytes in the attachment \(topName)"
            }
            result(line)
        case .notTaken(let reason):
            result("\(label): SAMPLE not taken (\(reason))")
        }
    }
}

// MARK: - The report

extension Phase4bDelHarness {
    /// Prints the report block of one click (one `RESULT MEASURE <command> #<n>:` line each) and attaches it as
    /// `md-speed-measure-<command>-<n>-<mode>-book12.txt`.
    @discardableResult
    func mdSpeedReport(command: MdSpeedCommand, number: Int, from: Int, followed: MdSpeedFollow, mode: MdSpeedMode) -> MdSpeedClickAnalysis {
        tail.poll()
        let window = Array(tail.lines[min(from, tail.lines.count)...])
        let traces = window.compactMap { Phase4bDelTraceLine($0) }
        var analysis = MdSpeedClickAnalysis(window: window)
        var block: [String] = []
        func add(_ line: String) { block.append(line) }
        let sampler = mode.samplerLeadMs.map { "; the sampler was started \($0) ms (test clock) before the click call" } ?? ""
        add("MODE  \(mode.detail ?? mode.name)" + sampler)
        guard let zeroIndex = window.firstIndex(where: { line in
            Phase4bDelTraceLine(line).map { $0.family == .timeline && $0.label == command.timelineLabel && command.isZeroStep($0.step) } ?? false
        }), let zeroTrace = Phase4bDelTraceLine(window[zeroIndex]) else {
            add("ZERO  no \(command == .drag ? "`md-speed drag drop-received`" : "`click-start`") line for \(command.timelineLabel) in the "
                + "\(window.count) log line(s) after the command (\(traces.count) of them trace lines): the app wrote no timeline")
            analysis.block = block
            mdSpeedEmit(block, command: command, number: number, mode: mode.name)
            return analysis
        }
        analysis.found = true
        analysis.zeroIndex = zeroIndex
        let zero = zeroTrace.t
        add("ZERO  t=\(zero) ms on the app clock: \"\(zeroTrace.step)\" (every offset below counts from here)")
        let spans = MdSpeedReport.spanRows(traces, zero: zero)
        let marks = MdSpeedReport.marks(traces, zero: zero)
        analysis.spans = spans
        analysis.marks = marks
        for row in spans { add(MdSpeedReport.stepLine(row)) }
        for row in MdSpeedReport.otherSpanRows(traces, zero: zero) { add(MdSpeedReport.spanLine(row)) }
        for mark in marks { add("MARK  +\(MdSpeedReport.pad(mark.atMs, 6)) ms  \(mark.step)") }
        for line in MdSpeedReport.gapLines(command: command.word, spans: spans, marks: marks) { add(line) }

        // The three figures of testMdTiming_book12, from the log stamps (the click's own time is its stamp minus the event's age).
        let age = Phase4bDelTypingParser.intAfter("age=", in: zeroTrace.step) ?? 0
        analysis.ageMs = age
        let zeroWall = window[zeroIndex].date.map { $0.addingTimeInterval(-Double(age) / 1000) }
        func stampMs(_ line: Phase4bLogLine?) -> Int? {
            guard let zeroWall, let date = line?.date else { return nil }
            return Int((date.timeIntervalSince(zeroWall) * 1000).rounded())
        }
        func figure(_ value: Int?) -> String { value.map { "\($0) ms" } ?? "n/a" }
        let after = window[(zeroIndex + 1)...]
        let raised = after.first { $0.text.contains("[MdWrite] structural hold raised") }
        var outline: Phase4bLogLine?
        var released: Phase4bLogLine?
        if let raised, let raisedAt = window.firstIndex(where: { $0.stamp == raised.stamp && $0.text == raised.text }) {
            outline = window[(raisedAt + 1)...].first { $0.text.contains("[SidebarBody]") }
            released = window[(raisedAt + 1)...].first { $0.text.contains("[MdWrite] structural hold released") }
        }
        analysis.holdRaisedFromEventMs = stampMs(raised)
        analysis.outlineFromEventMs = stampMs(outline)
        analysis.releasedFromEventMs = stampMs(released)
        add("FIGURES (log stamps, as testMdTiming_book12 computes them): click to hold raised \(figure(stampMs(raised))); "
            + "click to the first Outline render [SidebarBody] after it \(figure(stampMs(outline))); "
            + "click to hold released \(figure(stampMs(released))); click-start event age \(age) ms; "
            + "first Outline render [SidebarBody] after ZERO \(figure(stampMs(after.first { $0.text.contains("[SidebarBody]") })))")

        let events = MdSpeedReport.events(traces, zero: zero)
        analysis.events = events
        for event in events { add(MdSpeedReport.eventLine(event)) }
        let stalls = events.filter { $0.kind == "main-stall" }
        add("STALL TOTAL main-stall: \(stalls.count) stall(s), total \(stalls.reduce(0) { $0 + $1.durationMs }) ms, "
            + "longest \(stalls.map(\.durationMs).max() ?? 0) ms")

        for line in mdSpeedSpellAndMessageLines(spans: spans, command: command.word) { add(line) }
        let prepared = mdSpeedPrepareLines(window: window, spans: spans, zero: zero, zeroWall: zeroWall)
        for line in prepared.lines { add(line) }
        analysis.prepare = prepared.parsed
        let notices = window[zeroIndex...].filter { $0.text.contains("[toast] show") && $0.text.contains("Finishing the last change") }.count
        add("NOTICES \"Finishing the last change\" shown: \(notices)")
        add("DONE  hold released: \(Self.yesNo(followed.released)); settle ended: \(Self.yesNo(followed.settled)); "
            + "trace lines in the window: \(traces.count); log lines: \(window.count)")
        analysis.block = block
        mdSpeedEmit(block, command: command, number: number, mode: mode.name)
        return analysis
    }

    /// The SPELL and MESSAGES lines: counts and durations of the spell-check calls and of the editor's content messages, and how many
    /// spell-check calls began before the command's own `click` span ended (inside the click window).
    func mdSpeedSpellAndMessageLines(spans: [MdSpeedSpanRow], command: String) -> [String] {
        let clickEnd = spans.first { $0.name == "\(command) click" }?.endMs
        let spell = MdSpeedReport.summary(of: spans, step: "spellcheck.check", command: command)
        let spellRows = spans.filter { $0.name == "\(command) spellcheck.check" }
        let beforeClickEnd = spellRows.filter { row in clickEnd.map { row.startMs < $0 } ?? false }.count
        var lines = ["SPELL calls=\(spell.count) total=\(spell.totalMs) ms longest=\(spell.longestMs) ms; began before the click returned"
            + " (+\(clickEnd.map(String.init) ?? "n/a") ms): \(beforeClickEnd)"]
        for kind in ["contentChanged", "sectionChanged", "selectionChanged"] {
            let rows = MdSpeedReport.summary(of: spans, step: "contentMessage.\(kind)", command: command)
            lines.append("MESSAGES \(kind): count=\(rows.count) total=\(rows.totalMs) ms longest=\(rows.longestMs) ms")
        }
        return lines
    }

    /// The PREPARE lines. Each `writer.prepare.<trigger>` span is a call of the writer's parse and diff; each `[MdWrite] mode=` line is
    /// matched to the latest preceding call that no earlier line has claimed (a call that wrote nothing claims no line), and the call is
    /// named by its trigger and, for a `writeNow`, by the call-site span that was open around it.
    func mdSpeedPrepareLines(
        window: [Phase4bLogLine], spans: [MdSpeedSpanRow], zero: Int, zeroWall: Date?
    ) -> (lines: [String], parsed: [MdSpeedPrepareLine]) {
        struct Call {
            let trigger: String
            let via: String
        }
        var lines: [String] = []
        var parsed: [MdSpeedPrepareLine] = []
        var unclaimed: [Call] = []
        var calls = 0
        let sites = spans.filter { $0.step.hasPrefix("writer.writeNow.") }
        for line in window {
            if let trace = Phase4bDelTraceLine(line), trace.family == .timeline, trace.step.hasPrefix("start md-speed "),
               let range = trace.step.range(of: " writer.prepare.") {
                let trigger = String(trace.step[range.upperBound...])
                let offset = trace.t - zero
                let site = sites.first { row in row.startMs <= offset && (row.endMs ?? Int.max) >= offset }
                let via: String
                switch trigger {
                case "structuralClick": via = "prepareStructuralClick (the reply turn)"
                case "structuralFlush": via = "step 8's reserveStructuralFlush"
                case "debounceFire": via = "the re-parse debounce fire"
                default: via = site?.step ?? "an unnamed caller"
                }
                unclaimed.append(Call(trigger: trigger, via: via))
                calls += 1
                lines.append("PREPARE CALL #\(calls) at +\(offset) ms: trigger=\(trigger) via \(via)")
            } else if line.text.contains("[MdWrite] mode=") {
                let text = line.text.range(of: "[MdWrite]").map { String(line.text[$0.lowerBound...]) } ?? line.text
                let call = unclaimed.popLast()
                let caller = call.map { "trigger=\($0.trigger) via \($0.via)" } ?? "NO PRECEDING CALL SPAN"
                let wall = zeroWall.flatMap { start in line.date.map { Int(($0.timeIntervalSince(start) * 1000).rounded()) } }
                lines.append("PREPARE LINE +\(wall.map(String.init) ?? "n/a") ms after the click, caller: \(caller): \(text)")
                parsed.append(MdSpeedPrepareLine(trigger: call?.trigger ?? "?", via: call?.via ?? "no preceding call span", text: text))
            }
        }
        return (lines, parsed)
    }

    /// Prints the Fast class's per-click evidence line for the A/B family: `RESULT SPEED <command>-memo #<n>: GATED ...` (the parse memo ON) or
    /// `<command>-nomemo` (OFF), so the driver can compare the untouched steps ON versus OFF from the log. Prints, asserts nothing.
    func mdSpeedPrintGated(command: MdSpeedCommand, number: Int, analysis: MdSpeedClickAnalysis, memo: Bool) {
        let evidence = MdSpeedJudge.gatedEvidenceLine(
            command: command, analysis: analysis, references: MdSpeedLimits.references(for: command),
            floorMs: MdSpeedLimits.validityReferenceFloorMs)
        result("SPEED \(command.word)-\(memo ? "memo" : "nomemo") #\(number): \(evidence)")
    }

    /// Writes each line as a `RESULT MEASURE <command> #<n>:` result and attaches the block.
    func mdSpeedEmit(_ block: [String], command: MdSpeedCommand, number: Int, mode: String) {
        let label = "MEASURE \(command.word) #\(number)"
        for line in block { result("\(label): \(line)") }
        let text = block.map { "RESULT \(label): \($0)" }.joined(separator: "\n")
        attachText("md-speed-measure-\(command.word)-\(number)-\(mode)-\(size.identifier).txt", text)
    }
}
