//
//  MarkdownClickRig.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 1, round 5: the rig for the tests of the Markdown editor-first
//  Delete Section click (`StructuralUndoController.performMarkdownEditorFirstDelete`). Real database, real `BlockSyncService` with its real
//  `DocumentWriter`, a real `StructuralUndoController`, and the REAL CodeMirror page (EditorTestHelper(editorType: .codemirror): the built
//  web bundle, main.ts's real extension set and the real `window.FinalFinal.markdownStructuralEditorFirst`) as the controller's active web
//  view. User typing is `userTypes(_:after:)`: a USER-origin transaction (`insertAtCursor`), a history step that moves no saved
//  post-op copy. `type(_:)` is `helper.setContent(text)`, the APPLICATION's own push (the page treats it as derived content: no history
//  step, and an entry's saved post-op copy that equals the document moves along with it). Use `type(_:)` only to set a document up, or to
//  stand in for an application push (a rebuild, a hierarchy fix); never as typing made after a click.
//
//  `observesPage: true` also wires a REAL `CodeMirrorEditor.Coordinator` (bound to the editor state the way ContentView binds it) as the
//  page's `contentChanged` handler, so the page's own reports reach the content record through `handleContentPush`, and the click's
//  adopt (`adoptMarkdownPageText`) has an observer. With `observesPage: false` nothing listens: the content record stays whatever the test
//  makes it (it lags the page, as it does in the app for the 50 ms before a `contentChanged` arrives).
//
//  The rig points `DocumentManager.shared` at its project (the debounced re-parse and the rebuild services read it) and `restore()` puts
//  it back; every test that makes a rig calls `restore()` in `tearDown`.
//
//  Needs `cd web && pnpm build` first (the host tests load the built bundle). NOT RUN by the coder.
//

import Foundation
import SwiftUI
import WebKit
import XCTest
@testable import final_final

/// The `[toast] show ...` lines of one rig's toast center (see `MarkdownClickRig.toastLog`).
final class ToastShownLog {
    var lines: [String] = []
}

@MainActor
final class MarkdownClickRig {
    let writerRig: MarkdownWriterRig
    let helper: EditorTestHelper
    let controller = StructuralUndoController()
    let unifiedUndo = UnifiedUndoService()
    let sectionSync = SectionSyncService()
    let bibliography = BibliographySyncService()
    let footnotes = FootnoteSyncService()
    let findBar = FindBarState()
    private(set) var coordinator: CodeMirrorEditor.Coordinator?
    private let priorDatabase: ProjectDatabase?
    private let priorProjectId: String?
    private let priorUndoController: StructuralUndoController?
    private let routesUndo: Bool
    private var priorProgressDelay: Duration?
    /// This rig's OWN toast center. A bare `EditorViewState` points at `ToastCenter.shared`, a process-wide singleton on which a standing
    /// warning (the 9-second "Some undo or redo presses could not be carried out.") stays until a view dismisses it: one test that
    /// provokes the notice would then make every later test's "no notice is showing" check fail (round 7b, ten failures with one toast id).
    let toastCenter = ToastCenter()
    /// Every toast this rig's center has SHOWN, in order (the center's own `[toast] show` lines). `current` only says what is on screen
    /// now; this also catches a notice that was shown and then replaced.
    let toastLog = ToastShownLog()

    var editorState: EditorViewState { writerRig.editorState }
    var markdownWriter: MarkdownBlockWriter { writerRig.markdownWriter }
    var db: ProjectDatabase { writerRig.db }
    var pid: String { writerRig.pid }

