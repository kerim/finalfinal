//
//  ZoteroLibraryScopeTests+DuplicateLibraryNamesPipeline.swift
//  final finalTests
//
//  End-to-end mocked-HTTP coverage for the duplicate-group-library-name fix — the whole
//  fetchItemsForCitekeys pipeline, not groupLibraryScopes/mergeGroupOutcomes in isolation.
//  Split from ZoteroLibraryScopeTests+DuplicateLibraryNames.swift only to keep both files under
//  SwiftLint's 800-line file_length warning. Every test here registers the process-wide
//  MockBBTURLProtocol and therefore runs inside ZoteroNetworkTestLock.shared.run { ... } — see
//  ZoteroLibraryScopeTests.swift for why.
//

import Testing
import Foundation
@testable import final_final

/// Counts how many times a particular mocked call shape has been seen, so one `responseOverride`
/// can answer the same request differently on a later pass (pass 1's stale failure vs. pass 2's
/// retry). A plain captured `var` cannot be mutated from a `@Sendable` closure.
private final class MockCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// Reads the library scope out of a captured `item.pandoc_filter` request body.
private func capturedScope(_ body: [String: Any]) -> Any? {
    guard let params = body["params"] as? [Any], params.count > 2 else { return nil }
    return params[2]
}

extension ZoteroLibraryScopeTests {

    @Test(
        """
        THE BUG: two group libraries share a display name and the citekey lives only in the \
        second one. Pre-fix, the name de-dupe collapsed them into one scope and the citekey \
        reported "not found in any library." Post-fix each is searched by its own numeric id.
        """
    )
    @MainActor
    func collidingLibraryNamesAreSearchedSeparatelyByNumericId() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()

            let groupsJSON = """
            {"jsonrpc":"2.0","result":[{"id":1,"name":"My Library"},{"id":7,"name":"Shared"},\
            {"id":8,"name":"Shared"}],"id":1}
            """
            MockBBTURLProtocol.responses["user.groups"] = (200, Data(groupsJSON.utf8))

            // swiftlint:disable line_length
            let foundInEightJSON = """
            {"jsonrpc":"2.0","result":{"errors":{},"items":{"roy2022":{"id":"roy2022","type":"book","citation-key":"roy2022","title":"From Library Eight"}}},"id":4}
            """
            // swiftlint:enable line_length
            let notFoundJSON = #"{"jsonrpc":"2.0","result":{"errors":{"roy2022":0},"items":{}},"id":2}"#

