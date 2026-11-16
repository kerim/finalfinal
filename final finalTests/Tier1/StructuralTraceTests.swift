//
//  StructuralTraceTests.swift
//  final finalTests
//
//  Phase 4b part 2, slice 0 (t-94369a83): the helpers behind the measurement-only trace lines (StructuralTrace.swift). The
//  trace changes no behaviour and is silent unless Diagnostics logging is on, so what is worth pinning is what a person reading
//  the log (or the timing e2e parser) relies on: the line formats, which time a delete is measured from, what counts as a
//  main-thread stall, and that nothing is written (or even read from the event) while tracing is off. The recorder tests run
//  their OWN `StructuralTraceRecorder` with an injected switch, clock and sink, never the app-wide `StructuralTrace.shared`, so
//  they cannot interfere with, or be interfered with by, other tests. Every expected value is worked out by hand from the rules,
//  not read back from the code.
//

import Testing
import AppKit
import Foundation
@testable import final_final

@Suite("StructuralTrace helpers -- slice 0 measurement")
struct StructuralTraceTests {

    // MARK: - Line formats

    @Test("a [STRUCT-TRACE] line keeps today's format: t, +since-start, label, op, step")
    func structLineFormat() {
        let line = StructuralTrace.structLine(t: 123_456, since: 789, label: "sectionDelete", opId: "ABCD1234", step: "after modeAwareFlush")
        #expect(line == "[STRUCT-TRACE] t=123456ms +789ms sectionDelete op=ABCD1234 after modeAwareFlush")
    }

    @Test("the lines this file adds count from the timeline start, with a label the old lines' parser cannot read as its own base")
    func timelineLineFormat() {
        let line = StructuralTrace.timelineLine(
            t: 123_456, since: 789, label: "sectionDelete", opId: "ABCD1234", step: "end snapshot.fetchBlocks took=312ms"
        )
        #expect(line == "[STRUCT-TRACE] t=123456ms +timeline=789ms sectionDelete op=ABCD1234 end snapshot.fetchBlocks took=312ms")
        #expect(!line.contains(" +789ms "))
    }

    @Test("the click-start step says what kind of event was timed and how old it was")
    func clickStartStepFormat() {
        #expect(StructuralTrace.clickStartStep(eventType: "leftMouseUp", ageMs: 12) == "click-start type=leftMouseUp age=12ms")
        #expect(StructuralTrace.clickStartStep(eventType: nil, ageMs: nil) == "click-start type=none")
    }

    @Test("event types are named for the click-start line")
    func eventTypeNames() {
        #expect(StructuralTrace.eventTypeName(.leftMouseUp) == "leftMouseUp")
        #expect(StructuralTrace.eventTypeName(.rightMouseDown) == "rightMouseDown")
        #expect(StructuralTrace.eventTypeName(.keyDown) == "keyDown")
        // NSEvent.EventType.scrollWheel has raw value 22; a type with no name of its own is shown by that number.
        #expect(StructuralTrace.eventTypeName(.scrollWheel) == "other22")
    }

    @Test("a key line carries the time, the key code, and whether the key went to the editor")
    func keyLineFormat() {
        #expect(StructuralTrace.keyLine(t: 1_000, code: 6, inEditor: true) == "[TYPING-TRACE] key t=1000 code=6 editor=true")
        #expect(StructuralTrace.keyLine(t: 2_000, code: 53, inEditor: false) == "[TYPING-TRACE] key t=2000 code=53 editor=false")
    }

    @Test("an echo line says how many edits it covers; an echo without a count leaves it out")
    func echoLineFormat() {
        #expect(StructuralTrace.echoLine(t: 1_042, edits: 3) == "[TYPING-TRACE] echo t=1042 n=3")
        #expect(StructuralTrace.echoLine(t: 1_042, edits: nil) == "[TYPING-TRACE] echo t=1042")
    }

    @Test("an event timestamp in seconds since boot becomes whole milliseconds on the same clock")
    func eventTimestampToMs() {
        #expect(StructuralTrace.ms(ofEventTimestamp: 12.3456) == 12_345)
        #expect(StructuralTrace.ms(ofEventTimestamp: 0) == 0)
    }

