//
//  ZoteroExportDecodeResultTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Direct coverage for `ZoteroService.decodeExportResult(from:)` — the `item.export`
//  JSON-RPC response decoder used by `fetchItemsForCitekeysViaExport`. Before this file,
//  only prose comments in ZoteroService.swift defended the three-way distinction between
//  an empty `result` string, an empty `result` array, and a non-empty `result` string that
//  itself decodes to an empty CSL-item array. The last of these must NOT collapse into
//  `.noItems` — doing so would incorrectly skip updating connection state
//  (`isConnected`/`connectionError`) in the caller, which today only takes that early-return
//  path for the two genuinely-empty-payload cases.
//

import Testing
import Foundation
@testable import final_final

@Suite("Zotero item.export decode result — Tier 1: Silent Killers")
struct ZoteroExportDecodeResultTests {

    @Test("Empty result string decodes to .noItems")
    func emptyResultStringIsNoItems() throws {
        let data = Data(#"{"result":""}"#.utf8)
        let result = try ZoteroService.decodeExportResult(from: data)
        guard case .noItems = result else {
            Issue.record("Expected .noItems for an empty result string, got \(result)")
            return
        }
    }

    @Test("Empty result array decodes to .noItems")
    func emptyResultArrayIsNoItems() throws {
        let data = Data(#"{"result":[]}"#.utf8)
        let result = try ZoteroService.decodeExportResult(from: data)
        guard case .noItems = result else {
            Issue.record("Expected .noItems for an empty result array, got \(result)")
            return
        }
    }

    @Test("A non-empty result STRING that decodes to an empty CSL array is .items([]), NOT .noItems — the critical three-way distinction")
    func nonEmptyStringDecodingToEmptyArrayIsItemsNotNoItems() throws {
        // The result payload itself is the non-empty string "[]" — distinct from an empty
        // string ("") and distinct from the result being a JSON array literal directly.
        let data = Data(#"{"result":"[]"}"#.utf8)
        let result = try ZoteroService.decodeExportResult(from: data)
        switch result {
        case .items(let items):
            #expect(items.isEmpty)
        case .noItems:
            let message: String = "Expected .items([]) — a non-empty result STRING that decodes to an empty array must "
                + "not collapse to .noItems, or the caller would wrongly skip updating connection state"
            Issue.record("\(message)")
        }
    }

    @Test("A JSON-RPC error envelope throws ZoteroError.invalidResponse")
    func errorEnvelopeThrowsInvalidResponse() throws {
        let data = Data(#"{"error":{"message":"item not found"}}"#.utf8)
        do {
            _ = try ZoteroService.decodeExportResult(from: data)
            Issue.record("Expected decodeExportResult to throw for a JSON-RPC error envelope")
        } catch let error as ZoteroError {
            guard case .invalidResponse(let message) = error else {
                Issue.record("Expected ZoteroError.invalidResponse, got \(error)")
                return
            }
            #expect(message.contains("item not found"))
        } catch {
            Issue.record("Expected ZoteroError.invalidResponse, got \(error)")
        }
    }
}
