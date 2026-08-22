//
//  ZoteroLibraryScopeTests+GroupsResponseDecoding.swift
//  final finalTests
//
//  Split out of ZoteroLibraryScopeTests.swift to keep that file's struct body under SwiftLint's
//  type_body_length limit (300 lines). Same suite/fixture context applies — see the header
//  comment in ZoteroLibraryScopeTests.swift for the full regression background (the
//  shared/group-library citekey resolve bug, live-captured vs. synthesized fixtures, and the
//  ZoteroNetworkTestLock cross-suite mutex). These tests cover `user.groups` response decoding
//  (ZoteroService.parseLibraries / groupLibraryNames) in isolation, with no mocked HTTP involved.
//

import Testing
import Foundation
@testable import final_final

extension ZoteroLibraryScopeTests {

    // MARK: - user.groups response decoding

    @Test("user.groups fixture (19 libraries, no collections key) parses to the correct set of libraries")
    func parseLibrariesFromUserGroupsFixture() throws {
        // Synthesized (middle entries) — id 1 "My Library" and id 19 "Sifo-Futing" match the
        // developer's real library names; BBT only includes `collections` per entry when the
        // caller passes `includeCollections` (we don't), so this fixture omits it entirely.
        var entries = [#"{"id":1,"name":"My Library"}"#, #"{"id":2,"name":"Kerim's Bibliographies"}"#]
        for id in 3...18 {
            entries.append(#"{"id":\#(id),"name":"Group \#(id)"}"#)
        }
        entries.append(#"{"id":19,"name":"Sifo-Futing"}"#)
        let json = #"{"jsonrpc":"2.0","result":[\#(entries.joined(separator: ","))],"id":7}"#

        let libraries = try ZoteroService.parseLibraries(from: Data(json.utf8))

        #expect(libraries.count == 19)
        #expect(Set(libraries.map(\.id)) == Set(1...19))
        let expectedGroupNames = ["Kerim's Bibliographies"] + (3...18).map { "Group \($0)" } + ["Sifo-Futing"]
        #expect(
            ZoteroService.groupLibraryNames(from: libraries) == expectedGroupNames,
            """
            Must be the exact 18 group names (id 2, 3-18, 19), not just a matching count -- a \
            regression that included "My Library" while dropping a different group would \
            still total 18 under a bare count check
            """
        )
    }

    @Test(
        """
        user.groups entries with a missing name field, OR a wrong-typed name field, still parse \
        -- the whole decode succeeds and both malformed entries end up with name == nil, while \
        properly-named entries decode correctly; groupLibraryNames then drops both malformed \
        entries while keeping the properly-named one
        """
    )
    func parseLibrariesToleratesMissingOrWrongTypedName() throws {
        let json = #"{"jsonrpc":"2.0","result":[{"id":1,"name":"My Library"},{"id":19},{"id":20,"name":123}],"id":1}"#
        let libraries = try ZoteroService.parseLibraries(from: Data(json.utf8))

        #expect(libraries.count == 3, "A single malformed entry must not fail the whole decode")
        #expect(libraries.first { $0.id == 1 }?.name == "My Library")
        #expect(libraries.first { $0.id == 19 }?.name == nil, "Missing name key must decode to nil, not throw")
        #expect(libraries.first { $0.id == 20 }?.name == nil, "Wrong-typed (numeric) name must decode to nil, not throw")

        let names = ZoteroService.groupLibraryNames(from: libraries)
        #expect(names.isEmpty, "Both id 19 (nameless) and id 20 (wrong-typed name) must be dropped -- neither has a usable name")
    }

    @Test("parseLibraries throws for a missing OR explicitly-null result key, never silently degrading to []")
    func parseLibrariesThrowsOnMissingOrNullResult() throws {
        // A malformed/protocol-violating envelope -- per parseLibraries's doc comment, this must
        // throw rather than degrade to "zero libraries", which would get cached and never
        // self-heal (only a "JSON-RPC error:"-prefixed message triggers the stale-cache retry in
        // performGroupPhase).
        let missingResultJSON = #"{"jsonrpc":"2.0","id":7}"#
        #expect(throws: (any Error).self) {
            _ = try ZoteroService.parseLibraries(from: Data(missingResultJSON.utf8))
        }

        let nullResultJSON = #"{"jsonrpc":"2.0","result":null,"id":7}"#
        #expect(throws: (any Error).self) {
            _ = try ZoteroService.parseLibraries(from: Data(nullResultJSON.utf8))
        }
    }

    @Test(
        """
        A malformed entry (missing/non-numeric id) inside result is skipped, not fatal to the \
        whole decode -- the well-formed entries around it still parse, and decoding terminates in \
        bounded time rather than looping forever. Pins the fix documented on \
        GroupsRPCResponse.init's superDecoder() comment: a naive decode-in-a-loop never advances \
        this JSONDecoder's unkeyed-container index on a throwing element, so it would spin forever \
        re-decoding the same malformed entry rather than skip it
        """
    )
    func parseLibrariesSkipsMalformedEntryWithoutHanging() throws {
        let json = #"{"result":[{"id":1,"name":"My Library"},{"name":"No ID"},{"id":19,"name":"Sifo-Futing"}]}"#
        let data = Data(json.utf8)

        // A real, thread-level timeout (not cooperative-cancellation) -- if parseLibraries ever
        // regresses to a naive loop that spins forever on the malformed element, this test must
        // fail promptly instead of hanging the whole suite.
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<[ZoteroLibrary], Error>?
        DispatchQueue.global().async {
            outcome = Result { try ZoteroService.parseLibraries(from: data) }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 2) == .success else {
            Issue.record("parseLibraries did not return within 2s -- looks like an infinite-loop regression")
            return
        }

        let libraries = try #require(outcome).get()
        #expect(libraries.count == 2, "The malformed entry (missing id) must be skipped, not fail or hang the whole decode")
        #expect(Set(libraries.map(\.id)) == [1, 19])
    }
}