            // The item exists ONLY in library 8 — the one the pre-fix name de-dupe shadowed.
            MockBBTURLProtocol.responseOverride = { method, params in
                guard method == "item.pandoc_filter" else { return nil }
                let scope = params.count > 2 ? params[2] : nil
                if scope as? Int == 8 { return (200, Data(foundInEightJSON.utf8)) }
                return (200, Data(notFoundJSON.utf8))
            }

            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockBBTURLProtocol.self)
                MockBBTURLProtocol.responseOverride = nil
            }

            let service = ZoteroService()
            let items = try await service.fetchItemsForCitekeys(["roy2022"])

            #expect(items.count == 1, "Pre-fix this threw \"not found in any library\" — library 8 was never searched")
            #expect(items.first?.title == "From Library Eight")

            let scopes = MockBBTURLProtocol.capturedRequests
                .filter { $0.method == "item.pandoc_filter" }
                .compactMap { capturedScope($0.body) }
            #expect(scopes.contains { $0 as? Int == 7 }, "Library 7 must be searched by its own id")
            #expect(scopes.contains { $0 as? Int == 8 }, "Library 8 must be searched by its own id")
            #expect(
                !scopes.contains { ($0 as? [String])?.contains("Shared") == true },
                "A colliding name must never be sent as a name — that is the shadowing bug itself"
            )
        }
    }

    @Test("One scope failing does not discard another scope's results — the citekey still resolves")
    @MainActor
    func oneFailingScopeDoesNotDiscardOtherScopesResults() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()

            let groupsJSON = """
            {"jsonrpc":"2.0","result":[{"id":1,"name":"My Library"},{"id":7,"name":"Shared"},\
            {"id":8,"name":"Shared"}],"id":1}
            """
            MockBBTURLProtocol.responses["user.groups"] = (200, Data(groupsJSON.utf8))

            // swiftlint:disable line_length
            let foundInEightJSON = """
            {"jsonrpc":"2.0","result":{"errors":{},"items":{"roy2022":{"id":"roy2022","type":"book","citation-key":"roy2022","title":"From Library Eight"}}},"id":4}
            """
            // swiftlint:enable line_length
            let notFoundJSON = #"{"jsonrpc":"2.0","result":{"errors":{"roy2022":0},"items":{}},"id":2}"#

            // Library 7's scoped call fails at the transport layer (HTTP 500 -> ZoteroError
            // .noResponse, which is NOT stale-name-shaped, so no pass 2 fires). Library 8's
            // succeeds. Pre-two-pass, one failure aborted the whole group phase.
            MockBBTURLProtocol.responseOverride = { method, params in
                guard method == "item.pandoc_filter" else { return nil }
                let scope = params.count > 2 ? params[2] : nil
                if scope as? Int == 7 { return (500, Data("boom".utf8)) }
                if scope as? Int == 8 { return (200, Data(foundInEightJSON.utf8)) }
                return (200, Data(notFoundJSON.utf8))
            }

            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockBBTURLProtocol.self)
                MockBBTURLProtocol.responseOverride = nil
            }

            let service = ZoteroService()
            let items = try await service.fetchItemsForCitekeys(["roy2022"])

            #expect(items.count == 1, "Library 8's success must survive library 7's failure")
            #expect(items.first?.title == "From Library Eight")
            #expect(
                MockBBTURLProtocol.capturedRequests.filter { $0.method == "user.groups" }.count == 1,
                "A non-stale-shaped failure must not trigger the library-list refresh / pass 2"
            )
        }
    }

    @Test(
        """
        Pass 2 skips libraries pass 1 already covered, BY LIBRARY ID — a rename that resolves a \
        collision must not let a recomputed name scope re-search an id-scoped library and \
        manufacture a false "ambiguous across libraries"
        """
    )
    @MainActor
    func passTwoDoesNotReSearchLibrariesAlreadyCoveredInPassOne() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()

            // Pass 1 sees Foo(6), Shared(7), Shared(8) -> .libraryNames(["Foo"]), id 7, id 8.
            // The names call fails stale-shaped; both id calls succeed, and roy2022 lives in 7.
            // The refresh renames 7 to "Bar", so a naive recomputed partition would be the
            // single scope .libraryNames(["Foo","Bar","Shared"]) — re-searching 7 and 8 and
            // making roy2022 look like it lives in two libraries.
            let groupsCounter = MockCallCounter()
            let fooScopeCounter = MockCallCounter()

            let groupsBeforeJSON = """
            {"jsonrpc":"2.0","result":[{"id":1,"name":"My Library"},{"id":6,"name":"Foo"},\
            {"id":7,"name":"Shared"},{"id":8,"name":"Shared"}],"id":1}
            """
            let groupsAfterJSON = """
            {"jsonrpc":"2.0","result":[{"id":1,"name":"My Library"},{"id":6,"name":"Foo"},\
            {"id":7,"name":"Bar"},{"id":8,"name":"Shared"}],"id":1}
            """
            let staleErrorJSON = #"{"jsonrpc":"2.0","error":{"code":-32602,"message":"could not find library Foo"},"id":3}"#
            // swiftlint:disable line_length
            let foundInSevenJSON = """
            {"jsonrpc":"2.0","result":{"errors":{},"items":{"roy2022":{"id":"roy2022","type":"book","citation-key":"roy2022","title":"From Library Seven"}}},"id":4}
            """
            // swiftlint:enable line_length
            let notFoundJSON = #"{"jsonrpc":"2.0","result":{"errors":{"roy2022":0},"items":{}},"id":2}"#

            MockBBTURLProtocol.responseOverride = { method, params in
                if method == "user.groups" {
                    return groupsCounter.next() == 1
                        ? (200, Data(groupsBeforeJSON.utf8))
                        : (200, Data(groupsAfterJSON.utf8))
                }
                guard method == "item.pandoc_filter" else { return nil }
                let scope = params.count > 2 ? params[2] : nil
                if scope as? Int == 7 { return (200, Data(foundInSevenJSON.utf8)) }
                if let names = scope as? [String] {
                    // A pass-2 batch that wrongly includes the renamed library 7 ("Bar") would
                    // return the item a SECOND time and trip the withhold-on-duplicate rule.
                    if names.contains("Bar") { return (200, Data(foundInSevenJSON.utf8)) }
                    if names == ["Foo"] {
                        return fooScopeCounter.next() == 1
                            ? (200, Data(staleErrorJSON.utf8))   // pass 1: stale-shaped failure
                            : (200, Data(notFoundJSON.utf8))     // pass 2: retried, resolves nothing
                    }
                }
                return (200, Data(notFoundJSON.utf8))
            }

            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockBBTURLProtocol.self)
                MockBBTURLProtocol.responseOverride = nil
            }

            let service = ZoteroService()
            let items = try await service.fetchItemsForCitekeys(["roy2022"])

            #expect(items.count == 1, "roy2022 lives in exactly one library — it must resolve, not be withheld as ambiguous")
            #expect(items.first?.title == "From Library Seven")

            let scopes = MockBBTURLProtocol.capturedRequests
                .filter { $0.method == "item.pandoc_filter" }
                .compactMap { capturedScope($0.body) }
            #expect(
                scopes.filter { $0 as? Int == 7 }.count == 1,
                "Library 7 was already covered by a succeeded pass-1 id scope — pass 2 must not touch it again"
            )
            #expect(
                scopes.filter { $0 as? Int == 8 }.count == 1,
                "Library 8 was also already covered by pass 1"
            )
            #expect(
                !scopes.contains { ($0 as? [String])?.contains("Bar") == true },
                "Skipping must be by covered LIBRARY ID; a renamed library 7 inside a recomputed name batch is exactly the false-ambiguity bug"
            )
            #expect(
                !scopes.contains { ($0 as? [String])?.contains("Shared") == true },
                "Library 8 must not be re-searched under its still-colliding name either"
            )
            #expect(
                MockBBTURLProtocol.capturedRequests.filter { $0.method == "user.groups" }.count == 2,
                "Exactly one forced refresh: pass 2 runs once, not per failed scope"
            )
        }
    }

    @Test(
        """
        Pass 2's forced library-list refresh itself failing (a transient network blip, say) must \
        skip pass 2 entirely rather than throwing away pass 1's already-successful outcomes — the \
        function's own doc comment promises it only throws when NOTHING resolved across both passes
        """
    )
    @MainActor
    func pass2LibraryRefreshFailureDoesNotDiscardPass1Results() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()

            // Two group libraries share a name -> two per-id scopes, no batched name scope.
            let groupsCounter = MockCallCounter()
            let groupsBeforeJSON = """
            {"jsonrpc":"2.0","result":[{"id":1,"name":"My Library"},{"id":7,"name":"Shared"},\
            {"id":8,"name":"Shared"}],"id":1}
            """
            let notFoundJSON = #"{"jsonrpc":"2.0","result":{"errors":{"roy2022":0},"items":{}},"id":2}"#
            // swiftlint:disable line_length
            let foundInSevenJSON = """
            {"jsonrpc":"2.0","result":{"errors":{},"items":{"roy2022":{"id":"roy2022","type":"book","citation-key":"roy2022","title":"From Library Seven"}}},"id":4}
            """
            // swiftlint:enable line_length
            // Scope 8's failure is stale-name-shaped, so it triggers pass 2's forced refresh.
            let staleErrorJSON = #"{"jsonrpc":"2.0","error":{"code":-32602,"message":"could not find library 8"},"id":3}"#

            MockBBTURLProtocol.responseOverride = { method, params in
                if method == "user.groups" {
                    if groupsCounter.next() == 1 {
                        return (200, Data(groupsBeforeJSON.utf8))
                    }
                    // Pass 2's forced refresh fails at the transport layer.
                    return (500, Data("boom".utf8))
                }
                guard method == "item.pandoc_filter" else { return nil }
                let scope = params.count > 2 ? params[2] : nil
                if scope as? Int == ZoteroService.personalLibraryID { return (200, Data(notFoundJSON.utf8)) }
                if scope as? Int == 7 { return (200, Data(foundInSevenJSON.utf8)) }
                if scope as? Int == 8 { return (200, Data(staleErrorJSON.utf8)) }
                return (200, Data(notFoundJSON.utf8))
            }

            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockBBTURLProtocol.self)
                MockBBTURLProtocol.responseOverride = nil
            }

            let service = ZoteroService()
            let items = try await service.fetchItemsForCitekeys(["roy2022"])

            #expect(
                items.count == 1,
                "Pass 1's successful scope-7 resolution must survive pass 2's own refresh call failing, not be discarded"
            )
            #expect(items.first?.title == "From Library Seven")

            #expect(
                MockBBTURLProtocol.capturedRequests.filter { $0.method == "user.groups" }.count == 2,
                "The forced refresh must still be attempted once (proving pass 2 was actually entered), even though it then fails"
            )
        }
    }
}
