import Foundation

/// Lightweight category-based debug logging.
/// - Call sites are simple one-liners: `DebugLog.log(.sync, "message")`
/// - In release builds `log()` has no console output; it still forwards to `DiagnosticLogFile` when the user's
///   Diagnostics toggle is on (in any build).
/// - `always()` prints unconditionally (for safety guards that must never be silenced).
/// - To enable more categories during development, edit `enabled` below.
/// - The diagnostic file the user's Diagnostics switch writes must never hold key codes or pieces of the document
///   (t-561c4083). A log line that would carry document text builds it with `docText(_:)` inside the log call's argument;
///   `docText` writes only a length unless the developer-only switch is on (see `developerDetailOn`).
enum DebugLog {
    enum Category: String, CaseIterable {
        case sync        // [SYNC-DIAG:*] block sync diagnostics
        case contentPush // [ContentPush] per-keystroke content changes
        case blockPoll   // [BlockPoll] polling cycle details
        case editor      // [MilkdownEditor] [CodeMirrorEditor] lifecycle + errors
        case scheme      // [EditorSchemeHandler] [MediaSchemeHandler] asset serving
        case outline     // outline cache, [onSectionsUpdated]
        case lifecycle   // [AppDelegate] [DocumentManager] [FinalFinalApp] app lifecycle
        case zotero      // [ZoteroService] citation operations
        case theme       // [ThemeManager] [AppearanceSettings] [GoalColorSettings]
        case bib         // [CV:bib*] bibliography rebuild cycle
        case zoom        // zoom/section editing
        case fileOps     // [FileOperations] file commands
        case backup      // [SnapshotService] [AutoBackupService]
        case data        // [Database+Blocks] [ProjectRepairService] data layer
        case image       // [Image] width lifecycle tracing
        case proofing    // [LT] spellcheck + LanguageTool boundary diagnostics
        case footnotes   // [FootnoteSyncService] Notes-section reconciliation diagnostics
        case reentrancy  // [Reentrancy] crash-forensics: deferred main-queue @Observable writes
                         // from inside NSViewRepresentable.updateNSView (Milkdown/CodeMirror editors)
        case undo        // [UnifiedUndoService] unified chronological undo: routing decisions,
                          // refusals, degradations, barriers (docs/architecture/unified-undo.md)
        case escape       // [Escape] [EscapeWatchdog] Esc-key layer-order ladder (UX contract §6,
                           // EscapeLadder.swift): candidate dedup, watchdog arm/fire/resolve, and
                           // the rung applied. Deliberately NOT added to `enabled` below -- it
                           // exists so a future VM log capture can confirm a duplicate-monitor-
                           // entry-per-press bug if it ever resurfaces, not to print on every Esc
                           // in normal development use.
        case viewUpdates  // [ContentViewBody] [SidebarBody] [WordCountLabel] body-invocation counters
                          // for the sidebar re-render investigation (bt t-ef411da3), plus
                          // [ContentSyncObserved] marking each `.onChange(of: editorState.content)`
                          // firing inside ContentSyncObserverHost (bt t-63c521f5,
                          // ViewNotificationModifiers.swift) -- logged before the `.idle` guard, so it
                          // counts every attempted invocation (including no-op returns during
                          // bibliography rebuilds, zoom transitions, and mode switches), not only
                          // completed syncs. Extracted so this counter tracks content-sync activity even
                          // after ContentViewBody itself is driven toward zero. DEBUG-ONLY: every
                          // call site is `#if DEBUG`-guarded, so a Release build emits nothing for this
                          // category regardless of the user's Diagnostics toggle. In a DEBUG build the
                          // toggle routes it to the persistent DiagnosticLogFile; deliberately NOT added
                          // to `enabled` below, so it stays out of the console for other developers.
    }

