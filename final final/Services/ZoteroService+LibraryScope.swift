//
//  ZoteroService+LibraryScope.swift
//  final final
//
//  Two-phase, library-scoped citekey resolution via BBT's `item.pandoc_filter` JSON-RPC
//  method: personal library first, then (for anything still unresolved) every group/shared
//  library the user belongs to. Fixes citekeys that only exist in a shared/group library,
//  which the old unscoped `item.export` call silently failed to find (it always searched only
//  "My Library").
//
//  This file owns the RAW (undecoded) resolution engine, used directly by
//  `ZoteroService.fetchRawItemsForCitekeys` (export's bibliography JSON, which needs every CSL
//  field `CSLItem` doesn't model) and as the foundation `ZoteroService.fetchItemsForCitekeys`
//  decodes into `CSLItem` on top of (CAYW/autocomplete, which does need the typed model).
//

import Foundation

// MARK: - BBT response shapes

/// A Zotero library as reported by BBT's `user.groups` JSON-RPC method. Only `id` is read —
/// `name` is deliberately not modeled (a malformed/missing `name` on one entry must not throw
/// the whole decode and silently degrade to the unscoped fallback).
private struct BBTLibrary: Decodable {
    let id: Int
}

private struct GroupsRPCResponse: Decodable {
    let jsonrpc: String?
    let result: [BBTLibrary]?
    let error: JSONRPCError?
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
    /// more than one library, so which one the user meant can't be determined.
    var ambiguousKeys: Set<String>
    /// Same source as `ambiguousKeys` (BBT `errors` entries with count >= 2) at the point
    /// `parsePandocFilterResponseRaw` populates both, but tracked SEPARATELY from there on:
    /// `mergeRawOutcomes` intersects `ambiguousKeys` against the still-unresolved key set (so
    /// a spurious per-spelling miss can be cleared once some other casing of the same citekey
    /// resolves — see that function's doc comment), while `rawAmbiguousKeys` is only ever
    /// UNIONED, never intersected or cleared. This gives `ExportService.canonicalCitekeyMap`
    /// an ambiguity signal that survives the clearing `ambiguousKeys` is deliberately subject
    /// to, so it never proposes a citekey-case rewrite off an arbitrary winner among 2+ real
    /// BBT matches for the exact spelling requested.
    var rawAmbiguousKeys: Set<String> = []
}

extension ZoteroService {

    // MARK: - Constants

    /// Zotero's stable personal-library ID (`userLibraryID`). Always identify the personal
    /// library by this — never by its display name ("My Library"), which is
    /// localized/user-renamable text, not a stable identifier.
    nonisolated static let personalLibraryID = 1

    /// Timeout for a single `item.pandoc_filter` call. Longer than the other two calls below:
    /// a large bibliography can mean a batch of many citekeys searched across many libraries.
    private nonisolated static let pandocFilterTimeout: TimeInterval = 20
    /// Timeout for `user.groups` — a small, fast metadata call.
    private nonisolated static let userGroupsTimeout: TimeInterval = 10
    /// Timeout for the legacy `item.export` fallback — matches the timeout the pre-existing
    /// export flow used before this file's resolvers replaced its raw JSON-RPC call.
    nonisolated static let itemExportTimeout: TimeInterval = 10

    // MARK: - Cancellation

    /// True for a Swift Concurrency cancellation or a cancelled `URLSession` task. Callers
    /// check this FIRST in their error boundary and rethrow directly — a cancellation must
    /// never be treated as "the resolution path failed, try the fallback," since the caller
    /// already gave up and a fallback network request would just be wasted work racing a
    /// result nobody wants anymore.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    // MARK: - Citekey list hygiene

