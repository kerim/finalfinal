//
//  MarkdownPageModel.swift
//  final finalTests
//
//  A tiny JavaScript model of the Markdown (CodeMirror) page's two readers, so a test can run the Swift side's own script strings
//  (`BlockSyncService.fetchContentScript`, `CodeMirrorEditor.Coordinator.preSwitchContentScript`) against a document without a web view.
//  Shared by ModeSwitchBibliographySurvivalTests and ZoomedMarkdownCloseKeepsNotesTests.
//
//  The model (web/codemirror/src/api.ts, anchor-plugin.ts): `getContentRaw()` is the document as the page holds it, hidden markers
//  included; `getContent()` is the document with every hidden marker stripped (`stripAnchors`, ALL_HIDDEN_MARKERS_REGEX, the bibliography
//  end marker and the zoom-notes marker included).
//

import Foundation
import JavaScriptCore
import Testing
@testable import final_final

enum MarkdownPageModel {

    /// `ALL_HIDDEN_MARKERS_REGEX` (web/codemirror/src/anchor-plugin.ts), as a JavaScript regex literal.
    static let hiddenMarkersJS =
        "/<!-- @sid:[0-9a-fA-F-]+ -->|<!-- ::auto-bibliography:: -->|<!-- ::auto-bibliography-end:: -->|<!-- ::zoom-notes:: -->/g"

    /// Runs `script` against a page holding `document` and returns its string answer. With `hasRawReader: false` the page has no
    /// `getContentRaw` (a Rich Text page).
    static func run(_ script: String, onPageHolding document: String, hasRawReader: Bool = true) throws -> String {
        let context = try #require(JSContext(), "JavaScriptCore is available")
        context.setObject(document, forKeyedSubscript: "pageDocument" as NSString)
        let rawReader = hasRawReader ? "getContentRaw: function() { return pageDocument; }," : ""
        context.evaluateScript("""
            var window = {};
            window.FinalFinal = {
                \(rawReader)
                getContent: function() { return pageDocument.replace(\(hiddenMarkersJS), ''); }
            };
            """)
        let answer = context.evaluateScript(script)
        let isString = answer?.isString == true
        return try #require(
            isString ? answer?.toString() : nil, "the script answered a string (exception: \(String(describing: context.exception)))")
    }
}
