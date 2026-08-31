//
//  ZoteroLibraryScopeTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Regression coverage for the shared/group-library citekey resolve bug: ZoteroService's old
//  citekey resolver (`item.export`, no library argument) silently scoped every lookup to the
//  personal library ("My Library"), so a citekey that only exists in a shared/group library
//  failed with "BBT error: not found: <key>" even though CAYW/search (both unscoped) had just
//  found it. The fix resolves in two phases via `item.pandoc_filter` — personal library
//  first, then the user's remaining group libraries for anything still unresolved — and falls
//  back to the old `item.export` call if the new path fails for any reason.
//
//  The two-phase engine lives in `ZoteroService+LibraryScope.swift` as a RAW (undecoded, via
//  JSONSerialization) resolver, shared by the typed CAYW path (`fetchItemsForCitekeys`, which
//  decodes into `CSLItem` on top) and the raw export path (`fetchRawItemsForCitekeys`, which
//  hands undecoded CSL-JSON straight to pandoc so it doesn't lose fields `CSLItem` doesn't
//  model).
//
//  Fixtures below marked "live-captured" are verbatim JSON-RPC responses from a real Zotero
//  9.0.6 + Better BibTeX 9.0.47 install (the bug-report citekey `friedman2010`, which lives in
//  group library id 19, "Sifo-Futing"). Fixtures marked "synthesized" are hand-written to
//  exercise branches (ambiguous matches, malformed responses) that couldn't be captured live
//  without editing the developer's actual Zotero libraries.
//
//  Every test below that registers `MockBBTURLProtocol` (a process-wide `URLProtocol`) runs
//  inside `ZoteroNetworkTestLock.shared.run { ... }`. That lock also guards every
//  network-touching test in `ZoteroServiceConnectionTests.swift` (Tier 2), which hits the same
//  127.0.0.1:23119 host/port for real — without it, the mock could intercept a concurrently
//  running Tier 2 test's live traffic (or a stray live request could pollute this file's
//  captured-request assertions). Swift Testing has no built-in cross-suite mutual exclusion,
//  so this is a manual substitute.
//

import Testing
import Foundation
@testable import final_final

@Suite("Zotero library scope — Tier 1: Silent Killers", .serialized)
struct ZoteroLibraryScopeTests {

    // MARK: - item.pandoc_filter response decoding

