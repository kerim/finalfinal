//
//  LanguageToolProvider+ResponseParsing.swift
//  final final
//
//  Response parsing (LanguageTool JSON matches -> SpellCheckResult) for
//  LanguageToolProvider, split out of LanguageToolProvider.swift to keep that class's
//  body under SwiftLint's type_body_length limit. Mechanical move only -- no behavior
//  change.
//

import AppKit

extension LanguageToolProvider {
    // MARK: - Response Parsing

    struct ParseDiagnostics {
        var rawMatches: Int = 0
        var droppedMissingFields: Int = 0
        var droppedZeroLength: Int = 0
        var droppedNoSegment: Int = 0
        var droppedBoundary: Int = 0
        var droppedIgnored: Int = 0
        var droppedNonLatin: Int = 0
        var rawOffsetsDiag: [String] = []
    }

    struct ParsedResponse {
        let results: [SpellCheckService.SpellCheckResult]
        let diagnostics: ParseDiagnostics
    }

    func parseResponse(
        data: Data,
        offsetMap: [SegmentMapping]
    ) -> ParsedResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let matches = json["matches"] as? [[String: Any]] else {
            return ParsedResponse(results: [], diagnostics: ParseDiagnostics())
        }

        var results: [SpellCheckService.SpellCheckResult] = []
        var diag = ParseDiagnostics()
        diag.rawMatches = matches.count
        var rawOffsets: [String] = []

        for match in matches {
            guard let offset = match["offset"] as? Int,
                  let length = match["length"] as? Int else {
                diag.droppedMissingFields += 1
                continue
            }
            rawOffsets.append("\(offset)")
            if length <= 0 {
                diag.droppedZeroLength += 1
                continue
            }

            // Find which segment this match belongs to
            guard let mapping = findSegment(for: offset, in: offsetMap) else {
                diag.droppedNoSegment += 1
                continue
            }

            let localOffset = offset - mapping.fullTextOffset

            // Skip matches that span across same-block segment boundaries — these cross
            // the injected space between segments and are almost always false positives.
            // Per-scan drop count is logged under .proofing as `[LT] matches: … boundary=N`;
            // measured ~20% of raw matches on prose with citations/footnotes/annotations.
            let segmentTextLength = (mapping.segment.text as NSString).length
            if localOffset + length > segmentTextLength {
                diag.droppedBoundary += 1
                continue
            }

            let word = extractWord(from: mapping.segment.text, offset: localOffset, length: length)

            // Skip ignored words
            if ignoredWords.contains(word) {
                diag.droppedIgnored += 1
                continue
            }

            // Skip matches targeting non-Latin text (CJK, Arabic, Devanagari, etc.)
            if containsNonLatinScript(word) {
                diag.droppedNonLatin += 1
                continue
            }

            // Map to editor positions
            let editorFrom = mapping.segment.from + localOffset
            let editorTo = mapping.segment.from + localOffset + length

            // Classify error type
            let type = classifyMatch(match)
            let isPicky = (match["ignoreForIncompleteSentence"] as? Bool) == true
                || (type == "style" && settings.pickyMode)

            // Extract suggestions
            let replacements = match["replacements"] as? [[String: Any]] ?? []
            let suggestions = replacements.compactMap { $0["value"] as? String }

            // Extract rule ID and message
            let rule = match["rule"] as? [String: Any]
            let ruleId = rule?["id"] as? String
            let message = match["message"] as? String
            let shortMessage = match["shortMessage"] as? String

            results.append(SpellCheckService.SpellCheckResult(
                from: editorFrom, to: editorTo, word: word,
                type: type, suggestions: Array(suggestions.prefix(5)),
                message: message, shortMessage: shortMessage,
                ruleId: ruleId, isPicky: isPicky))
        }

        diag.rawOffsetsDiag = rawOffsets
        return ParsedResponse(results: results, diagnostics: diag)
    }

    private func findSegment(
        for offset: Int,
        in offsetMap: [SegmentMapping]
    ) -> SegmentMapping? {
        var best: SegmentMapping?
        for mapping in offsetMap {
            if mapping.fullTextOffset <= offset {
                best = mapping
            } else {
                break
            }
        }
        return best
    }

    private func extractWord(from text: String, offset: Int, length: Int) -> String {
        let nsString = text as NSString
        let range = NSRange(location: offset, length: length)
        guard NSMaxRange(range) <= nsString.length else { return "" }
        return nsString.substring(with: range)
    }

    private func classifyMatch(_ match: [String: Any]) -> String {
        if let rule = match["rule"] as? [String: Any],
           let category = rule["category"] as? [String: Any],
           let categoryId = category["id"] as? String {
            if categoryId == "TYPOS" || categoryId == "SPELLING" {
                return "spelling"
            }
        }
        if let rule = match["rule"] as? [String: Any],
           let issueType = rule["issueType"] as? String {
            if issueType == "misspelling" {
                return "spelling"
            }
            if issueType == "style" || issueType == "typographical" {
                return "style"
            }
        }
        return "grammar"
    }

    // MARK: - Non-Latin Script Filtering

    /// Returns true if the text contains non-Latin alphabetic characters (CJK, Arabic, etc.)
    /// Used to filter false positives from LanguageTool on non-English scripts.
    private static let latinLetters: CharacterSet = {
        // Basic Latin + Latin-1 Supplement + Latin Extended A/B + Additional
        var set = CharacterSet(charactersIn: "\u{0041}"..."\u{005A}")  // A-Z
        set.formUnion(.init(charactersIn: "\u{0061}"..."\u{007A}"))  // a-z
        set.formUnion(.init(charactersIn: "\u{00C0}"..."\u{024F}"))  // Latin Extended A/B
        set.formUnion(.init(charactersIn: "\u{1E00}"..."\u{1EFF}"))  // Latin Extended Additional
        set.formUnion(.init(charactersIn: "\u{2C60}"..."\u{2C7F}"))  // Latin Extended-C
        set.formUnion(.init(charactersIn: "\u{A720}"..."\u{A7FF}"))  // Latin Extended-D
        return set
    }()

    private func containsNonLatinScript(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if CharacterSet.letters.contains(scalar) && !Self.latinLetters.contains(scalar) {
                return true
            }
        }
        return false
    }
}
