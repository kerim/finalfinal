//
//  ToastCenter.swift
//  final final
//
//  The app's one non-modal feedback channel — UX contract §4.1/D6. Replaces the ad hoc
//  `EditorToast` (focus mode / Getting Started) and the "it worked" `NSAlert`s that used to
//  fire on export success and (nowhere, until now) on Save Version — see ToastFactory below
//  and the call sites it's wired into.
//
//  §0 call-out (stated, not invented — see the plan's coder note, t-15cb7dd8): §4.1.2 says a
//  new toast replaces the old. This queues a pending success instead of evicting a persistent
//  warning, so a warning is never lost — at the cost of discarding a stale pending success
//  after `pendingSuccessCutoff` seconds. See the rules below `show(_:now:)`.
//

import SwiftUI
import AppKit

/// The four visual/behavioral kinds of toast. `.progress` is §4.2's spinner shown while a long
/// export/print operation runs — see `ExportActivity`, which is its only call site (via
/// `ToastFactory.exportInProgress(message:)`) and the only thing that ever dismisses it. `.info`
/// is a neutral hint (no outcome, nothing succeeded or failed) that behaves exactly like
/// `.success` — fades on the same timer, queues the same way — but never shows a checkmark.
enum ToastStyle: Equatable {
    case success
    case warning
    case progress
    case info
}

/// A toast's single optional action button (§4.1.2: "carries exactly one action").
struct ToastAction {
    let title: String
    let perform: @MainActor () -> Void
}

/// One toast's content. `fades` is `true` for `.success` and `.info` — a warning never fades on
/// its own by default (§4.1.2: "does not fade... stays until dismissed"), and a `.progress`
/// toast is USUALLY replaced by its own result before fading would ever matter -- but not
/// always: `PrintOperations`'s formatted- and raw-markdown print paths both dismiss their
/// progress toast via `ExportActivity.end()` with no result toast to replace it (printing hands
/// off to the system print panel instead of showing an outcome toast), an intentional exception,
/// not a gap.
///
/// `fadeDelayOverride` lets a specific toast deviate from `ToastView`'s plain-success default
/// (3s): `ToastFactory.gettingStartedNotSaved()` uses it so that one warning auto-dismisses on
/// a longer, but finite, timer instead of camping in the app's one persistent-warning slot
/// forever; `ToastFactory.exportSucceeded(outputURL:)` uses it to fade slower than a plain
/// success because it carries an action button. Non-nil forces `fades == true` regardless of
/// `style`.
struct Toast: Identifiable {
    let id = UUID()
    let style: ToastStyle
    let message: String
    let action: ToastAction?
    let fadeDelayOverride: Duration?

    init(style: ToastStyle, message: String, action: ToastAction? = nil, fadeDelayOverride: Duration? = nil) {
        self.style = style
        self.message = message
        self.action = action
        self.fadeDelayOverride = fadeDelayOverride
    }

    var fades: Bool { style == .success || style == .info || fadeDelayOverride != nil }
}

/// The single toast slot for the whole app — a singleton, not per-view state, because the two
/// export call sites (`ExportViewModel`, `FileCommands+Export`) fire from outside any view's
/// own state tree. Holds no timers itself: a showing toast's auto-fade is driven entirely by
/// `ToastView`'s own `.task`, which calls `dismissCurrent()` — that keeps every rule below
/// directly unit-testable without waiting on real wall-clock time (see `ToastCenterTests`).
@MainActor
@Observable
final class ToastCenter {
    static let shared = ToastCenter()

    /// How long a pending success/progress toast is allowed to wait behind an undismissed
    /// warning before it's discarded rather than promoted (rule 5 below).
    static let pendingSuccessCutoff: TimeInterval = 10

    private(set) var current: Toast?
    private(set) var pending: (toast: Toast, stampedAt: Date)?

    /// Not `private` — `.shared` is the one production entry point, but tests construct their
    /// own isolated instances (see `ToastCenterTests`) rather than mutating the shared singleton
    /// and racing other parallel tests.
    init() {}