    @Test("the editor's rebuild-replaced-pending message becomes the documented line")
    func rebuildReplacedPendingLine() {
        let body: [String: Any] = ["event": "rebuild-replaced-pending", "kind": "notes", "block": "B-17"]
        #expect(StructuralTrace.rebuildReplacedPendingLine(body: body, t: 5_000)
            == "[TYPING-TRACE] rebuild-replaced-pending kind=notes block=B-17 t=5000")
        // The editor says "unknown" when the push did not name its kind; that is a valid kind to log.
        let unknown: [String: Any] = ["event": "rebuild-replaced-pending", "kind": "unknown", "block": "B-18"]
        #expect(StructuralTrace.rebuildReplacedPendingLine(body: unknown, t: 6_000)
            == "[TYPING-TRACE] rebuild-replaced-pending kind=unknown block=B-18 t=6000")
    }

    @Test("a typingTrace message that is not a complete rebuild-replaced-pending event writes no line")
    func rebuildReplacedPendingLineRejectsOtherBodies() {
        #expect(StructuralTrace.rebuildReplacedPendingLine(body: ["event": "something-else", "kind": "notes", "block": "B-1"], t: 1) == nil)
        #expect(StructuralTrace.rebuildReplacedPendingLine(body: ["event": "rebuild-replaced-pending", "block": "B-1"], t: 1) == nil)
        #expect(StructuralTrace.rebuildReplacedPendingLine(body: ["event": "rebuild-replaced-pending", "kind": "notes"], t: 1) == nil)
        #expect(StructuralTrace.rebuildReplacedPendingLine(body: ["event": "rebuild-replaced-pending", "kind": "", "block": "B-1"], t: 1) == nil)
        #expect(StructuralTrace.rebuildReplacedPendingLine(body: [:], t: 1) == nil)
    }

    // MARK: - What is sent to the editor

    @Test("with tracing off, the JS call carries no traceKind option, whatever the rebuild kind; with it on, it names the kind")
    func traceKindOptionOnlyWhileTracing() {
        for kind in [StructuralTrace.RebuildKind.notes, .bibliography, .footnote] {
            #expect(StructuralTrace.traceKindOption(kind, tracingOn: false) == nil)
        }
        #expect(StructuralTrace.traceKindOption(nil, tracingOn: true) == nil)
        #expect(StructuralTrace.traceKindOption(.notes, tracingOn: true) == "traceKind: `notes`")
        #expect(StructuralTrace.traceKindOption(.footnote, tracingOn: true) == "traceKind: `footnote`")
    }

    @Test("the script that arms the editor's typing trace names setTraceTyping, for on and for off")
    func editorTraceFlagScriptNamesTheEditorFunction() {
        #expect(StructuralTrace.editorTraceFlagScript(on: true) == "window.FinalFinal.setTraceTyping?.(true)")
        #expect(StructuralTrace.editorTraceFlagScript(on: false) == "window.FinalFinal.setTraceTyping?.(false)")
    }

    @MainActor
    @Test("a key that goes to a plain view, or to nothing, is not an editor key")
    func isInsideWebViewFalseOutsideAWebView() {
        let parent = NSView(frame: .zero)
        let child = NSView(frame: .zero)
        parent.addSubview(child)
        #expect(!StructuralTrace.isInsideWebView(nil))
        #expect(!StructuralTrace.isInsideWebView(child))
    }

    // MARK: - Where a delete's timeline starts

    @Test("a delete starts at the menu click, not at the later entry of the Swift sequence")
    func opStartsAtThePendingClick() {
        let start = StructuralTrace.opStartMs(now: 10_250, label: "sectionDelete", pendingClick: (label: "sectionDelete", ms: 10_000))
        #expect(start == 10_000)
    }

    @Test("a click for a different op, a stale click, and no click all start the op at the moment it begins")
    func opStartsNowWithoutAMatchingFreshClick() {
        // Undo has no menu click of its own: a pending Delete click must not be taken as its start.
        #expect(StructuralTrace.opStartMs(now: 20_000, label: "undo", pendingClick: (label: "sectionDelete", ms: 19_900)) == 20_000)
        // Older than the 10 s a click may wait for its op: 10,001 ms is too old, 10,000 ms is still taken.
        #expect(StructuralTrace.opStartMs(now: 30_001, label: "sectionDelete", pendingClick: (label: "sectionDelete", ms: 20_000)) == 30_001)
        #expect(StructuralTrace.opStartMs(now: 30_000, label: "sectionDelete", pendingClick: (label: "sectionDelete", ms: 20_000)) == 20_000)
        #expect(StructuralTrace.opStartMs(now: 40_000, label: "sectionDuplicate", pendingClick: nil) == 40_000)
    }

    // MARK: - Main-thread stall marker

    @Test("a stall is reported only when the main thread answered more than 50 ms late")
    func stallThreshold() {
        #expect(StructuralTrace.stallToReport(latencyMs: 0) == nil)
        #expect(StructuralTrace.stallToReport(latencyMs: 50) == nil)
        #expect(StructuralTrace.stallToReport(latencyMs: 51) == 51)
        #expect(StructuralTrace.stallToReport(latencyMs: 1_500) == 1_500)
    }

    @Test("the stall marker watches from the op's start until 10 s after it, and no longer")
    func stallWindow() {
        #expect(StructuralTrace.stallWindowIsOpen(nowMs: 100_000, opStartMs: 100_000))
        #expect(StructuralTrace.stallWindowIsOpen(nowMs: 110_000, opStartMs: 100_000))
        #expect(!StructuralTrace.stallWindowIsOpen(nowMs: 110_001, opStartMs: 100_000))
    }
}

