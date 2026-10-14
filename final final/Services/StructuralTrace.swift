//
//  StructuralTrace.swift
//  final final
//
//  Phase 4b part 2, slice 0 (t-94369a83): MEASUREMENT ONLY. Trace lines and a typing-latency trace so the next builds can be
//  timed old-versus-new in one session on the app's own clock (system uptime in milliseconds, the clock `NSEvent.timestamp`
//  uses too). Nothing here changes behaviour: every entry point starts with `isOn`, and while tracing is off the whole file
//  costs one cached boolean read per call (plus, for key presses, the one event monitor's closure call).
//
//  "Tracing is on" means the `.undo` log category is on. `.undo` is NOT in `DebugLog.enabled`, so a plain Debug run prints
//  nothing: it is on when Diagnostics logging is on, i.e. the Diagnostics pane's toggle (`DiagnosticsSettings.loggingEnabled`)
//  or, for UI tests, the launch environment variable `FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING=1`. Switching the toggle while a
//  document is open reaches the open editor too (`.diagnosticsLoggingChanged`, observed by the Milkdown coordinator, which
//  re-sends the editor's `setTraceTyping` flag). Same gate as today's `[STRUCT-TRACE]` lines in StructuralUndoController.
//
//  Two line families, both under `.undo`:
//
//    [STRUCT-TRACE] t=<ms>ms +<ms since the op's own start>ms <label> op=<id> <step>
//        Today's lines, written by StructuralUndoController.StructTrace (`structLine`). The base of `+` is the entry of the
//        Swift sequence.
//    [STRUCT-TRACE] t=<ms>ms +timeline=<ms>ms <label> op=<id> <step>
//        The lines this file adds (`timelineLine`): click-start, the snapshot steps, sync and refresh spans, rebuild pushes,
//        main-stall. `+timeline=` is a DIFFERENT base from the old `+`, on purpose, so the two cannot be mixed up: it counts
//        from the timeline's start, which is the click that chose the context-menu item for delete and duplicate, and the
//        entry of performStructuralOp / performUndo / performRedo for everything else. THE TIMELINE IS THE MOST RECENT OP'S:
//        a rebuild, sync or stall caused by op 1 that lands after op 2 has begun is labelled with op 2's label and op id and
//        timed from op 2's start. (Op ids are deliberately not carried into the rebuild pushes.) Lines are written for 30 s
//        after an op starts (a span's `end` is written even after that, when its `start` was); before the first op of a
//        session, and long after one, the family is silent.
//        click-start reads `type=<NSEvent type> age=<ms between the event's own time and now>` (`type=none` when there is no
//        current event), so the figure can be checked against the kind of event that was actually timed.
//        Steps added for the delete-speed measurement (fix round 12): `start (editor-first) guardMs=<n> managedIdsMs=<n>` (a `+`
//        line: how long the one-row root check and the managed-ids read took), then timeline lines `job task started` (the settle
//        task's first line), `onReserved fired`, `start contentPush chars=<n>` / `end contentPush took=<n>ms` (the editor's content
//        message handler), `start contentChange.handle` / `end contentChange.handle took=<n>ms` (the observer of
//        `editorState.content`), and, from StructuralTraceRunLoop.swift, `wake-work took=<n>ms` and `ui-update took=<n>ms` (a
//        main run-loop phase that took more than 50 ms). A delete started by the UI-test trigger (UITestingDeleteTrigger.swift)
//        also writes `[UITEST-TRIGGER] t=<ms>ms deleteSection received title=<title>` just before its `click-start type=none` line.
//    [TYPING-TRACE] key t=<ms> code=<keyCode> editor=<true|false>
//        One per key-down anywhere in the app, from ONE local event monitor (never a web-view subclass). `editor` is true when
//        the key window's first responder is a WKWebView or inside one.
//    [TYPING-TRACE] echo t=<ms> n=<edits>
//        Swift received the editor's `typingEcho` message. The Rich Text editor posts it from a task after the first frame that
//        follows a real user edit; `n` is how many real user edits that one echo covers (edits made before the same frame).
//    [TYPING-TRACE] rebuild-replaced-pending kind=<notes|bibliography|footnote|unknown> block=<id> t=<ms>
//        A managed rebuild push dropped a queued, unsaved edit of a block it replaced. `unknown` when the push did not say which.
//
//  PAIRING RULE for the analyser (keystroke-to-echo): pair each key with the FIRST echo at or after it. Not every key
//  produces an echo (arrows, Escape, ⌘Z, keys outside the editor), and one echo covers all edits made before a frame, so
//  pairing "the latest key before each echo" would hide the worst keystroke. Use `editor=true` and the echo's `n` to tell
//  which keys can be expected to echo. The echo time is still a LOWER BOUND on "keystroke on screen": it is taken after the
//  frame's rendering work has run, but the compositor and the scan-out are not visible from JavaScript.
//
//  Step names for the timeline family never end in the words " start" or " performed" (the UI-test parser matches the op's own
//  `start` and `performed` lines by suffix): spans read `start <name>` and `end <name> took=<n>ms`.
//

