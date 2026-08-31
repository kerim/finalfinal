//
//  ZoteroLibraryScopeTests+DuplicateLibraryNames.swift
//  final finalTests
//
//  Tier 1: Silent Killers. Regression coverage for the duplicate-group-library-name bug: the
//  old `groupLibraryNames(from:)` (deleted — see git history) de-duplicated group libraries by
//  exact display name, so two group libraries sharing a name collapsed into one `.libraryNames`
//  entry and a citekey living only in the shadowed one was reported "not found in any library."
//
//  The fix partitions phase 2: uniquely-named group libraries still batch into one
//  name-scoped call, while each colliding-or-nameless library gets its own numeric-id-scoped
//  call. Verified live on 2026-08-31 against Zotero 10.0 / BBT 9.0.57 that a bare numeric id
//  scopes ANY single library, group libraries included (citekey `roy2022` scoped to 19, 2 and
//  1 returned three genuinely different outcomes).
//
//  This file holds the pure unit tests. The mocked-HTTP pipeline tests live in
//  ZoteroLibraryScopeTests+DuplicateLibraryNamesPipeline.swift; see ZoteroLibraryScopeTests.swift
//  for the suite's fixture conventions and the ZoteroNetworkTestLock rationale.
//

import Testing
import Foundation
@testable import final_final

extension ZoteroLibraryScopeTests {

    // MARK: - Partitioning: groupLibraryScopes

    @Test("Uniquely-named group libraries batch into ONE .libraryNames scope covering all their ids")
    func uniquelyNamedGroupLibrariesBatchIntoOneNamesScope() {
        let libraries = [
            ZoteroLibrary(id: 1, name: "My Library"),
            ZoteroLibrary(id: 6, name: "Foo"),
            ZoteroLibrary(id: 7, name: "Bar")
        ]

        let plans = ZoteroService.groupLibraryScopes(from: libraries)

        #expect(plans.count == 1, "No collisions and no nameless libraries — one batched call, zero extra RPCs")
        #expect(plans.first?.scope == .libraryNames(["Foo", "Bar"]))
        #expect(plans.first?.libraryIDs == [6, 7])
    }

    @Test("The personal library is never scoped in phase 2, and is excluded by id, never by display name")
    func personalLibraryIsNeverScopedInPhaseTwo() {
        // Personal deliberately renamed to collide with a group library: excluding it by NAME
        // would both miss it here and wrongly drag library 6 into an id scope.
        let libraries = [
            ZoteroLibrary(id: ZoteroService.personalLibraryID, name: "Foo"),
            ZoteroLibrary(id: 6, name: "Foo")
        ]

        let plans = ZoteroService.groupLibraryScopes(from: libraries)

        #expect(plans.count == 1)
        #expect(plans.first?.scope == .libraryNames(["Foo"]), "Only the group library named Foo remains, and it is unique among GROUP libraries")
        #expect(plans.first?.libraryIDs == [6])
        #expect(!plans.contains { $0.libraryIDs.contains(ZoteroService.personalLibraryID) })
    }

