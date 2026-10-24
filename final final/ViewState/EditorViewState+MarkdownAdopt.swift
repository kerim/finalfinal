//
//  EditorViewState+MarkdownAdopt.swift
//  final final
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), round 4, O25/O30: the ONE adopter through which text the PAGE holds
//  (a region replace's `postRaw`, a pulled live text, and in round 5 the structural click's `postRaw`) becomes the content record.
//
//  `adoptMarkdownPageText(raw)` posts `.markdownEditorFirstAdoptText` carrying the window token; the window's CodeMirror coordinator
//  observes it SYNCHRONOUSLY (`queue: nil`, so the observer has finished when the post returns) and handles the text exactly as a
//  page `contentChanged` message that no guard drops: `lastPushedContent = raw` (so `shouldPushContent` has nothing to push),
//  `sourceContent = raw` through its binding, and `onContentChange(raw)` (which strips the anchors into `content`). No Swift push into
//  the editor follows, and the 150 ms push grace is NOT started (this text did not come from Swift).
//
//  Rounds 5 to 7 call this in the same synchronous turn as the page's reply (O25: step 8, the undo and redo swap, the click).
//

import Foundation

extension Notification.Name {
    /// Posted by `EditorViewState.adoptMarkdownPageText`. userInfo: `windowToken` (UUID), `raw` (String).
    static let markdownEditorFirstAdoptText = Notification.Name("markdownEditorFirstAdoptText")
}

extension EditorViewState {

    /// Makes `raw`, text the Markdown page already holds (anchors and markers included), the content record: `sourceContent`, `content`
    /// and the coordinator's `lastPushedContent`. Synchronous.
    func adoptMarkdownPageText(_ raw: String) {
        NotificationCenter.default.post(
            name: .markdownEditorFirstAdoptText, object: nil, userInfo: ["windowToken": windowToken, "raw": raw])
    }
}
