//
//  ZoteroLibraryScopeTests+CaseInsensitivity.swift
//  final finalTests
//
//  Split out of ZoteroLibraryScopeTests.swift to keep that file's struct body under SwiftLint's
//  type_body_length limit (300 lines) after this test was added. Same suite/fixture context
//  applies — see the header comment in ZoteroLibraryScopeTests.swift for the full regression
//  background (the shared/group-library citekey resolve bug, live-captured vs. synthesized
//  fixtures, and the ZoteroNetworkTestLock cross-suite mutex).
//

import Testing
import Foundation
@testable import final_final

extension ZoteroLibraryScopeTests {

    @Test(
        """
        loadItem's offline path has no "requested" citekey to align casing with (unlike the \
        online fetch paths' cacheItems()), so a document citekey differing only in case from \
        the item's id must still resolve via getItem/hasItem/getItems
        """
    )
    @MainActor
    func loadItemResolvesCaseInsensitivelyAgainstDocumentCitekey() throws {
        // citations.json records the id in lower case, but the document text cites it in a
        // different case (e.g. typed by hand, or carried over from before a Zotero rename) —
        // this must still resolve offline instead of showing a red "(key?)" placeholder.
        let itemJSON = """
        {"id":"friedman2010","type":"chapter","title":"Entering the Mountains"}
        """
        let item = try JSONDecoder().decode(CSLItem.self, from: Data(itemJSON.utf8))

        let service = ZoteroService()
        service.loadItem(item)

        #expect(service.getItem(citekey: "Friedman2010") != nil)
        #expect(service.getItem(citekey: "Friedman2010")?.title == "Entering the Mountains")
        #expect(service.getItem(citekey: "FRIEDMAN2010") != nil)
        #expect(service.hasItem(citekey: "Friedman2010"))
        #expect(service.getItems(citekeys: ["Friedman2010"]).count == 1)

        // A genuinely different citekey (not just a case variant) must still miss.
        #expect(service.getItem(citekey: "notFriedman2010") == nil)
    }

    // MARK: - resolveRawViaPandocFilter's fully-resolved-after-phase-1 reconciliation

    @Test(
        """
        resolveRawViaPandocFilter's fully-resolved-after-phase-1 early return still reconciles \
        BBT's raw errors against the case-insensitively-resolved items via mergeRawOutcomes, \
        instead of returning phase 1's raw outcome verbatim -- this is the exact line the fix \
        changed. Two differently-cased requests for the same citekey resolve to one item, but \
        BBT's `errors` still separately names one of the two literal spellings with match \
        count 0.
        """
    )
    @MainActor
    func fullyResolvedPhase1StillReconcilesSpuriousCaseVariantError() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()
            // Both casings of the same citekey requested together (as they would be if the
            // document cites [@Smith2020] once and [@smith2020] elsewhere). BBT resolves the
            // item once, keyed by its canonical id "smith2020" -- but its `errors` field still
            // separately names the "Smith2020" spelling with a zero match count, since that
            // exact spelling case-sensitively matched nothing on its own (a genuine per-spelling
            // miss, not a BBT bug -- this app's own case-insensitive citekey policy is what
            // should suppress it here, per resolveRawViaPandocFilter's doc comment).
            // swiftlint:disable line_length
            let json = """
            {"jsonrpc":"2.0","result":{"errors":{"Smith2020":0},"items":{"smith2020":{"id":"smith2020","type":"book","citation-key":"smith2020","title":"Canonical Copy"}}},"id":21}
            """
            // swiftlint:enable line_length
            MockBBTURLProtocol.responses["item.pandoc_filter"] = (200, Data(json.utf8))
            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer { URLProtocol.unregisterClass(MockBBTURLProtocol.self) }

            let service = ZoteroService()
            let outcome = try await service.resolveRawViaPandocFilter(["Smith2020", "smith2020"])

