//
//  ZoteroService+GroupLibraryScopes.swift
//  final final
//
//  BBT response shapes (`ZoteroLibrary`, `GroupsRPCResponse`/`parseLibraries`,
//  `PandocFilterRawOutcome`) plus phase-2 (group-library) scope partitioning and outcome merging
//  for the duplicate-group-library-name fix. Split out of ZoteroService+LibraryScope.swift to
//  keep that file under SwiftLint's 800-line file_length warning — that file still owns the
//  two-phase resolution engine this plugs into (`performGroupPhase`, `runGroupScopePass`,
//  `resolveRawViaPandocFilter`), which stayed behind because both are private/fileprivate and
//  moving them would require widening their access level, more invasive than moving these
//  self-contained data shapes and their one small parsing function instead.
//
//  THE BUG: the old `groupLibraryNames(from:)` (deleted — see git history) de-duplicated group
//  libraries by exact display name, so two group libraries sharing a name collapsed to one
//  `.libraryNames` entry and a citekey living only in the shadowed library reported "not found
//  in any library." THE FIX: BBT's `item.pandoc_filter` scope parameter also accepts a bare
//  numeric library id (verified live 2026-08-31 — see ZoteroService+LibraryScope.swift's
//  `pandocFilterRequestBody` doc comment), so every uniquely-named group library still batches
//  into one `.libraryNames` call (the fast common case, zero extra RPCs), while each
//  colliding-or-nameless library gets its own `.libraryID` call.
//
//  The export path (DOCX/ODT, via `ExportService+PandocArguments.swift` and the vendored
//  `Resources/Export/zotero.lua`) now consumes this SAME partition too, through the
//  `groupLibraryMetadata(from:)` adapter below — it flattens `groupLibraryScopes`'s plans into
//  the two wire shapes `zotero.lua` can carry: one batched name array (`zotero-group-libraries`
//  metadata) plus one bare id per colliding-or-nameless library (`zotero-group-library-ids`
//  metadata, one `item.pandoc_filter` call per id — BBT has no array-of-numbers scope form).
//  Both call paths now share one source of truth for "which group libraries can be scoped by
//  name," instead of the citekey-lookup path and the export path drifting into two different
//  answers to that question.
//

import Foundation

// MARK: - BBT response shapes

/// A Zotero library as reported by BBT's `user.groups` JSON-RPC method.
///
/// `id` is required; `name` is decoded leniently. A missing, null, OR wrong-typed `name`
/// (e.g. a JSON number) degrades to `nil` for that one entry instead of throwing — a single
/// malformed library must not fail the whole `user.groups` decode and silently drop the
/// group phase back to the unscoped fallback. Preserves the tolerance of the `BBTLibrary`
/// struct this replaces, which sidestepped the problem by not modeling `name` at all.
struct ZoteroLibrary: Equatable, Sendable {
    let id: Int
    let name: String?
}

extension ZoteroLibrary: Decodable {
    private enum CodingKeys: String, CodingKey { case id, name }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try? container.decode(String.self, forKey: .name)
    }
}

/// `result` decodes with genuine PER-ENTRY isolation: a single malformed library entry (e.g. a
/// missing or non-numeric `id` — the one field `ZoteroLibrary.init(from:)` still lets throw) is
/// logged and skipped, rather than failing the whole array decode the way the compiler-
/// synthesized `Array<ZoteroLibrary>: Decodable` conformance would. Losing the entire array to
/// one bad entry would disable ALL group libraries for that resolution, not just the bad one —
/// see `performGroupPhase`'s doc comment for why that matters.
///
/// `result` is `nil` when the key is absent or explicitly `null` (a malformed/protocol-violating
/// envelope — `parseLibraries` throws on this) and `[]` when the key is present with a valid,
/// possibly-empty array (a user with zero libraries is not realistic for a real Zotero install,
/// but is a valid JSON shape and must not be conflated with the malformed case above).
private struct GroupsRPCResponse: Decodable {
    let jsonrpc: String?
    let result: [ZoteroLibrary]?
    let error: JSONRPCError?

    private enum CodingKeys: String, CodingKey { case jsonrpc, result, error }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decodeIfPresent(String.self, forKey: .jsonrpc)
        error = try container.decodeIfPresent(JSONRPCError.self, forKey: .error)

        // Key absent, or present but null, both mean "no result" — `decodeNil` only throws
        // `keyNotFound` when the key is missing, so `contains` must be checked first to keep
        // that call safe; comma-separated `guard` conditions short-circuit like `&&`, so
        // `decodeNil` is never reached when `contains` is false.
        guard container.contains(.result), try !container.decodeNil(forKey: .result) else {
            result = nil
            return
        }