    /// Shows `toast`, applying the queue-with-cutoff rules (§0 above):
    /// 1. One toast at a time. A new **warning** always takes the slot, replacing whatever is
    ///    showing.
    /// 2. A new **progress** toast ALSO always takes the slot, even over an undismissed warning
    ///    -- a live export/print operation's progress is at least as important as a standing
    ///    warning, and `ExportActivity.begin(message:)` must never grey out the export/print
    ///    menu items with zero visible explanation for why (review fix: a progress toast used
    ///    to queue behind a warning in `pending` and simply never show). Like a new warning
    ///    replacing an old one, the toast being replaced here is not preserved for later
    ///    restoration -- only `pending` (untouched by this branch) survives past this call.
    /// 3. A new **success/info** replaces a showing success/progress, but never evicts an
    ///    undismissed warning — stored in a single **pending slot**, stamped with `now`. A newer
    ///    pending replaces an older one.
    /// `now` is injected (defaulting to `Date()`) so tests can drive the cutoff deterministically
    /// without sleeping real time.
    func show(_ toast: Toast, now: Date = Date()) {
        switch toast.style {
        case .warning, .progress:
            current = toast
            announceAccessibility(for: toast)
        case .success, .info:
            if let current, current.style == .warning {
                pending = (toast, now)
            } else {
                current = toast
                pending = nil
                announceAccessibility(for: toast)
            }
        }
    }

    /// Dismisses whatever is currently showing (✕, or a fading success's own `.task` timing
    /// out). If a success/info was pending behind it (the only styles that ever queue -- see
    /// rule 2 above, a `.progress` toast never sits in `pending`):
    /// 4. Promoted immediately if it was stamped within `pendingSuccessCutoff` seconds of `now`.
    /// 5. Otherwise discarded and logged via `DebugLog` — diagnostics only, never a user-facing
    ///    channel (a silently-vanished toast is the correct behavior here, not a bug to surface).
    func dismissCurrent(now: Date = Date()) {
        current = nil
        guard let pendingEntry = pending else { return }
        pending = nil
        if now.timeIntervalSince(pendingEntry.stampedAt) <= Self.pendingSuccessCutoff {
            current = pendingEntry.toast
            announceAccessibility(for: pendingEntry.toast)
        } else {
            DebugLog.log(
                .lifecycle,
                "[ToastCenter] Discarded a pending toast (\"\(pendingEntry.toast.message)\") " +
                    "after it aged past the \(Self.pendingSuccessCutoff)s cutoff"
            )
        }
    }

    /// Dismisses `current` only if it is still the toast with this `id`. A no-op if some other
    /// toast has since taken the slot — used by callers (e.g. `AutoBackupService`) that want to
    /// retract a warning they showed earlier without clobbering a newer, unrelated toast that
    /// has since taken the slot.
    func dismissIfCurrent(id: UUID, now: Date = Date()) {
        guard current?.id == id else { return }
        dismissCurrent(now: now)
    }

    /// Dismisses one specific toast wherever it currently sits — used by `ExportActivity.end()`
    /// so it tears down only its OWN progress toast, never whatever happens to be showing.
    /// If `id` is `current`, this behaves exactly like `dismissCurrent(now:)` (including
    /// promoting `pending`). If it is sitting in the `pending` slot (a success/info queued
    /// behind an undismissed warning -- never a `.progress` toast, which always takes `current`
    /// immediately per rule 2 in `show(_:now:)`), it is dropped from `pending` and `current` is
    /// left untouched — that queued toast never got to show, so there's nothing to promote in
    /// its place. If `id` matches neither slot (already replaced by a newer toast), this is a
    /// no-op.
    func dismiss(id: UUID, now: Date = Date()) {
        if current?.id == id {
            dismissCurrent(now: now)
        } else if pending?.toast.id == id {
            pending = nil
        }
    }

