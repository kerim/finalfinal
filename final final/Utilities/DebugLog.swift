import Foundation

/// Lightweight category-based debug logging.
/// - Call sites are simple one-liners: `DebugLog.log(.sync, "message")`
/// - In release builds, `log()` compiles to nothing.
/// - `always()` prints unconditionally (for safety guards that must never be silenced).
/// - To enable more categories during development, edit `enabled` below.
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
        case viewUpdates  // [ContentViewBody] [SidebarBody] [WordCountLabel] body-invocation counters
                          // for the sidebar re-render investigation (bt t-ef411da3). DEBUG-ONLY: every
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
    /// `.sync` and `.blockPoll` enabled to trace pollBlockChangesNow()/getBlockChanges()
    /// during FootnoteExportRaceTests. Safe to remove once the flush race is resolved.
    ///
    /// `.reentrancy` is deliberately NOT added here — it stays out of the DEBUG console by
    /// default; it still reaches the persistent file whenever the user's Diagnostics toggle
    /// is on, which is the whole point (a durable trail without adding console noise for
    /// other developers).
    static let enabled: Set<Category> = [.lifecycle, .zotero, .editor, .outline, .data, .footnotes, .sync, .blockPoll]

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
    @inline(__always)
    static func always(_ message: @autoclosure () -> String) {
        print(message())
    }
}
