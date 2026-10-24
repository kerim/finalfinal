//
//  EditorViewState+MarkdownLiveText.swift
//  final final
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), round 6: the Markdown counterpart of `adoptLiveEditorText`
//  (EditorViewState+RebuildGuard.swift), which the shared settle code and the stale-rebuild tails call to "read what the editor holds now
//  and make it the content record".
//
//  WHY THE RICH TEXT BODY CANNOT RUN IN MARKDOWN. It asks `BlockSyncService.fetchContentFromWebView`, which reads the service's own
//  web view, set from the Rich Text page only (`BlockSyncService` doc comment above `fetchContentScript`): in Markdown mode it has none
//  and answers nil, so the body would "keep the current content" -- which a rebuild handler has just set to the DATABASE's text. The
//  record would then hold the database's text while the editor holds its own. It would also announce the text with
//  `.blockSyncDidPushContent`, which the Rich Text coordinator answers and the CodeMirror one must not.
//
//  WHAT THIS DOES. It reads the Markdown page's raw text (`getContentRaw`, from the window's active web view) and hands it to the ONE
//  Markdown adopter (`adoptMarkdownPageText`, O25): `sourceContent`, `content` and the coordinator's `lastPushedContent` in one
//  synchronous turn, with no push back into the page. Nothing is written to the database here; the writer's baseline moves only through
//  its own paths (step 8's flush, the owed pull's re-parse).
//

import Foundation
import WebKit

extension EditorViewState {

    /// Markdown branch of `adoptLiveEditorText`. `readLive` is a test seam for the page's raw text; nil reads `getContentRaw()` from the
    /// window's active web view. Returns the text now held as `content` (anchors stripped, as every other reader of `content` expects);
    /// when the editor does not answer, the current `content` is returned unchanged and the gap is logged.
    @discardableResult
    func adoptLiveMarkdownText(why: String, requireUnchangedGeneration: Bool = true, readLive: (() async -> String?)? = nil) async -> String {
        let generationBefore = editorRestoreGeneration
        let raw: String?
        if let readLive {
            raw = await readLive()
        } else if let webView = lifecycleHost?.activeWebView() {
            raw = (try? await webView.evaluateJavaScript("window.FinalFinal.getContentRaw()")) as? String
        } else {
            raw = nil
        }
        if requireUnchangedGeneration, editorRestoreGeneration != generationBefore { return content }
        guard let raw else {
            let message = "[EditorViewState] " + why + ": the Markdown editor did not answer -- keeping the current content until its next change"
            DebugLog.alwaysPersisted(message)
            return content
        }
        adoptMarkdownPageText(raw)
        return content
    }
}