// MARK: - The recorder: switch, clock and sink injected

/// A recorder's lines, its clock, and how many times the click was asked for. A class so the injected closures share it.
private final class TraceBox: @unchecked Sendable {
    var lines: [String] = []
    var now = 0
    var clickReads = 0
}

private func makeRecorder(on isOn: Bool, _ box: TraceBox) -> StructuralTraceRecorder {
    StructuralTraceRecorder(isOn: { isOn }, now: { box.now }, emit: { box.lines.append($0) })
}

@Suite("StructuralTraceRecorder -- slice 0 measurement")
struct StructuralTraceRecorderTests {

    @Test("with tracing off, click, begin, log, span and timed write no line and never read the event")
    func offWritesNothing() {
        let box = TraceBox()
        box.now = 5_000
        let recorder = makeRecorder(on: false, box)

        func click() -> StructuralTraceClick? {
            box.clickReads += 1
            return StructuralTraceClick(typeName: "leftMouseUp", timestampMs: 4_990)
        }
        recorder.noteCommandClick(label: "sectionDelete", click: click())
        #expect(recorder.beginOp(label: "sectionDelete", opId: "AAAA0001") == nil)
        recorder.noteOpId("AAAA0002")
        recorder.discardPendingClick(label: "sectionDelete")
        recorder.log("a step")
        let span = recorder.span("sectionSync.syncNow", "detail")
        span.end("detail")
        let result = recorder.timed("snapshot.fetchBlocks") { 42 }

        #expect(result == 42) // the timed body still runs and returns
        #expect(box.lines.isEmpty)
        #expect(box.clickReads == 0)
        #expect(recorder.startMs == nil)
    }

    @Test("beginOp takes the click that chose the menu item as the op's start, and consumes it")
    func beginOpConsumesTheClick() {
        let box = TraceBox()
        let recorder = makeRecorder(on: true, box)

        box.now = 10_012
        recorder.noteCommandClick(label: "sectionDelete", click: StructuralTraceClick(typeName: "leftMouseUp", timestampMs: 10_000))
        #expect(box.lines == ["[STRUCT-TRACE] t=10000ms +timeline=0ms sectionDelete op=-------- click-start type=leftMouseUp age=12ms"])

        box.now = 10_250
        #expect(recorder.beginOp(label: "sectionDelete") == 10_000)
        #expect(recorder.startMs == 10_000)

        box.now = 10_300
        recorder.log("probe")
        #expect(box.lines.last == "[STRUCT-TRACE] t=10300ms +timeline=300ms sectionDelete op=-------- probe")

        // The click was consumed: the next delete without a click of its own starts when it begins.
        box.now = 20_000
        #expect(recorder.beginOp(label: "sectionDelete") == 20_000)
    }

    @Test("a click with no current event is logged as type=none, timed at the moment the action ran")
    func clickWithoutAnEvent() {
        let box = TraceBox()
        let recorder = makeRecorder(on: true, box)
        box.now = 7_000
        recorder.noteCommandClick(label: "sectionDuplicate", click: nil)
        #expect(box.lines == ["[STRUCT-TRACE] t=7000ms +timeline=0ms sectionDuplicate op=-------- click-start type=none"])
    }

