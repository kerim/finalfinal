//
//  CitationErrorPresenter.swift
//  final final
//
//  Single Swift presenter for citation/Zotero errors, shared by both editor
//  coordinators (MilkdownCoordinator+MessageHandlers.swift,
//  CodeMirrorCoordinator+Citations.swift) -- see
//  .claude/rules/ux-contract.md §4.4, "one error class, one presenter".
//

import AppKit
import WebKit

/// Presents the three citation/Zotero error alerts both editors show, in one
/// place instead of two byte-for-byte-duplicated private implementations.
///
/// Not covered: `ExportViewModel.swift`'s `showZoteroWarningAlert()` (around line 475) builds
/// its own separate "Zotero Not Running" `NSAlert` for export preflight. That alert is a
/// decision with a "Continue Export"/"Cancel" choice and a suppression checkbox, not an error
/// report -- it asks the user whether to proceed, which this presenter's report-and-dismiss
/// alerts don't do -- so it stays out of scope for this consolidation.
@MainActor
enum CitationErrorPresenter {

    enum Kind {
        /// Zotero was not running when a citation action was attempted (CAYW picker
        /// pre-check, or a background citekey-resolution retry).
        case notRunning
        /// Zotero was running, then stopped responding mid-picker-session.
        case connectionLost
        /// Any other CAYW/citation error, carrying the underlying description.
        case failed(String)

        var title: String {
            switch self {
            case .notRunning: return "Zotero Not Running"
            case .connectionLost: return "Zotero Connection Lost"
            case .failed: return "Citation Error"
            }
        }

        var message: String {
            switch self {
            case .notRunning, .connectionLost:
                return "Zotero is not running. Please open Zotero and try again."
            case .failed(let description):
                return description
            }
        }
    }

    /// Cooldown: last time `presentThrottled` actually showed an alert (prevents spam
    /// from repeated background citekey-resolution retries). App-wide, matching the
    /// throttle this replaces (`MilkdownCoordinator+MessageHandlers.swift`'s prior
    /// `lastZoteroAlertTime`, already `static`/app-wide before this move).
    private static var lastAlertTime: Date = .distantPast

    /// Show a native NSAlert for a citation/Zotero error, direct response to a user-initiated
    /// citation action (the Citation toolbar button / CAYW picker pre-check, or a mid-picker
    /// connection loss). JS `alert()` is silently swallowed in WKWebView (no WKUIDelegate), so
    /// we must use native alerts.
    ///
    /// App-modal (`runModal()`, not a sheet), fixed as part of the Phase C focus-restoration
    /// audit's Tier 3 review: given a judge-directed negative control found AppKit does NOT
    /// reliably restore both focus halves even for the more favorable separate-window case
    /// (see `EditorFocusRestoration`'s doc comment and `docs/architecture/unified-undo.md`),
    /// an app-modal alert over the SAME window (an even closer analogue to the already-
    /// confirmed find-bar/EquationDialog gap) is treated as a real gap, not assumed safe.
    /// `runModal()` blocks until dismissed and returns synchronously, so the restore call
    /// right after it is guaranteed to run after the alert has actually closed.
    ///
    /// Activates the app before presenting: since this path is always a direct reaction to the
    /// user clicking something, the app is already frontmost or about to be, and activating
    /// just guarantees `runModal()` cannot enter an invisible nested modal loop.
    static func present(_ kind: Kind, restoringFocusTo webView: WKWebView?, context: String) {
        showAlert(kind, activatingApp: true)
        EditorFocusRestoration.restoreFocus(to: webView, context: context)
    }

    /// Same as `present`, gated to at most once every 60 seconds app-wide, and does NOT
    /// activate the app first.
    ///
    /// Only the background citekey-resolution retry path (`handleResolveCitekeys`) uses
    /// this -- that path can fire repeatedly on a timer while the user may be working in a
    /// completely different app, and would otherwise both spam the user AND yank focus away
    /// from whatever they're doing. Every other citation alert is a direct response to the
    /// user clicking the Citation button and always calls `present` instead: gating a
    /// click-response risks the user clicking, Zotero being down, and nothing appearing
    /// because an unrelated alert fired 40s earlier -- a silent failure. Not activating here
    /// means a `runModal()` fired while backgrounded can be invisible until the user next
    /// switches to the app -- an accepted trade-off versus stealing focus on a timer; the
    /// throttle plus `lastAlertTime` keeps this from compounding, and the next foreground
    /// citation action still gets the fully-activated `present` path.
    static func presentThrottled(_ kind: Kind, restoringFocusTo webView: WKWebView?, context: String) {
        let now = Date()
        guard now.timeIntervalSince(lastAlertTime) >= 60 else { return }
        lastAlertTime = now
        showAlert(kind, activatingApp: false)
        EditorFocusRestoration.restoreFocus(to: webView, context: context)
    }

    /// Builds and runs the shared NSAlert. `activatingApp` controls whether `NSApp.activate`
    /// is called first -- see the doc comments on `present` and `presentThrottled` for why
    /// only the direct, user-initiated path does this.
    private static func showAlert(_ kind: Kind, activatingApp: Bool) {
        let alert = NSAlert()
        alert.messageText = kind.title
        alert.informativeText = kind.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if activatingApp {
            // NSApp.keyWindow can be nil not just when there's truly no window but whenever
            // the app is simply backgrounded/inactive -- without this, runModal() below can
            // enter a nested modal loop while the app is invisible, blocking the main thread
            // with nothing visible until the user happens to click the app.
            NSApp.activate(ignoringOtherApps: true)
        }
        alert.runModal()
    }
}