import AppKit
import Foundation
import os
import WebKit

/// The event a context-menu click was read from, as the trace needs it.
struct StructuralTraceClick: Sendable {
    let typeName: String
    /// The event's own time, milliseconds since system start.
    let timestampMs: Int
}

/// The trace's shared state and decisions, with the clock, the on-switch and the line sink injected, so the unit tests run an
/// isolated instance instead of touching the app-wide one. `StructuralTrace.shared` is the app's instance.
final class StructuralTraceRecorder: @unchecked Sendable {

    private struct Timeline: Sendable {
        var label = "none"
        var opId = "--------"
        /// Start of the most recent structural op; nil until the first one of this session.
        var startMs: Int?
        /// The click that chose a context-menu item, waiting for its op to begin: (op label, event time in ms).
        var pendingClick: (label: String, ms: Int)?
    }

    private let isOn: () -> Bool
    private let now: () -> Int
    private let emit: (String) -> Void
    private let timeline = OSAllocatedUnfairLock(initialState: Timeline())

    init(isOn: @escaping () -> Bool, now: @escaping () -> Int, emit: @escaping (String) -> Void) {
        self.isOn = isOn
        self.now = now
        self.emit = emit
    }

    /// Start of the most recent op's timeline, nil before the first.
    var startMs: Int? { timeline.withLock { $0.startMs } }

    /// Called when a section command's context-menu action fires. `click` is evaluated only while tracing is on. Logs the
    /// click as the op's start (see `StructuralTrace.noteCommandClick`).
    func noteCommandClick(label: String, click: @autoclosure () -> StructuralTraceClick?) {
        guard isOn() else { return }
        let nowMs = now()
        let event = click()
        let eventMs = event?.timestampMs ?? nowMs
        timeline.withLock { $0.pendingClick = (label, eventMs) }
        let step = StructuralTrace.clickStartStep(eventType: event?.typeName, ageMs: event.map { nowMs - $0.timestampMs })
        emit(StructuralTrace.timelineLine(t: eventMs, since: 0, label: label, opId: "--------", step: step))
    }

    /// A structural op's sequence begins. Starts the timeline (at the pending click for the same op, else now) and returns its
    /// start, or nil while tracing is off.
    @discardableResult
    func beginOp(label: String, opId: String = "--------") -> Int? {
        guard isOn() else { return nil }
        let nowMs = now()
        return timeline.withLock { state -> Int in
            let start = StructuralTrace.opStartMs(now: nowMs, label: label, pendingClick: state.pendingClick)
            state.pendingClick = nil
            state.label = label
            state.opId = opId
            state.startMs = start
            return start
        }
    }

    /// An op refused (or failed) before its sequence began: its click must not be taken as the start of the next one.
    func discardPendingClick(label: String) {
        guard isOn() else { return }
        timeline.withLock { state in
            if state.pendingClick?.label == label { state.pendingClick = nil }
        }
    }

    /// The op's short id is known.
    func noteOpId(_ opId: String) {
        guard isOn() else { return }
        timeline.withLock { $0.opId = opId }
    }

    /// One timeline line, `+timeline=` since the most recent op started. Silent when tracing is off, before the first op, or
    /// more than `timelineWindowMs` after it.
    func log(_ step: @autoclosure () -> String) {
        write(step, windowed: true)
    }

    fileprivate func write(_ step: () -> String, windowed: Bool) {
        guard isOn() else { return }
        let (label, opId, start) = timeline.withLock { ($0.label, $0.opId, $0.startMs) }
        guard let start else { return }
        let nowMs = now()
        if windowed, nowMs - start > StructuralTrace.timelineWindowMs { return }
        emit(StructuralTrace.timelineLine(t: nowMs, since: nowMs - start, label: label, opId: opId, step: step()))
    }