    @Test("Two group libraries sharing a name get ONE numeric-id scope EACH — neither is shadowed")
    func duplicateNamedLibrariesGetOneIdScopeEach() {
        let libraries = [
            ZoteroLibrary(id: 1, name: "My Library"),
            ZoteroLibrary(id: 6, name: "Foo"),
            ZoteroLibrary(id: 7, name: "Shared"),
            ZoteroLibrary(id: 8, name: "Shared")
        ]

        let plans = ZoteroService.groupLibraryScopes(from: libraries)

        #expect(plans.count == 3)
        #expect(plans[0].scope == .libraryNames(["Foo"]))
        #expect(plans[0].libraryIDs == [6])
        #expect(plans[1].scope == .libraryID(7))
        #expect(plans[1].libraryIDs == [7])
        #expect(plans[2].scope == .libraryID(8))
        #expect(plans[2].libraryIDs == [8])
        #expect(
            !plans.contains { if case .libraryNames(let names) = $0.scope { return names.contains("Shared") } else { return false } },
            "A colliding name must never be sent as a name — that is exactly the shadowing bug"
        )
    }

    @Test("A three-way name collision produces three separate id scopes, not two")
    func threeWayCollisionGetsThreeIdScopes() {
        let libraries = [
            ZoteroLibrary(id: 1, name: "My Library"),
            ZoteroLibrary(id: 7, name: "Shared"),
            ZoteroLibrary(id: 8, name: "Shared"),
            ZoteroLibrary(id: 9, name: "Shared")
        ]

        let plans = ZoteroService.groupLibraryScopes(from: libraries)

        #expect(plans.map(\.scope) == [.libraryID(7), .libraryID(8), .libraryID(9)])
        #expect(plans.flatMap(\.libraryIDs) == [7, 8, 9])
    }

    @Test("The .libraryNames scope is omitted ENTIRELY when every group library collides — never an empty array")
    func namesScopeIsOmittedEntirelyWhenTheUniqueBucketIsEmpty() {
        let libraries = [
            ZoteroLibrary(id: 1, name: "My Library"),
            ZoteroLibrary(id: 7, name: "Shared"),
            ZoteroLibrary(id: 8, name: "Shared")
        ]

        let plans = ZoteroService.groupLibraryScopes(from: libraries)

        #expect(plans.count == 2)
        #expect(
            !plans.contains { if case .libraryNames = $0.scope { return true } else { return false } },
            "An empty .libraryNames([]) call would scope to nothing and waste an RPC"
        )
    }

    @Test("A nameless or whitespace-only group library is scoped by id instead of being dropped from phase 2")
    func namelessLibraryIsScopedByIdInsteadOfDropped() {
        let libraries = [
            ZoteroLibrary(id: 1, name: "My Library"),
            ZoteroLibrary(id: 6, name: "Foo"),
            ZoteroLibrary(id: 7, name: nil),
            ZoteroLibrary(id: 8, name: "   ")
        ]

        let plans = ZoteroService.groupLibraryScopes(from: libraries)

        #expect(plans.map(\.scope) == [.libraryNames(["Foo"]), .libraryID(7), .libraryID(8)])
    }

    @Test("Collision detection normalizes trim+case, but the name actually SENT is the library's verbatim string")
    func collisionDetectionNormalizesButTheSentNameIsVerbatim() {
        // "Shared" vs " shared " collide only after trim+lowercase — they must both become id
        // scopes. " Sifo-Futing " is unique, so its verbatim, UNTRIMMED name is what goes out:
        // it is matched against Zotero's own stored name, and trimming could break a real match.
        let libraries = [
            ZoteroLibrary(id: 1, name: "My Library"),
            ZoteroLibrary(id: 6, name: " Sifo-Futing "),
            ZoteroLibrary(id: 7, name: "Shared"),
            ZoteroLibrary(id: 8, name: " shared ")
        ]

        let plans = ZoteroService.groupLibraryScopes(from: libraries)

        #expect(plans.count == 3)
        #expect(
            plans[0].scope == .libraryNames([" Sifo-Futing "]),
            "Normalization is for DETECTION only — the sent name must be byte-identical to the library's own"
        )
        #expect(plans[1].scope == .libraryID(7))
        #expect(plans[2].scope == .libraryID(8))
    }

    @Test("excludingLibraryIDs suppresses covered libraries but still detects collisions against the FULL list")
    func excludedLibrariesAreNotScopedAndDoNotUnmaskACollision() {
        // Library 8 is already covered; 7 still shares its name with 8. Detecting collisions
        // over the non-excluded subset alone would make 7 look uniquely named and earn a
        // .libraryNames(["Shared"]) call, which BBT would match against library 8 too.
        let libraries = [
            ZoteroLibrary(id: 1, name: "My Library"),
            ZoteroLibrary(id: 6, name: "Foo"),
            ZoteroLibrary(id: 7, name: "Shared"),
            ZoteroLibrary(id: 8, name: "Shared")
        ]

        let plans = ZoteroService.groupLibraryScopes(from: libraries, excludingLibraryIDs: [8])

        #expect(plans.map(\.scope) == [.libraryNames(["Foo"]), .libraryID(7)])
        #expect(!plans.flatMap(\.libraryIDs).contains(8))
    }

    // MARK: - Export-path adapter: groupLibraryMetadata

    @Test("groupLibraryMetadata: colliding names become ids and the shared name is never sent")
    func groupLibraryMetadataCollidingNamesBecomeIDs() {
        let libraries = [
            ZoteroLibrary(id: 1, name: "My Library"),
            ZoteroLibrary(id: 6, name: "Foo"),
            ZoteroLibrary(id: 7, name: "Shared"),
            ZoteroLibrary(id: 8, name: "Shared")
        ]

        let metadata = ZoteroService.groupLibraryMetadata(from: libraries)

        #expect(metadata.names == ["Foo"])
        #expect(metadata.ids == [7, 8])
        #expect(!metadata.names.contains("Shared"), "A colliding name must never be batched -- that is exactly the shadowing bug")
    }

    @Test("groupLibraryMetadata excludes the personal library from both arrays")
    func groupLibraryMetadataExcludesPersonal() {
        let libraries = [
            ZoteroLibrary(id: ZoteroService.personalLibraryID, name: "My Library"),
            ZoteroLibrary(id: 6, name: "Foo")
        ]

        let metadata = ZoteroService.groupLibraryMetadata(from: libraries)

        #expect(metadata.names == ["Foo"])
        #expect(metadata.ids.isEmpty)
        #expect(!metadata.names.contains("My Library"))
    }

    @Test("groupLibraryMetadata: a nameless group library becomes an id, not a dropped/silent entry")
    func groupLibraryMetadataNamelessLibraryBecomesID() {
        let libraries = [
            ZoteroLibrary(id: 1, name: "My Library"),
            ZoteroLibrary(id: 6, name: "Foo"),
            ZoteroLibrary(id: 7, name: nil)
        ]

        let metadata = ZoteroService.groupLibraryMetadata(from: libraries)

        #expect(metadata.names == ["Foo"])
        #expect(metadata.ids == [7])
    }

    @Test("groupLibraryMetadata: no group libraries at all means both arrays come back empty")
    func groupLibraryMetadataNoGroupLibrariesMeansBothEmpty() {
        let libraries = [ZoteroLibrary(id: ZoteroService.personalLibraryID, name: "My Library")]

        let metadata = ZoteroService.groupLibraryMetadata(from: libraries)

        #expect(metadata.names.isEmpty)
        #expect(metadata.ids.isEmpty)
    }

    // MARK: - Merging: mergeGroupOutcomes

    @Test("A citekey resolved by exactly one scope is kept, with no ambiguity flag")
    func keyResolvedByExactlyOneScopeIsKept() {
        let item: [String: Any] = ["id": "roy2022", "type": "book", "citation-key": "roy2022", "title": "From Library Seven"]
        let found = PandocFilterRawOutcome(items: ["roy2022": item], notFoundKeys: [], ambiguousKeys: [])
        let missed = PandocFilterRawOutcome(items: [:], notFoundKeys: ["roy2022"], ambiguousKeys: [])

        let merged = ZoteroService.mergeGroupOutcomes(requested: ["roy2022"], outcomes: [found, missed])

        #expect(merged.items.count == 1)
        #expect(merged.items["roy2022"]?["title"] as? String == "From Library Seven")
        #expect(merged.ambiguousKeys.isEmpty)
        // `mergeGroupOutcomes` does a plain union of notFoundKeys — it never subtracts a key
        // that some OTHER scope resolved. That clean-up happens downstream, in
        // `mergeRawOutcomes`'s own `notFoundKeys.intersection(unresolved)` (see
        // `notFoundKeysUnionAcrossThreeScopes` below, which exercises that downstream step).
        #expect(merged.notFoundKeys == ["roy2022"], "A plain union keeps the miss here; mergeRawOutcomes clears it downstream")
    }

    @Test("A citekey resolved by TWO scopes is withheld from items and flagged ambiguous in both key sets")
    func keyResolvedByTwoScopesIsWithheldAndFlaggedAmbiguous() {
        let seven: [String: Any] = ["id": "roy2022", "type": "book", "citation-key": "roy2022", "title": "From Library Seven"]
        let eight: [String: Any] = ["id": "roy2022", "type": "book", "citation-key": "roy2022", "title": "From Library Eight"]
        let a = PandocFilterRawOutcome(items: ["roy2022": seven], notFoundKeys: [], ambiguousKeys: [])
        let b = PandocFilterRawOutcome(items: ["roy2022": eight], notFoundKeys: [], ambiguousKeys: [])

        let merged = ZoteroService.mergeGroupOutcomes(requested: ["roy2022"], outcomes: [a, b])

        #expect(
            merged.items["roy2022"] == nil,
            "Withholding is the mechanism: an item left in `items` would be resolved, and mergeRawOutcomes would then drop the ambiguity flag"
        )
        #expect(merged.items.isEmpty)
        #expect(merged.ambiguousKeys == ["roy2022"])
        #expect(merged.rawAmbiguousKeys == ["roy2022"])
    }

    @Test("Cross-scope duplicate detection is case-insensitive, matching this app's citekey identity everywhere else")
    func crossScopeDuplicateDetectionIsCaseInsensitive() {
        let lower: [String: Any] = ["id": "roy2022", "type": "book", "title": "From Library Seven"]
        let upper: [String: Any] = ["id": "ROY2022", "type": "book", "title": "From Library Eight"]
        let a = PandocFilterRawOutcome(items: ["roy2022": lower], notFoundKeys: [], ambiguousKeys: [])
        let b = PandocFilterRawOutcome(items: ["ROY2022": upper], notFoundKeys: [], ambiguousKeys: [])

        let merged = ZoteroService.mergeGroupOutcomes(requested: ["roy2022"], outcomes: [a, b])

        #expect(merged.items.isEmpty, "Two casings of one citekey identity are one collision, not two independent resolutions")
        #expect(merged.ambiguousKeys == ["roy2022"])
    }

    @Test(
        """
        Two case-variant keys inside the SAME outcome's own `items` (real when BBT's \
        case-insensitive-citekeys preference is off) collide too — neither silently wins the \
        slot based on unspecified dictionary iteration order
        """
    )
    func withinOutcomeCaseVariantCollisionIsWithheldAndFlaggedAmbiguous() {
        let upper: [String: Any] = ["id": "Dup2020", "type": "book", "title": "First Distinct Item"]
        let lower: [String: Any] = ["id": "dup2020", "type": "book", "title": "Second Distinct Item"]
        let outcome = PandocFilterRawOutcome(items: ["Dup2020": upper, "dup2020": lower], notFoundKeys: [], ambiguousKeys: [])

        let merged = ZoteroService.mergeGroupOutcomes(requested: ["Dup2020", "dup2020"], outcomes: [outcome])

        #expect(
            merged.items.isEmpty,
            """
            Two genuinely different items sharing one case-insensitive citekey identity within a single BBT \
            response must never silently pick one — dictionary iteration order is unspecified
            """
        )
        #expect(merged.ambiguousKeys == ["Dup2020", "dup2020"])
        #expect(merged.rawAmbiguousKeys == ["Dup2020", "dup2020"])
        #expect(merged.notFoundKeys.isEmpty, "Must not silently vanish as not-found either — every requested spelling gets a signal")
    }

    @Test(
        """
        The ambiguity flag is inserted under the REQUESTED spelling, never the item-id spelling — \
        otherwise mergeRawOutcomes's exact-string intersection(unresolved) silently drops it again
        """
    )
    func ambiguityIsFlaggedUnderTheRequestedSpellingNotTheItemIdSpelling() {
        // Three-way case mismatch, all deliberately different: the document typed "Roy2022";
        // one library's item has CSL id "roy2022", the other's has "ROY2022". `items` keys are
        // item ids; `ambiguousKeys` is contractually keyed by what was requested.
        let seven: [String: Any] = ["id": "roy2022", "type": "book", "title": "From Library Seven"]
        let eight: [String: Any] = ["id": "ROY2022", "type": "book", "title": "From Library Eight"]
        let a = PandocFilterRawOutcome(items: ["roy2022": seven], notFoundKeys: [], ambiguousKeys: [])
        let b = PandocFilterRawOutcome(items: ["ROY2022": eight], notFoundKeys: [], ambiguousKeys: [])

        let merged = ZoteroService.mergeGroupOutcomes(requested: ["Roy2022"], outcomes: [a, b])

        #expect(merged.ambiguousKeys == ["Roy2022"], "Neither \"roy2022\" nor \"ROY2022\" — the flag must carry the requested spelling")
        #expect(merged.rawAmbiguousKeys == ["Roy2022"])

        // ...and it must survive the REAL merge chain, not just this function in isolation.
        let final = ZoteroService.mergeRawOutcomes(
            requested: ["Roy2022"],
            personal: PandocFilterRawOutcome(items: [:], notFoundKeys: [], ambiguousKeys: []),
            groups: merged
        )
        #expect(
            final.ambiguousKeys == ["Roy2022"],
            """
            ambiguousKeys.intersection(unresolved) builds `unresolved` from the requested strings by EXACT \
            match — an item-id spelling would intersect to nothing here
            """
        )
        #expect(final.items.isEmpty)
    }

    @Test("When a batch requests several spellings of one citekey identity, EVERY requested spelling is flagged")
    func everyRequestedSpellingOfACollidingKeyIsFlagged() {
        let seven: [String: Any] = ["id": "roy2022", "type": "book", "title": "From Library Seven"]
        let eight: [String: Any] = ["id": "roy2022", "type": "book", "title": "From Library Eight"]
        let a = PandocFilterRawOutcome(items: ["roy2022": seven], notFoundKeys: [], ambiguousKeys: [])
        let b = PandocFilterRawOutcome(items: ["roy2022": eight], notFoundKeys: [], ambiguousKeys: [])

        let merged = ZoteroService.mergeGroupOutcomes(requested: ["Roy2022", "roy2022"], outcomes: [a, b])

        #expect(merged.ambiguousKeys == ["Roy2022", "roy2022"])

        let final = ZoteroService.mergeRawOutcomes(
            requested: ["Roy2022", "roy2022"],
            personal: PandocFilterRawOutcome(items: [:], notFoundKeys: [], ambiguousKeys: []),
            groups: merged
        )
        #expect(final.ambiguousKeys == ["Roy2022", "roy2022"], "Both spellings are unresolved, so both must survive the intersection")
    }

    @Test("A cross-scope collision detected on a key one scope also called ambiguous stays ambiguous, never not-found")
    func ambiguousBeatsNotFoundAcrossScopes() {
        let item: [String: Any] = ["id": "roy2022", "type": "book", "title": "From Library Seven"]
        let a = PandocFilterRawOutcome(items: ["roy2022": item], notFoundKeys: [], ambiguousKeys: [])
        let b = PandocFilterRawOutcome(items: [:], notFoundKeys: ["roy2022"], ambiguousKeys: [])
        let bbtAmbiguous = PandocFilterRawOutcome(items: [:], notFoundKeys: [], ambiguousKeys: ["roy2022"])

        let merged = ZoteroService.mergeGroupOutcomes(requested: ["roy2022"], outcomes: [a, b, bbtAmbiguous])

        #expect(merged.ambiguousKeys == ["roy2022"])
        #expect(merged.notFoundKeys.isEmpty, "notFoundKeys.subtract(ambiguousKeys) mirrors mergeRawOutcomes's own precedence rule")
    }

    @Test(
        """
        A key one outcome reports ambiguous via its OWN errors (BBT's errors[key] >= 2, a genuine \
        2+ match inside that one scope) withholds the item even when a DIFFERENT outcome \
        separately resolved it to a single item — regression guard for the case pre-split, one \
        batched call would have summed both libraries' matches into one ambiguous errors[key]
        """
    )
    func selfReportedAmbiguityInOneScopeWithholdsAnItemResolvedInAnother() {
        let ambiguousInA = PandocFilterRawOutcome(items: [:], notFoundKeys: [], ambiguousKeys: ["roy2022"])
        let item: [String: Any] = ["id": "roy2022", "type": "book", "title": "From Library Eight"]
        let resolvedInB = PandocFilterRawOutcome(items: ["roy2022": item], notFoundKeys: [], ambiguousKeys: [])

        let merged = ZoteroService.mergeGroupOutcomes(requested: ["roy2022"], outcomes: [ambiguousInA, resolvedInB])

        #expect(
            merged.items["roy2022"] == nil,
            "Scope B's single, separately-scoped match must not silently override scope A's genuine 2+-match ambiguity"
        )
        #expect(merged.items.isEmpty)
        #expect(merged.ambiguousKeys == ["roy2022"])
        #expect(merged.rawAmbiguousKeys == ["roy2022"])
    }

    @Test("Not-found keys union across three scopes; a key no scope found stays not-found")
    func notFoundKeysUnionAcrossThreeScopes() {
        let item: [String: Any] = ["id": "roy2022", "type": "book", "title": "From Library Seven"]
        let a = PandocFilterRawOutcome(items: ["roy2022": item], notFoundKeys: ["ghost2099"], ambiguousKeys: [])
        let b = PandocFilterRawOutcome(items: [:], notFoundKeys: ["roy2022", "ghost2099"], ambiguousKeys: [])
        let thirdScope = PandocFilterRawOutcome(items: [:], notFoundKeys: ["roy2022", "ghost2099"], ambiguousKeys: [])

        let merged = ZoteroService.mergeGroupOutcomes(requested: ["roy2022", "ghost2099"], outcomes: [a, b, thirdScope])

        #expect(merged.items.count == 1)
        #expect(merged.notFoundKeys == ["ghost2099", "roy2022"])
        #expect(merged.ambiguousKeys.isEmpty)

        // mergeRawOutcomes then clears roy2022 (it resolved) and keeps ghost2099.
        let final = ZoteroService.mergeRawOutcomes(
            requested: ["roy2022", "ghost2099"],
            personal: PandocFilterRawOutcome(items: [:], notFoundKeys: [], ambiguousKeys: []),
            groups: merged
        )
        #expect(final.notFoundKeys == ["ghost2099"])
    }
}
