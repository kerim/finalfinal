//
//  ZoteroService.swift
//  final final
//
//  Observable service for Zotero/Better BibTeX integration.
//  Uses JSON-RPC endpoint for on-demand search (not bulk export).
//

import Foundation
import AppKit

/// Zotero connection errors
enum ZoteroError: LocalizedError {
    case notRunning
    case noResponse
    case invalidResponse(String)
    case networkError(Error)
    case userCancelled

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Zotero is not running or Better BibTeX is not installed"
        case .noResponse:
            return "No response from Zotero"
        case .invalidResponse(let message):
            return "Invalid response: \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .userCancelled:
            return "User cancelled citation selection"
        }
    }
}

// MARK: - Pandoc Citation Parsing

/// A single citation entry within a Pandoc citation bracket
struct CitationEntry {
    let citekey: String
    let prefix: String?
    let locator: String?
    let suffix: String?
    let suppressAuthor: Bool
}

/// Parsed Pandoc citation bracket containing one or more entries
struct ParsedCitation {
    let rawSyntax: String
    let entries: [CitationEntry]

    /// All citekeys in this citation
    var citekeys: [String] { entries.map { $0.citekey } }

    /// JSON-encoded locators array (for web API compatibility)
    var locatorsJSON: String {
        let locators = entries.map { $0.locator ?? "" }
        guard let data = try? JSONSerialization.data(withJSONObject: locators),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}

/// Parse a Pandoc-format citation string from CAYW
/// Handles: [@key], [@key, p. 45], [see @a; @b], [-@key]
func parsePandocCitation(_ pandoc: String) -> ParsedCitation? {
    let trimmed = pandoc.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // Must start and end with brackets
    guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else { return nil }

    let inner = String(trimmed.dropFirst().dropLast())
    guard inner.contains("@") else { return nil }

    // Split by semicolon for multiple citations
    let parts = inner.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }

    let entries = parts.compactMap { parseCitationEntry(from: $0) }

    guard !entries.isEmpty else { return nil }

    return ParsedCitation(rawSyntax: trimmed, entries: entries)
}

/// Parse a single semicolon-delimited part of a Pandoc citation bracket into a `CitationEntry`.
/// Returns `nil` when the part has no `@` or the citekey after `@` is empty — both map to the
/// `continue` in the original inline loop, silently skipping the part.
private func parseCitationEntry(from part: String) -> CitationEntry? {
    // Find the @ symbol
    guard let atIndex = part.firstIndex(of: "@") else { return nil }

    // Check for prefix before @
    let beforeAt = String(part[..<atIndex]).trimmingCharacters(in: .whitespaces)
    let (prefix, suppressAuthor) = citationPrefixAndSuppression(beforeAt: beforeAt)

    // Parse citekey and locator after @
    let afterAt = String(part[part.index(after: atIndex)...])

    let citekey = leadingCitekey(in: afterAt)
    guard !citekey.isEmpty else { return nil }

    let remainder = String(afterAt.dropFirst(citekey.count))

    // Check for locator after comma
    var locator: String?
    let suffix: String? = nil

    if remainder.hasPrefix(",") {
        let locatorPart = String(remainder.dropFirst()).trimmingCharacters(in: .whitespaces)
        if !locatorPart.isEmpty {
            locator = locatorPart
        }
    }

    return CitationEntry(
        citekey: citekey,
        prefix: prefix,
        locator: locator,
        suffix: suffix,
        suppressAuthor: suppressAuthor
    )
}

/// Determine the citation prefix and suppress-author flag from the text before `@`.
/// Handles: `-` (suppress, no prefix), empty (no prefix, not suppressed), a trailing `-`
/// like `"see -@key"` (suppress with the leading text as prefix), and any other non-empty
/// text (prefix, not suppressed).
private func citationPrefixAndSuppression(beforeAt: String) -> (prefix: String?, suppressAuthor: Bool) {
    if beforeAt == "-" {
        return (nil, true)
    } else if beforeAt.isEmpty {
        return (nil, false)
    } else if beforeAt.hasSuffix("-") {
        // "see -@key" pattern
        let prefix = String(beforeAt.dropLast()).trimmingCharacters(in: .whitespaces)
        return (prefix, true)
    } else {
        return (beforeAt, false)
    }
}

/// Accumulate the leading run of citekey characters (alphanumeric, `:`, `.`, `-`, `_`) from
/// the text immediately after `@`, stopping at the first character that isn't part of a
/// citekey.
private func leadingCitekey(in afterAt: String) -> String {
    var citekey = ""
    for char in afterAt {
        if isCitekeyCharacter(char) {
            citekey.append(char)
        } else {
            break
        }
    }
    return citekey
}