    /// Starts a span: writes `start <name> <detail>` and remembers the time. `detail` is evaluated before the clock is read.
    /// Writes nothing (and the span's `end` writes nothing) when tracing is off or no op is in its timeline window.
    func span(_ name: String, _ detail: @autoclosure () -> String = "") -> StructuralTraceSpan {
        guard isOn(), let start = startMs, now() - start <= StructuralTrace.timelineWindowMs else {
            return StructuralTraceSpan(recorder: self, name: name, startMs: nil)
        }
        let extra = detail()
        write({ "start \(name)\(extra.isEmpty ? "" : " " + extra)" }, windowed: true)
        return StructuralTraceSpan(recorder: self, name: name, startMs: now())
    }

    /// Runs `body` as a span named `name`.
    @discardableResult
    func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let timedSpan = span(name)
        defer { timedSpan.end() }
        return try body()
    }

    fileprivate func nowMs() -> Int { now() }
}

/// A timed step. `end` writes the closing line, even after the timeline window has closed (when the `start` was written).
struct StructuralTraceSpan {
    fileprivate let recorder: StructuralTraceRecorder
    fileprivate let name: String
    fileprivate let startMs: Int?

    func end(_ detail: @autoclosure () -> String = "") {
        guard let startMs else { return }
        let extra = detail()
        let took = recorder.nowMs() - startMs
        recorder.write({ "end \(name) took=\(took)ms\(extra.isEmpty ? "" : " " + extra)" }, windowed: false)
    }
}

enum StructuralTrace {

    // MARK: - Switch and clock

    /// Whether tracing is on. Cheap enough to call on every hot path (a cached read, see `DiagnosticLogFile.isEnabled`).
    static var isOn: Bool { DebugLog.isEnabled(.undo) }

    /// Milliseconds since system start, the clock every trace line uses.
    static func nowMs() -> Int { Int(ProcessInfo.processInfo.systemUptime * 1000) }

    /// `NSEvent.timestamp` (seconds since system start) as milliseconds on the same clock as `nowMs()`.
    static func ms(ofEventTimestamp timestamp: TimeInterval) -> Int { Int(timestamp * 1000) }

    /// How long after a structural op starts the timeline lines (spans, rebuild pushes, stalls) are still written.
    static let timelineWindowMs = 30_000

    /// The app's recorder.
    static let shared = StructuralTraceRecorder(
        isOn: { StructuralTrace.isOn },
        now: { StructuralTrace.nowMs() },
        emit: { line in DebugLog.log(.undo, line) }
    )

    // MARK: - Line formats (pure; unit-tested)

    /// One `[STRUCT-TRACE]` line in the format StructuralUndoController's own step lines have always used (`+` counts from the
    /// op's entry).
    static func structLine(t: Int, since: Int, label: String, opId: String, step: String) -> String {
        "[STRUCT-TRACE] t=\(t)ms +\(since)ms \(label) op=\(opId) \(step)"
    }

    /// One `[STRUCT-TRACE]` line of this file's timeline family: `+timeline=` counts from the timeline's start, a different base.
    static func timelineLine(t: Int, since: Int, label: String, opId: String, step: String) -> String {
        "[STRUCT-TRACE] t=\(t)ms +timeline=\(since)ms \(label) op=\(opId) \(step)"
    }

    /// The step text of the click-start line: which kind of event was timed, and how old it was when the action ran.
    static func clickStartStep(eventType: String?, ageMs: Int?) -> String {
        guard let eventType, let ageMs else { return "click-start type=none" }
        return "click-start type=\(eventType) age=\(ageMs)ms"
    }

    /// A name for an event type, for the click-start line.
    static func eventTypeName(_ type: NSEvent.EventType) -> String {
        let names: [NSEvent.EventType: String] = [
            .leftMouseDown: "leftMouseDown",
            .leftMouseUp: "leftMouseUp",
            .rightMouseDown: "rightMouseDown",
            .rightMouseUp: "rightMouseUp",
            .otherMouseDown: "otherMouseDown",
            .otherMouseUp: "otherMouseUp",
            .keyDown: "keyDown",
            .keyUp: "keyUp",
            .appKitDefined: "appKitDefined",
            .applicationDefined: "applicationDefined",
            .systemDefined: "systemDefined",
            .periodic: "periodic"
        ]
        return names[type] ?? "other\(type.rawValue)"
    }

    /// `[TYPING-TRACE] key t=<ms> code=<keyCode> editor=<bool>`.
    static func keyLine(t: Int, code: UInt16, inEditor: Bool) -> String {
        "[TYPING-TRACE] key t=\(t) code=\(code) editor=\(inEditor)"
    }

    /// `[TYPING-TRACE] echo t=<ms> n=<edits covered>`; the `n=` part is left out when the message did not carry a count.
    static func echoLine(t: Int, edits: Int?) -> String {
        "[TYPING-TRACE] echo t=\(t)\(edits.map { " n=\($0)" } ?? "")"
    }

