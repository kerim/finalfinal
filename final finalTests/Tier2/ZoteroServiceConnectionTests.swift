import Testing
import Foundation
@testable import final_final

@Suite("ZoteroService connection guard")
struct ZoteroServiceConnectionTests {

    @Test @MainActor
    func isConnected_defaultsToFalse() {
        let service = ZoteroService()
        #expect(service.isConnected == false)
    }

    @Test @MainActor
    func fetchItemsForCitekeys_attemptsHTTP_whenNotConnected() async {
        let service = ZoteroService()
        #expect(service.isConnected == false, "Precondition: starts disconnected")

        // With the guard removed, fetchItemsForCitekeys attempts the HTTP request
        // even when isConnected is false. This verifies it doesn't short-circuit.
        let start = ContinuousClock.now
        do {
            _ = try await service.fetchItemsForCitekeys(["someCitekey"])
            // Zotero is running in this environment — that's fine, verify it connected
            #expect(service.isConnected == true, "Should set isConnected on success")
        } catch {
            // Any error is acceptable — what matters is the HTTP was attempted.
            // The old guard would have returned in <1ms with .notRunning.
            let elapsed = ContinuousClock.now - start
            #expect(elapsed > .milliseconds(1),
                    "Should take >1ms (HTTP attempt), not instant (old guard)")
        }
    }

    // MARK: - Shared/group-library citekey resolution

    // Phase 2 (t-94369a83) review round 3 -- de-flake: these three tests used to depend on
    // the DEVELOPER'S OWN Zotero + Better BibTeX install being running AND their own
    // personal/group libraries containing these exact real citekeys (`friedman2010` in a
    // real shared/group library, "Sifo-Futing"; `friedmanEnteringMountainsRule2010` in the
    // personal library) -- reachable via `ping()`, but resolution was then hard-asserted
    // to succeed against WHATEVER real library the host machine happened to have. On any
    // machine other than the original author's own (any CI runner, any other developer),
    // this either always no-ops via the `ping()` skip (never actually exercising the
    // resolution logic) or, worse, hard-fails because these specific citekeys simply don't
    // exist in that machine's library -- neither outcome is a meaningful, host-independent
    // regression test. Fixed by swapping the live HTTP dependency for `MockBBTURLProtocol`
    // (Tier 1, `ZoteroLibraryScopeTests.swift`) -- the exact same infrastructure that file's
    // own phase-1/phase-2 resolution tests already use -- with canned JSON-RPC responses
    // standing in for "friedman2010 exists only in a group library" and
    // "friedmanEnteringMountainsRule2010 exists in the personal library", preserving each
    // test's original intent (this is still, per the original comment, a direct automated
    // analogue of the real bug report these citekeys came from) while making it
    // deterministic and independent of host environment or network latency.
    //
    // Every test below runs inside `ZoteroNetworkTestLock.shared.run { ... }` — see that
    // type's doc comment in `ZoteroLibraryScopeTests.swift` (Tier 1) for why: both suites
    // hit the exact same real host/port (127.0.0.1:23119), and Tier 1 registers a
    // process-wide mock `URLProtocol` there.

    @Test @MainActor
    func resolveGroupLibraryCitekey_friedman2010() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()

            let groupsJSON = #"{"jsonrpc":"2.0","result":[{"id":1,"name":"My Library"},{"id":19,"name":"Sifo-Futing"}],"id":1}"#
            MockBBTURLProtocol.responses["user.groups"] = (200, Data(groupsJSON.utf8))

            let personalNotFoundJSON = #"{"jsonrpc":"2.0","result":{"errors":{"friedman2010":0},"items":{}},"id":2}"#
            // swiftlint:disable line_length
            let groupFoundJSON = """
            {"jsonrpc":"2.0","result":{"errors":{},"items":{"friedman2010":{"id":"friedman2010","type":"chapter","citation-key":"friedman2010","title":"Entering the Mountains"}}},"id":3}
            """
            // swiftlint:enable line_length
            MockBBTURLProtocol.responseOverride = { method, params in
                guard method == "item.pandoc_filter" else { return nil }
                let scope = params.count > 2 ? params[2] : nil
                if scope as? Int == ZoteroService.personalLibraryID {
                    return (200, Data(personalNotFoundJSON.utf8))
                }
                return (200, Data(groupFoundJSON.utf8))
            }

            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockBBTURLProtocol.self)
                MockBBTURLProtocol.responseOverride = nil
            }

            let service = ZoteroService()

            // Direct automated analogue of the bug report: friedman2010 only exists in a
            // shared/group library, so this succeeding proves the two-phase resolver
            // actually reaches group libraries (the old item.export-only path failed here
            // with "BBT error: not found: friedman2010").
            let items = try await service.fetchItemsForCitekeys(["friedman2010"])
            #expect(items.count == 1)
            #expect(items.first?.citekey == "friedman2010")

            #expect(
                !MockBBTURLProtocol.capturedRequests.filter({ $0.method == "user.groups" }).isEmpty,
                "Phase 2 must fetch user.groups to know which group libraries to query")
        }
    }

    @Test @MainActor
    func resolvePersonalLibraryCitekey_friedmanEnteringMountainsRule2010() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()
            // swiftlint:disable line_length
            let itemJSON = """
            {"jsonrpc":"2.0","result":{"errors":{},"items":{"friedmanEnteringMountainsRule2010":{"id":"friedmanEnteringMountainsRule2010","type":"chapter","citation-key":"friedmanEnteringMountainsRule2010","title":"Entering the Mountains"}}},"id":4}
            """
            // swiftlint:enable line_length
            MockBBTURLProtocol.responses["item.pandoc_filter"] = (200, Data(itemJSON.utf8))
            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer { URLProtocol.unregisterClass(MockBBTURLProtocol.self) }

            let service = ZoteroService()

            // Guards the two-phase ordering against regressing the common case: a
            // personal-library citekey must still resolve in phase 1, without needing phase 2.
            let items = try await service.fetchItemsForCitekeys(["friedmanEnteringMountainsRule2010"])
            #expect(items.count == 1)
            #expect(items.first?.citekey == "friedmanEnteringMountainsRule2010")

            #expect(MockBBTURLProtocol.capturedRequests.filter { $0.method == "user.groups" }.isEmpty,
                "Fully resolved in phase 1 -- phase 2 (user.groups) must never fire")
        }
    }

    @Test @MainActor
    func resolveBothPersonalAndGroupCitekeysTogether() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()

            let groupsJSON = #"{"jsonrpc":"2.0","result":[{"id":1,"name":"My Library"},{"id":19,"name":"Sifo-Futing"}],"id":1}"#
            MockBBTURLProtocol.responses["user.groups"] = (200, Data(groupsJSON.utf8))

            // Phase 1 (personal scope, both citekeys batched): resolves the personal-library
            // citekey directly and reports the group-only one as not found.
            // swiftlint:disable line_length
            let personalMixedJSON = """
            {"jsonrpc":"2.0","result":{"errors":{"friedman2010":0},"items":{"friedmanEnteringMountainsRule2010":{"id":"friedmanEnteringMountainsRule2010","type":"chapter","citation-key":"friedmanEnteringMountainsRule2010","title":"Entering the Mountains"}}},"id":2}
            """
            // Phase 2 (group scope, just the leftover citekey): resolves the group-only one.
            let groupFoundJSON = """
            {"jsonrpc":"2.0","result":{"errors":{},"items":{"friedman2010":{"id":"friedman2010","type":"chapter","citation-key":"friedman2010","title":"Entering the Mountains"}}},"id":3}
            """
            // swiftlint:enable line_length
            MockBBTURLProtocol.responseOverride = { method, params in
                guard method == "item.pandoc_filter" else { return nil }
                let scope = params.count > 2 ? params[2] : nil
                if scope as? Int == ZoteroService.personalLibraryID {
                    return (200, Data(personalMixedJSON.utf8))
                }
                return (200, Data(groupFoundJSON.utf8))
            }

            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockBBTURLProtocol.self)
                MockBBTURLProtocol.responseOverride = nil
            }

            let service = ZoteroService()
            let items = try await service.fetchItemsForCitekeys(
                ["friedman2010", "friedmanEnteringMountainsRule2010"]
            )
            #expect(items.count == 2)
            let resolvedCitekeys = Set(items.map(\.citekey))
            #expect(
                resolvedCitekeys == Set(["friedman2010", "friedmanEnteringMountainsRule2010"]),
                "Both the personal-library and group-library citekey must resolve from a single batched call"
            )
        }
    }
}