            #expect(outcome.items.count == 1)
            #expect(
                outcome.notFoundKeys.isEmpty,
                """
                Before the fix this returned personalOutcome verbatim, surfacing a false not-found \
                for "Smith2020" even though the item resolved and cached correctly
                """
            )
            #expect(outcome.ambiguousKeys.isEmpty)

            // Confirms we're on the phase-1-only early-return branch (the changed line), not phase 2.
            #expect(
                MockBBTURLProtocol.capturedRequests.filter { $0.method == "user.groups" }.isEmpty,
                "Everything must resolve from personal library alone -- phase 2 must never fire"
            )
        }
    }

    @Test(
        """
        Same early-return branch (personal library alone fully resolves everything, phase 2 \
        never fires) but with a batch of two DISTINCT citekeys: one is a differently-cased pair \
        that resolves to a single item while its other spelling case-sensitively misses on its \
        own (so BBT reports it in `errors`), and the other is a wholly separate, cleanly-resolved \
        item with no `errors` entry at all. The reconciliation on this branch clears \
        notFoundKeys/ambiguousKeys wholesale, not selectively -- this test shows that clearing \
        does not disturb the unrelated, cleanly-resolved item, which survives in the result \
        untouched.
        """
    )
    @MainActor
    func fullyResolvedGroupWithOneSpuriousCaseVariantKeepsBothItems() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()
            // "Smith2020"/"smith2020" -- differently-cased pair: one item resolves, and the
            // "Smith2020" spelling case-sensitively misses on its own (BBT reports it in errors).
            // "Jones2019" -- a wholly separate, cleanly-resolved item with no error entry at all.
            // swiftlint:disable line_length
            let json = """
            {"jsonrpc":"2.0","result":{"errors":{"Smith2020":0},"items":{"smith2020":{"id":"smith2020","type":"book","citation-key":"smith2020","title":"Canonical Copy"},"Jones2019":{"id":"Jones2019","type":"article","citation-key":"Jones2019","title":"Unrelated Item"}}},"id":23}
            """
            // swiftlint:enable line_length
            MockBBTURLProtocol.responses["item.pandoc_filter"] = (200, Data(json.utf8))
            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer { URLProtocol.unregisterClass(MockBBTURLProtocol.self) }

            let service = ZoteroService()
            let outcome = try await service.resolveRawViaPandocFilter(["Smith2020", "smith2020", "Jones2019"])

            #expect(outcome.items.count == 2, "Both the case-variant pair's item and the unrelated item must survive")
            #expect(outcome.notFoundKeys.isEmpty)
            #expect(outcome.ambiguousKeys.isEmpty)
            #expect(
                MockBBTURLProtocol.capturedRequests.filter { $0.method == "user.groups" }.isEmpty,
                "Everything resolved from personal library alone -- phase 2 must never fire"
            )
        }
    }

    @Test(
        """
        A genuinely-nonexistent citekey mixed into the SAME batch as a resolving \
        differently-cased pair: the not-found key must still be reported (never silently \
        swallowed by the reconciliation the fix relies on), while the spurious case-variant \
        error for the resolved pair is still correctly cleared. A genuinely-unresolvable key \
        can never itself reach the fix's early-return branch (by definition its lowercased \
        form is absent from every resolved item's id, so `stillUnresolved` is non-empty and \
        phase 2 runs instead -- the "genuinely missing citekey throws" case above already \
        covers that in isolation); with no group libraries to search, phase 2 falls through to \
        the SAME mergeRawOutcomes(..., groups: nil) call shape the fix's early return now uses, \
        so this proves that shared reconciliation correctly keeps the real not-found and drops \
        only the spurious one when both appear in the same errors dict together.
        """
    )
    @MainActor
    func genuinelyMissingKeyStillReportedAlongsideResolvingCaseVariantPair() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()
            // No group libraries -- phase 2 (which will run, since one key stays unresolved
            // after phase 1) has nothing to search and falls through immediately.
            let groupsJSON = #"{"jsonrpc":"2.0","result":[{"id":1,"name":"My Library"}],"id":1}"#
            MockBBTURLProtocol.responses["user.groups"] = (200, Data(groupsJSON.utf8))

            // Personal library resolves "Smith2020"/"smith2020" (case-variant pair) to one
            // item, while BBT's errors names the spurious "Smith2020" spelling AND the
            // genuinely nonexistent "definitelyMissingKey9999" -- both with match count 0.
            // swiftlint:disable line_length
            let json = """
            {"jsonrpc":"2.0","result":{"errors":{"Smith2020":0,"definitelyMissingKey9999":0},"items":{"smith2020":{"id":"smith2020","type":"book","citation-key":"smith2020","title":"Canonical Copy"}}},"id":22}
            """
            // swiftlint:enable line_length
            MockBBTURLProtocol.responses["item.pandoc_filter"] = (200, Data(json.utf8))
            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer { URLProtocol.unregisterClass(MockBBTURLProtocol.self) }

            let service = ZoteroService()
            let outcome = try await service.resolveRawViaPandocFilter(
                ["Smith2020", "smith2020", "definitelyMissingKey9999"]
            )

            #expect(outcome.items.count == 1)
            #expect(
                outcome.notFoundKeys == ["definitelyMissingKey9999"],
                """
                The genuinely missing key must still be reported not-found; the spurious \
                case-variant error for the resolved pair must be cleared, not the other way around
                """
            )
            #expect(outcome.ambiguousKeys.isEmpty)
        }
    }

    // MARK: - Export-side fix: citekey-case mismatch is now actively corrected, not just disclosed

    @Test(
        """
        The fix: a document that cites the same reference under two different casings (e.g. \
        [@Smith2020] and [@smith2020]) still resolves to ONE CSL item keyed under ONE \
        canonical id (unchanged from before), but now `ExportService.canonicalCitekeyMap`/ \
        `canonicalizeCitekeys` actively rewrite the miscased spelling in the exported markdown \
        to match that canonical id -- so pandoc's own case-SENSITIVE --citeproc bibliography \
        matching (PDF) and zotero.lua's literal-string BBT lookup (DOCX/ODT) both see the \
        identical, resolvable spelling for every citation in the document, not just the one \
        that happened to match already.
        """
    )
    @MainActor
    func exportRawFetchNowGetsCanonicalizedToMatchTheExportedBibliography() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()
            // swiftlint:disable line_length
            let json = """
            {"jsonrpc":"2.0","result":{"errors":{"Smith2020":0},"items":{"smith2020":{"id":"smith2020","type":"book","citation-key":"smith2020","title":"Canonical Copy"}}},"id":24}
            """
            // swiftlint:enable line_length
            MockBBTURLProtocol.responses["item.pandoc_filter"] = (200, Data(json.utf8))
            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer { URLProtocol.unregisterClass(MockBBTURLProtocol.self) }

            let service = ZoteroService()
            let batch = try await service.fetchRawItemsForCitekeys(["Smith2020", "smith2020"])

            // Unchanged from before the fix: no warning surfaces, one canonical item resolves.
            #expect(batch.notFoundKeys.isEmpty)
            #expect(batch.ambiguousKeys.isEmpty)
            #expect(batch.items.count == 1)
            let resolvedID = batch.items.first?["id"] as? String
            #expect(resolvedID == "smith2020")

            // THE FIX: canonicalCitekeyMap proposes rewriting the miscased "Smith2020"
            // spelling to the resolved canonical id -- the exact-cased "smith2020" spelling
            // is left alone (it's already correct, so `canonical != key` excludes it).
            let map = ExportService.canonicalCitekeyMap(
                requested: ["Smith2020", "smith2020"],
                resolvedIDs: batch.items.compactMap { $0["id"] as? String },
                rawAmbiguousKeys: batch.rawAmbiguousKeys
            )
            #expect(map == ["Smith2020": "smith2020"])

            // Applying the map to the exported markdown rewrites the miscased citation, so
            // pandoc's case-sensitive --citeproc matching against the bibliography JSON's
            // "smith2020" id now succeeds for BOTH citations in the document, not just one.
            let exportService = ExportService()
            let content = "First cite [@Smith2020]. Second cite [@smith2020]."
            let rewritten = await exportService.canonicalizeCitekeys(in: content, using: map)
            #expect(rewritten == "First cite [@smith2020]. Second cite [@smith2020].")
        }
    }
}
