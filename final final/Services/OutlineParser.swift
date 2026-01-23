//
//  OutlineParser.swift
//  final final
//
//  Stub - full implementation in Phase 1.2.
//

import Foundation

struct OutlineParser {
    static func parse(markdown: String, projectId: String) -> [OutlineNode] {
        []
    }

    static func extractPreview(from markdown: String, startOffset: Int, endOffset: Int, maxLines: Int = 4) -> String {
        ""
    }

    static func wordCount(in text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}
