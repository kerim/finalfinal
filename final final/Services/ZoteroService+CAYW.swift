//
//  ZoteroService+CAYW.swift
//  final final
//

import Foundation

// MARK: - CAYW (Cite-As-You-Write) Picker

extension ZoteroService {

    /// Open Zotero's native CAYW citation picker
    /// Returns parsed citation data and CSL items for the selected references
    /// - Throws: ZoteroError.notRunning if Zotero is not available
    /// - Throws: ZoteroError.userCancelled if user closes picker without selecting
    func openCAYWPicker() async throws -> (ParsedCitation, [CSLItem]) {
        // Phase D UI-testing seam (plan §8.2 "the Zotero seam") -- see `ZoteroService.ping()`'s
        // matching mock branch. Returns a canned, deterministic citation instead of making the
        // two real network round trips, so the citation-bearing e2e scenario
        // (`UnifiedUndoE2ETests`) can exercise the CAYW insert path -- including racing it
        // against a structural op to confirm N1's `cancelPendingInsertions` port (Phase B)
        // actually cancels a genuinely in-flight request, not one that already resolved.
        if TestMode.isUITestingZoteroMockEnabled {
            let delayMs = TestMode.uiTestingZoteroMockDelayMilliseconds
            if delayMs > 0 {
                // A real in-flight window: without this, a test that fires a structural op
                // "during" the CAYW round trip would actually be racing against a response that
                // already returned (mock calls with no delay complete faster than any UI
                // interaction can follow up), proving nothing about cancellation.
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            }
            let (parsed, items) = try Self.mockCAYWResult()
            for item in items { loadItem(item) }
            isConnected = true
            connectionError = nil
            DebugLog.log(
                .zotero,
                "[ZoteroService] UI-testing Zotero mock: returning canned CAYW result for "
                    + "\(parsed.citekeys) after \(delayMs)ms delay"
            )
            return (parsed, items)
        }

        // Build CAYW URL with pandoc format and brackets
        guard let url = URL(string: "\(baseURL)/better-bibtex/cayw?format=pandoc&brackets=true") else {
            throw ZoteroError.invalidResponse("Invalid CAYW URL")
        }

        DebugLog.log(.zotero, "[ZoteroService] Opening CAYW picker...")

        do {
            // This call blocks until user selects references and closes Zotero's picker
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw ZoteroError.noResponse
            }

            let responseText = String(data: data, encoding: .utf8) ?? ""
            let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)

            DebugLog.log(.zotero, "[ZoteroService] CAYW response: '\(trimmed)'")

            // Empty response means user cancelled
            if trimmed.isEmpty {
                throw ZoteroError.userCancelled
            }

            // Parse the Pandoc citation syntax
            guard let parsed = parsePandocCitation(trimmed) else {
                throw ZoteroError.invalidResponse("Failed to parse CAYW response: \(trimmed)")
            }

            DebugLog.log(.zotero, "[ZoteroService] Parsed citekeys: \(parsed.citekeys)")

            // Fetch CSL items for the citekeys
            let items = try await fetchItemsForCitekeys(parsed.citekeys)

            DebugLog.log(.zotero, "[ZoteroService] Fetched \(items.count) CSL items")

            isConnected = true
            connectionError = nil

            return (parsed, items)
        } catch let error as ZoteroError {
            throw error
        } catch {
            isConnected = false
            throw ZoteroError.networkError(error)
        }
    }

    // MARK: - UI-testing mock (Phase D, plan §8.2)

    /// Citekey for the canned mock CAYW result. Distinctive enough that it can never collide
    /// with real fixture content, and greppable in a persisted `content.markdown`/
    /// `section.markdownContent` DB read -- the e2e suite's own ground-truth check for whether
    /// the mock citation actually landed (or, for the raced scenario, correctly did NOT land).
    ///
    /// Not `private`: `ZoteroService.fetchItemsForCitekeys`/`fetchItemsForCitekeysViaExport`
    /// (a different file) match requested citekeys against this to decide whether their own
    /// UI-testing mock branch can resolve them -- Swift's `private` doesn't extend to
    /// extensions/types in other files. See those functions' doc comments for why they need a
    /// mock branch at all (they're real network fetches `openCAYWPicker()`'s own mock bypasses,
    /// but callers like `BibliographySyncService` and `handleResolveCitekeys` reach them
    /// directly even when the citation was already cached via this file's mock `loadItem` call).
    static let mockCitekey = "ffe2emockcitation2026"

    private static let mockCSLJSON = """
    [{"id":"\(mockCitekey)","type":"article-journal","title":"Mock Citation For E2E Testing",\
    "author":[{"family":"Ffmocksurname","given":"Ada"}],"issued":{"date-parts":[[2026]]},\
    "container-title":"Journal of Automated Testing"}]
    """

    /// The canned mock CSL item, decoded via the SAME `JSONDecoder` path a real network
    /// response goes through, not a hand-built struct literal -- `CSLItem` defines a custom
    /// `init(from decoder:)`, which suppresses Swift's synthesized memberwise initializer, so
    /// decoding from a literal CSL-JSON string is both the simplest and the most faithful way to
    /// construct one here. Not `private`: shared with `ZoteroService.fetchItemsForCitekeys`/
    /// `fetchItemsForCitekeysViaExport`'s own mock branches (see `mockCitekey`'s doc comment).
    static func mockCSLItem() throws -> CSLItem {
        guard let data = mockCSLJSON.data(using: .utf8) else {
            throw ZoteroError.invalidResponse("UI-testing Zotero mock: literal CSL-JSON was not valid UTF-8")
        }
        guard let item = try JSONDecoder().decode([CSLItem].self, from: data).first else {
            throw ZoteroError.invalidResponse("UI-testing Zotero mock: canned CSL-JSON decoded to no items")
        }
        return item
    }

    /// Canned CAYW result for the mock path above: one distinctive, resolvable citation.
    private static func mockCAYWResult() throws -> (ParsedCitation, [CSLItem]) {
        guard let parsed = parsePandocCitation("[@\(mockCitekey)]") else {
            throw ZoteroError.invalidResponse("UI-testing Zotero mock: failed to build parsed citation")
        }
        let item = try mockCSLItem()
        return (parsed, [item])
    }
}
