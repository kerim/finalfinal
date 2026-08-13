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
}