    /// Default: only lifecycle + zotero + editor. Add categories here when debugging.
    /// `.outline` and `.data` enabled temporarily for word-count debugging — gives
    /// per-refresh totals (`[batchWordCounts]`) and per-edit deltas (`[Blocks:edit]`)
    /// so a spurious wordcount jump can be traced to the exact block that moved.
    /// DIAGNOSTIC (temporary, added during footnote-export-race investigation):
    /// `.sync` and `.blockPoll` enabled to trace the editor's block reports and their apply
    /// during FootnoteExportRaceTests. Safe to remove once the flush race is resolved.
    /// `.zoom` enabled permanently: `HeadingZoomClickRouter.decide`'s drop-reason logging
    /// uses this category, and it was invisible in the console by default — a violation of
    /// this feature's own "no silent failures" invariant.
    ///
    /// `.reentrancy` is deliberately NOT added here — it stays out of the DEBUG console by
    /// default; it still reaches the persistent file whenever the user's Diagnostics toggle
    /// is on, which is the whole point (a durable trail without adding console noise for
    /// other developers).
    static let enabled: Set<Category> = [
        .lifecycle, .zotero, .editor, .outline, .data, .footnotes, .sync, .blockPoll, .zoom
    ]

    /// Category-gated log. In DEBUG builds, prints to the console when `category` is in
    /// `enabled`. In ALL builds (including Release), forwards to the persistent
    /// `DiagnosticLogFile` sink when the user's runtime Diagnostics toggle is on — this path
    /// is independent of the compile-time `enabled` set above, so it captures every category.
    ///
    /// HARD REQUIREMENT: the enable-check guard below must run BEFORE `message()` is called.
    /// `message` MUST stay `@autoclosure` so the interpolation/allocation at every one of this
    /// app's ~500+ call sites (a 500ms polling loop, the GRDB writer queue, etc.) is never
    /// paid when logging is off — do not change `message` to a plain `String` parameter, and
    /// do not evaluate `message()` above the guard.
    @inline(__always)
    static func log(_ category: Category, _ message: @autoclosure () -> String) {
        let forwardToFile = DiagnosticLogFile.isEnabled
        #if DEBUG
        let forwardToConsole = enabled.contains(category)
        #else
        let forwardToConsole = false
        #endif
        guard forwardToFile || forwardToConsole else { return }
        let text = message()
        if forwardToFile {
            DiagnosticLogFile.shared.append("[\(category.rawValue)] \(text)")
        }
        #if DEBUG
        if forwardToConsole { print(text) }
        #endif
    }

    /// The developer-only switch (t-561c4083): the launch environment variable `FF_DEV_LOG_KEYS_AND_TEXT=1`, read once at
    /// launch. Settings never offers it, and a UserDefaults key is deliberately not used (one `defaults write` would keep
    /// logging text forever, unnoticed; a variable ends when the app quits). Set it in an Xcode scheme's Environment
    /// Variables, in a UI test's `app.launchEnvironment`, or with `open --env FF_DEV_LOG_KEYS_AND_TEXT=1 "<app>"`.
    /// It only adds detail to lines the Diagnostics switch already writes: with Diagnostics off nothing is logged either way.
    static let developerDetailOn: Bool = ProcessInfo.processInfo.environment["FF_DEV_LOG_KEYS_AND_TEXT"] == "1"

    /// How document text appears in a log line: `len=<characters>`, or the quoted text itself while the developer-only switch
    /// is on. Every log line that would carry a piece of the document goes through this (the rule `DiagnosticLogPrivacyTests`
    /// enforces). Call it INSIDE the log call's argument, never hoisted above it, so the work is skipped while logging is off.
    static func docText<S: StringProtocol>(_ text: S, developerDetail: Bool = DebugLog.developerDetailOn) -> String {
        developerDetail ? "\"\(text)\"" : "len=\(text.count)"
    }

    /// Check whether a category is currently logging. Use to short-circuit work
    /// done *outside* a `log()` call (e.g. allocating a preview string or counting).
    /// Inline the check at the top of logging helpers so the body is skipped entirely
    /// when the category is disabled.
    ///
    /// Must mirror `log()`'s own gate (`forwardToFile || forwardToConsole`) exactly — this
    /// used to check only the compile-time console set, so a caller gating on `isEnabled()`
    /// (e.g. `LanguageToolProvider`'s request/response boundary logging) silently never wrote
    /// to the persistent `DiagnosticLogFile` sink even with the user's runtime Diagnostics
    /// toggle on, since that path only checked `forwardToFile` inside `log()` itself, never here.
    @inline(__always)
    static func isEnabled(_ category: Category) -> Bool {
        if DiagnosticLogFile.isEnabled { return true }
        #if DEBUG
        return enabled.contains(category)
        #else
        return false
        #endif
    }

