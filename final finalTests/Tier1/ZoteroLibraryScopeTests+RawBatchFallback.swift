//
//  ZoteroLibraryScopeTests+RawBatchFallback.swift
//  final finalTests
//
//  Split out of ZoteroLibraryScopeTests.swift so that struct's body stays under
//  SwiftLint's 300-line type_body_length threshold. See that file for the shared
//  mocked-HTTP test harness (MockBBTURLProtocol, ZoteroNetworkTestLock) this extension
//  reuses.
//
//  Regression coverage for the "one bad citekey drops the whole PDF bibliography" bug:
//  fetchRawItemsForCitekeys used to throw the instant ANY requested citekey was
//  unresolved, which meant a single typo among a dozen real citations silently killed
//  --citeproc for the WHOLE document. It now returns a RawCitekeyBatchResult that names
//  which citekeys were skipped instead of throwing, so export.swift can build a partial
//  bibliography and warn about just the bad key(s). The legacy item.export fallback path
//  (fetchRawItemsForCitekeysViaExport) gets the same treatment via unresolvedKeys, since
//  item.export itself reports no per-key not-found information of its own — without the
//  diff, a citekey that only failed via the fallback would vanish with zero warning,
//  recreating the exact bug this file guards against.
//

import Testing
import Foundation
@testable import final_final

extension ZoteroLibraryScopeTests {

    // MARK: - unresolvedKeys (pure, no network)

    @Test("unresolvedKeys diffs requested citekeys against resolved items' id field, case-insensitively")
    func unresolvedKeysDiffsCaseInsensitively() {
        let resolved: [[String: Any]] = [["id": "Friedman2010"], ["id": "other2020"]]
        let result = ZoteroService.unresolvedKeys(
            requested: ["friedman2010", "missing2099", "OTHER2020"],
            resolvedItems: resolved
        )
        #expect(result == ["missing2099"], "Only the genuinely-unresolved key should survive the diff")
    }

    @Test("unresolvedKeys treats an item with a missing/non-string id as unresolved for every requested key")
    func unresolvedKeysToleratesMissingIdField() {
        let resolved: [[String: Any]] = [["title": "No id field here"]]
        let result = ZoteroService.unresolvedKeys(requested: ["anykey"], resolvedItems: resolved)
        #expect(result == ["anykey"])
    }

    // MARK: - fetchRawItemsForCitekeys: mixed batch never throws, names the not-found key

    @Test("fetchRawItemsForCitekeys: a mixed batch resolves the good key and names the bad one, without throwing")
    @MainActor
    func mixedBatchIsPartialSuccessNotAllOrNothingRaw() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()
            // Only the personal library exists, so phase 2 never fires.
            let groupsJSON = #"{"jsonrpc":"2.0","result":[{"id":1,"name":"My Library"}],"id":1}"#
            MockBBTURLProtocol.responses["user.groups"] = (200, Data(groupsJSON.utf8))

            // swiftlint:disable line_length
            let itemJSON = """
            {"jsonrpc":"2.0","result":{"errors":{"badkey2099":0},"items":{"friedman2010":{"id":"friedman2010","type":"chapter","citation-key":"friedman2010","title":"Entering the Mountains"}}},"id":5}
            """
            // swiftlint:enable line_length
            MockBBTURLProtocol.responses["item.pandoc_filter"] = (200, Data(itemJSON.utf8))

            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer { URLProtocol.unregisterClass(MockBBTURLProtocol.self) }

            let service = ZoteroService()
            let result = try await service.fetchRawItemsForCitekeys(["friedman2010", "badkey2099"])

            #expect(result.items.count == 1, "The one real item must still resolve even though another key in the same batch failed")
            #expect(result.notFoundKeys == ["badkey2099"])
            #expect(result.ambiguousKeys.isEmpty)
        }
    }

    // MARK: - fetchRawItemsForCitekeys: forced primary-path failure -> item.export fallback

    @Test("fetchRawItemsForCitekeys: primary path failure falls back to item.export, which still names the key it couldn't find")
    @MainActor
    func fallbackToItemExportStillReportsUnresolvedKeys() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()
            // A top-level JSON-RPC error object forces resolveRawViaPandocFilter to throw,
            // triggering the item.export fallback.
            let errorJSON = #"{"jsonrpc":"2.0","error":{"code":-1,"message":"forced failure for test"},"id":5}"#
            MockBBTURLProtocol.responses["item.pandoc_filter"] = (200, Data(errorJSON.utf8))

            // item.export (unlike item.pandoc_filter) reports no per-key not-found info of
            // its own -- it just silently omits "missingkey2099" from the result array.
            let fallbackJSON = """
            [{"id":"friedman2010","type":"chapter","citation-key":"friedman2010","title":"Fallback Title"}]
            """
            MockBBTURLProtocol.responses["item.export"] =
                (200, Data(#"{"jsonrpc":"2.0","result":\#(fallbackJSON),"id":6}"#.utf8))

            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer { URLProtocol.unregisterClass(MockBBTURLProtocol.self) }

            let service = ZoteroService()
            let result = try await service.fetchRawItemsForCitekeys(["friedman2010", "missingkey2099"])

            #expect(result.items.count == 1)
            #expect(result.items.first?["title"] as? String == "Fallback Title")
            #expect(
                result.notFoundKeys == ["missingkey2099"],
                "The fallback must diff requested vs. resolved and report the missing key -- not silently drop it"
            )
            #expect(result.ambiguousKeys.isEmpty, "item.export has no notion of ambiguous -- everything unresolved is not-found")

            #expect(!MockBBTURLProtocol.capturedRequests.filter({ $0.method == "item.export" }).isEmpty, "Fallback must actually fire")
        }
    }
}
