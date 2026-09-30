import Testing
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

    // MARK: - Shared/group-library citekey resolution (live)
    //
    // These three tests depend on the developer's own Zotero + Better BibTeX install AND
    // their own personal/group libraries containing these exact citekeys (`friedman2010`
    // lives in a real shared/group library, "Sifo-Futing"; `friedmanEnteringMountainsRule2010`
    // lives in the personal library). They skip ONLY when Zotero/BBT itself isn't reachable
    // (checked via `ping()`, the codebase's standard mechanism for this — see
    // `handleOpenCitationPicker`'s pre-check) — not on any other failure. Once Zotero is
    // confirmed reachable, resolution is hard-asserted to succeed: a real regression (a throw,
    // an empty result, a wrong citekey) fails the test, it does not silently skip. This is
    // deliberately narrower than the pattern in `fetchItemsForCitekeys_attemptsHTTP_whenNotConnected`
    // above, which tolerates any outcome because it isn't testing a specific citekey's
    // resolvability — a `guard let items = try? ..., else { return }` here would have let a
    // genuine regression (either a thrown error OR a wrongly-empty result) slip through as a
    // silent skip instead of a failure.
    //
    // Every test below runs inside `ZoteroNetworkTestLock.shared.run { ... }` — see that type's
    // doc comment in `ZoteroLibraryScopeTests.swift` (Tier 1) for why: both suites hit the same
    // 127.0.0.1:23119 host/port, and Tier 1 registers a process-wide mock `URLProtocol` there.

    @Test @MainActor
    func resolveGroupLibraryCitekey_friedman2010() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            let service = ZoteroService()
            guard await service.ping() else {
                return // Zotero/BBT not reachable in this environment — skip cleanly.
            }

            // Direct automated analogue of the bug report: friedman2010 only exists in a
            // shared/group library, so this succeeding proves the two-phase resolver actually
            // reaches group libraries (the old item.export-only path failed here with
            // "BBT error: not found: friedman2010").
            let items = try await service.fetchItemsForCitekeys(["friedman2010"])
            #expect(items.count == 1)
            #expect(items.first?.citekey == "friedman2010")
        }
    }

    @Test @MainActor
    func resolvePersonalLibraryCitekey_friedmanEnteringMountainsRule2010() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            let service = ZoteroService()
            guard await service.ping() else {
                return // Zotero/BBT not reachable in this environment — skip cleanly.
            }

            // Guards the two-phase ordering against regressing the common case: a
            // personal-library citekey must still resolve in phase 1, without needing phase 2.
            let items = try await service.fetchItemsForCitekeys(["friedmanEnteringMountainsRule2010"])
            #expect(items.count == 1)
            #expect(items.first?.citekey == "friedmanEnteringMountainsRule2010")
        }
    }

    @Test @MainActor
    func resolveBothPersonalAndGroupCitekeysTogether() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            let service = ZoteroService()
            guard await service.ping() else {
                return // Zotero/BBT not reachable in this environment — skip cleanly.
            }

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