    /// Additive VoiceOver announcement — never a substitute for the visual channel, which is
    /// `ToastView` itself. Silently does nothing if there's no main window to announce against
    /// (e.g. in a headless test run).
    private func announceAccessibility(for toast: Toast) {
        guard let window = NSApp.mainWindow else { return }
        let priority: NSAccessibilityPriorityLevel = toast.style == .warning ? .high : .medium
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: toast.message,
                .priority: priority.rawValue
            ]
        )
    }
}

// MARK: - ToastFactory

/// Builds every toast the app shows, so each call site names an outcome ("export succeeded
/// with warnings") rather than re-deriving message text/style/action inline.
///
/// `@MainActor` because `showExportWarningsDetailAlert(outputURL:warnings:separator:)` calls
/// `NSAlert.runModal()` and every factory method's result feeds straight into the `@MainActor`
/// `ToastCenter` — this was previously only safe by luck of every call site already running on
/// the main actor.
@MainActor
enum ToastFactory {

    // MARK: Export

    static func exportSucceeded(result: ExportResult) -> Toast {
        exportSucceeded(outputURL: result.outputURL)
    }

    static func exportSucceeded(result: ExportService.MarkdownExportResult) -> Toast {
        exportSucceeded(outputURL: result.outputURL)
    }

    /// Fades slower than a plain success toast (`ToastView.fadeDelay`, 3s): this one carries an
    /// action button ("Show in Finder") the user needs time to notice and click, unlike
    /// "Version saved." which has no action and can afford to disappear quickly. 2x the plain
    /// rate keeps it in the same family rather than drifting toward the Getting Started
    /// warning's ~9s (user feedback, 2026-09-07: the 3s default felt too quick to react to).
    private static func exportSucceeded(outputURL: URL) -> Toast {
        Toast(
            style: .success,
            message: "Exported.",
            action: ToastAction(title: "Show in Finder") {
                NSWorkspace.shared.selectFile(outputURL.path, inFileViewerRootedAtPath: "")
            },
            fadeDelayOverride: .seconds(6)
        )
    }

    /// `separator` preserves each call site's own pre-existing joining behavior for the detail
    /// alert's `informativeText` exactly (`ExportViewModel` used "\n\n"; `FileCommands+Export`
    /// used "\n") — not a deliberate difference this task introduces, just not unified either,
    /// since that's outside this task's scope.
    static func exportSucceededWithWarnings(result: ExportResult) -> Toast {
        exportSucceededWithWarnings(outputURL: result.outputURL, warnings: result.warnings, separator: "\n\n")
    }

    static func exportSucceededWithWarnings(result: ExportService.MarkdownExportResult) -> Toast {
        exportSucceededWithWarnings(outputURL: result.outputURL, warnings: result.warnings, separator: "\n")
    }

    private static func exportSucceededWithWarnings(outputURL: URL, warnings: [String], separator: String) -> Toast {
        Toast(
            style: .warning,
            message: "Exported with warnings.",
            action: ToastAction(title: "Show Details") {
                showExportWarningsDetailAlert(outputURL: outputURL, warnings: warnings, separator: separator)
            }
        )
    }

