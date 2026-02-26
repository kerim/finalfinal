//
//  PreviewViewController.swift
//  QuickLook Extension
//
//  QLPreviewingController that displays rendered markdown content
//  from .ff project packages using NSTextView.
//

import AppKit
import QuickLookUI
import Quartz

class PreviewViewController: NSViewController, QLPreviewingController {
    private var textView: NSTextView!

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 20, height: 20)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.backgroundColor = .textBackgroundColor
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        self.textView = textView
        self.view = scrollView
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            let data = try SQLiteReader.read(from: url)
            let attributed = MarkdownRenderer.render(title: data.title, markdown: data.markdown)
            textView.textStorage?.setAttributedString(attributed)
            handler(nil)
        } catch {
            let errorText = MarkdownRenderer.renderError()
            textView.textStorage?.setAttributedString(errorText)
            handler(nil)
        }
    }
}