        // Decode element-by-element via `superDecoder()` rather than
        // `nestedUnkeyedContainer(forKey:).decode(ZoteroLibrary.self)` in a loop: this project's
        // JSONDecoder does NOT advance an unkeyed container's index when `decode(_:)` itself
        // throws (verified empirically — a naive do/catch loop around `decode(_:)` spins forever
        // re-decoding the same malformed element). `superDecoder()` captures the element and
        // advances the index unconditionally, before we attempt to decode it, so a throwing
        // element is safely skipped without looping.
        var unkeyed = try container.nestedUnkeyedContainer(forKey: .result)
        var libraries: [ZoteroLibrary] = []
        while !unkeyed.isAtEnd {
            let elementDecoder = try unkeyed.superDecoder()
            do {
                libraries.append(try ZoteroLibrary(from: elementDecoder))
            } catch {
                DebugLog.log(
                    .zotero,
                    "[ZoteroService] Skipping malformed library entry in user.groups response (\(error)) — " +
                    "the rest of the user.groups list still decodes; this one library's citekeys will be " +
                    "reported not-found rather than disabling the whole group-library phase"
                )
            }
        }
        result = libraries
    }
}

/// Raw (undecoded) outcome of a single `item.pandoc_filter` call.
///
/// `items` is keyed by each resolved item's own CSL `id` field (re-keyed from BBT's raw
/// response by `parsePandocFilterResponseRaw` — see that function's doc comment for why: BBT's
/// own dict key is the item's `citation-key`, not the `id` it actually matched the request
/// against). This canonical key can differ in case from the originally-requested citekey when
/// BBT's "case-insensitive citekeys" preference is on. `notFoundKeys`/`ambiguousKeys` are keyed
/// by the exact citekey strings that were requested: BBT always echoes the literal request
/// string in `errors` (`result.errors[citationKey] = found.length` in BBT's own `json-rpc.ts`),
/// never a canonical form, so those two sets need no case reconciliation.
struct PandocFilterRawOutcome {
    var items: [String: [String: Any]]
    /// Citekeys with zero matches in the libraries this call queried.
    var notFoundKeys: Set<String>
    /// Citekeys with 2+ matches in the libraries this call queried — exists identically in
    /// more than one library, so which one the user meant can't be determined. TWO sources
    /// feed this: BBT's own `errors` entries with count >= 2 (one call, 2+ matches inside the
    /// scope it queried), and — on the merged group-phase outcome only — a duplicate/ambiguity
    /// detected by `mergeGroupOutcomes` itself: two separately-scoped calls each returning an
    /// item for the same citekey, two case-variant keys inside one call's own `items`, or one
    /// scope's own `errors` entry for a citekey a DIFFERENT scope separately resolved to one
    /// item. None of these three `mergeGroupOutcomes`-detected cases has a fresh BBT `errors`
    /// entry of its own behind it — `mergeGroupOutcomes` synthesizes/propagates the flag
    /// locally, and in all three cases withholds the matching item from the merged `items`
    /// (even one that resolved cleanly in its own single-scope call) so the key stays
    /// unresolved and the flag survives `mergeRawOutcomes`'s
    /// `ambiguousKeys.intersection(unresolved)`. Every source is keyed by the REQUESTED citekey
    /// spelling, never by an item's own CSL `id` — see this struct's doc comment above for why
    /// that distinction matters.
    var ambiguousKeys: Set<String>
    /// Same sources as `ambiguousKeys` above, populated in lockstep with it, but tracked
    /// SEPARATELY from there on: `mergeRawOutcomes` intersects `ambiguousKeys` against the
    /// still-unresolved key set (so a spurious per-spelling miss can be cleared once some other
    /// casing of the same citekey resolves — see that function's doc comment), while
    /// `rawAmbiguousKeys` is only ever UNIONED, never intersected or cleared. This gives
    /// `ExportService.canonicalCitekeyMap` an ambiguity signal that survives the clearing
    /// `ambiguousKeys` is deliberately subject to, so it never proposes a citekey-case rewrite
    /// off an arbitrary winner among 2+ real BBT matches for the exact spelling requested.
    var rawAmbiguousKeys: Set<String> = []
}

