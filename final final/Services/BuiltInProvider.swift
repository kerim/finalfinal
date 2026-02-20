//
//  BuiltInProvider.swift
//  final final
//
//  Wraps NSSpellChecker for spelling-only proofing.
//

import AppKit

@MainActor
final class BuiltInProvider: ProofingProvider {
    private let checker = NSSpellChecker.shared
    private var documentTag: Int = 0

    func openDocument() {
        documentTag = NSSpellChecker.uniqueSpellDocumentTag()
    }

    func closeDocument() {
        checker.closeSpellDocument(withTag: documentTag)
        documentTag = 0
    }

    func check(segments: [SpellCheckService.TextSegment]) async -> [SpellCheckService.SpellCheckResult] {
        var allResults: [SpellCheckService.SpellCheckResult] = []

        for segment in segments {
            guard !Task.isCancelled else { return allResults }
            await Task.yield()

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

            for result in results where result.resultType == .spelling {
                let word = nsString.substring(with: result.range)
                let jsFrom = segment.from + result.range.location
                let jsTo = segment.from + NSMaxRange(result.range)
                let suggestions = checker.guesses(
                    forWordRange: result.range, in: segment.text,
                    language: nil, inSpellDocumentWithTag: documentTag) ?? []
                allResults.append(SpellCheckService.SpellCheckResult(
                    from: jsFrom, to: jsTo, word: word,
                    type: "spelling", suggestions: suggestions,
                    message: nil, ruleId: nil, isPicky: false))
            }
        }
        return allResults
    }

    func learnWord(_ word: String) {
        checker.learnWord(word)
    }

    func ignoreWord(_ word: String) {
        checker.ignoreWord(word, inSpellDocumentWithTag: documentTag)
    }
}