    @Test("Live-captured friedman2010 pandoc_filter fixture decodes to one CSLItem with the expected fields")
    func friedmanFixtureDecodesCorrectly() throws {
        // Live-captured: the real BBT response for the bug-report citekey.
        // swiftlint:disable line_length
        let json = """
        {"jsonrpc":"2.0","result":{"errors":{},"items":{"friedman2010":{"id":"friedman2010","author":[{"family":"Friedman","given":"P Kerim"}],"citation-key":"friedman2010","container-title":"Becoming Taiwan, from Colonialism to Democracy","custom":{"itemID":24042,"uri":"http://zotero.org/groups/6623119/items/LRJAHBUL","author":"Friedman"},"editor":[{"family":"Heylen","given":"Ann"},{"family":"Sommers","given":"Scott"}],"issued":{"date-parts":[["2010"]]},"page":"19–32","publisher":"Harrassowitz-Verlag","publisher-place":"Wiesbaden","title":"Entering the Mountains to Rule the Aborigines: Taiwanese Aborigine Education and the Colonial Encounter","type":"chapter"}}},"id":5}
        """
        // swiftlint:enable line_length

        let outcome = try ZoteroService.parsePandocFilterResponseRaw(Data(json.utf8))

        #expect(outcome.items.count == 1)
        let rawItem = try #require(outcome.items["friedman2010"])
        let item = try ZoteroService.decodeCSLItem(from: rawItem)
        #expect(item.citekey == "friedman2010")
        #expect(
            item.year == "2010",
            "CSLItem.year wraps CSLDate.year as a String — BBT sent the year as the string \"2010\", not an Int"
        )
        #expect(item.type == .chapter)
        #expect(outcome.notFoundKeys.isEmpty)
        #expect(outcome.ambiguousKeys.isEmpty)
    }

    @Test("Mixed pandoc_filter response: real items resolve AND the not-found key is reported")
    func mixedBatchIsPartialSuccessNotAllOrNothing() throws {
        // Synthesized: real friedman2010 item alongside a citekey guaranteed not to exist.
        // swiftlint:disable line_length
        let json = """
        {"jsonrpc":"2.0","result":{"errors":{"definitelyNotARealKey2099":0},"items":{"friedman2010":{"id":"friedman2010","type":"chapter","citation-key":"friedman2010","title":"Entering the Mountains"}}},"id":9}
        """
        // swiftlint:enable line_length

        let outcome = try ZoteroService.parsePandocFilterResponseRaw(Data(json.utf8))

        #expect(outcome.items.count == 1, "The one real item must still resolve even though another key in the same batch failed")
        #expect(outcome.items["friedman2010"] != nil)
        #expect(outcome.notFoundKeys == ["definitelyNotARealKey2099"])
        #expect(outcome.ambiguousKeys.isEmpty)
    }

    @Test("errors count >= 2 is classified as ambiguous, distinct from not-found (errors count == 0)")
    func ambiguousIsDistinctFromNotFound() throws {
        // Synthesized — NOT live-verified against a real BBT ambiguous response: no
        // genuinely-ambiguous citekey could be constructed without editing the developer's
        // actual Zotero libraries to create a real duplicate across libraries. Verified only
        // by reading BBT's `json-rpc.ts` source for `item.pandoc_filter`:
        // `result.errors[citationKey] = found.length`, where `found.length` is 0 (not found)
        // or >= 2 (ambiguous) — a single match (found.length == 1) is never put in `errors`
        // at all, so any key present in `errors` is one or the other, never both.
        let json = #"{"jsonrpc":"2.0","result":{"errors":{"x":2},"items":{}},"id":10}"#

        let outcome = try ZoteroService.parsePandocFilterResponseRaw(Data(json.utf8))

        #expect(outcome.ambiguousKeys == ["x"])
        #expect(outcome.notFoundKeys.isEmpty)
    }

    @Test("An item whose citation-key differs from its id is re-keyed by id, not by BBT's raw items-dict key")
    func itemsDictIsReKeyedByIdNotByCitationKey() throws {
        // Synthesized: reproduces a legacy `Citation Key:` line left in the item's Zotero
        // Extra field from pre-Zotero-8 Better BibTeX. BBT internally resolves/matches items by
        // its own KeyManager key (surfaced as CSL `id`) but its `item.pandoc_filter` response
        // keys the `items` object by the item's `citation-key` field, which can be a stale,
        // unrelated string left over from that legacy Extra-field line. Before the fix, this
        // left the item reachable only under "oldLegacyKey2010" — a name nothing in the
        // resolution pipeline can trace back to the request — producing a false
        // "not found in any library."
        let json = """
        {"jsonrpc":"2.0","result":{"errors":{},"items":{"oldLegacyKey2010":{"id":"friedman2010",\
        "citation-key":"oldLegacyKey2010","type":"chapter","title":"Entering the Mountains"}}},"id":11}
        """

        let outcome = try ZoteroService.parsePandocFilterResponseRaw(Data(json.utf8))

        #expect(outcome.items.count == 1)
        #expect(
            outcome.items["friedman2010"] != nil,
            "items dict must be re-keyed by the item's CSL id, not left keyed by BBT's raw citation-key dict key"
        )
        #expect(
            outcome.items["oldLegacyKey2010"] == nil,
            "The stale citation-key must not survive as the dict key once a non-empty id is present"
        )
    }

    // MARK: - item.pandoc_filter request body

    @Test("pandocFilterRequestBody with .personal scope puts a bare Int (never a String or [String]) at params[2]")
    func requestBodyPersonalScopeIsABareInt() throws {
        let body = ZoteroService.pandocFilterRequestBody(citekeys: ["friedman2010"], scope: .personal)

        #expect(body["method"] as? String == "item.pandoc_filter")
        let params = try #require(body["params"] as? [Any])
        // [citekeys, asCSL, scope] — a library scope must always be the 3rd element. The old
        // (buggy) item.export call only ever sent 2 params with no library scope at all, so
        // this shape alone is a regression guard for the root cause.
        #expect(params.count == 3)

        #expect(
            params[2] as? Int == ZoteroService.personalLibraryID,
            "The personal library must be scoped by a bare JSON number matching personalLibraryID"
        )
        #expect(params[2] as? String == nil, "Must NOT serialize as a string — BBT reads a string as a library NAME")
        #expect(params[2] as? [String] == nil, "Must NOT serialize as an array — that spelling is for group libraries")
    }

    @Test("pandocFilterRequestBody with .libraryNames scope puts exactly that [String] at params[2]")
    func requestBodyLibraryNamesScopeIsThatExactStringArray() throws {
        let body = ZoteroService.pandocFilterRequestBody(
            citekeys: ["friedman2010"], scope: .libraryNames(["Kerim's Bibliographies", "Sifo-Futing"])
        )

        #expect(body["method"] as? String == "item.pandoc_filter")
        let params = try #require(body["params"] as? [Any])
        #expect(params.count == 3)

        let names = try #require(params[2] as? [String])
        #expect(
            names == ["Kerim's Bibliographies", "Sifo-Futing"],
            "Group libraries must serialize as an array of their exact display names, not stringified ids"
        )
    }

    @Test("groupLibraryScopes excludes the personal library (id 1) from a full user.groups list, batching the rest by name")
    func groupLibraryScopesExcludesPersonal() {
        var libraries = [ZoteroLibrary(id: 1, name: "My Library")]
        for id in 2...19 {
            libraries.append(ZoteroLibrary(id: id, name: "Group \(id)"))
        }

        let plans = ZoteroService.groupLibraryScopes(from: libraries)

        #expect(plans.count == 1, "19 uniquely-named group libraries batch into one .libraryNames plan")
        guard case .libraryNames(let names) = plans.first?.scope else {
            Issue.record("Expected a single .libraryNames plan")
            return
        }
        #expect(!names.contains("My Library"))
        #expect(names == (2...19).map { "Group \($0)" })
    }

    @Test("orderedUniqueCitekeys deduplicates while preserving first-occurrence order")
    func orderedUniqueCitekeysDedupes() {
        let result = ZoteroService.orderedUniqueCitekeys(["a", "b", "a", "c", "b"])
        #expect(result == ["a", "b", "c"])
    }

    // MARK: - Cancellation

    @Test("isCancellation recognizes CancellationError and a cancelled URLError, nothing else")
    func isCancellationRecognizesCancellationShapes() {
        #expect(ZoteroService.isCancellation(CancellationError()))
        #expect(ZoteroService.isCancellation(URLError(.cancelled)))
        #expect(!ZoteroService.isCancellation(URLError(.timedOut)))
        #expect(!ZoteroService.isCancellation(ZoteroError.noResponse))
    }

    // MARK: - Two-phase precedence, case-insensitivity, and error unioning (mergeRawOutcomes)

    @Test("mergeRawOutcomes: personal library is attempted/kept first, even if a group library matches the same citekey")
    func personalLibraryWinsOverGroupMatch() {
        let personalItem: [String: Any] = [
            "id": "dup2020", "type": "book", "citation-key": "dup2020", "title": "Personal Copy"
        ]
        let groupItem: [String: Any] = [
            "id": "dup2020", "type": "book", "citation-key": "dup2020", "title": "Group Copy"
        ]

        let personalOutcome = PandocFilterRawOutcome(items: ["dup2020": personalItem], notFoundKeys: [], ambiguousKeys: [])
        let groupOutcome = PandocFilterRawOutcome(items: ["dup2020": groupItem], notFoundKeys: [], ambiguousKeys: [])

        let merged = ZoteroService.mergeRawOutcomes(requested: ["dup2020"], personal: personalOutcome, groups: groupOutcome)

        #expect(merged.items.count == 1)
        #expect(
            merged.items["dup2020"]?["title"] as? String == "Personal Copy",
            "An item existing in both the personal library and a group library must still resolve from personal"
        )
    }

    @Test("A citekey resolved under different casing than requested is not dropped or reported not-found")
    func caseInsensitiveCitekeyMatchIsNotDroppedOrReportedMissing() {
        // BBT resolved "Friedman2010" (as typed in the document) to its canonical
        // "friedman2010" citation-key (case-insensitive-citekeys preference on) — `items` is
        // keyed by the canonical form, never by the originally-requested string.
        let rawItem: [String: Any] = ["id": "friedman2010", "type": "chapter", "citation-key": "friedman2010"]
        let outcome = PandocFilterRawOutcome(items: ["friedman2010": rawItem], notFoundKeys: [], ambiguousKeys: [])

        let merged = ZoteroService.mergeRawOutcomes(requested: ["Friedman2010"], personal: outcome, groups: nil)

        #expect(merged.items.count == 1, "Resolved item must not be dropped just because its canonical key differs in case from the request")
        #expect(merged.notFoundKeys.isEmpty, "Must not be reported not-found — it WAS found, just under different casing")
    }

    @Test("A key ambiguous in personal and not-found in groups unions to ambiguous, not not-found")
    func ambiguousInPersonalUnionsCorrectlyWithNotFoundInGroups() {
        let personalOutcome = PandocFilterRawOutcome(items: [:], notFoundKeys: [], ambiguousKeys: ["dupkey"])
        let groupOutcome = PandocFilterRawOutcome(items: [:], notFoundKeys: ["dupkey"], ambiguousKeys: [])

        let merged = ZoteroService.mergeRawOutcomes(requested: ["dupkey"], personal: personalOutcome, groups: groupOutcome)

        #expect(merged.ambiguousKeys == ["dupkey"])
        #expect(
            merged.notFoundKeys.isEmpty,
            "A key ambiguous in personal must stay ambiguous even though phase 2 separately reported it not-found"
        )
    }

    // MARK: - End-to-end via mocked HTTP: regression guard, phase-2 wiring, fallback, not-found

    @Test("fetchItemsForCitekeys calls item.pandoc_filter scoped to the personal library first")
    @MainActor
    func resolveCallsAreScopedToALibrary() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()
            // swiftlint:disable line_length
            let itemJSON = """
            {"jsonrpc":"2.0","result":{"errors":{},"items":{"friedman2010":{"id":"friedman2010","type":"chapter","citation-key":"friedman2010","title":"Entering the Mountains"}}},"id":5}
            """
            // swiftlint:enable line_length
            MockBBTURLProtocol.responses["item.pandoc_filter"] = (200, Data(itemJSON.utf8))
            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer { URLProtocol.unregisterClass(MockBBTURLProtocol.self) }

            let service = ZoteroService()
            let items = try await service.fetchItemsForCitekeys(["friedman2010"])

            #expect(items.count == 1)
            #expect(items.first?.citekey == "friedman2010")

            let pandocRequests = MockBBTURLProtocol.capturedRequests.filter { $0.method == "item.pandoc_filter" }
            #expect(!pandocRequests.isEmpty, "Must call item.pandoc_filter, not just item.export")

            let params = try #require(pandocRequests.first?.body["params"] as? [Any])
            let scopeID = try #require(params[safe: 2] as? Int)
            #expect(
                scopeID == ZoteroService.personalLibraryID,
                "Phase 1 must scope to the personal library (a bare Int) and must be tried first"
            )

            // Fully resolved in phase 1, so phase 2 (user.groups + a second pandoc_filter call)
            // must never fire — proves personal library is genuinely tried first.
            #expect(MockBBTURLProtocol.capturedRequests.filter { $0.method == "user.groups" }.isEmpty)
        }
    }

    @Test("Phase 2 actually resolves what phase 1 could not — full mocked pipeline, not just mergeRawOutcomes in isolation")
    @MainActor
    func phase2ResolvesWhatPhase1Missed() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()

            let groupsJSON = #"{"jsonrpc":"2.0","result":[{"id":1,"name":"My Library"},{"id":19,"name":"Sifo-Futing"}],"id":1}"#
            MockBBTURLProtocol.responses["user.groups"] = (200, Data(groupsJSON.utf8))

            let personalNotFoundJSON = #"{"jsonrpc":"2.0","result":{"errors":{"friedman2010":0},"items":{}},"id":2}"#
            // swiftlint:disable line_length
            let groupFoundJSON = """
            {"jsonrpc":"2.0","result":{"errors":{},"items":{"friedman2010":{"id":"friedman2010","type":"chapter","citation-key":"friedman2010","title":"From Group Library"}}},"id":3}
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
            let items = try await service.fetchItemsForCitekeys(["friedman2010"])

            #expect(items.count == 1)
            #expect(items.first?.title == "From Group Library")

            let pandocCalls = MockBBTURLProtocol.capturedRequests.filter { $0.method == "item.pandoc_filter" }
            #expect(pandocCalls.count == 2, "Phase 1 (personal) must be tried, then phase 2 (groups) for the leftover")
            #expect(
                !MockBBTURLProtocol.capturedRequests.filter({ $0.method == "user.groups" }).isEmpty,
                "Phase 2 must fetch user.groups to know which group libraries to query"
            )
        }
    }

    @Test("A citekey unresolved after both phases throws — not-found must surface, never be silently dropped")
    @MainActor
    func genuinelyMissingCitekeyThrows() async {
        await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()
            // Only the personal library exists — phase 1 alone is the final word.
            let groupsJSON = #"{"jsonrpc":"2.0","result":[{"id":1,"name":"My Library"}],"id":1}"#
            MockBBTURLProtocol.responses["user.groups"] = (200, Data(groupsJSON.utf8))
            let notFoundJSON = #"{"jsonrpc":"2.0","result":{"errors":{"definitelyNotARealKey2099":0},"items":{}},"id":2}"#
            MockBBTURLProtocol.responses["item.pandoc_filter"] = (200, Data(notFoundJSON.utf8))

            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer { URLProtocol.unregisterClass(MockBBTURLProtocol.self) }

            let service = ZoteroService()
            await #expect(throws: Error.self) {
                _ = try await service.fetchItemsForCitekeys(["definitelyNotARealKey2099"])
            }
        }
    }

    @Test("A malformed item.pandoc_filter response (not just an explicit RPC error) triggers fallback to item.export")
    @MainActor
    func malformedPandocFilterResponseTriggersExportFallback() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()
            // Structurally valid JSON-RPC envelope, but the one CSL item is missing its
            // required `type` field. The raw layer (JSONSerialization only) parses this fine;
            // the subsequent CSLItem decode throws, which must be caught by
            // fetchItemsForCitekeys's wide error boundary and trigger the fallback — not just
            // an explicit `{"error": ...}` RPC object.
            let malformedJSON = #"{"jsonrpc":"2.0","result":{"errors":{},"items":{"friedman2010":{"id":"friedman2010"}}},"id":5}"#
            MockBBTURLProtocol.responses["item.pandoc_filter"] = (200, Data(malformedJSON.utf8))

            let fallbackJSON = """
            [{"id":"friedman2010","type":"chapter","citation-key":"friedman2010","title":"Fallback Title"}]
            """
            MockBBTURLProtocol.responses["item.export"] = (200, Data(#"{"jsonrpc":"2.0","result":\#(fallbackJSON),"id":6}"#.utf8))

            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer { URLProtocol.unregisterClass(MockBBTURLProtocol.self) }

            let service = ZoteroService()
            let items = try await service.fetchItemsForCitekeys(["friedman2010"])

            #expect(items.count == 1)
            #expect(
                items.first?.title == "Fallback Title",
                "Result must come from the item.export fallback, not a silent \"zero items found\""
            )

            #expect(!MockBBTURLProtocol.capturedRequests.filter({ $0.method == "item.pandoc_filter" }).isEmpty)
            #expect(!MockBBTURLProtocol.capturedRequests.filter({ $0.method == "item.export" }).isEmpty, "Fallback to item.export must actually fire")
            // The fallback is also logged via DebugLog.log(.zotero, ...) at the
            // fetchItemsForCitekeys catch site — not independently asserted here, as this
            // suite has no DebugLog-capture rig; verified by reading ZoteroService.swift's
            // fetchItemsForCitekeys catch block.
        }
    }

    @Test(
        """
        citation-key, id, and the requested citekey are all three different strings — the item \
        still resolves (no false not-found) and is cached under the REQUESTED key, so getItem/getItems/ \
        cslJSONForCitekeys (called with the document's citekey) find it
        """
    )
    @MainActor
    func citationKeyIdAndRequestedKeyAllDifferStillResolvesAndCaches() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()
            // Three distinct strings exercised at once, matching the real bug report:
            //   requested    = "Friedman2010"       — typed in the document; differs in CASE from id
            //   id           = "friedman2010"       — BBT's canonical KeyManager match key
            //   citation-key = "oldLegacyKey2010"   — stale legacy Extra-field value; BBT's raw
            //                                          items-dict key
            // swiftlint:disable line_length
            let itemJSON = """
            {"jsonrpc":"2.0","result":{"errors":{},"items":{"oldLegacyKey2010":{"id":"friedman2010","citation-key":"oldLegacyKey2010","type":"chapter","title":"Entering the Mountains"}}},"id":12}
            """
            // swiftlint:enable line_length
            MockBBTURLProtocol.responses["item.pandoc_filter"] = (200, Data(itemJSON.utf8))
            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer { URLProtocol.unregisterClass(MockBBTURLProtocol.self) }

            let service = ZoteroService()
            let items = try await service.fetchItemsForCitekeys(["Friedman2010"])

            #expect(items.count == 1, "Must resolve, not throw a false \"not found in any library\"")
            #expect(items.first?.title == "Entering the Mountains")

            // getItem/getItems/cslJSONForCitekeys must all find the item under the REQUESTED
            // key ("Friedman2010") — proving the cache is keyed by what was asked for, not by
            // CSLItem.citekey (== citationKey ?? id), which here would resolve to
            // "oldLegacyKey2010" and never be found by a lookup for "Friedman2010".
            #expect(service.getItem(citekey: "Friedman2010") != nil)
            #expect(service.hasItem(citekey: "Friedman2010"))
            #expect(service.getItems(citekeys: ["Friedman2010"]).count == 1)

            let cslJSON = service.cslJSONForCitekeys(["Friedman2010"])
            #expect(
                cslJSON.contains("Entering the Mountains"),
                "cslJSONForCitekeys must return the item's CSL JSON for the requested key, not \"[]\""
            )
        }
    }

    @Test(
        """
        loadItem (the loadEmbeddedCitations/offline path, reading a document's bundled \
        references/citations.json) caches by id, not by citation-key, so getItem/getItems find \
        the item under the id — the same key the document's citations actually use post-fix
        """
    )
    @MainActor
    func loadItemCachesByIdNotCitationKey() throws {
        // Same shape as the fixture above: citation-key ("oldLegacyKey2010") differs from id
        // ("friedman2010"). loadItem is called directly here to simulate
        // DocumentManager.loadEmbeddedCitations(from:), which decodes CSLItem straight from a
        // bundled citations.json (no network, no MockBBTURLProtocol involved).
        let itemJSON = """
        {"id":"friedman2010","citation-key":"oldLegacyKey2010","type":"chapter","title":"Entering the Mountains"}
        """
        let item = try JSONDecoder().decode(CSLItem.self, from: Data(itemJSON.utf8))
        #expect(item.citekey == "oldLegacyKey2010", "Sanity check: citekey falls back to citation-key, not id")

        let service = ZoteroService()
        service.loadItem(item)

        // Must be found under the id ("friedman2010") — the key the document's own citations
        // reference post-fix — not under citekey ("oldLegacyKey2010"), which would reproduce
        // the "not found" / red placeholder symptom offline.
        #expect(service.getItem(citekey: "friedman2010") != nil)
        #expect(service.hasItem(citekey: "friedman2010"))
        #expect(service.getItems(citekeys: ["friedman2010"]).count == 1)
        #expect(service.getItem(citekey: "friedman2010")?.title == "Entering the Mountains")

        // Must NOT be reachable under citation-key — proves the cache key changed, not just
        // that a second copy got added under id.
        #expect(service.getItem(citekey: "oldLegacyKey2010") == nil)
    }
}

private extension Array {
    /// Safe-index subscript used only for readable test assertions above.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Cross-suite network test lock

/// Serializes every test in this file that registers `MockBBTURLProtocol` with every
/// network-touching test in `ZoteroServiceConnectionTests.swift` (Tier 2) — both target the
/// exact same real host/port (127.0.0.1:23119). `@MainActor`-isolated (matching every test
/// call site) specifically so the lock's own `run` closure never has to cross an
/// actor-isolation boundary — everything involved is already on the main actor.
///
/// This is a real acquire/continuation-queue mutex, not just "call an actor method": actor
/// reentrancy means simply awaiting a method on a shared actor does NOT, by itself, serialize
/// callers across an internal `await` — a second caller's call can start executing during the
/// first's suspension. The explicit `isLocked` flag + `waiters` queue below is what actually
/// provides mutual exclusion.
@MainActor
final class ZoteroNetworkTestLock {
    static let shared = ZoteroNetworkTestLock()
    private init() {}

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    func run<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}

// MARK: - Mock URLProtocol

/// Intercepts requests to BBT's local JSON-RPC endpoint (127.0.0.1:23119) and returns a
/// canned response per JSON-RPC method name (or, via `responseOverride`, per method+params —
/// needed to distinguish phase 1's personal-library `item.pandoc_filter` call from phase 2's
/// group-library call, which share a method name), capturing every request's decoded body so
/// tests can assert on what was actually sent. Registered/unregistered per test (process-wide
/// state) via `URLProtocol.registerClass`, mirroring `MockLTURLProtocol` in
/// `LanguageToolProviderDedupTests.swift`.
final class MockBBTURLProtocol: URLProtocol, @unchecked Sendable {
    /// Canned (statusCode, responseData) per JSON-RPC method name.
    nonisolated(unsafe) static var responses: [String: (Int, Data)] = [:]
    /// Response used for any method with no entry in `responses` and no `responseOverride` match.
    nonisolated(unsafe) static var defaultResponse: (Int, Data) = (200, Data(#"{"jsonrpc":"2.0","result":{},"id":0}"#.utf8))
    /// Optional per-request override, checked before `responses`/`defaultResponse`. Return nil
    /// to fall through to those. Needed when two calls share a method name but must respond
    /// differently based on params (e.g. phase 1 vs. phase 2's `item.pandoc_filter` calls).
    nonisolated(unsafe) static var responseOverride: (@Sendable (String, [Any]) -> (Int, Data)?)?

    /// Guards ALL mutable static state above (not just `_capturedRequests`) — `reset()` used
    /// to mutate `responses`/`defaultResponse`/`responseOverride` outside this lock, a real
    /// (if narrow) data race with a concurrently-loading request reading them in `startLoading`.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _capturedRequests: [(method: String, body: [String: Any])] = []

    static var capturedRequests: [(method: String, body: [String: Any])] {
        lock.lock()
        defer { lock.unlock() }
        return _capturedRequests
    }

    /// Resets all mutable state to defaults. Call at the start of every test, before
    /// registering the class.
    static func reset() {
        lock.lock()
        _capturedRequests = []
        responses = [:]
        defaultResponse = (200, Data(#"{"jsonrpc":"2.0","result":{},"id":0}"#.utf8))
        responseOverride = nil
        lock.unlock()
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" && request.url?.port == 23119
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// Reads the request body regardless of whether URLSession preserved it as `httpBody` or
    /// converted it to `httpBodyStream`.
    private static func extractBody(from request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override func startLoading() {
        let bodyData = Self.extractBody(from: request)
        let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]
        let method = json?["method"] as? String ?? ""
        let params = (json?["params"] as? [Any]) ?? []

        Self.lock.lock()
        Self._capturedRequests.append((method: method, body: json ?? [:]))
        let override = Self.responseOverride
        let responses = Self.responses
        let defaultResponse = Self.defaultResponse
        Self.lock.unlock()

        let (statusCode, data) = override?(method, params) ?? responses[method] ?? defaultResponse

        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: statusCode, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