/// One phase-2 `item.pandoc_filter` call: how it is scoped, and which group libraries that
/// scope actually covers. The `libraryIDs` are what pass 2 uses to avoid re-searching a
/// library pass 1 already searched successfully — never scope-object equality, which cannot
/// see that a renamed library moved between scopes.
struct GroupLibraryScopePlan: Equatable {
    let scope: ZoteroService.PandocFilterScope
    let libraryIDs: [Int]
}

extension ZoteroService {

    /// Parse a raw `user.groups` JSON-RPC response body into the list of libraries it reports.
    ///
    /// Throws when `result` is missing or `null` — a malformed/protocol-violating envelope that
    /// should never happen for a valid Zotero install (every install has at least a personal
    /// library). Silently treating that shape as "zero libraries" would get cached and never
    /// self-heal, since the stale-library retry in `performGroupPhase` only fires on a
    /// `"JSON-RPC error:"`-prefixed message. A genuinely empty array (`"result":[]` — not
    /// realistic for Zotero, but a valid JSON shape) is NOT this case and still returns `[]`
    /// successfully, same as `parsePandocFilterResponseRaw`'s analogous guard on `result`.
    nonisolated static func parseLibraries(from data: Data) throws -> [ZoteroLibrary] {
        let decoded = try JSONDecoder().decode(GroupsRPCResponse.self, from: data)
        if let rpcError = decoded.error {
            throw ZoteroError.invalidResponse("JSON-RPC error: \(rpcError.message)")
        }
        guard let result = decoded.result else {
            throw ZoteroError.invalidResponse("Missing result in user.groups response")
        }
        return result
    }

    /// Partition the user's group libraries into phase-2 `item.pandoc_filter` scopes.
    ///
    /// Every uniquely-named group library batches into ONE `.libraryNames` plan (zero extra
    /// RPCs — the common case). Every group library whose display name collides with
    /// another's (trim+lowercase-insensitively) — or has no usable name at all — gets its own
    /// `.libraryID` plan instead, since sending a colliding name to BBT would match only ONE of
    /// the colliding libraries and silently shadow the rest — the bug this file exists to fix.
    ///
    /// Collision detection counts over the FULL `libraries` list, including any library named in
    /// `excludingLibraryIDs` — exclusion only suppresses emitting a plan for an already-covered
    /// library, it must never change what looks "unique" to another library that still shares
    /// its name. See `performGroupPhase`'s pass-2 call site: excluding one half of a colliding
    /// pair must not make the other half look uniquely named and earn a name-scoped call that
    /// silently re-searches the excluded half too.
    ///
    /// Deterministic order: the batched `.libraryNames` plan first (when non-empty), then the
    /// per-id plans in `libraries` order.
    nonisolated static func groupLibraryScopes(
        from libraries: [ZoteroLibrary],
        excludingLibraryIDs: Set<Int> = []
    ) -> [GroupLibraryScopePlan] {
        let groups = libraries.filter { $0.id != personalLibraryID }

        // nil = no usable name (missing or whitespace-only). Non-nil = trimmed+lowercased, for
        // DETECTION only; the string actually sent to BBT is always the library's own `name`,
        // verbatim and untrimmed.
        func detectionKey(_ library: ZoteroLibrary) -> String? {
            guard let name = library.name else { return nil }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed.lowercased()
        }

        var keyCounts: [String: Int] = [:]
        for library in groups {
            guard let key = detectionKey(library) else { continue }
            keyCounts[key, default: 0] += 1
        }

        var uniqueNames: [String] = []
        var uniqueIDs: [Int] = []
        var perIDPlans: [GroupLibraryScopePlan] = []

        for library in groups where !excludingLibraryIDs.contains(library.id) {
            let key = detectionKey(library)
            guard let key, keyCounts[key] == 1 else {
                logPerIDScopeReason(library: library, key: key, keyCounts: keyCounts)
                perIDPlans.append(GroupLibraryScopePlan(scope: .libraryID(library.id), libraryIDs: [library.id]))
                continue
            }
            uniqueNames.append(library.name!)
            uniqueIDs.append(library.id)
        }

        var plans: [GroupLibraryScopePlan] = []
        if !uniqueNames.isEmpty {
            plans.append(GroupLibraryScopePlan(scope: .libraryNames(uniqueNames), libraryIDs: uniqueIDs))
        }
        plans.append(contentsOf: perIDPlans)
        return plans
    }

