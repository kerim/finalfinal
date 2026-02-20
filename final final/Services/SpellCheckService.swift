//
//  SpellCheckService.swift
//  final final
//
//  Bridges NSSpellChecker to web editors via message handlers.
//  Uses the unified check() API for spelling.
//  Grammar checking is deferred to LanguageTool (optional).
//

import AppKit

@MainActor
final class SpellCheckService {
    static let shared = SpellCheckService()
    private let checker = NSSpellChecker.shared
    private var documentTag: Int = 0
    private init() {}

    struct TextSegment: Codable, Sendable {
        let text: String
        let from: Int   // Editor position (UTF-16 code unit offset)
        let to: Int
    }

    struct SpellCheckResult: Codable, Sendable {
        let from: Int          // Editor position (UTF-16 code unit offset)
        let to: Int
        let word: String
        let type: String       // "spelling" or "grammar"
        let suggestions: [String]
        let message: String?   // Grammar explanation (nil for spelling; reserved for LanguageTool)
    }

    // MARK: - Document Tag Lifecycle

    func openDocument() {
        documentTag = NSSpellChecker.uniqueSpellDocumentTag()
    }

    func closeDocument() {
        checker.closeSpellDocument(withTag: documentTag)
        documentTag = 0
    }

    // MARK: - Batch Checking

    /// Batch check segments for spelling errors using NSSpellChecker.
    func check(segments: [TextSegment]) async -> [SpellCheckResult] {
        var allResults: [SpellCheckResult] = []

        for segment in segments {
            guard !Task.isCancelled else { return allResults }

            await Task.yield()  // Yield between segments for main thread responsiveness

            let nsString = segment.text as NSString
            let range = NSRange(location: 0, length: nsString.length)

            var orthography: NSOrthography?
            var wordCount: Int = 0
            let results = checker.check(
                segment.text, range: range,
                types: NSTextCheckingAllTypes,
                options: [:],
                inSpellDocumentWithTag: documentTag,
                orthography: &orthography,
                wordCount: &wordCount)

            // Process spelling results
            for result in results where result.resultType == .spelling {
                let word = nsString.substring(with: result.range)
                let jsFrom = segment.from + result.range.location
                let jsTo = segment.from + NSMaxRange(result.range)
                let suggestions = checker.guesses(
                    forWordRange: result.range, in: segment.text,
                    language: nil, inSpellDocumentWithTag: documentTag) ?? []
                allResults.append(SpellCheckResult(
                    from: jsFrom, to: jsTo, word: word,
                    type: "spelling", suggestions: suggestions, message: nil))
            }
        }
        return allResults
    }

    // MARK: - Learn / Ignore

    func learnWord(_ word: String) {
        checker.learnWord(word)
    }

    func ignoreWord(_ word: String) {
        checker.ignoreWord(word, inSpellDocumentWithTag: documentTag)
    }
}
