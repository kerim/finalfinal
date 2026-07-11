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

    // MARK: - Deduplication State

    // Tracks the request currently in flight (if any) and the most recently
    // completed successful request, both keyed by `requestSignature(for:)`, so that
    // `check(segments:)` can recognize "this is the exact same text and check
    // settings as a request that's already running or just finished" and reuse it
    // instead of firing a redundant HTTP call. See `check(segments:)` for the guard
    // logic and `performNetworkCheck` for the actual network round-trip.
    private var inFlightSignature: String?
    private var inFlightTask: Task<CheckOutcome, Never>?
    private var lastCompletedSignature: String?
    private var lastCompletedResults: [SpellCheckService.SpellCheckResult]?

    // Monotonically increasing counter, bumped every time a new network request is
    // installed as "the" in-flight request AND every time `learnWord`/`ignoreWord`
    // invalidate all dedup state (see `invalidateDedupState()`). Each fired request
    // captures its own epoch at install time; when it resumes, it only touches the
    // shared dedup state above if its captured epoch still matches the current one.
    // Comparing `requestSignature` strings alone isn't enough for this: (1) an older,
    // superseded request finishing late would otherwise unconditionally overwrite a
    // newer request's already-cached result (or the fresh emptiness left by a
    // learn/ignore invalidation) with its own stale one; (2) if content changes away
    // from and back to an earlier signature while that earlier request is still in
    // flight, the old request's completion would match the new request's signature by
    // value and wrongly clear its in-flight bookkeeping (an ABA hazard) — letting a
    // duplicate concurrent request for the same content slip through, which is exactly
    // what this cache exists to prevent. The epoch makes "is this still the request
    // that matters" an identity check instead of a value comparison.
    private var checkEpoch = 0

    private struct CheckOutcome: Sendable {
        let results: [SpellCheckService.SpellCheckResult]
        let succeeded: Bool
    }

    // MARK: - ProofingProvider

    func check(segments: [SpellCheckService.TextSegment]) async -> [SpellCheckService.SpellCheckResult] {
        guard let baseURL = settings.mode.baseURL else { return [] }
        guard !segments.isEmpty else { return [] }

        let signature = requestSignature(for: segments)

        // A check for this exact content+settings is already running — await it
        // instead of firing a second HTTP request for the same thing. LanguageTool's
        // server has been observed returning inconsistent results for near-simultaneous
        // identical requests, so there's nothing to gain (and real risk) in asking twice.
        // Deliberately does not touch `connectionStatus`: it's left at whatever it last
        // resolved to (e.g. `.connected`) rather than getting stuck mid-check.
        if signature == inFlightSignature, let task = inFlightTask {
            DebugLog.log(.proofing, "[LT] dedup: identical check already in flight — awaiting it instead of re-requesting")
            return await task.value.results
        }

        // Content + settings unchanged since the last completed check — reuse it.
        // Same as above: `connectionStatus` is deliberately left untouched here too.
        if signature == lastCompletedSignature, let cached = lastCompletedResults {
            DebugLog.log(.proofing, "[LT] dedup: content+settings unchanged since last completed check — reusing cached results")
            return cached
        }

        let (fullText, offsetMap) = consolidateSegments(segments)
        let segmentCount = segments.count
        checkEpoch += 1
        let myEpoch = checkEpoch
        let task = Task<CheckOutcome, Never> { [weak self] in
            await self?.performNetworkCheck(
                baseURL: baseURL, fullText: fullText, offsetMap: offsetMap, segmentCount: segmentCount
            ) ?? CheckOutcome(results: [], succeeded: false)
        }
        inFlightSignature = signature
        inFlightTask = task

        let outcome = await task.value

        // Only touch the shared dedup state if no newer request — and no
        // learn/ignore invalidation — has superseded this one while we were awaiting
        // the network. Otherwise this stale completion would clobber a fresher
        // in-flight/cached entry, or resurrect a just-invalidated cache. See the
        // `checkEpoch` doc comment above for why signature equality alone isn't
        // sufficient here.
        guard myEpoch == checkEpoch else { return outcome.results }

        inFlightSignature = nil
        inFlightTask = nil
        // Only cache a genuine success. A transient failure (rate limit, auth error,
        // network blip, timeout) must NOT be cached — the next trigger for the same
        // content should get a real retry, not a replay of the failure forever.
        if outcome.succeeded {
            lastCompletedSignature = signature
            lastCompletedResults = outcome.results
        } else {
            lastCompletedSignature = nil
            lastCompletedResults = nil
        }
        return outcome.results
    }

    func learnWord(_ word: String) {
        // Invalidate all dedup state: `parseResponse` bakes `ignoredWords` filtering
        // into its results, so without this the very next check — which both JS
        // plugins fire immediately after learn/ignore, with unchanged text/settings —
        // would replay results computed before this word was learned. Bumping
        // `checkEpoch` makes any request still in flight at this moment a no-op on
        // resume (it's left to complete on its own terms — not cancelled — but its
        // result is discarded rather than cached). Clearing `inFlightSignature`/
        // `inFlightTask` here too, not just the completed cache, matters just as much:
        // without it, a new identical-signature check arriving right after this call
        // would still match the *stale* in-flight task and simply await its
        // already-in-progress (pre-invalidation) result instead of firing fresh.
        invalidateDedupState()

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
        // See learnWord(_:) above — same cache-invalidation reasoning applies here.
        invalidateDedupState()
        ignoredWords.insert(word)
    }

    /// Clears all dedup tracking (in-flight *and* completed) and bumps `checkEpoch` so
    /// any request already in flight becomes a no-op on resume instead of clobbering
    /// whatever the next fresh check produces. Used by `learnWord`/`ignoreWord`, whose
    /// effect on future results isn't captured by content+settings signature equality
    /// alone.
    private func invalidateDedupState() {
        checkEpoch += 1
        inFlightSignature = nil
        inFlightTask = nil
        lastCompletedSignature = nil
        lastCompletedResults = nil
    }

    // MARK: - Network

    /// Performs the actual LanguageTool HTTP round-trip. Extracted from
    /// `check(segments:)` so the dedup logic there can track this work as a single
    /// awaitable `Task` — letting duplicate callers await the one real network
    /// round-trip instead of each starting (and racing) their own.
    private func performNetworkCheck(
        baseURL: URL,
        fullText: String,
        offsetMap: [SegmentMapping],
        segmentCount: Int
    ) async -> CheckOutcome {
        connectionStatus = .checking

        let request = buildCheckRequest(baseURL: baseURL, fullText: fullText)
        logRequestBoundary(fullText: fullText, segmentCount: segmentCount)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled else { return CheckOutcome(results: [], succeeded: false) }

            guard let httpResponse = response as? HTTPURLResponse else {
                connectionStatus = .disconnected
                DebugLog.log(.proofing, "[LT] network: non-HTTP response")
                return CheckOutcome(results: [], succeeded: false)
            }

            switch httpResponse.statusCode {
            case 200:
                connectionStatus = .connected
            case 401, 403:
                connectionStatus = .authError
                DebugLog.log(.proofing, "[LT] network: auth error \(httpResponse.statusCode)")
                return CheckOutcome(results: [], succeeded: false)
            case 429:
                connectionStatus = .rateLimited
                DebugLog.log(.proofing, "[LT] network: rate limited")
                return CheckOutcome(results: [], succeeded: false)
            default:
                connectionStatus = .disconnected
                DebugLog.log(.proofing, "[LT] network: status \(httpResponse.statusCode)")
                return CheckOutcome(results: [], succeeded: false)
            }

            let parsed = parseResponse(data: data, offsetMap: offsetMap)
            logResponseBoundary(parsed: parsed)
            return CheckOutcome(results: parsed.results, succeeded: true)
        } catch {
            guard !Task.isCancelled else { return CheckOutcome(results: [], succeeded: false) }
            connectionStatus = .disconnected
            DebugLog.log(.proofing, "[LT] network error: \(error.localizedDescription)")
            return CheckOutcome(results: [], succeeded: false)
        }
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
        var rawOffsetsDiag: [String] = []
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

    // MARK: - Request Construction

    private func buildCheckRequest(baseURL: URL, fullText: String) -> URLRequest {
        let url = baseURL.appendingPathComponent("v2/check")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

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

    // MARK: - Request Signature

    /// Builds a cache/in-flight key that identifies "this exact document content
    /// checked with this exact set of parameters." Includes each segment's
    /// `from`/`to`/`blockId` (not just its `text`) because position matters: the same
    /// text could come from structurally different segments (e.g. a paragraph split
    /// elsewhere), and reusing a cached result in that case would place underlines at
    /// the wrong offsets. Also includes every check parameter that affects the actual
    /// LT request, so a real settings change (language, picky mode, disabled rules) is
    /// never mistaken for a duplicate. `disabledRules` is sorted first since its order
    /// doesn't affect the request's meaning.
    private func requestSignature(for segments: [SpellCheckService.TextSegment]) -> String {
        let fieldSeparator = "\u{0}"
        let segmentSeparator = "\u{1}"

        var parts: [String] = segments.map { segment in
            [
                String(segment.from),
                String(segment.to),
                segment.blockId.map(String.init) ?? "nil",
                segment.text
            ].joined(separator: fieldSeparator)
        }
        parts.append(settings.mode.rawValue)
        parts.append(String(settings.pickyMode))
        parts.append(settings.language)
        parts.append(settings.disabledRules.sorted().joined(separator: fieldSeparator))

        return parts.joined(separator: segmentSeparator)
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
        let positions = parsed.results.map { "\($0.from)-\($0.to):\($0.type)" }.joined(separator: ", ")
        DebugLog.log(.proofing, "[LT] DIAG kept positions (editor coords): [\(positions)]")
        DebugLog.log(.proofing, "[LT] DIAG raw offsets (LT's own text coords): [\(diag.rawOffsetsDiag.joined(separator: ", "))]")
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

    /// Encodes a single `application/x-www-form-urlencoded` field value. `.urlQueryAllowed`
    /// is the wrong character set for this: it leaves `&`, `+`, and `=` unescaped (they're
    /// valid inside a URL query component as a whole), but those are exactly the delimiter
    /// characters that separate fields within a form-urlencoded body — a literal `&` in a
    /// value (e.g. an ampersand in document prose) silently truncates that field, and
    /// everything after it in the body is misparsed as bogus/ignored parameters, with no
    /// error surfaced anywhere. Only percent-encode-exempt RFC 3986 "unreserved" characters
    /// (letters, digits, `-._~`) may pass through unescaped; everything else — including the
    /// delimiters — must be escaped.
    private static let formFieldSafeCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private func urlEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: Self.formFieldSafeCharacters) ?? string
    }
}