    /// The export path's (DOCX/ODT) view of `groupLibraryScopes`: the same partition, flattened
    /// into the two wire shapes `zotero.lua` can actually call BBT with — one batched
    /// `.libraryNames` array, plus one bare numeric id per colliding-or-nameless library.
    ///
    /// Exists so `ExportService` gets the collision-safe partition from the SAME source of truth
    /// as the citekey-resolution path, rather than the old exact-string dedupe of
    /// `groupLibraryNames(from:)`, which silently collapsed two same-named group libraries into
    /// one entry.
    nonisolated static func groupLibraryMetadata(
        from libraries: [ZoteroLibrary]
    ) -> (names: [String], ids: [Int]) {
        var names: [String] = []
        var ids: [Int] = []
        for plan in groupLibraryScopes(from: libraries) {
            switch plan.scope {
            case .libraryNames(let planNames): names.append(contentsOf: planNames)
            case .libraryID(let id): ids.append(id)
            case .personal: continue  // groupLibraryScopes never emits this; belt-and-braces.
            }
        }
        return (names, ids)
    }

    /// Logs why a single group library is being scoped by numeric id rather than folded into
    /// the batched `.libraryNames` plan — either it has no usable name, or its (normalized) name
    /// collides with one or more other group libraries.
    private nonisolated static func logPerIDScopeReason(library: ZoteroLibrary, key: String?, keyCounts: [String: Int]) {
        guard let key else {
            DebugLog.log(
                .zotero,
                "[ZoteroService] Group library id \(library.id) has no usable name in the user.groups response — " +
                "scoping it by numeric id instead of dropping it from the group-library phase"
            )
            return
        }
        let collisionCount = (keyCounts[key] ?? 1) - 1
        DebugLog.log(
            .zotero,
            "[ZoteroService] Group library id \(library.id) (\"\(library.name ?? "")\") shares its display name " +
            "with \(collisionCount) other group librar\(collisionCount == 1 ? "y" : "ies") — scoping it by " +
            "numeric id instead of by name to avoid silently shadowing one of them"
        )
    }

    /// Detect duplicate/ambiguous item-id keys across (and within) a set of group-library scope
    /// outcomes, and pick the first-surviving `(key, item)` pair for every key that is not
    /// withheld. Split out of `mergeGroupOutcomes` purely to keep that function's cyclomatic
    /// complexity within SwiftLint's limit — this implements exactly cases 1, 2, and 3 from
    /// `mergeGroupOutcomes`'s doc comment (cross-scope duplicate, within-scope duplicate, and
    /// self-reported ambiguity), unchanged from when they lived inline there.
    ///
    /// `firstSeen` and `withheldLower` are both keyed by LOWERCASED item-id key, per
    /// `mergeGroupOutcomes`'s own keying rules; `firstSeen`'s value retains the original-case key
    /// alongside the item so the caller can re-key `items` by that original spelling.
    private nonisolated static func collectFirstSeenAndWithheldKeys(
        outcomes: [PandocFilterRawOutcome]
    ) -> (firstSeen: [String: (key: String, item: [String: Any])], withheldLower: Set<String>) {
        // First outcome to report a given (lowercased) item-id key wins the slot; a SECOND
        // outcome reporting the same lowercased key is a cross-scope collision (case 1 above).
        // A lowercased key appearing more than once WITHIN one outcome's own `items` is a
        // within-scope collision (case 2) — caught via `lowerCountsInOutcome` before that
        // outcome's entries ever reach `firstSeen`, so neither of its two case variants can win
        // the slot silently.
        var firstSeen: [String: (key: String, item: [String: Any])] = [:]
        var withheldLower: Set<String> = []
        for outcome in outcomes {
            var lowerCountsInOutcome: [String: Int] = [:]
            for key in outcome.items.keys {
                lowerCountsInOutcome[key.lowercased(), default: 0] += 1
            }
            for (lower, count) in lowerCountsInOutcome where count > 1 || firstSeen[lower] != nil {
                withheldLower.insert(lower)
            }
            for (key, item) in outcome.items where firstSeen[key.lowercased()] == nil {
                firstSeen[key.lowercased()] = (key: key, item: item)
            }
        }

        // Case 3: a citekey any single outcome itself reported ambiguous is withheld too, even
        // if it never collided in `items` above (e.g. one scope reports it ambiguous with zero
        // matching item while a different scope separately resolved a single item for it).
        for outcome in outcomes {
            for key in outcome.ambiguousKeys {
                withheldLower.insert(key.lowercased())
            }
        }

        return (firstSeen, withheldLower)
    }

