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
}
