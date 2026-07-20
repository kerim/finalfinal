//
//  LanguageToolProviderDedupTests.swift
//  final finalTests
//
//  Tier 1: request-signature dedup cache in LanguageToolProvider — verifies redundant
//  identical checks (same content + same check settings) reuse an in-flight or just-
//  completed request instead of firing a new HTTP call, while genuine content/settings
//  changes and failed requests always get a real network round-trip.
//

import Testing
import Foundation
@testable import final_final

@Suite("LanguageTool Provider — Request Dedup", .serialized)
@MainActor
struct LanguageToolProviderDedupTests {

    // MARK: - Fixtures

    // `nonisolated` so it can be used as a default parameter value below — default
    // argument expressions are evaluated in a nonisolated context regardless of the
    // isolation of the function or its caller.
    private nonisolated static let sampleText = "This is a test sentence."

    /// One canned match at offset 0 / length 4 ("This"), classified as spelling.
    private static let sampleMatchResponseJSON = """
    {"matches":[{"offset":0,"length":4,"message":"Test message","shortMessage":"Short",
    "replacements":[{"value":"That"}],"rule":{"id":"TEST_RULE","category":{"id":"TYPOS"}}}]}
    """

    private func makeSegments(
        text: String = sampleText,
        blockId: Int? = 0
    ) -> [SpellCheckService.TextSegment] {
        [SpellCheckService.TextSegment(text: text, from: 0, to: (text as NSString).length, blockId: blockId)]
    }

    /// Snapshots the `ProofingSettings.shared` fields these tests touch, so each test can
    /// restore them in its own `defer` — it's a real UserDefaults-backed singleton, not
    /// injectable, so leaking a change here would pollute the rest of the suite.
    @MainActor
    private struct SettingsSnapshot {
        let mode: ProofingMode
        let pickyMode: Bool
        let language: String
        let disabledRules: [String]

        static func capture() -> SettingsSnapshot {
            SettingsSnapshot(
                mode: ProofingSettings.shared.mode,
                pickyMode: ProofingSettings.shared.pickyMode,
                language: ProofingSettings.shared.language,
                disabledRules: ProofingSettings.shared.disabledRules)
        }

        func restore() {
            ProofingSettings.shared.mode = mode
            ProofingSettings.shared.pickyMode = pickyMode
            ProofingSettings.shared.language = language
            ProofingSettings.shared.disabledRules = disabledRules
        }
    }

    // MARK: - Tests

    @Test("Identical content and settings, called twice — one network call, same cached results")
    func identicalContentReusesCache() async throws {
        let snapshot = SettingsSnapshot.capture()
        MockLTURLProtocol.reset()
        MockLTURLProtocol.responseData = Data(Self.sampleMatchResponseJSON.utf8)
        URLProtocol.registerClass(MockLTURLProtocol.self)
        ProofingSettings.shared.mode = .languageToolFree
        defer {
            URLProtocol.unregisterClass(MockLTURLProtocol.self)
            snapshot.restore()
        }

        let provider = LanguageToolProvider()
        let segments = makeSegments()

        let first = await provider.check(segments: segments)
        let second = await provider.check(segments: segments)

        #expect(MockLTURLProtocol.requestCount == 1)
        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(first.first?.word == second.first?.word)
        #expect(first.first?.ruleId == second.first?.ruleId)
    }

    @Test("Different content, same settings — two network calls")
    func differentContentAlwaysNetworks() async throws {
        let snapshot = SettingsSnapshot.capture()
        MockLTURLProtocol.reset()
        URLProtocol.registerClass(MockLTURLProtocol.self)
        ProofingSettings.shared.mode = .languageToolFree
        defer {
            URLProtocol.unregisterClass(MockLTURLProtocol.self)
            snapshot.restore()
        }

        let provider = LanguageToolProvider()

        _ = await provider.check(segments: makeSegments(text: "This is the first sentence."))
        _ = await provider.check(segments: makeSegments(text: "This is a completely different one."))

        #expect(MockLTURLProtocol.requestCount == 2)
    }

