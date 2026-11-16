//
//  EditorPreloader+Prepare.swift
//  final final
//
//  Phase 5 jobs A9 and A10 (design: docs/architecture/write-queue-plan/phase5/a7-a10-design.md, sections 3 and 4; run record
//  a9-notes.md): the incoming page of a switch between Rich Text and Markdown is filled BEFORE the flip, while it is still detached (the
//  standby page, or a fresh one loaded now when no standby is ready), so the outgoing page stays on screen and typeable until the incoming
//  page has its text (the sync model's TransIncomingReady, round 4, TransTwoPage). At the flip the filled page is STAGED here and the
//  incoming editor's `makeNSView` claims it in place of the standby, skipping its own content handover.
//
//  Focus: the staged page makes itself first responder the moment SwiftUI attaches it to the window (`FocusOnAttachWebView`), in the same
//  view commit that detaches the outgoing page, so there is no turn in which keys go to no editor (today's `restoreEditorFocus` runs one or
//  two run-loop turns later and stays as a second, idempotent step).
//

import AppKit
import WebKit

/// A WKWebView that takes keyboard focus the moment it is attached to a window, once, when asked to (`focusOnAttach`).
final class FocusOnAttachWebView: WKWebView {
    var focusOnAttach = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusOnAttach, let window else { return }
        focusOnAttach = false
        let took = window.makeFirstResponder(self)
        DebugLog.alwaysPersisted("[TRANS] incoming page focused on attach ok=\(took)")
    }
}

/// Keeps a key typed at the flip from landing twice (hand test 2026-11-06, a9-notes.md, "Cursor fix and switch notice";
/// run-1793948299-61623: "fivee", the `e` logged twice by `[TYPING-TRACE] key` with one timestamp). A key that reaches the OUTGOING page
/// as the flip removes it from the window is typed there (the catch-up carries it), but WebKit, which loses the page's answer with the
/// window, reports it unhandled and re-sends the same NSEvent through `[NSApp sendEvent:]` (the resend the Escape monitor already guards
/// against, AppDelegate.swift); by then the incoming page has the focus and types it a second time. While a switch's flip is under way
/// this monitor drops such a resend: the same event (timestamp and key code) seen a second time, first seen while the outgoing page had
/// the focus, which no longer has it. Keys with Command or Control, and Escape, pass untouched (their resend is how menus see them).
@MainActor
final class SwitchKeyResendFilter {
    static let shared = SwitchKeyResendFilter()

    private var monitor: Any?
    private weak var outgoing: NSView?
    /// The keys seen since the filter was armed, and whether the outgoing page had the focus at the first sight.
    private var seen: [KeySighting] = []
    private var disarmTask: Task<Void, Never>?

    private struct KeySighting {
        let timestamp: TimeInterval
        let keyCode: UInt16
        let toOutgoing: Bool
    }

    /// Arms the filter for a flip away from `page` (idempotent; a later arm replaces the page).
    func arm(outgoing page: NSView) {
        disarmTask?.cancel()
        disarmTask = nil
        outgoing = page
        seen.removeAll()
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let (timestamp, keyCode, flags) = (event.timestamp, event.keyCode, event.modifierFlags.rawValue)
            let drop = MainActor.assumeIsolated {
                SwitchKeyResendFilter.shared.isResend(timestamp: timestamp, keyCode: keyCode, flags: NSEvent.ModifierFlags(rawValue: flags))
            }
            return drop ? nil : event
        }
    }

    /// Disarms the filter half a second from now (a resend comes within tens of milliseconds of the key).
    func disarmSoon() {
        disarmTask?.cancel()
        disarmTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            if let monitor = self.monitor { NSEvent.removeMonitor(monitor) }
            self.monitor = nil
            self.outgoing = nil
            self.seen.removeAll()
        }
    }

    /// True for the resend described above (the caller drops it); records every other key.
    private func isResend(timestamp: TimeInterval, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        if flags.contains(.command) || flags.contains(.control) || keyCode == 53 { return false }
        let responder = NSApp.keyWindow?.firstResponder as? NSView
        let onOutgoing = outgoing.map { responder?.isDescendant(of: $0) == true } ?? false
        if let first = seen.first(where: { $0.timestamp == timestamp && $0.keyCode == keyCode }) {
            guard first.toOutgoing, !onOutgoing else { return false }
            // t-561c4083: no key code in the log (a run of key codes reads back what was typed).
            DebugLog.alwaysPersisted("[TRANS] dropped the resend of a key typed in the outgoing page at the flip")
            return true
        }
        seen.append(KeySighting(timestamp: timestamp, keyCode: keyCode, toOutgoing: onOutgoing))
        if seen.count > 64 { seen.removeFirst(seen.count - 64) }
        return false
    }
}

/// An incoming page filled before the flip, waiting for its editor's `makeNSView`. `content` is the text it holds (what the coordinator
/// records as already pushed, so `updateNSView` does not push it again).
struct StagedSwitchPage {
    let webView: WKWebView
    let content: String
}

extension EditorPreloader {
    /// The bound on loading a fresh page for a switch (the Markdown page wait's bound; a page that never loads is a fault).
    nonisolated static let switchPageLoadTimeout: Duration = .seconds(15)

