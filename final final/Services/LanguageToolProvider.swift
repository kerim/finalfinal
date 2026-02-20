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

        // Build request
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

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled else { return [] }

            guard let httpResponse = response as? HTTPURLResponse else {
                connectionStatus = .disconnected
                return []
            }

            switch httpResponse.statusCode {
            case 200:
                connectionStatus = .connected
            case 401, 403:
                connectionStatus = .authError
                return []
            case 429:
                connectionStatus = .rateLimited
                return []
            default:
                connectionStatus = .disconnected
                return []
            }

            return parseResponse(data: data, offsetMap: offsetMap)
        } catch {
            guard !Task.isCancelled else { return [] }
            connectionStatus = .disconnected
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

        for (i, segment) in segments.enumerated() {
            if !fullText.isEmpty {
                fullText += "\n\n"
            }
            offsetMap.append(SegmentMapping(
                index: i,
                fullTextOffset: fullText.utf16.count,
                segment: segment))
            fullText += segment.text
        }

        return (fullText, offsetMap)
    }

    // MARK: - Response Parsing

    private func parseResponse(
        data: Data,
        offsetMap: [SegmentMapping]
    ) -> [SpellCheckService.SpellCheckResult] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let matches = json["matches"] as? [[String: Any]] else {
            return []
        }

        var results: [SpellCheckService.SpellCheckResult] = []

        for match in matches {
            guard let offset = match["offset"] as? Int,
                  let length = match["length"] as? Int,
                  length > 0 else { continue }

            // Find which segment this match belongs to
            guard let mapping = findSegment(for: offset, in: offsetMap) else { continue }

            let localOffset = offset - mapping.fullTextOffset
            let word = extractWord(from: mapping.segment.text, offset: localOffset, length: length)

            // Skip ignored words
            if ignoredWords.contains(word) { continue }

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

        return results
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

    private func urlEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }
}
