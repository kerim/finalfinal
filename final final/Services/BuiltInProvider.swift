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
        // Round C1b measurement (MdSpeed.swift, plan step 1): one span for the whole check; its end line reports the longest SLICE, the
        // main-thread stretch between two yields (one segment's check and suggestions), so a slice that blocks typing shows up. Silent
        // and clock-free while tracing is off.
        let tracing = StructuralTrace.isOn
        var maxSliceMs = 0
        let slicesSpan = MdSpeed.span("spellcheck.slice")
        defer { slicesSpan.end("maxSliceMs=\(maxSliceMs) segments=\(segments.count)") }

        for segment in segments {
            guard !Task.isCancelled else { return allResults }
            await Task.yield()
            let sliceStart = tracing ? StructuralTrace.nowMs() : 0
            defer { if tracing { maxSliceMs = max(maxSliceMs, StructuralTrace.nowMs() - sliceStart) } }

            let nsString = segment.text as NSString
            let range = NSRange(location: 0, length: nsString.length)

            var orthography: NSOrthography?
            var wordCount: Int = 0
            // Spelling only: only `.spelling` results are used below, and asking for every
            // type made the checker run its grammar pass (an XPC round trip on the main thread,
            // most of a typing pause's cost) just to have those results thrown away.
            let results = checker.check(
                segment.text, range: range,
                types: NSTextCheckingResult.CheckingType.spelling.rawValue,
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
                    message: nil, shortMessage: nil,
                    ruleId: nil, isPicky: false))
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
