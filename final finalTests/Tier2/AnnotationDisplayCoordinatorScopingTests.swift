//
//  AnnotationDisplayCoordinatorScopingTests.swift
//  final finalTests
//
//  Tier 2: the REAL editor coordinators (Milkdown and CodeMirror) receive annotation display posts
//  from their own window's EditorViewState and from no other window's -- the wiring the unit suite
//  used to leave uncovered (a coordinator that never subscribed, a token that was dropped or
//  invented at the representable, or a missing guard would all have stayed green).
//
//  Each coordinator gets a WKWebView subclass that records `evaluateJavaScript` instead of
//  running it, and `isEditorReady = true`. Three posts are made through `AnnotationDisplayBroadcast`:
//  this window's token (its JS is recorded), another window's token (nothing), and no token
//  (nothing). What the compiler already enforces, and so needs no test: the token is a REQUIRED
//  parameter of both representables and both coordinator initializers, so a creation site that
//  omits it does not build.
//

import Testing
import Foundation
import WebKit
@testable import final_final

/// Records every script instead of running it.
@MainActor
private final class RecordingWebView: WKWebView {
    private(set) var scripts: [String] = []

    /// How many times the display state was pushed to the editor.
    var displayPushCount: Int { scripts.filter { $0.contains("setAnnotationDisplayModes") }.count }

    override func evaluateJavaScript(
        _ javaScriptString: String,
        completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil
    ) {
        scripts.append(javaScriptString)
        completionHandler?(nil, nil)
    }
}

@Suite(.serialized)
struct AnnotationDisplayCoordinatorScopingTests {

    private let modes: [AnnotationType: AnnotationDisplayMode] = [.task: .inline, .comment: .collapsed, .reference: .inline]

    /// The editors observe with `queue: .main`, so a post is applied on a later main-queue turn.
    @MainActor
    private func letMainQueueRun() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    /// Post as this window, as another window, and with no token; the editor must react to the first only.
    @MainActor
    private func exerciseScoping(ownToken: UUID, editor: RecordingWebView) async {
        AnnotationDisplayBroadcast.post(modes: modes, isPanelOnly: false, hideCompletedTasks: false, windowToken: ownToken)
        await letMainQueueRun()
        #expect(editor.displayPushCount == 1, "A post from this window's state reaches its editor")

        AnnotationDisplayBroadcast.post(modes: modes, isPanelOnly: false, hideCompletedTasks: false, windowToken: UUID())
        await letMainQueueRun()
        #expect(editor.displayPushCount == 1, "A post from another window's state does not")

        // No token at all. Spelled out with the wire name on purpose: production code cannot post
        // without a token (the name is private to the broadcast type).
        NotificationCenter.default.post(
            name: Notification.Name("annotationDisplayModesChanged"), object: nil, userInfo: ["modes": modes, "isPanelOnly": false]
        )
        await letMainQueueRun()
        #expect(editor.displayPushCount == 1, "A post carrying no token does not")
    }

    @Test("A Milkdown coordinator applies only its own window's annotation display posts")
    @MainActor
    func milkdownCoordinatorIsScopedToItsWindow() async {
        let token = UUID()
        let webView = RecordingWebView(frame: .zero)
        let coordinator = MilkdownEditor.Coordinator(
            content: .constant(""),
            cursorPositionToRestore: .constant(nil),
            scrollToOffset: .constant(nil),
            scrollToBlockId: .constant(nil),
            isResettingContent: .constant(false),
            contentState: .idle,
            onContentChange: { _, _ in },
            onStatsChange: { _, _ in },
            onSectionChange: { _ in },
            onCursorPositionSaved: { _ in },
            onContentAcknowledged: nil,
            onWebViewReady: nil,
            windowToken: token
        )
        coordinator.webView = webView
        coordinator.isEditorReady = true

        await exerciseScoping(ownToken: token, editor: webView)
    }

    @Test("A CodeMirror coordinator applies only its own window's annotation display posts")
    @MainActor
    func codeMirrorCoordinatorIsScopedToItsWindow() async {
        let token = UUID()
        let webView = RecordingWebView(frame: .zero)
        let coordinator = CodeMirrorEditor.Coordinator(
            content: .constant(""),
            cursorPositionToRestore: .constant(nil),
            scrollToOffset: .constant(nil),
            scrollToAnnotationIndex: .constant(nil),
            isResettingContent: .constant(false),
            onContentChange: { _, _ in },
            onStatsChange: { _, _ in },
            onSectionChange: { _ in },
            onCursorPositionSaved: { _ in },
            onWebViewReady: nil,
            windowToken: token
        )
        coordinator.webView = webView
        coordinator.isEditorReady = true

        await exerciseScoping(ownToken: token, editor: webView)
    }

    // The same, one step earlier: the coordinator SwiftUI creates for the representable carries the
    // token the representable was given (a `makeCoordinator()` that dropped or invented it fails here).
    @Test("The coordinators the representables create carry the representables' window token")
    @MainActor
    func representablesHandTheirTokenToTheirCoordinators() async {
        let milkdownToken = UUID()
        let milkdownWebView = RecordingWebView(frame: .zero)
        let milkdown = MilkdownEditor(
            content: .constant(""),
            focusModeEnabled: .constant(false),
            cursorPositionToRestore: .constant(nil),
            scrollToOffset: .constant(nil),
            scrollToBlockId: .constant(nil),
            scrollToAnnotationIndex: .constant(nil),
            isResettingContent: .constant(false),
            windowToken: milkdownToken,
            onContentChange: { _, _ in },
            onStatsChange: { _, _ in },
            onSectionChange: { _ in },
            onCursorPositionSaved: { _ in }
        ).makeCoordinator()
        milkdown.webView = milkdownWebView
        milkdown.isEditorReady = true
        await exerciseScoping(ownToken: milkdownToken, editor: milkdownWebView)

        let codeMirrorToken = UUID()
        let codeMirrorWebView = RecordingWebView(frame: .zero)
        let codeMirror = CodeMirrorEditor(
            content: .constant(""),
            focusModeEnabled: .constant(false),
            cursorPositionToRestore: .constant(nil),
            scrollToOffset: .constant(nil),
            scrollToAnnotationIndex: .constant(nil),
            isResettingContent: .constant(false),
            pendingImageMeta: .constant(nil),
            windowToken: codeMirrorToken,
            onContentChange: { _, _ in },
            onStatsChange: { _, _ in },
            onSectionChange: { _ in },
            onCursorPositionSaved: { _ in }
        ).makeCoordinator()
        codeMirror.webView = codeMirrorWebView
        codeMirror.isEditorReady = true
        await exerciseScoping(ownToken: codeMirrorToken, editor: codeMirrorWebView)
    }
}
