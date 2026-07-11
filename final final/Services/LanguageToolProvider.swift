//
//  LanguageToolProvider.swift
//  final final
//
//  LanguageTool HTTP API provider for spelling + grammar + style checking.
//

import AppKit

enum LTConnectionStatus: Equatable {
    case connected
    case disconnected
    case authError
    case rateLimited
    case checking
}

@MainActor
final class LanguageToolProvider: ProofingProvider {
    private let settings = ProofingSettings.shared
    private var ignoredWords: Set<String> = []
    private(set) var connectionStatus: LTConnectionStatus = .disconnected

    // MARK: - ProofingProvider

    func check(segments: [SpellCheckService.TextSegment]) async -> [SpellCheckService.SpellCheckResult] {
        guard let baseURL = settings.mode.baseURL else { return [] }
        guard !segments.isEmpty else { return [] }

        connectionStatus = .checking

        // Consolidate segments into a single text with offset map
        let (fullText, offsetMap) = consolidateSegments(segments)

        let request = buildCheckRequest(baseURL: baseURL, fullText: fullText)
        logRequestBoundary(fullText: fullText, segmentCount: segments.count)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled else { return [] }

            guard let httpResponse = response as? HTTPURLResponse else {
                connectionStatus = .disconnected
                DebugLog.log(.proofing, "[LT] network: non-HTTP response")
                return []
            }

            switch httpResponse.statusCode {
            case 200:
                connectionStatus = .connected
            case 401, 403:
                connectionStatus = .authError
                DebugLog.log(.proofing, "[LT] network: auth error \(httpResponse.statusCode)")
                return []
            case 429:
                connectionStatus = .rateLimited
                DebugLog.log(.proofing, "[LT] network: rate limited")
                return []
            default:
                connectionStatus = .disconnected
                DebugLog.log(.proofing, "[LT] network: status \(httpResponse.statusCode)")
                return []
            }

            let parsed = parseResponse(data: data, offsetMap: offsetMap)
            logResponseBoundary(parsed: parsed)
            return parsed.results
        } catch {
            guard !Task.isCancelled else { return [] }
            connectionStatus = .disconnected
            DebugLog.log(.proofing, "[LT] network error: \(error.localizedDescription)")
            return []
        }
    }

    func learnWord(_ word: String) {
        // Always add to macOS dictionary
        NSSpellChecker.shared.learnWord(word)
        ignoredWords.remove(word)

        // For Premium: also sync to LT cloud dictionary
        if settings.mode == .languageToolPremium && !settings.apiKey.isEmpty {
            Task {
                await syncWordToCloud(word: word, action: "add")
            }
        }
    }

    func ignoreWord(_ word: String) {
        ignoredWords.insert(word)
    }

    // MARK: - Segment Consolidation

    private struct SegmentMapping {
        let index: Int
        let fullTextOffset: Int
        let segment: SpellCheckService.TextSegment
    }

    private func consolidateSegments(
        _ segments: [SpellCheckService.TextSegment]
    ) -> (String, [SegmentMapping]) {
        var fullText = ""
        var offsetMap: [SegmentMapping] = []
        var lastBlockId: Int?

        for (i, segment) in segments.enumerated() {
            if !fullText.isEmpty {
                // Same paragraph: join with space to preserve sentence context
                // Different paragraph (or no blockId): join with paragraph break
                if let bid = segment.blockId, bid == lastBlockId {
                    fullText += " "
                } else {
                    fullText += "\n\n"
                }
            }
            offsetMap.append(SegmentMapping(
                index: i,
                fullTextOffset: fullText.utf16.count,
                segment: segment))
            fullText += segment.text
            lastBlockId = segment.blockId
        }

        return (fullText, offsetMap)
    }

    // MARK: - Response Parsing

    struct ParseDiagnostics {
        var rawMatches: Int = 0
        var droppedMissingFields: Int = 0
        var droppedZeroLength: Int = 0
        var droppedNoSegment: Int = 0
        var droppedBoundary: Int = 0
        var droppedIgnored: Int = 0
        var droppedNonLatin: Int = 0
    }

    struct ParsedResponse {
        let results: [SpellCheckService.SpellCheckResult]
        let diagnostics: ParseDiagnostics
    }

    private func parseResponse(
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

        for match in matches {
            guard let offset = match["offset"] as? Int,
                  let length = match["length"] as? Int else {
                diag.droppedMissingFields += 1
                continue
            }
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

    // MARK: - Request Construction

    private func buildCheckRequest(baseURL: URL, fullText: String) -> URLRequest {
        let url = baseURL.appendingPathComponent("v2/check")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var params: [String] = [
            "text=\(urlEncode(fullText))",
            "language=\(urlEncode(settings.language))"
        ]
        if settings.pickyMode {
            params.append("level=picky")
        }
        if settings.mode == .languageToolPremium {
            if !settings.username.isEmpty {
                params.append("username=\(urlEncode(settings.username))")
            }
            if !settings.apiKey.isEmpty {
                params.append("apiKey=\(urlEncode(settings.apiKey))")
            }
        }
        if !settings.disabledRules.isEmpty {
            params.append("disabledRules=\(urlEncode(settings.disabledRules.joined(separator: ",")))")
        }
        request.httpBody = params.joined(separator: "&").data(using: .utf8)
        return request
    }

    // MARK: - Diagnostic Logging

    private static let boundaryPreviewChars = 200

    private func logRequestBoundary(fullText: String, segmentCount: Int) {
        guard DebugLog.isEnabled(.proofing) else { return }
        let nsFull = fullText as NSString
        DebugLog.log(.proofing,
            "[LT] sent: segments=\(segmentCount) chars=\(nsFull.length) " +
            "mode=\(settings.mode.rawValue) picky=\(settings.pickyMode) " +
            "lang=\(settings.language) disabledRules=\(settings.disabledRules.count)")
        guard nsFull.length > 0 else { return }
        let previewLen = Self.boundaryPreviewChars
        let head = nsFull.substring(to: min(previewLen, nsFull.length))
        DebugLog.log(.proofing, "[LT] head: \"\(head.replacingOccurrences(of: "\n", with: "⏎"))\"")
        if nsFull.length > previewLen {
            let tail = nsFull.substring(from: nsFull.length - previewLen)
            DebugLog.log(.proofing, "[LT] tail: \"\(tail.replacingOccurrences(of: "\n", with: "⏎"))\"")
        }
    }

    private func logResponseBoundary(parsed: ParsedResponse) {
        guard DebugLog.isEnabled(.proofing) else { return }
        let diag = parsed.diagnostics
        DebugLog.log(.proofing,
            "[LT] matches: raw=\(diag.rawMatches) kept=\(parsed.results.count) | " +
            "drops: missing=\(diag.droppedMissingFields) zeroLen=\(diag.droppedZeroLength) " +
            "noSegment=\(diag.droppedNoSegment) boundary=\(diag.droppedBoundary) " +
            "ignored=\(diag.droppedIgnored) nonLatin=\(diag.droppedNonLatin)")
        let counts = SpellCheckService.countByType(parsed.results)
        DebugLog.log(.proofing,
            "[LT] byType (pre-dispatcher-filter): spelling=\(counts.spelling) " +
            "grammar=\(counts.grammar) style=\(counts.style)")
    }

    // MARK: - Cloud Dictionary Sync

    private func syncWordToCloud(word: String, action: String) async {
        guard let baseURL = settings.mode.baseURL else { return }
        let url = baseURL.appendingPathComponent("v2/words/\(action)")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "word=\(urlEncode(word))&username=\(urlEncode(settings.username))&apiKey=\(urlEncode(settings.apiKey))"
        request.httpBody = body.data(using: .utf8)
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Helpers

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

    private func urlEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }
}
