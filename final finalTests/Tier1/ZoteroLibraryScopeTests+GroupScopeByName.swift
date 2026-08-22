//
//  ZoteroLibraryScopeTests+GroupScopeByName.swift
//  final finalTests
//
//  Split out of ZoteroLibraryScopeTests.swift to keep that file's struct body under SwiftLint's
//  type_body_length limit (300 lines). Same suite/fixture context applies — see the header
//  comment in ZoteroLibraryScopeTests.swift for the full regression background (the
//  shared/group-library citekey resolve bug, live-captured vs. synthesized fixtures, and the
//  ZoteroNetworkTestLock cross-suite mutex).
//
//  Regression coverage for a second bug layered on top of the original one: even after adding
//  a library-scope parameter to `item.pandoc_filter`, that scope was serialized as an array of
//  STRINGIFIED numeric IDs (e.g. ["19"]). Better BibTeX only matches a bare JSON NUMBER against
//  the personal library, and a string/string-array against library NAMES — never a stringified
//  ID — so every scoped lookup silently failed and fell back to unscoped (personal-only)
//  behavior. The fix sends `.personal` as a bare Int and `.libraryNames` as an array of the
//  libraries' actual display names. These tests guard the corrected serialization directly, in
//  addition to the request-shape tests already in ZoteroLibraryScopeTests.swift.
//

import Testing
import Foundation
@testable import final_final

extension ZoteroLibraryScopeTests {

    @Test("A request built with .personal scope serializes params[2] as a bare Int, never a String or [String]")
    func personalScopeRequestSerializesAsABareInt() throws {
        let body = ZoteroService.pandocFilterRequestBody(citekeys: ["friedman2010"], scope: .personal)
        let params = try #require(body["params"] as? [Any])
        let scope = params.count > 2 ? params[2] : nil

        #expect(scope as? Int == ZoteroService.personalLibraryID)
        #expect(scope as? String == nil, "A stringified id (e.g. \"1\") is read by BBT as a library NAME, not an id")
        #expect(scope as? [String] == nil)
    }

    @Test("A request built with .libraryNames scope serializes params[2] as exactly that [String], never stringified ids")
    func libraryNamesScopeRequestSerializesAsThatExactStringArray() throws {
        let groupNames = ["Kerim's Bibliographies", "Sifo-Futing"]
        let body = ZoteroService.pandocFilterRequestBody(citekeys: ["friedman2010"], scope: .libraryNames(groupNames))
        let params = try #require(body["params"] as? [Any])
        let scope = params.count > 2 ? params[2] : nil

        let serializedNames = try #require(scope as? [String])
        #expect(serializedNames == groupNames)
        for name in serializedNames {
            #expect(Int(name) == nil, "\"\(name)\" must be the library's display name, not a numeric id in string clothing")
        }
    }

    @Test(
        """
        End-to-end mocked: a group-only citekey resolves via fetchItemsForCitekeys, and the \
        outbound item.pandoc_filter call that actually matched carried the group library's exact \
        NAME as its scope -- not a stringified id, which is what the pre-fix bug sent and which \
        BBT silently rejected as "not found"
        """
    )
    @MainActor
    func groupOnlyCitekeyResolvesViaLibraryNameScope() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()

            let groupsJSON = #"{"jsonrpc":"2.0","result":[{"id":1,"name":"My Library"},{"id":19,"name":"Sifo-Futing"}],"id":1}"#
            MockBBTURLProtocol.responses["user.groups"] = (200, Data(groupsJSON.utf8))

            // swiftlint:disable line_length
            let groupFoundJSON = """
            {"jsonrpc":"2.0","result":{"errors":{},"items":{"friedman2010":{"id":"friedman2010","type":"chapter","citation-key":"friedman2010","title":"From Sifo-Futing"}}},"id":3}
            """
            // swiftlint:enable line_length
            let notFoundJSON = #"{"jsonrpc":"2.0","result":{"errors":{"friedman2010":0},"items":{}},"id":2}"#

            // Mock only returns the item when the scope array is exactly the group's own name --
            // proves the outbound request carried the display name, not a stringified id (which
            // this override would never match, correctly reproducing the pre-fix silent failure).
            MockBBTURLProtocol.responseOverride = { method, params in
                guard method == "item.pandoc_filter" else { return nil }
                let scope = params.count > 2 ? params[2] : nil
                if scope as? [String] == ["Sifo-Futing"] {
                    return (200, Data(groupFoundJSON.utf8))
                }
                return (200, Data(notFoundJSON.utf8))
            }

            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockBBTURLProtocol.self)
                MockBBTURLProtocol.responseOverride = nil
            }

            let service = ZoteroService()
            let items = try await service.fetchItemsForCitekeys(["friedman2010"])

            #expect(items.count == 1)
            #expect(items.first?.title == "From Sifo-Futing")

            let groupCall = MockBBTURLProtocol.capturedRequests.last { request in
                guard request.method == "item.pandoc_filter",
                      let params = request.body["params"] as? [Any],
                      params.count > 2 else { return false }
                return (params[2] as? [String]) != nil
            }
            let capturedParams = try #require(groupCall?.body["params"] as? [Any])
            let capturedScope = capturedParams.count > 2 ? capturedParams[2] : nil
            #expect(
                capturedScope as? [String] == ["Sifo-Futing"],
                "The captured outbound request's scope must be the group library's exact name"
            )
        }
    }
}