    /// Always prints in ALL builds. Reserved for:
    /// - Mass-delete safety guards (data loss prevention)
    /// - Truly critical errors where silence risks data corruption
    /// Do NOT use for routine error logging — use log() instead.
    /// Console only — this does not reach the persistent `DiagnosticLogFile`. If the signal
    /// also needs to survive there (e.g. a user's "Generate Diagnostic Report…" bundle), use
    /// `alwaysPersisted(_:)` below instead, which does everything `always()` does plus that.
    @inline(__always)
    static func always(_ message: @autoclosure () -> String) {
        let text = message()
        print(text)
        #if DEBUG
        // A18: copy the sink under the lock and invoke it AFTER unlocking. Holding
        // the lock across the call meant a sink that (directly or indirectly) touched
        // `DebugLog` could deadlock, and it made the sink's own re-entrancy contract
        // load-bearing.
        alwaysSinkLock.lock()
        let sink = _alwaysSink
        let observers = Array(_alwaysObservers.values)
        alwaysSinkLock.unlock()
        sink?(text)
        for observer in observers { observer(text) }
        #endif
    }

    /// `always(_:)` plus the persistent DiagnosticLogFile (subject to the user's Diagnostics
    /// toggle — `append` gates itself). Reserved for block-sync data-loss / timeout signals.
    /// Goes through `always`, so console output and the DEBUG `alwaysSink` are unchanged.
    @inline(__always)
    static func alwaysPersisted(_ message: @autoclosure () -> String,
                                to logFile: DiagnosticLogFile = .shared) {
        let text = message()
        always(text)
        logFile.append("[always] \(text)")
    }

    #if DEBUG
    private static let alwaysSinkLock = NSLock()
    /// `nonisolated(unsafe)`: every read and write goes through `alwaysSinkLock`
    /// (`always` above copies it under the lock; the accessor below locks for get and
    /// set). The annotation is what tells the compiler that this mutable global is
    /// guarded externally rather than actor-isolated.
    nonisolated(unsafe) private static var _alwaysSink: ((String) -> Void)?
    /// Test-only sink: every always(...) line is forwarded here too, under the same
    /// lock that guards the assignment. Only tests asserting on unconditional lines
    /// (e.g. the poll-watchdog timeout line's literal text) install it; tests that
    /// only need to observe a condition should prefer an instance-scoped seam, since
    /// this one is process-global and shared with concurrently running suites.
    static var alwaysSink: ((String) -> Void)? {
        get { alwaysSinkLock.lock(); defer { alwaysSinkLock.unlock() }; return _alwaysSink }
        set { alwaysSinkLock.lock(); defer { alwaysSinkLock.unlock() }; _alwaysSink = newValue }
    }

    /// Additional test observers of every always(...) line (t-18b7fa48 Phase 4b slice 2, round 2d-i). Unlike `alwaysSink` there can
    /// be any number of them, installed and removed independently, so suites that run in parallel cannot replace each other's capture:
    /// the test rig of the editor-first restore tests registers one that keeps only the lines carrying ITS project id. Guarded by the
    /// same lock. The observer is called on whatever thread logged the line.
    nonisolated(unsafe) private static var _alwaysObservers: [UUID: (String) -> Void] = [:]

    static func addAlwaysObserver(_ observer: @escaping (String) -> Void) -> UUID {
        let token = UUID()
        alwaysSinkLock.lock()
        _alwaysObservers[token] = observer
        alwaysSinkLock.unlock()
        return token
    }

    static func removeAlwaysObserver(_ token: UUID) {
        alwaysSinkLock.lock()
        _alwaysObservers[token] = nil
        alwaysSinkLock.unlock()
    }
    #endif
}