    /// The `[TYPING-TRACE] rebuild-replaced-pending ...` line for a `typingTrace` message body from the editor, or nil if
    /// the body is not that event (unknown event, or a missing kind or block).
    static func rebuildReplacedPendingLine(body: [String: Any], t: Int) -> String? {
        guard (body["event"] as? String) == "rebuild-replaced-pending",
              let kind = body["kind"] as? String, !kind.isEmpty,
              let block = body["block"] as? String, !block.isEmpty else { return nil }
        return "[TYPING-TRACE] rebuild-replaced-pending kind=\(kind) block=\(block) t=\(t)"
    }

    /// The `traceKind` option of the JS `setContentWithBlockIds` call: only while tracing is on, and only for a rebuild push.
    /// With tracing off the call string carries no trace option at all.
    static func traceKindOption(_ kind: RebuildKind?, tracingOn: Bool) -> String? {
        guard tracingOn, let kind else { return nil }
        return "traceKind: `\(kind.rawValue)`"
    }

    /// Pure: when an op that begins at `now` is taken to have started: at the pending click if it is for the same op `label`
    /// and no older than `maxAgeMs`, else `now` (undo, redo, and every op with no menu click).
    static func opStartMs(
        now: Int, label: String, pendingClick: (label: String, ms: Int)?, maxAgeMs: Int = pendingClickMaxAgeMs
    ) -> Int {
        if let click = pendingClick, click.label == label, now - click.ms <= maxAgeMs { return click.ms }
        return now
    }

    /// A click that chose "Delete Section" / "Duplicate Section" belongs to an op that begins a moment later.
    static let pendingClickMaxAgeMs = 10_000

    // MARK: - Calls from the app (forward to `shared`)

    #if DEBUG
    /// Set by the UI-test delete trigger (UITestingDeleteTrigger.swift) for the duration of its `perform` call: the next
    /// `noteCommandClick` is not backed by a click at all, so `NSApp.currentEvent` there is only the last event the run loop
    /// happened to handle (in a UI-test run, a key-up many seconds old). While set, `noteCommandClick` writes `click-start
    /// type=none` timed now instead of reading that stale event. Taken and cleared by the call that consumes it.
    static let nextClickHasNoEvent = OSAllocatedUnfairLock(initialState: false)
    #endif

    /// Called when a section command's context-menu action fires (ContentView+SectionOperations). `event` is evaluated only
    /// while tracing is on: `NSApp.currentEvent`, which at that moment is whichever event is being processed (normally the
    /// click that chose the menu item). It is logged as the op's start, with its type and age, so the op's own start (a
    /// moment later, when the Swift sequence is entered) is not taken as the click time. `label` is the op's label
    /// (`"\(StructuralEntry.Kind)"`: sectionDelete, sectionDuplicate).
    static func noteCommandClick(label: String, event: @autoclosure () -> NSEvent?) {
        #if DEBUG
        let hasNoEvent = nextClickHasNoEvent.withLock { flag -> Bool in
            let wasSet = flag
            flag = false
            return wasSet
        }
        if hasNoEvent {
            shared.noteCommandClick(label: label, click: nil)
            return
        }
        #endif
        shared.noteCommandClick(label: label, click: event().map {
            StructuralTraceClick(typeName: eventTypeName($0.type), timestampMs: ms(ofEventTimestamp: $0.timestamp))
        })
    }

    /// A structural op's sequence begins (performStructuralOp, performUndo, performRedo). Starts the shared timeline, at the
    /// click for delete and duplicate, and the main-thread stall marker for the next 10 seconds.
    static func beginOp(label: String, opId: String = "--------") {
        if let start = shared.beginOp(label: label, opId: opId) {
            startStallMonitor(opStartMs: start)
            StructuralRunLoopTracer.installIfNeeded()   // fix round 12: `wake-work` / `ui-update` lines, see StructuralTraceRunLoop.swift
        }
    }

    static func discardPendingClick(label: String) { shared.discardPendingClick(label: label) }
    static func noteOpId(_ opId: String) { shared.noteOpId(opId) }
    static func log(_ step: @autoclosure () -> String) { shared.log(step()) }
    static func span(_ name: String, _ detail: @autoclosure () -> String = "") -> StructuralTraceSpan {
        shared.span(name, detail())
    }