    @Test("Same content, settings changed between calls — two network calls")
    func settingsChangeForcesNewNetworkCall() async throws {
        let snapshot = SettingsSnapshot.capture()
        MockLTURLProtocol.reset()
        URLProtocol.registerClass(MockLTURLProtocol.self)
        ProofingSettings.shared.mode = .languageToolFree
        ProofingSettings.shared.pickyMode = false
        defer {
            URLProtocol.unregisterClass(MockLTURLProtocol.self)
            snapshot.restore()
        }

        let provider = LanguageToolProvider()
        let segments = makeSegments()

        _ = await provider.check(segments: segments)
        ProofingSettings.shared.pickyMode.toggle()
        _ = await provider.check(segments: segments)

        #expect(MockLTURLProtocol.requestCount == 2)
    }

    @Test("Two concurrent identical calls — one network call, both callers get the same result")
    func concurrentIdenticalCallsShareInFlightRequest() async throws {
        let snapshot = SettingsSnapshot.capture()
        MockLTURLProtocol.reset()
        MockLTURLProtocol.responseData = Data(Self.sampleMatchResponseJSON.utf8)
        MockLTURLProtocol.delay = .milliseconds(200)
        URLProtocol.registerClass(MockLTURLProtocol.self)
        ProofingSettings.shared.mode = .languageToolFree
        defer {
            URLProtocol.unregisterClass(MockLTURLProtocol.self)
            snapshot.restore()
        }

        let provider = LanguageToolProvider()
        let segments = makeSegments()

        async let first = provider.check(segments: segments)
        async let second = provider.check(segments: segments)
        let (firstResult, secondResult) = await (first, second)

        #expect(MockLTURLProtocol.requestCount == 1)
        #expect(firstResult.count == 1)
        #expect(secondResult.count == 1)
        #expect(firstResult.first?.word == secondResult.first?.word)
    }

    @Test("First call fails, second identical call retries — two network calls, failure not cached")
    func failedCheckIsNotCached() async throws {
        let snapshot = SettingsSnapshot.capture()
        MockLTURLProtocol.reset()
        MockLTURLProtocol.statusCode = 500
        URLProtocol.registerClass(MockLTURLProtocol.self)
        ProofingSettings.shared.mode = .languageToolFree
        defer {
            URLProtocol.unregisterClass(MockLTURLProtocol.self)
            snapshot.restore()
        }

        let provider = LanguageToolProvider()
        let segments = makeSegments()

        let first = await provider.check(segments: segments)
        #expect(first.isEmpty)
        #expect(MockLTURLProtocol.requestCount == 1)

        _ = await provider.check(segments: segments)
        #expect(MockLTURLProtocol.requestCount == 2)
    }

    @Test("ignoreWord invalidates the completed-check cache — re-check hits the network again")
    func ignoreWordInvalidatesCache() async throws {
        let snapshot = SettingsSnapshot.capture()
        MockLTURLProtocol.reset()
        MockLTURLProtocol.responseData = Data(Self.sampleMatchResponseJSON.utf8)
        URLProtocol.registerClass(MockLTURLProtocol.self)
        ProofingSettings.shared.mode = .languageToolFree
        defer {
            URLProtocol.unregisterClass(MockLTURLProtocol.self)
            snapshot.restore()
        }

        let provider = LanguageToolProvider()
        let segments = makeSegments()

        let first = await provider.check(segments: segments)
        #expect(first.count == 1)
        #expect(MockLTURLProtocol.requestCount == 1)

        provider.ignoreWord("This")

        _ = await provider.check(segments: segments)
        #expect(MockLTURLProtocol.requestCount == 2)
    }

