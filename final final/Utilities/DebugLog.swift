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
    }

    /// Default: only lifecycle + zotero + editor. Add categories here when debugging.
    /// `.outline` and `.data` enabled temporarily for word-count debugging — gives
    /// per-refresh totals (`[batchWordCounts]`) and per-edit deltas (`[Blocks:edit]`)
    /// so a spurious wordcount jump can be traced to the exact block that moved.
    // DIAGNOSTIC (temporary, added during footnote-export-race investigation):
    // `.sync` and `.blockPoll` enabled to trace pollBlockChangesNow()/getBlockChanges()
    // during FootnoteExportRaceTests. Safe to remove once the flush race is resolved.
    static let enabled: Set<Category> = [.lifecycle, .zotero, .editor, .outline, .data, .footnotes, .sync, .blockPoll]

    /// Category-gated log. Compiles to nothing in release builds.
    @inline(__always)
    static func log(_ category: Category, _ message: @autoclosure () -> String) {
        #if DEBUG
        guard enabled.contains(category) else { return }
        print(message())
        #endif
    }

    /// Check whether a category is currently logging. Use to short-circuit work
    /// done *outside* a `log()` call (e.g. allocating a preview string or counting).
    /// Inline the check at the top of logging helpers so the body is skipped entirely
    /// when the category is disabled.
    @inline(__always)
    static func isEnabled(_ category: Category) -> Bool {
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
