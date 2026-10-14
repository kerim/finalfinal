//
//  ZoteroService+ItemCache.swift
//  final final
//
//  Cached-item accessors (getItem/getItems/loadItem/clearCache and CSL-JSON encoding) for
//  ZoteroService, split out of ZoteroService.swift to keep that class's body under
//  SwiftLint's type_body_length limit. Mechanical move only -- no behavior change.
//

import Foundation

extension ZoteroService {
    /// Get a single item by citekey (from cache)
    ///
    /// Tries an exact match first, then falls back to a case-insensitive scan (a `.lowercased()`
    /// comparison — the same technique `cacheItems()` (ZoteroService.swift) uses at
    /// cache-write time). The fallback matters for the offline embedded-citations path
    /// (`loadItem` below): unlike `cacheItems()`, which caches a fetched item under the exact
    /// citekey string the document requested, `loadItem` caches by the CSL `id` as authored in
    /// citations.json, with no "requested" citekey available at write time to align casing
    /// with. A document citekey differing only in case from that `id` would otherwise miss here.
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
    /// (== `citationKey ?? id`) — same rationale as `fetchItemsForCitekeys` (ZoteroService.swift):
    /// BBT resolves items by `id`, so that's the key `getItem`/`getItems`/`cslJSONForCitekeys`
    /// look up later. Falls back to `citekey` only if `id` is empty. A document citekey
    /// differing only in case from this `id` still resolves — `getItem`'s case-insensitive
    /// fallback (see above) covers it, since this offline path (unlike `cacheItems()`) has no
    /// "requested" citekey available here to align casing with up front.
    func loadItem(_ item: CSLItem) {
        let key = item.id.isEmpty ? item.citekey : item.id
        itemsByKey[key] = item
        noteLibraryChanged()
    }

    /// Clear cached data
    func clearCache() {
        itemsByKey = [:]
        noteLibraryChanged()
    }

    /// Every write to `itemsByKey` ends here: bumps `itemsRevision` and tells the citation-prefill scheduler (if the app created one).
    func noteLibraryChanged() {
        itemsRevision &+= 1
        onLibraryChanged?()
    }
}