    @Test("Over-limit document splits into multiple chunked requests with correctly merged offsets; re-check still dedupes")
    func overLimitDocumentChunksIntoMultipleRequestsAndStillDedupes() async throws {
        let snapshot = SettingsSnapshot.capture()
        MockLTURLProtocol.reset()
        // One canned match at local offset 0 / length 4 in every chunk's own
        // request text — safe here because every chunk starts with a full
        // "AAAA " unit (see `bigText` below), so "offset 0 length 4" always
        // resolves to the literal word "AAAA" regardless of which chunk it is.
        MockLTURLProtocol.responseData = Data(Self.sampleMatchResponseJSON.utf8)
        URLProtocol.registerClass(MockLTURLProtocol.self)
        ProofingSettings.shared.mode = .languageToolFree
        defer {
            URLProtocol.unregisterClass(MockLTURLProtocol.self)
            snapshot.restore()
        }

        let provider = LanguageToolProvider()
        // Comfortably over LanguageToolProvider's ~18,000-UTF16-unit per-request
        // budget. Built from a uniform 5-char unit so every whitespace-boundary
        // chunk cut lands cleanly on a unit boundary — each chunk's first four
        // characters are therefore always "AAAA", never a mid-word fragment.
        let unit = "AAAA "
        let bigText = String(repeating: unit, count: 9_000)  // 45,000 UTF-16 units
        let segments = [
            SpellCheckService.TextSegment(text: bigText, from: 0, to: bigText.utf16.count, blockId: 0)
        ]

        let firstResults = await provider.check(segments: segments)
        let firstRequestCount = MockLTURLProtocol.requestCount

        // The whole point of chunking: one oversized document, several requests
        // — never a silently-dropped/truncated single request.
        #expect(firstRequestCount > 1)
        // One canned match merged in per chunk, at absolute (not chunk-local) editor
        // positions, in document order, with no duplicate/overlapping offsets.
        #expect(firstResults.count == firstRequestCount)
        let froms = firstResults.map(\.from)
        #expect(froms == froms.sorted())
        #expect(Set(froms).count == froms.count)
        #expect(froms.first == 0)
        #expect(firstResults.allSatisfy { $0.word == "AAAA" })

        // Every individual request body should be well under what one giant
        // unsplit ~45,000-char request would have been, proving the split
        // actually shrank each request rather than just relabeling it.
        let bodies = MockLTURLProtocol.capturedBodies
        #expect(bodies.count == firstRequestCount)
        #expect(bodies.allSatisfy { $0.count < 40_000 })

        // Re-triggering an identical check on the same large document must still
        // only fire one full multi-chunk pass, not a second one — the dedup
        // signature is computed over the original segment array before chunking
        // ever happens, so this proves chunking didn't bypass the existing
        // dedup mechanism.
        let secondResults = await provider.check(segments: segments)
        #expect(MockLTURLProtocol.requestCount == firstRequestCount)
        #expect(secondResults.count == firstResults.count)
    }