    /// Deduplicate a requested citekey list, preserving first-occurrence order. Matches BBT's
    /// own `item.pandoc_filter` behavior (`citekeys = [...new Set(citekeys)]`) and the old
    /// `item.export` call's effective behavior (each existing citekey contributes one item
    /// regardless of how many times it's requested) — without this, a citation with the same
    /// key repeated (or BBT's case-insensitive-citekey matching folding two differently-cased
    /// requests onto the same item) could yield duplicate items in the result.
    nonisolated static func orderedUniqueCitekeys(_ citekeys: [String]) -> [String] {
        var seen = Set<String>()
        return citekeys.filter { seen.insert($0).inserted }
    }

    // MARK: - Not-found / ambiguous error

    /// Compose the user-visible error for citekeys that never resolved after both phases —
    /// the direct analogue of the old `item.export`'s "not found: X" error, but with not-found
    /// and ambiguous citekeys named and worded distinctly instead of collapsed into one
    /// generic message.
    nonisolated static func notFoundOrAmbiguousError(notFound: Set<String>, ambiguous: Set<String>) -> ZoteroError {
        var parts: [String] = []
        if !notFound.isEmpty {
            parts.append("not found in any library: \(notFound.sorted().joined(separator: ", "))")
        }
        if !ambiguous.isEmpty {
            parts.append("ambiguous across libraries: \(ambiguous.sorted().joined(separator: ", "))")
        }
        return .invalidResponse("BBT error: \(parts.joined(separator: "; "))")
    }

    // MARK: - CSLItem decode (typed path only)

    /// Decode one raw CSL-JSON dict (as returned by `item.pandoc_filter`) into a `CSLItem`.
    /// Only the typed path (`fetchItemsForCitekeys`) calls this — the raw path
    /// (`fetchRawItemsForCitekeys`) hands the dict straight to pandoc undecoded, so it never
    /// drops fields `CSLItem` doesn't model (translator, edition, collection-title,
    /// chapter-number, genre, original-date, etc. — fields the bundled CSL styles do use).
    nonisolated static func decodeCSLItem(from rawItem: [String: Any]) throws -> CSLItem {
        let data = try JSONSerialization.data(withJSONObject: rawItem)
        return try JSONDecoder().decode(CSLItem.self, from: data)
    }

    // MARK: - Request building

