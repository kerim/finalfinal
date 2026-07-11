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
}

// MARK: - Mock URLProtocol

/// Intercepts requests to LanguageTool's cloud endpoints and returns a configurable
/// canned response, counting real network hits so tests can assert on dedup behavior.
/// Registered/unregistered per test (process-wide state) via `URLProtocol.registerClass`.
private final class MockLTURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseData = Data(#"{"matches": []}"#.utf8)
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var delay: Duration?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _requestCount = 0

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _requestCount
    }

    /// Resets both the invocation counter and the response configuration to defaults.
    /// Call at the start of every test, before registering the class.
    static func reset() {
        lock.lock()
        _requestCount = 0
        lock.unlock()
        responseData = Data(#"{"matches": []}"#.utf8)
        statusCode = 200
        delay = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host == "api.languagetool.org" || host == "api.languagetoolplus.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self._requestCount += 1
        Self.lock.unlock()

        guard let url = request.url else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let statusCode = Self.statusCode
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