    @Test("a click whose op was refused before it began is discarded, so it is not taken as the next op's start")
    func refusedClickIsDiscarded() {
        let box = TraceBox()
        let recorder = makeRecorder(on: true, box)

        box.now = 10_005
        recorder.noteCommandClick(label: "sectionDelete", click: StructuralTraceClick(typeName: "leftMouseUp", timestampMs: 10_000))
        recorder.discardPendingClick(label: "sectionDelete") // what performStructuralOp does on a refusal

        box.now = 12_000 // a second delete 2 s later, well inside the 10 s a click may wait
        #expect(recorder.beginOp(label: "sectionDelete") == 12_000)
    }

    @Test("discarding the click of one kind leaves a pending click of another kind alone")
    func discardIsPerLabel() {
        let box = TraceBox()
        let recorder = makeRecorder(on: true, box)
        box.now = 10_005
        recorder.noteCommandClick(label: "sectionDuplicate", click: StructuralTraceClick(typeName: "leftMouseUp", timestampMs: 10_000))
        recorder.discardPendingClick(label: "sectionDelete")
        box.now = 10_100
        #expect(recorder.beginOp(label: "sectionDuplicate") == 10_000)
    }

    @Test("a late line goes to the MOST RECENT op: its label, its id and its start")
    func lateLinesBelongToTheMostRecentOp() {
        let box = TraceBox()
        let recorder = makeRecorder(on: true, box)

        box.now = 1_000
        recorder.beginOp(label: "sectionDelete", opId: "AAAA0001")
        box.now = 2_000
        recorder.beginOp(label: "undo", opId: "BBBB0002")
        box.now = 2_500
        recorder.log("start notes-rebuild-push chars=100") // caused by the delete, landing after the undo began

        #expect(box.lines == ["[STRUCT-TRACE] t=2500ms +timeline=500ms undo op=BBBB0002 start notes-rebuild-push chars=100"])
    }

    @Test("a span writes start and end, and its end is still written after the 30 s window has closed; a plain line is not")
    func spanEndOutlivesTheWindow() {
        let box = TraceBox()
        let recorder = makeRecorder(on: true, box)

        box.now = 1_000
        recorder.beginOp(label: "sectionDelete", opId: "AAAA0001")
        let span = recorder.span("sectionSync.syncNow")
        box.now = 32_000 // 31 s after the op started: the 30 s window has closed
        span.end()
        recorder.log("a plain line after the window")
        recorder.span("another").end() // started after the window closed: no start, so no end either

        #expect(box.lines == [
            "[STRUCT-TRACE] t=1000ms +timeline=0ms sectionDelete op=AAAA0001 start sectionSync.syncNow",
            "[STRUCT-TRACE] t=32000ms +timeline=31000ms sectionDelete op=AAAA0001 end sectionSync.syncNow took=31000ms"
        ])
    }

    @Test("before any op has begun nothing is written, and a span detail appears on both of its lines")
    func silentBeforeTheFirstOp() {
        let box = TraceBox()
        let recorder = makeRecorder(on: true, box)
        box.now = 500
        recorder.log("too early")
        recorder.span("refreshSectionsAwaiting").end()
        #expect(box.lines.isEmpty)

        recorder.beginOp(label: "redo", opId: "CCCC0003")
        let span = recorder.span("notes-rebuild-push", "chars=58764")
        box.now = 620
        span.end("chars=58764")
        #expect(box.lines == [
            "[STRUCT-TRACE] t=500ms +timeline=0ms redo op=CCCC0003 start notes-rebuild-push chars=58764",
            "[STRUCT-TRACE] t=620ms +timeline=120ms redo op=CCCC0003 end notes-rebuild-push took=120ms chars=58764"
        ])
    }

    @Test("timed runs its body once, returns its value and rethrows its error, writing start and end")
    func timedWrapsTheBody() {
        struct Boom: Error {}
        let box = TraceBox()
        let recorder = makeRecorder(on: true, box)
        recorder.beginOp(label: "sectionDelete", opId: "AAAA0001")

        var runs = 0
        let value = recorder.timed("snapshot.fetchBlocks") { () -> Int in runs += 1; return 7 }
        #expect(value == 7)
        #expect(runs == 1)
        #expect(box.lines.count == 2)

        #expect(throws: Boom.self) {
            try recorder.timed("snapshot.saveContent") { () -> Int in throw Boom() }
        }
        #expect(box.lines.count == 4) // the failing step still wrote its end line
    }
}
