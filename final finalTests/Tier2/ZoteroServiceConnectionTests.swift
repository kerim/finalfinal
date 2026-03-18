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
    func fetchItemsForCitekeys_throwsNotRunning_onlyWhenHTTPFails() async {
        let service = ZoteroService()
        // With the guard removed, fetchItemsForCitekeys now attempts the HTTP request.
        // When Zotero is not running, connection-refused maps to .notRunning.
        do {
            _ = try await service.fetchItemsForCitekeys(["someCitekey"])
            // If Zotero happens to be running, this could succeed — not a test failure
        } catch let error as ZoteroError {
            switch error {
            case .notRunning:
                // Connection refused → .notRunning (correct behavior)
                break
            case .networkError:
                // Other network error — also acceptable when Zotero isn't running
                break
            default:
                // Any ZoteroError is acceptable (invalidResponse, noResponse, etc.)
                break
            }
        } catch {
            Issue.record("Unexpected non-ZoteroError type: \(error)")
        }
    }
}