    @Test("Middle chunk of a 3-chunk check fails — overall check is not marked succeeded, and connectionStatus is not silently left at .connected")
    func middleChunkFailureIsNotMaskedByLaterSuccess() async throws {
        let snapshot = SettingsSnapshot.capture()
        MockLTURLProtocol.reset()
        MockLTURLProtocol.responseData = Data(Self.sampleMatchResponseJSON.utf8)
        // The 2nd of the 3 requests this document splits into fails (simulating a
        // rate limit or transient network error mid-check) while the 1st and 3rd
        // chunks succeed normally.
        MockLTURLProtocol.failingRequestNumbers = [2]
        MockLTURLProtocol.failureStatusCode = 429
        URLProtocol.registerClass(MockLTURLProtocol.self)
        ProofingSettings.shared.mode = .languageToolFree
        defer {
            URLProtocol.unregisterClass(MockLTURLProtocol.self)
            snapshot.restore()
        }

        let provider = LanguageToolProvider()
        // Same construction as `overLimitDocumentChunksIntoMultipleRequestsAndStillDedupes`
        // above: a single ~45,000-UTF16-unit segment built from a uniform 5-char
        // unit, which reliably splits into exactly 3 chunks of ~18,000 / ~18,000 /
        // ~9,000 units each.
        let unit = "AAAA "
        let bigText = String(repeating: unit, count: 9_000)
        let segments = [
            SpellCheckService.TextSegment(text: bigText, from: 0, to: bigText.utf16.count, blockId: 0)
        ]

        _ = await provider.check(segments: segments)

        #expect(MockLTURLProtocol.requestCount == 3)
        // The regression this guards against: chunk 3 succeeding (200, sets
        // `.connected`) must not erase chunk 2's failure (429, `.rateLimited`) from
        // the final reported status — that would silently show a healthy green
        // status bar for a check that never actually covered chunk 2's text.
        #expect(provider.connectionStatus != .connected)
        #expect(provider.connectionStatus == .rateLimited)

        // A check where one chunk failed must not be cached as an overall success
        // either: an identical re-check should hit the network again for all 3
        // chunks rather than reusing a poisoned "succeeded" result. (Mirrors
        // `failedCheckIsNotCached` above, adapted to the chunked path — this is how
        // `succeeded == false` is observed from outside, since `CheckOutcome` is
        // private.)
        _ = await provider.check(segments: segments)
        #expect(MockLTURLProtocol.requestCount == 6)
    }
}

// MARK: - Mock URLProtocol

/// Intercepts requests to LanguageTool's cloud endpoints and returns a configurable
/// canned response, counting real network hits so tests can assert on dedup behavior.
/// Registered/unregistered per test (process-wide state) via `URLProtocol.registerClass`.
private final class MockLTURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseData = Data(#"{"matches": []}"#.utf8)
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var delay: Duration?
    /// 1-indexed request numbers (in dispatch order) that should respond with
    /// `failureStatusCode` instead of the configured `statusCode` — lets a chunking
    /// test simulate "the Nth request of a multi-chunk check fails" without
    /// affecting the other chunks' requests.
    nonisolated(unsafe) static var failingRequestNumbers: Set<Int> = []
    nonisolated(unsafe) static var failureStatusCode = 500

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _requestCount = 0
    // Per-request bodies, in dispatch order — lets chunking tests assert on how
    // many requests fired AND how big each one's payload actually was, not just
    // the count.
    nonisolated(unsafe) private static var _capturedBodies: [Data] = []

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _requestCount
    }

    static var capturedBodies: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return _capturedBodies
    }

    /// Resets both the invocation counter and the response configuration to defaults.
    /// Call at the start of every test, before registering the class.
    static func reset() {
        lock.lock()
        _requestCount = 0
        _capturedBodies = []
        lock.unlock()
        responseData = Data(#"{"matches": []}"#.utf8)
        statusCode = 200
        delay = nil
        failingRequestNumbers = []
        failureStatusCode = 500
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host == "api.languagetool.org" || host == "api.languagetoolplus.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// Reads the request body regardless of whether URLSession preserved it as
    /// `httpBody` or converted it to `httpBodyStream` (which can happen for
    /// larger payloads once a request passes through a custom URLProtocol).
    private static func extractBody(from request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override func startLoading() {
        let body = Self.extractBody(from: request)
        Self.lock.lock()
        Self._requestCount += 1
        let requestNumber = Self._requestCount
        Self._capturedBodies.append(body)
        Self.lock.unlock()

        guard let url = request.url else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let statusCode = Self.failingRequestNumbers.contains(requestNumber)
            ? Self.failureStatusCode : Self.statusCode
        let data = Self.responseData
        let delay = Self.delay

        Task {
            if let delay {
                try? await Task.sleep(for: delay)
            }
            guard let client = self.client,
                  let response = HTTPURLResponse(
                    url: url, statusCode: statusCode, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]) else { return }
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: data)
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