    /// The full-text pandoc-warnings alert, previously shown automatically on every export with
    /// warnings — now reachable only via the warning toast's "Show Details" action (§4.1.2:
    /// "it worked" is never an alert; this alert says what went imperfectly, on request).
    private static func showExportWarningsDetailAlert(outputURL: URL, warnings: [String], separator: String) {
        let alert = NSAlert()
        alert.messageText = "Export Complete with Warnings"
        alert.informativeText = warnings.joined(separator: separator)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.selectFile(outputURL.path, inFileViewerRootedAtPath: "")
        }
    }

    // MARK: Export Progress

    /// The spinner toast shown for the duration of a long export/print operation (§4.2 / D7).
    /// No `fadeDelayOverride` — this toast is dismissed explicitly by `ExportActivity.end()`
    /// when the operation finishes, never on a timer.
    static func exportInProgress(message: String) -> Toast {
        Toast(style: .progress, message: message)
    }

    // MARK: Save Version

    static func versionSaved() -> Toast {
        Toast(style: .success, message: "Version saved.")
    }

    /// §4.1: a failure the user would care about must be visible without opening a log. Persistent
    /// (like every other warning) because a failed Save Version is exactly the kind of outcome
    /// that must not be missed by fading away unseen.
    static func versionSaveFailed() -> Toast {
        Toast(style: .warning, message: "Couldn't save version.")
    }

    // MARK: Table Truncated

    static func tableTruncated(rows: Int, cols: Int) -> Toast {
        Toast(
            style: .warning,
            message: "The pasted table was truncated to \(rows) rows × \(cols) columns."
        )
    }

    // MARK: Getting Started

    /// A finite (though distinctly longer than a success toast's 3s) auto-dismiss, not the
    /// default persistent warning: this notice must be seen, but it must not camp in the app's
    /// one persistent-warning slot indefinitely -- while it did, every later success/progress
    /// toast (Save Version, export) queued behind it and silently discarded past
    /// `ToastCenter.pendingSuccessCutoff`, so a user who left this notice up got zero
    /// confirmation for real operations (review round 2, must-fix 7).
    ///
    /// The delay must stay under `pendingSuccessCutoff` (10s), not just "finite" -- that's the
    /// whole point of must-fix 7. A prior value of 30s here was actually **worse** than no fix
    /// at all in practice: it fades eventually, but any success/progress toast queued behind it
    /// almost always ages past the 10s cutoff and gets silently discarded before this warning
    /// ever clears the slot, reproducing the exact "zero confirmation" bug the must-fix exists
    /// to prevent -- and 30s is long enough that a person manually testing it (waiting 10-15s)
    /// reasonably concludes it never fades at all (user feedback, 2026-09-07). 9s keeps this
    /// comfortably under the cutoff so a queued success is reliably promoted, not discarded.
    static func gettingStartedNotSaved() -> Toast {
        Toast(
            style: .warning,
            message: "Changes to the Getting Started guide aren't saved.",
            fadeDelayOverride: .seconds(9)
        )
    }

    // MARK: Focus Mode

    /// `.info`, not `.success` -- entering Focus Mode isn't an outcome that succeeded or failed,
    /// just a hint, so it never shows the success checkmark (review round 2, must-fix 6).
    static func focusModeHint() -> Toast {
        Toast(style: .info, message: "Press Esc or ⇧⌘F to exit Focus Mode.")
    }

    // MARK: Auto-Backup Failure

    /// §4.3: "Auto-backup skipped or failed" -> "warning toast, persistent until the next
    /// successful backup; detail in Diagnostics". Persistent (no `fadeDelayOverride`) like every
    /// other warning -- a failed backup must not be missed by fading away unseen. Wording uses
    /// the §5 glossary term "Version" (not "backup", which the glossary retires).
    static func autoBackupFailed() -> Toast {
        Toast(
            style: .warning,
            message: "Couldn't save an automatic version.",
            action: ToastAction(title: "Open Diagnostics") {
                NotificationCenter.default.post(name: .showDiagnosticsPreferences, object: nil)
            }
        )
    }

    // MARK: Section Reorder Bail-Out

    /// §4.3: "Drag-reorder bailed out" -> "toast". Fades (unlike the persistent warnings above)
    /// per the plan's judgment call: this one isn't the kind of outcome that needs to camp in
    /// the app's one persistent-warning slot -- 9s matches `gettingStartedNotSaved()`'s
    /// comfortably-under-`pendingSuccessCutoff` reasoning.
    static func sectionReorderBailedOut() -> Toast {
        Toast(
            style: .warning,
            message: "Couldn't move the section. Nothing was changed.",
            fadeDelayOverride: .seconds(9)
        )
    }
}
