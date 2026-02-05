//
//  MarkdownUtils.swift
//  final final
//
//  Utilities for processing markdown text, including stripping syntax
//  for accurate word counts.
//

import Foundation

enum MarkdownUtils {
    /// Strip markdown syntax from content to get plain text
    /// Used for accurate word counting that excludes formatting symbols
    static func stripMarkdownSyntax(from content: String) -> String {
        var result = content

        // Remove heading markers: # ## ### etc at line start
        let headingPattern = "^#{1,6}\\s+"
        if let regex = try? NSRegularExpression(pattern: headingPattern, options: .anchorsMatchLines) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Remove bold/italic markers: ** __ * _
        // Handle bold first (** and __), then italic (* and _)
        let boldPattern = "\\*\\*(.+?)\\*\\*|__(.+?)__"
        if let regex = try? NSRegularExpression(pattern: boldPattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1$2")
        }

        let italicPattern = "\\*([^*]+)\\*|_([^_]+)_"
        if let regex = try? NSRegularExpression(pattern: italicPattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1$2")
        }

        // Remove strikethrough: ~~text~~
        let strikethroughPattern = "~~(.+?)~~"
        if let regex = try? NSRegularExpression(pattern: strikethroughPattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
        }

        // Remove inline code backticks: `code`
        let inlineCodePattern = "`([^`]+)`"
        if let regex = try? NSRegularExpression(pattern: inlineCodePattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
        }

        // Convert links [text](url) to just text
        let linkPattern = "\\[([^\\]]+)\\]\\([^)]+\\)"
        if let regex = try? NSRegularExpression(pattern: linkPattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
        }

        // Remove images ![alt](url) entirely (don't count alt text as words)
        let imagePattern = "!\\[[^\\]]*\\]\\([^)]+\\)"
        if let regex = try? NSRegularExpression(pattern: imagePattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Remove list markers: - * + or 1. 2. etc
        let listPattern = "^\\s*(?:[-*+]|\\d+\\.)\\s+"
        if let regex = try? NSRegularExpression(pattern: listPattern, options: .anchorsMatchLines) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Remove blockquote markers: > at line start
        let blockquotePattern = "^>+\\s*"
        if let regex = try? NSRegularExpression(pattern: blockquotePattern, options: .anchorsMatchLines) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Remove section break markers: <!-- ::break:: -->
        let breakPattern = "<!--\\s*::break::\\s*-->"
        if let regex = try? NSRegularExpression(pattern: breakPattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Remove code fence markers: ```language
        let codeFencePattern = "^```[a-zA-Z]*\\s*$"
        if let regex = try? NSRegularExpression(pattern: codeFencePattern, options: .anchorsMatchLines) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Remove horizontal rules: ---, ***, ___
        let hrPattern = "^[-*_]{3,}\\s*$"
        if let regex = try? NSRegularExpression(pattern: hrPattern, options: .anchorsMatchLines) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Remove annotations: <!-- ::type:: content -->
        result = stripAnnotations(from: result)

        return result
    }

    /// Strip annotation HTML comments from content
    /// Annotations follow the pattern: <!-- ::type:: content -->
    /// where type is task, comment, reference, or break
    static func stripAnnotations(from content: String) -> String {
        var result = content

        // Pattern matches: <!-- ::word:: any content -->
        // This handles task, comment, reference, break, and auto-bibliography annotations
        let annotationPattern = "<!--\\s*::\\w+::\\s*[\\s\\S]*?-->"
        if let regex = try? NSRegularExpression(pattern: annotationPattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        return result
    }

    /// Count words in markdown content, excluding syntax symbols
    static func wordCount(for content: String) -> Int {
        let text = stripMarkdownSyntax(from: content)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        return trimmed.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
    }
}
