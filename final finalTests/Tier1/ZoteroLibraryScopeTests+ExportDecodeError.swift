//
//  ZoteroLibraryScopeTests+ExportDecodeError.swift
//  final finalTests
//
//  Split out of ZoteroLibraryScopeTests.swift (2026-08-07) so that struct's body
//  stays under SwiftLint's 300-line type_body_length threshold. See that file for
//  the shared mocked-HTTP test harness (MockBBTURLProtocol, ZoteroNetworkTestLock)
//  this extension reuses.
//

import Testing
import Foundation
@testable import final_final

extension ZoteroLibraryScopeTests {
    @Test("A malformed item.export FALLBACK response (decode failure) throws ZoteroError.invalidResponse, not .networkError")
    @MainActor
    func malformedExportFallbackResponseThrowsInvalidResponseNotNetworkError() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()
            // Same trigger as malformedPandocFilterResponseTriggersExportFallback (in
            // ZoteroLibraryScopeTests.swift): the item.pandoc_filter item is missing its
            // required `type` field, so its CSLItem decode throws and fetchItemsForCitekeys
            // falls back to fetchItemsForCitekeysViaExport.
            let malformedPandocJSON = #"{"jsonrpc":"2.0","result":{"errors":{},"items":{"friedman2010":{"id":"friedman2010"}}},"id":5}"#
            MockBBTURLProtocol.responses["item.pandoc_filter"] = (200, Data(malformedPandocJSON.utf8))

            // The item.export fallback itself now also returns a CSL item missing its required
            // `type` field — a malformed/unexpected response shape, not a network failure.
            // Before the fix, fetchItemsForCitekeysViaExport folded this DecodingError into
            // ZoteroError.networkError, surfacing a misleading "Network error" message to the
            // user for what is actually a decode failure.
            let malformedExportItemsJSON = #"[{"id":"friedman2010"}]"#
            MockBBTURLProtocol.responses["item.export"] =
                (200, Data(#"{"jsonrpc":"2.0","result":\#(malformedExportItemsJSON),"id":6}"#.utf8))

            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer { URLProtocol.unregisterClass(MockBBTURLProtocol.self) }

            let service = ZoteroService()
            do {
                _ = try await service.fetchItemsForCitekeys(["friedman2010"])
                Issue.record("Expected the item.export fallback's decode failure to throw")
            } catch let error as ZoteroError {
                guard case .invalidResponse = error else {
                    Issue.record("Expected ZoteroError.invalidResponse for a decode failure, got \(error)")
                    return
                }
            } catch {
                Issue.record("Expected ZoteroError.invalidResponse, got \(error)")
            }
        }
    }
}
