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
/// `items` is keyed by BBT's own canonical citation-key for each resolved item — which can
/// differ in case from the originally-requested citekey when BBT's "case-insensitive
/// citekeys" preference is on. `notFoundKeys`/`ambiguousKeys` are keyed by the exact citekey
/// strings that were requested: BBT always echoes the literal request string in `errors`
/// (`result.errors[citationKey] = found.length` in BBT's own `json-rpc.ts`), never a canonical
/// form, so those two sets need no case reconciliation.
struct PandocFilterRawOutcome {
    var items: [String: [String: Any]]
    /// Citekeys with zero matches in the libraries this call queried.
    var notFoundKeys: Set<String>
    /// Citekeys with 2+ matches in the libraries this call queried — exists identically in
    /// more than one library, so which one the user meant can't be determined.
    var ambiguousKeys: Set<String>
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

        let items = (result["items"] as? [String: [String: Any]]) ?? [:]

        return PandocFilterRawOutcome(items: items, notFoundKeys: notFoundKeys, ambiguousKeys: ambiguousKeys)
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
    /// Resolved items are matched back to the requested citekeys CASE-INSENSITIVELY: BBT's
    /// `items` dict is keyed by each item's own canonical citation-key, which can differ in
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
        if let groups {
            ambiguousKeys.formUnion(groups.ambiguousKeys)
            notFoundKeys.formUnion(groups.notFoundKeys)
        }
        notFoundKeys.subtract(ambiguousKeys)

        return PandocFilterRawOutcome(
            items: resolved,
            notFoundKeys: notFoundKeys.intersection(unresolved),
            ambiguousKeys: ambiguousKeys.intersection(unresolved)
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
    func resolveRawViaPandocFilter(_ requested: [String]) async throws -> PandocFilterRawOutcome {
        let personalOutcome = try await performPandocFilterRequestRaw(
            citekeys: requested, libraryIDs: [Self.personalLibraryID]
        )

        let resolvedLower = Set(personalOutcome.items.keys.map { $0.lowercased() })
        let stillUnresolved = requested.filter { !resolvedLower.contains($0.lowercased()) }

        guard !stillUnresolved.isEmpty else {
            return personalOutcome
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

    /// Fetch bibliography items by citekey, scoped the same way as `fetchItemsForCitekeys`,
    /// but returning the RAW (undecoded) CSL-JSON per item instead of decoding into `CSLItem`.
    /// `CSLItem` only models a subset of CSL-JSON fields; export needs every field the bundled
    /// CSL style might use (translator, edition, collection-title, chapter-number, genre,
    /// original-date, etc.), which a decode-then-reencode round trip through `CSLItem` would
    /// silently drop. Shares the exact two-phase resolution, stale-cache retry, and
    /// not-found/ambiguous error behavior with `fetchItemsForCitekeys` — only the final
    /// per-item representation (raw dict vs. `CSLItem`) differs.
    func fetchRawItemsForCitekeys(_ citekeys: [String]) async throws -> [[String: Any]] {
        guard !citekeys.isEmpty else { return [] }
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

        if !outcome.notFoundKeys.isEmpty || !outcome.ambiguousKeys.isEmpty {
            throw Self.notFoundOrAmbiguousError(notFound: outcome.notFoundKeys, ambiguous: outcome.ambiguousKeys)
        }

        return Array(outcome.items.values)
    }

    /// Fetch raw (undecoded) CSL-JSON items by citekey using BBT's `item.export` — unscoped,
    /// so BBT searches only the personal library ("My Library"). Fallback for when
    /// `item.pandoc_filter` resolution (`resolveRawViaPandocFilter`) fails for any reason.
    /// Mirrors the pre-existing `ExportService+Citations.swift` raw JSON-RPC call this
    /// replaced, so PDF export keeps its old fallback behavior when the new path can't run.
    fileprivate func fetchRawItemsForCitekeysViaExport(_ citekeys: [String]) async throws -> [[String: Any]] {
        guard !citekeys.isEmpty else { return [] }
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
            if resultString.isEmpty { return [] }
            guard let resultData = resultString.data(using: .utf8),
                  let parsed = try JSONSerialization.jsonObject(with: resultData) as? [[String: Any]] else {
                throw ZoteroError.invalidResponse("Failed to decode result string")
            }
            isConnected = true
            connectionError = nil
            return parsed
        } else if let resultArray = jsonObj["result"] as? [[String: Any]] {
            isConnected = true
            connectionError = nil
            return resultArray
        } else if let error = jsonObj["error"] as? [String: Any], let message = error["message"] as? String {
            throw ZoteroError.invalidResponse("BBT error: \(message)")
        } else {
            throw ZoteroError.invalidResponse("Unexpected result format in item.export")
        }
    }
}