/// Whether `char` may appear in a Pandoc citekey (alphanumeric, `:`, `.`, `-`, `_`).
private func isCitekeyCharacter(_ char: Character) -> Bool {
    char.isLetter || char.isNumber || char == ":" || char == "." || char == "-" || char == "_"
}

/// JSON-RPC response wrapper for BBT item.search
private struct JSONRPCResponse: Decodable {
    let jsonrpc: String
    let result: [CSLItem]?
    let error: JSONRPCError?
}

// Not `private`: also decoded by `GroupsRPCResponse` in ZoteroService+LibraryScope.swift, a
// different file — Swift's `private` doesn't extend to extensions/types in other files.
struct JSONRPCError: Decodable {
    let code: Int
    let message: String
}

@MainActor
@Observable
final class ZoteroService {
    // MARK: - Singleton

    /// Thread-safe singleton storage
    private static var _shared: ZoteroService?

    /// Shared singleton instance (actor-safe initialization)
    static var shared: ZoteroService {
        if _shared == nil {
            _shared = ZoteroService()
        }
        return _shared!
    }

    // MARK: - Configuration

    /// Better BibTeX HTTP server port (default)
    private let bbtPort = 23119

    /// Base URL for Better BibTeX API
    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(bbtPort)")!
    }

    // MARK: - State

    /// Whether connected to Zotero
    var isConnected: Bool = false

    /// Last connection error
    var connectionError: String?

    /// Last successful ping time
    var lastPingTime: Date?

    // MARK: - Cache

    /// CSL items indexed by citekey (populated by search results)
    private var itemsByKey: [String: CSLItem] = [:]

    /// Session cache of libraries known to Better BibTeX (from `user.groups`) — the
    /// personal library plus every group/shared library the user belongs to. Populated
    /// lazily by `fetchLibraries()`; pass `forceRefresh: true` there to bypass this cache
    /// (a group could be joined/left mid-session). No automatic polling.
    /// Not `private`: `fetchLibraries()` lives in `ZoteroService+LibraryScope.swift`, a
    /// different file, and Swift's `private` doesn't extend to extensions in other files.
    var cachedLibraries: [ZoteroLibrary]?

    // MARK: - API Methods

    /// Check if Zotero is running and Better BibTeX is accessible
    /// Uses the cayw?probe=true endpoint which returns "ready" when BBT is available
    func ping() async -> Bool {
        // Phase D UI-testing seam (plan §8.2 "the Zotero seam") -- lets a citation-bearing e2e
        // scenario exercise the CAYW insert path without a real running Zotero. See
        // `openCAYWPicker()`'s matching mock branch and `TestMode.isUITestingZoteroMockEnabled`'s
        // own doc comment for why this is its own flag, not folded into the general UI-testing
        // flag every other test relies on `ping()` genuinely failing under.
        if TestMode.isUITestingZoteroMockEnabled {
            isConnected = true
            lastPingTime = Date()
            connectionError = nil
            return true
        }

        guard let url = URL(string: "\(baseURL)/better-bibtex/cayw?probe=true") else {
            return false
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                isConnected = false
                return false
            }

            // BBT returns "ready" when available
            let responseText = String(data: data, encoding: .utf8) ?? ""
            let connected = responseText.trimmingCharacters(in: .whitespacesAndNewlines) == "ready"

            isConnected = connected
            if connected {
                lastPingTime = Date()
                connectionError = nil
            }
            return connected
        } catch {
            isConnected = false
            connectionError = error.localizedDescription
            return false
        }
    }

    /// Folds a freshly probed `ZoteroStatus` (from `ZoteroChecker.check()`, run during an
    /// export preflight or export) into this service's cached connection state, so UI reading
    /// `isConnected` doesn't keep showing a stale "connected" long after Zotero went away.
    func applyProbedStatus(_ status: ZoteroStatus) {
        switch status {
        case .running:
            isConnected = true
            connectionError = nil
            lastPingTime = Date()
        case .notRunning, .betterBibTeXMissing, .timeout, .error:
            isConnected = false
            connectionError = ExportService.zoteroPreflightReason(for: status)
        }
    }

    /// Connect to Zotero - just verifies BBT is running via ping
    func connect() async throws {
        let connected = await ping()
        if !connected {
            throw ZoteroError.notRunning
        }
    }

    /// Search Zotero library via JSON-RPC item.search
    /// Returns CSL-JSON items matching the query
    func search(query: String) async throws -> [CSLItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return []
        }

        guard let url = URL(string: "\(baseURL)/better-bibtex/json-rpc") else {
            throw ZoteroError.invalidResponse("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build JSON-RPC request
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "item.search",
            "params": [query]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw ZoteroError.invalidResponse("Failed to serialize request: \(error)")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw ZoteroError.noResponse
            }

            // Decode JSON-RPC response
            let decoder = JSONDecoder()
            let rpcResponse = try decoder.decode(JSONRPCResponse.self, from: data)

            if let rpcError = rpcResponse.error {
                throw ZoteroError.invalidResponse("JSON-RPC error: \(rpcError.message)")
            }

            let items = rpcResponse.result ?? []

            // Cache results by `id` (BBT's KeyManager key), not `item.citekey`
            // (== `citationKey ?? id`) — same rationale as `fetchItemsForCitekeys`/`loadItem`.
            // Falls back to `citekey` only if `id` is empty. (No known call sites — kept
            // correct rather than left as a landmine.)
            for item in items {
                let key = item.id.isEmpty ? item.citekey : item.id
                itemsByKey[key] = item
            }

            isConnected = true
            connectionError = nil

            return items
        } catch let error as DecodingError {
            throw ZoteroError.invalidResponse("Failed to decode: \(error.localizedDescription)")
        } catch let error as ZoteroError {
            throw error
        } catch {
            isConnected = false
            throw ZoteroError.networkError(error)
        }
    }

    /// Fetch items by citekey, decoded into `CSLItem`, scoped in two phases so items in
    /// shared/group libraries resolve correctly. See `ZoteroService+LibraryScope.swift` for
    /// the full two-phase design (`resolveRawViaPandocFilter`) shared with
    /// `fetchRawItemsForCitekeys` below.
    ///
    /// Throws `ZoteroError.invalidResponse("BBT error: not found in any library: ...")` (or
    /// `"ambiguous across libraries: ..."`, naming only the unresolved keys) if any requested
    /// citekey never resolves — this must surface, not be silently dropped, since it's the
    /// only visible sign of a real typo or deleted Zotero item (the exact "Citation Error"
    /// alert from the original bug report). Whatever DID resolve is cached before the throw,
    /// so a caller that retries later doesn't re-fetch citekeys that already succeeded.
    ///
    /// If the two-phase resolution path fails for ANY reason — network/transport failure,
    /// non-200, malformed JSON-RPC envelope, a JSON-RPC error object, or a `CSLItem` decode
    /// throw — falls back to the old unscoped `item.export` call (`fetchItemsForCitekeysViaExport`),
    /// logged with the reason. A `CancellationError`/cancelled `URLError` is rethrown directly,
    /// never treated as "the new path failed."
    /// Caches each of `items` under whichever requested citekey it matches (case-insensitively
    /// against the item's CSL `id`), not under `item.citekey` (== `citationKey ?? id`). BBT
    /// resolves items by its own KeyManager key (surfaced as CSL `id`) but can report a
    /// different `citation-key` for the same item (e.g. a stale legacy `Citation Key:` line
    /// left in the item's Zotero Extra field from pre-Zotero-8 Better BibTeX) — caching under
    /// `citationKey` would store the item under a name `getItem`/`getItems`/`cslJSONForCitekeys`
    /// never look it up by, since those are called with the citekey the document/editor
    /// actually asked for. Shared by both fetch paths below.
    private func cacheItems(_ items: [CSLItem], forRequestedCitekeys requested: [String]) {
        var itemsByID: [String: CSLItem] = [:]
        for item in items where itemsByID[item.id.lowercased()] == nil {
            itemsByID[item.id.lowercased()] = item
        }
        for key in requested {
            if let item = itemsByID[key.lowercased()] {
                itemsByKey[key] = item
            }
        }
    }

    func fetchItemsForCitekeys(_ citekeys: [String]) async throws -> [CSLItem] {
        guard !citekeys.isEmpty else { return [] }
        let requested = Self.orderedUniqueCitekeys(citekeys)

        let outcome: PandocFilterRawOutcome
        var items: [CSLItem] = []
        do {
            outcome = try await resolveRawViaPandocFilter(requested)
            items = try outcome.items.values.map { try Self.decodeCSLItem(from: $0) }
        } catch {
            if Self.isCancellation(error) { throw error }
            DebugLog.log(
                .zotero,
                "[ZoteroService] item.pandoc_filter resolution failed (\(error)) — falling back to unscoped item.export"
            )
            return try await fetchItemsForCitekeysViaExport(requested)
        }

        // Cache by the citekey string actually REQUESTED (matched case-insensitively against
        // each item's CSL `id`), not by `item.citekey` (== `citationKey ?? id`). BBT resolves
        // items by its own KeyManager key (surfaced as CSL `id`) but can report a different
        // `citation-key` for the same item (e.g. a stale legacy `Citation Key:` line left in
        // the item's Zotero Extra field from pre-Zotero-8 Better BibTeX) — caching under
        // `citationKey` would store the item under a name `getItem`/`getItems`/
        // `cslJSONForCitekeys` never look it up by, since those are called with the citekey the
        // document/editor actually asked for. `outcome.items` is keyed by `id` (see
        // `parsePandocFilterResponseRaw`), so match each decoded item back to its raw `id` to
        // find which requested key(s) it resolved.
        cacheItems(items, forRequestedCitekeys: requested)
        isConnected = true
        connectionError = nil

        if !outcome.notFoundKeys.isEmpty || !outcome.ambiguousKeys.isEmpty {
            throw Self.notFoundOrAmbiguousError(notFound: outcome.notFoundKeys, ambiguous: outcome.ambiguousKeys)
        }

        return items
    }

    /// Fetch items by citekey using BBT's `item.export` — unscoped, so BBT searches only the
    /// personal library ("My Library"). This is the pre-fix behavior, kept as the fallback for
    /// when `item.pandoc_filter` resolution (`resolveRawViaPandocFilter`) fails.
    private func fetchItemsForCitekeysViaExport(_ citekeys: [String]) async throws -> [CSLItem] {
        guard !citekeys.isEmpty else { return [] }
        let request = try makeExportRequest(citekeys: citekeys)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw ZoteroError.noResponse
            }

            let items: [CSLItem]
            switch try Self.decodeExportResult(from: data) {
            case .noItems:
                // Empty result payload — leave connection state untouched, matching the
                // pre-refactor early `return []` for an empty string/array result.
                return []
            case .items(let decoded):
                items = decoded
            }

            // Cache by the citekey string actually REQUESTED (matched case-insensitively against
            // each item's CSL `id`), not by `item.citekey` (== `citationKey ?? id`) — same
            // rationale as `fetchItemsForCitekeys` above: BBT resolves by its own KeyManager key
            // (surfaced as CSL `id`) but can report a different `citation-key` for the same item.
            cacheItems(items, forRequestedCitekeys: citekeys)

            isConnected = true
            connectionError = nil

            return items
        } catch let error as DecodingError {
            // Malformed/unexpected response shape, not a network failure — report distinctly
            // from `.networkError`, matching `search()`'s handling of the same error type.
            throw ZoteroError.invalidResponse("Failed to decode: \(error.localizedDescription)")
        } catch let error as ZoteroError {
            throw error
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
            || urlError.code == .networkConnectionLost {
            isConnected = false
            throw ZoteroError.notRunning
        } catch {
            throw ZoteroError.networkError(error)
        }
    }

    /// Build the `item.export` JSON-RPC request for `fetchItemsForCitekeysViaExport`. Runs
    /// before the network `do` block, exactly where this code sat inline before the refactor,
    /// so a thrown `ZoteroError` here is not caught by that block's catch clauses.
    private func makeExportRequest(citekeys: [String]) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)/better-bibtex/json-rpc") else {
            throw ZoteroError.invalidResponse("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.itemExportTimeout

        // item.export returns CSL-JSON for specified citekeys
        // Note: BBT requires the full translator name "Better CSL JSON" (not "csljson")
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "item.export",
            "params": [citekeys, "Better CSL JSON"]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw ZoteroError.invalidResponse("Failed to serialize request: \(error)")
        }

        return request
    }

    /// Result of decoding an `item.export` JSON-RPC response body.
    enum ExportDecodeResult {
        /// Empty result payload (empty string or empty array) — the caller returns `[]` and
        /// leaves connection state (`isConnected`/`connectionError`) untouched, matching the
        /// pre-refactor early-return behavior. A non-empty `result` string that decodes to an
        /// empty CSL-item array does NOT take this case.
        case noItems
        case items([CSLItem])
    }

    /// Decode the JSON-RPC envelope from `item.export`: CSL-JSON as a string, CSL-JSON as an
    /// array, a JSON-RPC error object, or an unrecognized shape. Must be called inside the
    /// network `do` block in `fetchItemsForCitekeysViaExport` — a `DecodingError` from the CSL
    /// decode here needs to fall through to that block's
    /// `catch let error as DecodingError { throw ZoteroError.invalidResponse(...) }`, matching
    /// how `search()` reports decode failures distinctly from network failures, while a
    /// `ZoteroError` thrown here needs to pass through
    /// `catch let error as ZoteroError { throw error }` unwrapped.
    nonisolated static func decodeExportResult(from data: Data) throws -> ExportDecodeResult {
        // item.export returns a JSON-RPC wrapper with CSL-JSON in result
        guard let jsonObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ZoteroError.invalidResponse("Invalid JSON-RPC response")
        }

        // Try result as string first (CSL-JSON encoded as string)
        if let resultString = jsonObj["result"] as? String {
            // Handle empty string (no items found)
            if resultString.isEmpty {
                return .noItems
            }
            guard let resultData = resultString.data(using: .utf8) else {
                throw ZoteroError.invalidResponse("Failed to decode result string")
            }
            let items = try JSONDecoder().decode([CSLItem].self, from: resultData)
            return .items(items)
        }
        // Try result as array directly (CSL items as array)
        else if let resultArray = jsonObj["result"] as? [[String: Any]] {
            if resultArray.isEmpty {
                return .noItems
            }
            let resultData = try JSONSerialization.data(withJSONObject: resultArray)
            let items = try JSONDecoder().decode([CSLItem].self, from: resultData)
            return .items(items)
        }
        // Check for JSON-RPC error
        else if let error = jsonObj["error"] as? [String: Any],
                let message = error["message"] as? String {
            throw ZoteroError.invalidResponse("BBT error: \(message)")
        } else {
            throw ZoteroError.invalidResponse("Unexpected result format in item.export")
        }
    }

    /// Get a single item by citekey (from cache)
    ///
    /// Tries an exact match first, then falls back to a case-insensitive scan (a `.lowercased()`
    /// comparison — the same technique `cacheItems()` above uses at cache-write time). The
    /// fallback matters for the offline embedded-citations path (`loadItem` below): unlike
    /// `cacheItems()`, which caches a fetched item under the exact citekey string the document
    /// requested, `loadItem` caches by the CSL `id` as authored in citations.json, with no
    /// "requested" citekey available at write time to align casing with. A document citekey
    /// differing only in case from that `id` would otherwise miss here.
    func getItem(citekey: String) -> CSLItem? {
        if let exact = itemsByKey[citekey] {
            return exact
        }
        let normalized = citekey.lowercased()
        return itemsByKey.first { $0.key.lowercased() == normalized }?.value
    }

    /// Check if a citekey exists in the cache (case-insensitively — see `getItem`)
    func hasItem(citekey: String) -> Bool {
        getItem(citekey: citekey) != nil
    }

    /// Get multiple items by citekeys (from cache, case-insensitively — see `getItem`)
    func getItems(citekeys: [String]) -> [CSLItem] {
        citekeys.compactMap { getItem(citekey: $0) }
    }

    /// Generate CSL-JSON string for the given citekeys (for web citeproc)
    func cslJSONForCitekeys(_ citekeys: [String]) -> String {
        let items = getItems(citekeys: citekeys)
        guard !items.isEmpty else { return "[]" }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(items)
            return String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            DebugLog.log(.zotero, "[ZoteroService] Failed to encode CSL-JSON: \(error)")
            return "[]"
        }
    }

    /// Get all cached items
    var cachedItems: [CSLItem] {
        Array(itemsByKey.values)
    }

    /// Generate JSON string of cached items
    func cachedItemsJSON() -> String {
        let items = cachedItems
        guard !items.isEmpty else { return "[]" }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(items)
            return String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            DebugLog.log(.zotero, "[ZoteroService] Failed to encode cached items: \(error)")
            return "[]"
        }
    }

    /// Load a pre-resolved CSL item into the cache (for embedded citations)
    ///
    /// Caches by the CSL `id` (BBT's KeyManager key), not `item.citekey`
    /// (== `citationKey ?? id`) — same rationale as `fetchItemsForCitekeys` above: BBT
    /// resolves items by `id`, so that's the key `getItem`/`getItems`/`cslJSONForCitekeys`
    /// look up later. Falls back to `citekey` only if `id` is empty. A document citekey
    /// differing only in case from this `id` still resolves — `getItem`'s case-insensitive
    /// fallback (see above) covers it, since this offline path (unlike `cacheItems()`) has no
    /// "requested" citekey available here to align casing with up front.
    func loadItem(_ item: CSLItem) {
        let key = item.id.isEmpty ? item.citekey : item.id
        itemsByKey[key] = item
    }

    /// Clear cached data
    func clearCache() {
        itemsByKey = [:]
    }

}