    /// Merge N phase-2 `item.pandoc_filter` outcomes — one per `groupLibraryScopes` plan — into
    /// one `PandocFilterRawOutcome`.
    ///
    /// THREE cases are all withheld from `items` and flagged ambiguous under the REQUESTED
    /// spelling(s) — never an item's own CSL `id` spelling, which can differ in case and would
    /// intersect to nothing in `mergeRawOutcomes`'s `ambiguousKeys.intersection(unresolved)`.
    /// See `PandocFilterRawOutcome.ambiguousKeys`'s doc comment for why withholding (not just
    /// flagging) is what makes the ambiguity survive that intersection:
    ///
    /// 1. CROSS-scope duplicate: two DIFFERENT scopes each return an item for the SAME citekey
    ///    identity, because the citekey genuinely exists in two different libraries queried
    ///    separately. Picking whichever scope happened to run first would be an arbitrary
    ///    silent choice.
    /// 2. WITHIN-scope duplicate: a SINGLE outcome's own `items` already contains two
    ///    case-variant keys for the same identity (e.g. both `Roy2022` and `roy2022`) — real
    ///    when BBT's case-insensitive-citekeys preference is off and two genuinely different
    ///    items happen to have citekeys differing only in case. Dictionary iteration order is
    ///    unspecified, so silently keeping "whichever one the loop saw first" would be
    ///    nondeterministic AND silent — the collision must be caught before either item is kept.
    /// 3. SELF-reported ambiguity: a single outcome's own `ambiguousKeys` already reports this
    ///    identity as a 2+ match INSIDE the one scope it queried (BBT's `errors[key] >= 2`).
    ///    This must withhold the item even when some OTHER scope separately resolved it to one
    ///    item — pre-split, a single batched call would have summed both libraries' matches
    ///    into one `errors[key]` count and reported the whole thing ambiguous; splitting into
    ///    per-library scopes must not let that same real-world duplication turn into a silent
    ///    arbitrary pick just because one of the two scopes happened to see only one match.
    ///
    /// `notFoundKeys` is a plain union across every outcome — it does NOT subtract keys resolved
    /// by some other scope here; that clean-up happens downstream, in `mergeRawOutcomes`'s own
    /// `notFoundKeys.intersection(unresolved)`.
    nonisolated static func mergeGroupOutcomes(
        requested: [String],
        outcomes: [PandocFilterRawOutcome]
    ) -> PandocFilterRawOutcome {
        var requestedByLower: [String: [String]] = [:]
        for key in requested {
            requestedByLower[key.lowercased(), default: []].append(key)
        }

        let (firstSeen, withheldLower) = collectFirstSeenAndWithheldKeys(outcomes: outcomes)

        var items: [String: [String: Any]] = [:]
        for (lower, seen) in firstSeen where !withheldLower.contains(lower) {
            items[seen.key] = seen.item
        }

        var notFoundKeys: Set<String> = []
        var ambiguousKeys: Set<String> = []
        var rawAmbiguousKeys: Set<String> = []
        for outcome in outcomes {
            notFoundKeys.formUnion(outcome.notFoundKeys)
            ambiguousKeys.formUnion(outcome.ambiguousKeys)
            rawAmbiguousKeys.formUnion(outcome.rawAmbiguousKeys)
        }

        for lower in withheldLower {
            let spellings = requestedByLower[lower] ?? []
            if spellings.isEmpty {
                // Defensive only — should not happen, since this lowercased key came back from
                // a call made with `requested`.
                let fallback = firstSeen[lower]?.key ?? lower
                DebugLog.log(
                    .zotero,
                    "[ZoteroService] Withheld duplicate/ambiguous key for \"\(lower)\" matched no requested " +
                    "spelling — flagging \"\(fallback)\" ambiguous instead"
                )
                ambiguousKeys.insert(fallback)
                rawAmbiguousKeys.insert(fallback)
            } else {
                ambiguousKeys.formUnion(spellings)
                rawAmbiguousKeys.formUnion(spellings)
            }
            DebugLog.log(
                .zotero,
                "[ZoteroService] Citekey \(spellings.isEmpty ? [firstSeen[lower]?.key ?? lower] : spellings) " +
                "resolved in more than one group library scope, collided within one scope's own response, or " +
                "was itself reported ambiguous by a scope — withholding it and reporting it ambiguous rather " +
                "than picking an arbitrary winner"
            )
        }

        notFoundKeys.subtract(ambiguousKeys)

        return PandocFilterRawOutcome(
            items: items,
            notFoundKeys: notFoundKeys,
            ambiguousKeys: ambiguousKeys,
            rawAmbiguousKeys: rawAmbiguousKeys
        )
    }
}