    /// `routesUndo` (round 7a, needs `observesPage`): the page's `structuralUndoRequested` / `structuralRedoRequested` / `historyEdited`
    /// messages reach the REAL coordinator, which routes them to this rig's controller exactly as the app does
    /// (`routeStructuralRequest` through `DocumentManager.shared.structuralUndoController`), so `press(_:)` is a real Cmd-Z.
    init(markdown: String, observesPage: Bool = false, routesUndo: Bool = false) async throws {
        writerRig = try MarkdownWriterRig(content: markdown)
        writerRig.editorState.toastCenter = toastCenter
        toastCenter.logSink = { [toastLog] line in
            if line.hasPrefix("[toast] show") { toastLog.lines.append(line) }
        }
        helper = EditorTestHelper(editorType: .codemirror)
        let documentManager = DocumentManager.shared
        priorDatabase = documentManager.projectDatabase
        priorProjectId = documentManager.projectId
        priorUndoController = documentManager.structuralUndoController
        self.routesUndo = routesUndo
        documentManager.projectDatabase = writerRig.db
        documentManager.projectId = writerRig.pid
        if routesUndo { documentManager.structuralUndoController = controller }

        if observesPage {
            let editorState = writerRig.editorState
            let sectionSync = sectionSync
            let coordinator = CodeMirrorEditor.Coordinator(
                content: Binding(get: { editorState.sourceContent }, set: { editorState.sourceContent = $0 }),
                cursorPositionToRestore: .constant(nil),
                scrollToOffset: .constant(nil),
                scrollToAnnotationIndex: .constant(nil),
                isResettingContent: Binding(get: { editorState.isResettingContent }, set: { editorState.isResettingContent = $0 }),
                onContentChange: { text, _ in
                    // What ContentView's closure does: the raw text is the source copy, the stripped text is the content record.
                    editorState.sourceContent = text
                    editorState.content = SectionSyncService.stripBibliographyMarker(from: sectionSync.stripSectionAnchors(from: text))
                },
                onStatsChange: { _, _ in },
                onSectionChange: { _ in },
                onCursorPositionSaved: { _ in },
                onWebViewReady: nil,
                windowToken: editorState.windowToken)
            coordinator.isEditorReady = true
            helper.webView.configuration.userContentController.add(coordinator, name: "contentChanged")
            if routesUndo {
                let undoMessages = [
                    "structuralUndoRequested", "structuralRedoRequested", "historyEdited", "undoHeldPressSettled", "undoQueueDropped"
                ]
                for name in undoMessages {
                    helper.webView.configuration.userContentController.add(coordinator, name: name)
                }
            }
            self.coordinator = coordinator
        }
        do {
            try await helper.loadAndWaitForReady()
            try await helper.setContent(markdown)
        } catch {
            // A failed set-up never reaches the test's `tearDown` (the rig was not assigned), so the process-wide state it pointed at
            // this project is put back here (review C.F12).
            restore()
            throw error
        }

        bibliography.configure(database: writerRig.db, projectId: writerRig.pid)
        footnotes.configure(database: writerRig.db, projectId: writerRig.pid)
        sectionSync.configure(database: writerRig.db, projectId: writerRig.pid)
        controller.configure(
            editorState: writerRig.editorState, blockSyncService: writerRig.sync, sectionSyncService: sectionSync,
            bibliographySyncService: bibliography, footnoteSyncService: footnotes, annotationSyncService: AnnotationSyncService(),
            unifiedUndoService: unifiedUndo, findBarState: findBar)
        controller.activeWebView = helper.webView
        if routesUndo {
            // A WKWebView outside a window never runs requestAnimationFrame: the sidebar update that waits for the editor's paint stands
            // in with an immediate frame (the controller's own test seam).
            controller.testNextPaintWait = {}
        }
        editorState.sections = try db.fetchOutlineBlocks(projectId: pid).map { SectionViewModel(from: $0) }
        MarkdownEditorFirstSwitch.enabled = true
    }

    /// Puts the process-wide state back (call from `tearDown`).
    func restore() {
        if let priorProgressDelay { DelayedProgressToast.defaultDelay = priorProgressDelay }
        priorProgressDelay = nil
        editorState.lifecycleHost = nil
        MarkdownEditorFirstSwitch.enabled = MarkdownEditorFirstSwitch.productionDefault
        if routesUndo { DocumentManager.shared.structuralUndoController = priorUndoController }
        DocumentManager.shared.projectDatabase = priorDatabase
        DocumentManager.shared.projectId = priorProjectId
    }

    // MARK: - Helpers

    func section(_ title: String) throws -> Block {
        try XCTUnwrap(try writerRig.heading(title), "no heading titled \(title)")
    }

    /// The page's raw document.
    func pageText() async throws -> String {
        let answer = try await helper.webView.evaluateJavaScript("window.FinalFinal.getContentRaw()")
        return try XCTUnwrap(answer as? String)
    }

    /// The user types: the page's document becomes `text`. NOTE (round 6): this is `setContent`, the application's own push; the page
    /// treats it as derived content (no history step, and a saved post-op copy that equals the document moves along with it). Use
    /// `userTypes(_:after:)` wherever the test is about what the user typed.
    func type(_ text: String) async throws {
        try await helper.setContent(text)
    }

    /// The user types `text` right after the first `marker` in the page, as a keystroke does: a USER-origin transaction (a history step;
    /// it does not move any saved post-op copy). Returns the page's raw text afterwards.
    @discardableResult
    func userTypes(_ text: String, after marker: String) async throws -> String {
        try await helper.userTypes(text, after: marker)
    }

    /// What ContentView does and the rig does not: the host `EditorViewState.lifecycleHost` carries the closures the production code
    /// calls to arm a re-parse (`scheduleSourceModeReparse`) and to find the page. Here a scheduled re-parse is the REAL debounced
    /// scheduler pointed at this project (`MarkdownWriterRig.schedule`). Opt-in: a test that needs the app's re-arming calls this.
    func installReparseHost() {
        let writerRig = writerRig
        let webView = helper.webView
        editorState.lifecycleHost = LifecycleHost(
            activeWebView: { webView },
            runOpenTail: { _ in },
            runCreateTail: { _, _ in },
            runCloseTail: { _, _ in },
            repostDeferredRebuilds: {},
            scheduleSourceModeReparse: { text in _ = writerRig.schedule(text) },
            toastCenter: { ToastCenter() })
    }