    /// A loaded CodeMirror page for a switch to Markdown, still detached: the standby when it is ready (a replacement starts loading, as a
    /// claim always does), else a fresh page loaded now and awaited (bounded). Nil when no page could be loaded.
    func takeCodeMirrorPageForSwitch(timeout: Duration = EditorPreloader.switchPageLoadTimeout) async -> WKWebView? {
        if case .ready = codemirrorState, let standby = claimCodeMirrorView() {
            DebugLog.alwaysPersisted("[TRANS] switch page: the Markdown standby page")
            return standby
        }
        guard let webView = makeLoadingCodeMirrorWebView() else { return nil }
        let clock = ContinuousClock()
        let start = clock.now
        guard await waitForPrepareLoad(webView, timeout: timeout) else {
            DebugLog.alwaysPersisted("[TRANS] switch page: a fresh Markdown page did not load")
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "errorHandler")
            return nil
        }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "errorHandler")
        DebugLog.alwaysPersisted("[TRANS] switch page: a fresh Markdown page loaded in \(Self.milliseconds(clock.now - start)) ms")
        return webView
    }

    /// A loaded Rich Text page for a switch to Rich Text (job A10), still detached and with its editor mounted: the standby when it is
    /// ready (with its citation memo and prefill, claimed exactly where `claimMilkdownView` claims it today), else a fresh page loaded now
    /// and awaited (bounded). Nil when no page could be loaded or its editor never mounted.
    func takeMilkdownPageForSwitch(timeout: Duration = EditorPreloader.switchPageLoadTimeout) async -> WKWebView? {
        let clock = ContinuousClock()
        let start = clock.now
        let page: WKWebView
        if case .ready = milkdownState, let standby = claimMilkdownView() {
            DebugLog.alwaysPersisted("[TRANS] switch page: the Rich Text standby page")
            page = standby
        } else {
            guard let webView = makeLoadingMilkdownWebView() else { return nil }
            let loaded = await waitForPrepareLoad(webView, timeout: timeout)
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "errorHandler")
            guard loaded else {
                DebugLog.alwaysPersisted("[TRANS] switch page: a fresh Rich Text page did not load")
                return nil
            }
            // The same as a fresh page's own mount does (MilkdownCoordinator `didFinish`): UI tests that run without the citation memo.
            if TestMode.isUITestingCitationMemoOff { _ = try? await webView.evaluateJavaScript(CitationPrefillTestScripts.memoOff) }
            page = webView
        }
        // The editor itself is created asynchronously after the page load (main.ts `initEditor`): wait for it, as the mount gate does.
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if (try? await page.evaluateJavaScript("window.FinalFinal && window.FinalFinal.isEditorReady() === true")) as? Bool == true {
                DebugLog.alwaysPersisted("[TRANS] switch page: the Rich Text editor ready in \(Self.milliseconds(clock.now - start)) ms")
                return page
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        DebugLog.alwaysPersisted("[TRANS] switch page: the Rich Text editor never mounted")
        return nil
    }

    /// Stages the filled Rich Text page for the flip: the Milkdown `makeNSView` that the flip causes claims it.
    func stageMilkdownPage(_ webView: WKWebView, content: String) {
        (webView as? FocusOnAttachWebView)?.focusOnAttach = true
        suppressOutgoingCursorSave = true
        stagedMilkdown = StagedSwitchPage(webView: webView, content: content)
    }

    /// The staged Rich Text page, handed over once.
    func claimStagedMilkdownPage() -> StagedSwitchPage? {
        defer { stagedMilkdown = nil }
        return stagedMilkdown
    }

    /// Waits for a fresh page's load to finish (this object is its navigation delegate). False on a failed load or the bound.
    func waitForPrepareLoad(_ webView: WKWebView, timeout: Duration) async -> Bool {
        let key = ObjectIdentifier(webView)
        return await withCheckedContinuation { continuation in
            prepareLoads[key] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finishPrepareLoad(webView, loaded: false)
            }
        }
    }

    /// Resumes the wait for `webView`'s load, once (later calls find nothing to resume).
    func finishPrepareLoad(_ webView: WKWebView, loaded: Bool) {
        guard let continuation = prepareLoads.removeValue(forKey: ObjectIdentifier(webView)) else { return }
        continuation.resume(returning: loaded)
    }

    // MARK: - The handover at the flip

    /// Stages the filled Markdown page for the flip: the CodeMirror `makeNSView` that the flip causes claims it. The page takes keyboard
    /// focus when it is attached.
    func stageCodeMirrorPage(_ webView: WKWebView, content: String) {
        (webView as? FocusOnAttachWebView)?.focusOnAttach = true
        suppressOutgoingCursorSave = true
        stagedCodeMirror = StagedSwitchPage(webView: webView, content: content)
    }

    /// The staged Markdown page, handed over once (nil when no switch staged one).
    func claimStagedCodeMirrorPage() -> StagedSwitchPage? {
        defer { stagedCodeMirror = nil }
        return stagedCodeMirror
    }

    /// True once after a carried switch's flip (the outgoing page's dismantle asks); false otherwise.
    func consumeOutgoingCursorSaveSuppression() -> Bool {
        defer { suppressOutgoingCursorSave = false }
        return suppressOutgoingCursorSave
    }

    /// Forgets a staged page nobody claimed (a switch that ended before its editor was made).
    func discardStagedPages() {
        stagedCodeMirror = nil
        stagedMilkdown = nil
        suppressOutgoingCursorSave = false
    }

    nonisolated static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
