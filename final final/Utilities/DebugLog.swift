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
    }

    /// Default: only lifecycle + zotero. Add categories here when debugging.
    static let enabled: Set<Category> = [.lifecycle, .zotero, .editor]

    /// Category-gated log. Compiles to nothing in release builds.
    @inline(__always)
    static func log(_ category: Category, _ message: @autoclosure () -> String) {
        #if DEBUG
        guard enabled.contains(category) else { return }
        print(message())
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