    /// Build the JSON-RPC request body for BBT's `item.pandoc_filter` method.
    ///
    /// CRITICAL: `libraryID` (3rd positional param) must be serialized as an array of
    /// STRINGS, e.g. `["2","3"]` — NOT integers. The installed BBT's JSON schema for this
    /// parameter is `oneOf: [string, number, string[]]`; passing a *numeric* array fails
    /// schema validation outright ("must match exactly one schema in oneOf"), even though
    /// every individual ID is itself a number — only a `string[]` satisfies that `oneOf`.
    /// Verified live against a real Zotero 9.0.6 + Better BibTeX 9.0.47 install. Do NOT
    /// "helpfully" change `libraryIDs.map { String($0) }` back to a plain `[Int]`.
    nonisolated static func pandocFilterRequestBody(citekeys: [String], libraryIDs: [Int]) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "method": "item.pandoc_filter",
            "params": [citekeys, true, libraryIDs.map { String($0) }]
        ]
    }

    // MARK: - Response parsing

    /// Parse a raw `item.pandoc_filter` JSON-RPC response body via `JSONSerialization` (not
    /// `Codable`) — this layer never decodes into `CSLItem`, so a field only some CSL styles
    /// use doesn't need to round-trip through a typed model here. Throws on a JSON-RPC error
    /// object, a malformed envelope, or a missing `result`; every failure here is meant to be
    /// caught by the caller and treated as "the new path failed, fall back to item.export."
    ///
    /// BBT's `result.items` object is keyed by each item's `citation-key` field — but BBT
    /// internally *resolves/matches* items by its own KeyManager key and stores that matched
    /// key in the item's CSL `id` field, which is not necessarily the same string as
    /// `citation-key`. This diverges when a legacy `Citation Key:` line lingers in an item's
    /// Zotero "Extra" field from pre-Zotero-8 Better BibTeX — `citation-key` reflects that
    /// stale Extra-field value while `id` reflects what BBT actually matched against. Trusting
    /// BBT's own dict key (`citation-key`) here means such an item comes back keyed under a
    /// name nothing else in this resolution pipeline can trace back to the request, producing a
    /// false "not found in any library." So every item is re-keyed by its own `id` field below;
    /// only when `id` is absent or empty (shouldn't happen for a real BBT response, but keeps
    /// this defensive) does the original dict key survive as a fallback.
    nonisolated static func parsePandocFilterResponseRaw(_ data: Data) throws -> PandocFilterRawOutcome {
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ZoteroError.invalidResponse("Invalid JSON-RPC response")
        }
        if let error = envelope["error"] as? [String: Any], let message = error["message"] as? String {
            throw ZoteroError.invalidResponse("JSON-RPC error: \(message)")
        }
        guard let result = envelope["result"] as? [String: Any] else {
            throw ZoteroError.invalidResponse("Missing result in item.pandoc_filter response")
        }

        var notFoundKeys: Set<String> = []
        var ambiguousKeys: Set<String> = []
        for (key, value) in (result["errors"] as? [String: Any]) ?? [:] {
            guard let matchCount = (value as? NSNumber)?.intValue else { continue }
            if matchCount == 0 {
                notFoundKeys.insert(key)
            } else if matchCount >= 2 {
                ambiguousKeys.insert(key)
            }
        }

        let rawItems = (result["items"] as? [String: [String: Any]]) ?? [:]
        var items: [String: [String: Any]] = [:]
        items.reserveCapacity(rawItems.count)
        for (bbtDictKey, item) in rawItems {
            if let id = item["id"] as? String, !id.isEmpty {
                items[id] = item
            } else {
                items[bbtDictKey] = item
            }
        }

        return PandocFilterRawOutcome(
            items: items,
            notFoundKeys: notFoundKeys,
            ambiguousKeys: ambiguousKeys,
            rawAmbiguousKeys: ambiguousKeys
        )
    }

    /// Parse a raw `user.groups` JSON-RPC response body into a flat list of library IDs.
    nonisolated static func parseLibraryIDs(from data: Data) throws -> [Int] {
        let decoded = try JSONDecoder().decode(GroupsRPCResponse.self, from: data)
        if let rpcError = decoded.error {
            throw ZoteroError.invalidResponse("JSON-RPC error: \(rpcError.message)")
        }
        return (decoded.result ?? []).map(\.id)
    }

    /// Extract every group/shared library ID from a full `user.groups` library-ID list
    /// (excludes the personal library, id 1).
    nonisolated static func groupLibraryIDs(from allLibraryIDs: [Int]) -> [Int] {
        allLibraryIDs.filter { $0 != personalLibraryID }
    }

    /// Heuristic for "the group-library phase failed because BBT rejected a library ID we had
    /// cached" (e.g. a group was left/deleted mid-session, so a cached ID is now stale). True
    /// for a JSON-RPC-level error object *from BBT itself* (as opposed to a network/transport
    /// failure) — the closest identifiable signal available, since BBT doesn't document a
    /// dedicated "unknown library" error code separate from its generic invalid-parameters
    /// error.
    private nonisolated static func looksLikeStaleLibraryError(_ error: Error) -> Bool {
        guard case let ZoteroError.invalidResponse(message) = error else { return false }
        return message.hasPrefix("JSON-RPC error:")
    }

    // MARK: - Two-phase merge

    /// Merge phase 1 (personal) and phase 2 (group) raw outcomes.
    ///
    /// Resolved items are matched back to the requested citekeys CASE-INSENSITIVELY: `items` on
    /// each outcome is keyed by each item's own CSL `id` (re-keyed from BBT's raw
    /// `citation-key`-keyed response by `parsePandocFilterResponseRaw`), which can differ in
    /// case from the exact string requested when BBT's "case-insensitive citekeys" preference
    /// is on. Re-indexing by exact string here would silently drop a genuinely-resolved item.
    ///
    /// Personal-library precedence is preserved: a citekey resolved in phase 1 always wins,
    /// even if phase 2 also returned something keyed the same way.
    ///
    /// Not-found/ambiguous classifications are UNIONED across both phases — with ambiguous
    /// taking precedence over not-found for the same key — rather than letting phase 2 fully
    /// replace phase 1's. A key ambiguous within the personal library and absent from every
    /// group library is still ambiguous (the item does exist, just can't be disambiguated),
    /// not "not found in any library."
    nonisolated static func mergeRawOutcomes(
        requested: [String],
        personal: PandocFilterRawOutcome,
        groups: PandocFilterRawOutcome?
    ) -> PandocFilterRawOutcome {
        var resolved: [String: [String: Any]] = [:]
        for (key, item) in personal.items {
            resolved[key] = item
        }
        if let groups {
            for (key, item) in groups.items where resolved[key] == nil {
                resolved[key] = item
            }
        }

        let resolvedLower = Set(resolved.keys.map { $0.lowercased() })
        let unresolved = Set(requested.filter { !resolvedLower.contains($0.lowercased()) })

        var ambiguousKeys = personal.ambiguousKeys
        var notFoundKeys = personal.notFoundKeys
        var rawAmbiguousKeys = personal.rawAmbiguousKeys
        if let groups {
            ambiguousKeys.formUnion(groups.ambiguousKeys)
            notFoundKeys.formUnion(groups.notFoundKeys)
            rawAmbiguousKeys.formUnion(groups.rawAmbiguousKeys)
        }
        notFoundKeys.subtract(ambiguousKeys)

        return PandocFilterRawOutcome(
            items: resolved,
            notFoundKeys: notFoundKeys.intersection(unresolved),
            ambiguousKeys: ambiguousKeys.intersection(unresolved),
            // Plain union — never intersected against `unresolved`, never cleared. See
            // `rawAmbiguousKeys`'s doc comment: this is what lets a case-insensitive citekey
            // rewrite still veto off a genuine 2+-match ambiguity even on the branch where
            // `ambiguousKeys` itself gets cleared (e.g. `resolveRawViaPandocFilter`'s
            // fully-resolved-after-phase-1 early return, which calls this with `unresolved`
            // empty).
            rawAmbiguousKeys: rawAmbiguousKeys
        )
    }

    // MARK: - Network primitives

    /// Perform a single `item.pandoc_filter` JSON-RPC call scoped to `libraryIDs`.
    fileprivate func performPandocFilterRequestRaw(
        citekeys: [String], libraryIDs: [Int]
    ) async throws -> PandocFilterRawOutcome {
        guard let url = URL(string: "\(baseURL)/better-bibtex/json-rpc") else {
            throw ZoteroError.invalidResponse("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.pandocFilterTimeout
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.pandocFilterRequestBody(citekeys: citekeys, libraryIDs: libraryIDs)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ZoteroError.noResponse
        }

        return try Self.parsePandocFilterResponseRaw(data)
    }

    /// Fetch every library ID Better BibTeX knows about (personal + all group/shared
    /// libraries the user belongs to), via `user.groups`. Session-cached; pass
    /// `forceRefresh: true` to bypass the cache — used by `performGroupPhase` when a cached
    /// library ID looks stale (a group could be joined/left mid-session; there's no automatic
    /// polling for that otherwise).
    func fetchLibraryIDs(forceRefresh: Bool = false) async throws -> [Int] {
        if !forceRefresh, let cached = cachedLibraryIDs {
            return cached
        }

        guard let url = URL(string: "\(baseURL)/better-bibtex/json-rpc") else {
            throw ZoteroError.invalidResponse("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.userGroupsTimeout
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "user.groups",
            "params": []
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ZoteroError.noResponse
        }

        let ids = try Self.parseLibraryIDs(from: data)
        cachedLibraryIDs = ids
        return ids
    }

    /// Attempt phase 2 (group libraries) for `unresolved` citekeys. Returns `nil` if there are
    /// no group libraries to search.
    ///
    /// If the request fails in a way that looks like a stale cached library ID (see
    /// `looksLikeStaleLibraryError`), invalidates the library-ID cache and retries once with a
    /// forced refresh before giving up — a group could have been left mid-session, in which
    /// case a cached ID BBT no longer recognizes would otherwise silently reinstate the
    /// original unscoped-lookup bug for the rest of the session. `forceRefresh`'s only caller
    /// is this retry.
    fileprivate func performGroupPhase(unresolved: [String]) async throws -> PandocFilterRawOutcome? {
        let libraryIDs = try await fetchLibraryIDs()
        let groupIDs = Self.groupLibraryIDs(from: libraryIDs)
        guard !groupIDs.isEmpty else { return nil }

        do {
            return try await performPandocFilterRequestRaw(citekeys: unresolved, libraryIDs: groupIDs)
        } catch {
            guard !Self.isCancellation(error), Self.looksLikeStaleLibraryError(error) else { throw error }
            DebugLog.log(
                .zotero,
                "[ZoteroService] Group-library item.pandoc_filter call failed (\(error)) — " +
                "looks like a stale cached library ID; invalidating cache and retrying once"
            )
            let freshLibraryIDs = try await fetchLibraryIDs(forceRefresh: true)
            let freshGroupIDs = Self.groupLibraryIDs(from: freshLibraryIDs)
            guard !freshGroupIDs.isEmpty else { return nil }
            return try await performPandocFilterRequestRaw(citekeys: unresolved, libraryIDs: freshGroupIDs)
        }
    }

    /// Two-phase `item.pandoc_filter` resolution: personal library first, then (for anything
    /// still unresolved) the user's remaining group libraries. Returns raw, undecoded CSL-JSON
    /// per resolved citekey plus the not-found/ambiguous classification for anything that
    /// never resolved.
    ///
    /// Throws only for transport/shape failures (network, non-200, malformed body) from the
    /// FIRST (personal-library) call — nothing has succeeded yet at that point, so falling
    /// back to the full-list `item.export` call is correct. It does NOT throw for individual
    /// not-found/ambiguous citekeys, which are reported via the returned outcome so callers can
    /// decide how to surface them (`fetchItemsForCitekeys` throws explicitly after this
    /// succeeds structurally; see its doc comment).
    ///
    /// If phase 2's `user.groups` lookup (or the group-library `item.pandoc_filter` call
    /// itself, after the stale-cache retry in `performGroupPhase`) fails, phase 1's
    /// already-resolved items are kept — the still-unresolved keys are simply reported as
    /// not-found rather than discarding phase 1's work or forcing the caller to re-run the
    /// fallback against the full original citekey list.
    ///
    /// Even when everything is resolved after phase 1 alone (`stillUnresolved` empty), the
    /// result is still routed through `mergeRawOutcomes` rather than returned as `personalOutcome`
    /// directly. Reason: this app treats a citekey as a case-insensitive identity everywhere else
    /// (getItem/hasItem/getItems, `mergeRawOutcomes` itself for the phase-1+phase-2 merge, the
    /// offline `loadItem` cache — see their doc comments), and this branch is the one place that
    /// policy wasn't yet being enforced. BBT itself only writes a citekey into `errors` when that
    /// exact spelling case-SENSITIVELY matched nothing on its own — which is a genuine miss, not
    /// a BBT bug or a stale/spurious report, and only surfaces at all when BBT's own
    /// "case-insensitive citekeys" preference is OFF. So when a document cites the same
    /// reference under two spellings (e.g. `[@Smith2020]` and `[@smith2020]`), BBT's response can
    /// legitimately contain both a resolved item (for whichever spelling matched) AND an `errors`
    /// entry for the other, genuinely-non-matching spelling — that key's own lowercased form IS
    /// present among the resolved items, so `stillUnresolved` (computed case-insensitively, just
    /// above) correctly comes up empty, but `personalOutcome`'s raw `notFoundKeys`/`ambiguousKeys`
    /// still contain that per-spelling miss verbatim. Returning `personalOutcome` as-is would
    /// surface a "not found in any library" error for a citekey identity that, under this app's
    /// own case-insensitive policy, did resolve and cache correctly. `mergeRawOutcomes` enforces
    /// that policy the same way it already does for the phase-1+phase-2 merge: it intersects
    /// `notFoundKeys`/`ambiguousKeys` against the (case-insensitively computed) set of keys that
    /// are actually still unresolved, which is empty here — clearing the per-spelling miss. Do
    /// NOT "optimize" this back to `return personalOutcome`; that reintroduces the bug.
    ///
    /// Two limits of this, both intentional and neither requiring a fix:
    /// - This only helps when SOME spelling of the citekey resolved within the same batch (in
    ///   practice, the same document — `fetchRawItemsForCitekeys` sends every distinct citekey
    ///   string found in one document in a single call). A document citing ONLY the miscased
    ///   spelling, with no correctly-cased citation anywhere else in it, still correctly reports
    ///   not-found — there is no other spelling in the batch to resolve against, so this is
    ///   honest, unchanged behavior, not a gap.
    /// - The intersection above clears `notFoundKeys` AND `ambiguousKeys` wholesale on this
    ///   branch, not selectively per-key. Consequence: if a key BBT reported as genuinely
    ///   ambiguous (2+ real matches) happens to case-fold to the same string as a separately-
    ///   resolving spelling elsewhere in the same batch, its ambiguity warning is cleared here
    ///   too, even though the ambiguity itself was real. Judged an acceptable trade-off for the
    ///   same reason as the not-found case above: this app's citekey identity is case-insensitive
    ///   everywhere else, and a case-fold match is exactly the situation this branch exists to
    ///   handle. (A genuinely-ambiguous key with no other spelling anywhere in the batch cannot
    ///   reach this branch at all — its lowercased form wouldn't be present among the resolved
    ///   items, so `stillUnresolved` above would be non-empty and phase 2 would run instead.)
    func resolveRawViaPandocFilter(_ requested: [String]) async throws -> PandocFilterRawOutcome {
        let personalOutcome = try await performPandocFilterRequestRaw(
            citekeys: requested, libraryIDs: [Self.personalLibraryID]
        )

        let resolvedLower = Set(personalOutcome.items.keys.map { $0.lowercased() })
        let stillUnresolved = requested.filter { !resolvedLower.contains($0.lowercased()) }

        guard !stillUnresolved.isEmpty else {
            return Self.mergeRawOutcomes(requested: requested, personal: personalOutcome, groups: nil)
        }

        var groupOutcome: PandocFilterRawOutcome?
        do {
            groupOutcome = try await performGroupPhase(unresolved: stillUnresolved)
        } catch {
            if Self.isCancellation(error) { throw error }
            DebugLog.log(
                .zotero,
                "[ZoteroService] Could not resolve group libraries for phase 2 (\(error)) — keeping phase 1's " +
                "results; remaining citekeys will be reported unresolved rather than retried against the full " +
                "original list"
            )
            groupOutcome = nil
        }

        return Self.mergeRawOutcomes(requested: requested, personal: personalOutcome, groups: groupOutcome)
    }

    // MARK: - Raw (undecoded) public entry point + fallback

    /// Diff requested citekeys against the CSL `id` field of each returned raw item
    /// (case-insensitively) — lets the legacy item.export fallback report unresolved keys
    /// instead of silently omitting them. item.export has no notion of "ambiguous", so
    /// everything diffed-missing here is classified not-found.
    nonisolated static func unresolvedKeys(requested: [String], resolvedItems: [[String: Any]]) -> Set<String> {
        let resolvedLower = Set(resolvedItems.compactMap { ($0["id"] as? String)?.lowercased() })
        return Set(requested.filter { !resolvedLower.contains($0.lowercased()) })
    }

    /// Fetch bibliography items by citekey, scoped the same way as `fetchItemsForCitekeys`,
    /// but returning the RAW (undecoded) CSL-JSON per item instead of decoding into `CSLItem`.
    /// `CSLItem` only models a subset of CSL-JSON fields; export needs every field the bundled
    /// CSL style might use (translator, edition, collection-title, chapter-number, genre,
    /// original-date, etc.), which a decode-then-reencode round trip through `CSLItem` would
    /// silently drop. Shares the exact two-phase resolution and stale-cache retry behavior
    /// with `fetchItemsForCitekeys` — but, unlike that typed path, never throws for individual
    /// not-found/ambiguous citekeys: export needs to build a partial bibliography rather than
    /// lose `--citeproc` for the whole document over one bad citekey, so those are reported via
    /// the returned `RawCitekeyBatchResult` instead. Still throws for real transport/cancellation
    /// failures — those fall back to `fetchRawItemsForCitekeysViaExport` as before.
    func fetchRawItemsForCitekeys(_ citekeys: [String]) async throws -> RawCitekeyBatchResult {
        guard !citekeys.isEmpty else {
            return RawCitekeyBatchResult(
                items: [], notFoundKeys: [], ambiguousKeys: [], rawAmbiguousKeys: [], supportsAmbiguityReporting: true
            )
        }
        let requested = Self.orderedUniqueCitekeys(citekeys)

        let outcome: PandocFilterRawOutcome
        do {
            outcome = try await resolveRawViaPandocFilter(requested)
        } catch {
            if Self.isCancellation(error) { throw error }
            DebugLog.log(
                .zotero,
                "[ZoteroService] item.pandoc_filter resolution failed (\(error)) — falling back to unscoped item.export"
            )
            return try await fetchRawItemsForCitekeysViaExport(requested)
        }

        isConnected = true
        connectionError = nil

        return RawCitekeyBatchResult(
            items: Array(outcome.items.values),
            notFoundKeys: outcome.notFoundKeys,
            ambiguousKeys: outcome.ambiguousKeys,
            rawAmbiguousKeys: outcome.rawAmbiguousKeys,
            supportsAmbiguityReporting: true
        )
    }

    /// Fetch raw (undecoded) CSL-JSON items by citekey using BBT's `item.export` — unscoped,
    /// so BBT searches only the personal library ("My Library"). Fallback for when
    /// `item.pandoc_filter` resolution (`resolveRawViaPandocFilter`) fails for any reason.
    /// Mirrors the pre-existing `ExportService+Citations.swift` raw JSON-RPC call this
    /// replaced, so PDF export keeps its old fallback behavior when the new path can't run.
    ///
    /// Unlike `item.pandoc_filter`, `item.export` reports no per-key not-found/ambiguous
    /// information of its own — it just silently omits anything it couldn't match. Every
    /// return path below diffs the requested citekeys against the resolved items' `id` fields
    /// via `unresolvedKeys` so a citekey that only fails via this fallback is still reported,
    /// instead of vanishing with zero warning (which would recreate the exact bug this fix
    /// addresses).
    ///
    /// `rawAmbiguousKeys` is always empty on every return path below: `item.export` has no
    /// ambiguity concept at all (it just returns whatever it matched, silently, with no error
    /// list to derive an ambiguity signal from). `supportsAmbiguityReporting` is `false` on
    /// every return path below for the same reason — see that field's doc comment: this is
    /// what disables `ExportService`'s citekey-case rewrite entirely on this fallback path,
    /// rather than leaving it to rely on an ambiguity veto that has nothing to veto with here.
    fileprivate func fetchRawItemsForCitekeysViaExport(_ citekeys: [String]) async throws -> RawCitekeyBatchResult {
        guard !citekeys.isEmpty else {
            return RawCitekeyBatchResult(
                items: [], notFoundKeys: [], ambiguousKeys: [], rawAmbiguousKeys: [], supportsAmbiguityReporting: false
            )
        }
        guard let url = URL(string: "\(baseURL)/better-bibtex/json-rpc") else {
            throw ZoteroError.invalidResponse("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.itemExportTimeout

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "item.export",
            "params": [citekeys, "Better CSL JSON"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ZoteroError.noResponse
        }

        guard let jsonObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ZoteroError.invalidResponse("Invalid JSON-RPC response")
        }

        if let resultString = jsonObj["result"] as? String {
            if resultString.isEmpty {
                return RawCitekeyBatchResult(
                    items: [], notFoundKeys: Set(citekeys), ambiguousKeys: [], rawAmbiguousKeys: [],
                    supportsAmbiguityReporting: false
                )
            }
            guard let resultData = resultString.data(using: .utf8),
                  let parsed = try JSONSerialization.jsonObject(with: resultData) as? [[String: Any]] else {
                throw ZoteroError.invalidResponse("Failed to decode result string")
            }
            isConnected = true
            connectionError = nil
            return RawCitekeyBatchResult(
                items: parsed,
                notFoundKeys: Self.unresolvedKeys(requested: citekeys, resolvedItems: parsed),
                ambiguousKeys: [],
                rawAmbiguousKeys: [],
                supportsAmbiguityReporting: false
            )
        } else if let resultArray = jsonObj["result"] as? [[String: Any]] {
            isConnected = true
            connectionError = nil
            return RawCitekeyBatchResult(
                items: resultArray,
                notFoundKeys: Self.unresolvedKeys(requested: citekeys, resolvedItems: resultArray),
                ambiguousKeys: [],
                rawAmbiguousKeys: [],
                supportsAmbiguityReporting: false
            )
        } else if let error = jsonObj["error"] as? [String: Any], let message = error["message"] as? String {
            throw ZoteroError.invalidResponse("BBT error: \(message)")
        } else {
            throw ZoteroError.invalidResponse("Unexpected result format in item.export")
        }
    }
}

/// Outcome of a raw (undecoded) citekey batch fetch for export: resolved CSL-JSON items,
/// plus which requested citekeys never resolved — named separately (not-found vs. ambiguous)
/// so the caller can build a specific warning. Never thrown as an error: the caller decides
/// whether to export a partial bibliography instead of losing --citeproc for the whole
/// document over one bad citekey.
struct RawCitekeyBatchResult {
    let items: [[String: Any]]
    let notFoundKeys: Set<String>
    let ambiguousKeys: Set<String>
    /// See `PandocFilterRawOutcome.rawAmbiguousKeys`'s doc comment: a plain union, never
    /// intersected/cleared the way `ambiguousKeys` can be. Always empty on the
    /// `fetchRawItemsForCitekeysViaExport` fallback path — `item.export` has no ambiguity
    /// concept to derive it from.
    let rawAmbiguousKeys: Set<String>
    /// True when this batch resolved via `item.pandoc_filter` (`fetchRawItemsForCitekeys`'s
    /// own success path), which reports real per-key ambiguity information (`rawAmbiguousKeys`
    /// above is trustworthy). False when this batch resolved via the `item.export` fallback
    /// (`fetchRawItemsForCitekeysViaExport`), which has NO ambiguity concept at all — not
    /// "reports zero ambiguous keys," but structurally incapable of reporting any, ever. An
    /// empty `rawAmbiguousKeys` on that path means "no information," not "verified
    /// unambiguous," so a caller using `rawAmbiguousKeys` as a veto (see
    /// `ExportService.canonicalCitekeyMap`) must not trust it there: two genuinely different
    /// references sharing a citekey except for case, with only one of them ever requested in
    /// this batch, would resolve via the fallback to one arbitrary match with zero error
    /// signal — the collision guard can't help either, since the OTHER reference was never
    /// requested/seen. This flag exists so the caller can refuse to build ANY rewrite map at
    /// all on the fallback path, rather than relying on an ambiguity veto that is silently
    /// inert there. See `ExportService.swift`'s citekey-canonicalization sequencing for where
    /// this is enforced.
    let supportsAmbiguityReporting: Bool
}