    /// Makes the "Finishing the last change…" / "Undoing…" notices show after `delay` instead of one second (put back by `restore()`).
    func shortenProgressDelay(_ delay: Duration = .milliseconds(150)) {
        if priorProgressDelay == nil { priorProgressDelay = DelayedProgressToast.defaultDelay }
        DelayedProgressToast.defaultDelay = delay
    }

    /// A real Cmd-Z (`"undo"`) or Cmd-Shift-Z (`"redo"`) keydown on the editor's content element: the page's capture-phase interceptor
    /// decides structural or text, a structural press reaches the controller through the real coordinator (`routesUndo`).
    func press(_ direction: String, times: Int = 1) async throws {
        let isRedo = direction == "redo"
        _ = try await helper.webView.evaluateJavaScript(
            """
            (() => {
              const el = document.querySelector('.cm-content');
              for (let n = 0; n < \(times); n++) {
                el.dispatchEvent(new KeyboardEvent('keydown', {
                  key: '\(isRedo ? "Z" : "z")', code: 'KeyZ', keyCode: 90, metaKey: true, shiftKey: \(isRedo ? "true" : "false"),
                  bubbles: true, cancelable: true
                }));
              }
              return true;
            })()
            """)
    }

    /// The page posts `body` (a JSON object literal) to its message handler `name`, as its own undo coordinator does.
    func postPageMessage(_ name: String, body: String) async throws {
        _ = try await helper.webView.evaluateJavaScript(
            "(() => { window.webkit.messageHandlers.\(name).postMessage(\(body)); return true; })()")
    }

    /// How many presses the page holds behind its undo latch right now.
    func heldPressCount() async throws -> Int {
        let count = try await helper.webView.evaluateJavaScript("window.FinalFinal.heldUndoPressCount()")
        return (count as? NSNumber)?.intValue ?? -1
    }

    /// Waits until the page's raw text satisfies `condition`; returns the last text read.
    @discardableResult
    func waitForPage(seconds: Double = 8, _ condition: (String) -> Bool) async throws -> String {
        let deadline = ContinuousClock.now + .seconds(seconds)
        var text = try await pageText()
        while !condition(text), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            text = try await pageText()
        }
        return text
    }

    /// Waits (polling, up to `seconds`) until `condition` holds.
    func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Everything the click started has finished: the job and its settle, the hold, the writer's last write.
    func settleEverything() async {
        await editorState.efJobRegistry.awaitAllSettled()
        _ = await waitUntil { !markdownWriter.isHeldForStructuralWork }
        await writerRig.settle()
    }

    /// A job-body hold: the queued Delete job blocks on the writer's thread until `release()` (the existing `testEFJobBodyHold` seam).
    final class JobHold: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        func wait() { semaphore.wait() }
        func release() { semaphore.signal() }
    }

    func holdNextJob() -> JobHold {
        let hold = JobHold()
        controller.testEFJobBodyHold = { hold.wait() }
        return hold
    }

    /// The same for the quick undo's reinsert job (the controller's `testReinsertBodyHold`): it blocks the writer's thread until released.
    func holdReinsert() -> JobHold {
        let hold = JobHold()
        controller.testReinsertBodyHold = { hold.wait() }
        return hold
    }
}

extension EditorTestHelper {
    /// The user types `text` right after the first `marker` in the page, as a keystroke does: a USER-origin transaction (`setCursorPosition`
    /// then `insertAtCursor`, a history step that moves no saved post-op copy). NOT `setContent`: that is the application's own push, which
    /// the page treats as derived content. Returns the page's raw text afterwards.
    @discardableResult
    func userTypes(_ text: String, after marker: String) async throws -> String {
        let markerLiteral = try XCTUnwrap(StructuralUndoController.jsLiteral(marker))
        let textLiteral = try XCTUnwrap(StructuralUndoController.jsLiteral(text))
        let typed = try await webView.evaluateJavaScript(
            """
            (() => {
              const ff = window.FinalFinal;
              const doc = ff.getContentRaw();
              const at = doc.indexOf(\(markerLiteral));
              if (at < 0) return false;
              const before = doc.slice(0, at + \(markerLiteral).length);
              ff.setCursorPosition({ line: before.split('\\n').length, column: before.length - (before.lastIndexOf('\\n') + 1) });
              ff.insertAtCursor(\(textLiteral));
              return true;
            })()
            """)
        XCTAssertEqual(typed as? Bool, true, "premise: the marker \(marker) is in the page")
        let raw = try await webView.evaluateJavaScript("window.FinalFinal.getContentRaw()")
        return try XCTUnwrap(raw as? String)
    }
}