    @discardableResult
    static func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        try shared.timed(name, body)
    }

    // MARK: - Rebuild pushes

    /// The three managed rebuilds that push the document into the editor (`preserveUserBlocks`).
    enum RebuildKind: String {
        case notes
        case bibliography
        case footnote
    }

    // MARK: - Typing trace

    /// Installed once at app start. A plain local monitor, never a web-view subclass (A11): the editor's web views are plain
    /// `WKWebView`s built in four places. The handler logs the key's own timestamp and returns the event untouched.
    @MainActor private static var keyMonitor: Any?

    @MainActor static func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if isOn {
                DebugLog.log(
                    .undo,
                    keyLine(
                        t: ms(ofEventTimestamp: event.timestamp), code: event.keyCode,
                        inEditor: isInsideWebView(NSApp.keyWindow?.firstResponder))
                )
            }
            return event
        }
    }

    /// Whether `responder` is a `WKWebView` or a view inside one (WebKit's first responder is a private subview).
    @MainActor static func isInsideWebView(_ responder: NSResponder?) -> Bool {
        var view = responder as? NSView
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }

    /// Swift received `typingEcho` from the editor: a frame after a real user edit has been reached. `edits` is how many real
    /// user edits that one echo covers.
    static func noteEcho(edits: Int?) {
        guard isOn else { return }
        DebugLog.log(.undo, echoLine(t: nowMs(), edits: edits))
    }

    /// Swift received a `typingTrace` message from the editor.
    static func noteTypingTraceMessage(_ body: [String: Any]) {
        guard isOn, let line = rebuildReplacedPendingLine(body: body, t: nowMs()) else { return }
        DebugLog.log(.undo, line)
    }

    /// JavaScript that sets the editor's typing trace flag. `?.` so an editor bundle without the function does nothing.
    static func editorTraceFlagScript(on enabled: Bool) -> String {
        "window.FinalFinal.setTraceTyping?.(\(enabled))"
    }

    /// The script that switches the editor's typing trace on at editor load, or nil while tracing is off (so nothing is sent).
    static var editorLoadTraceFlagScript: String? {
        isOn ? editorTraceFlagScript(on: true) : nil
    }

    // MARK: - Main-thread stall marker

    /// From a structural op's start until this long after it, a stall is reported.
    static let stallWindowMs = 10_000
    /// A main thread that answered a ping later than this is reported.
    static let stallThresholdMs = 50
    private static let pingIntervalMs = 20

    /// Pure: the stall to report for a ping that the main thread answered `latencyMs` after it was posted, or nil if it
    /// answered in time (not more than `thresholdMs`).
    static func stallToReport(latencyMs: Int, thresholdMs: Int = stallThresholdMs) -> Int? {
        latencyMs > thresholdMs ? latencyMs : nil
    }

    /// Pure: whether the stall marker is still watching `nowMs`, for an op that started at `opStartMs`.
    static func stallWindowIsOpen(nowMs: Int, opStartMs: Int, windowMs: Int = stallWindowMs) -> Bool {
        nowMs - opStartMs <= windowMs
    }

    private struct MonitorState: Sendable {
        var running = false
        var pingInFlight = false
    }

    private static let monitorState = OSAllocatedUnfairLock(initialState: MonitorState())
    private static let stallQueue = DispatchQueue(label: "final-final.struct-trace.stall", qos: .utility)

    /// Starts the monitor if it is not running: a utility-queue timer pings the main queue every 20 ms (one ping at a time)
    /// and reports each answer that took more than 50 ms as `main-stall <ms>ms` (the line is written when the main thread
    /// answers, so its `t=` is the END of the stall). It stops itself when the most recent op is more than 10 s old, and does
    /// nothing at all while tracing is off.
    private static func startStallMonitor(opStartMs: Int) {
        let shouldStart = monitorState.withLock { state -> Bool in
            if state.running { return false }
            state.running = true
            state.pingInFlight = false
            return true
        }
        guard shouldStart else { return }
        let timer = DispatchSource.makeTimerSource(queue: stallQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(pingIntervalMs), leeway: .milliseconds(5))
        timer.setEventHandler {
            let start = shared.startMs ?? opStartMs
            guard isOn, stallWindowIsOpen(nowMs: nowMs(), opStartMs: start) else {
                monitorState.withLock { $0.running = false }
                timer.cancel()
                return
            }
            let pingBusy = monitorState.withLock { state -> Bool in
                if state.pingInFlight { return true }
                state.pingInFlight = true
                return false
            }
            guard !pingBusy else { return }
            let sentMs = nowMs()
            DispatchQueue.main.async {
                let latency = nowMs() - sentMs
                monitorState.withLock { $0.pingInFlight = false }
                if let stall = stallToReport(latencyMs: latency) {
                    log("main-stall \(stall)ms")
                }
            }
        }
        timer.resume()
    }
}
