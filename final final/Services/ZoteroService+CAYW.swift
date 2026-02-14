//
//  ZoteroService+CAYW.swift
//  final final
//

import AppKit
import Foundation

// MARK: - CAYW (Cite-As-You-Write) Picker

extension ZoteroService {

    /// Edit an existing citation by selecting items in Zotero
    /// Opens zotero://select to pre-select items, then gets current selection via CAYW
    /// - Parameter citekeys: The citekeys currently in the citation
    /// - Returns: Parsed citation and CSL items for the updated selection
    func editCitation(citekeys: [String]) async throws -> (ParsedCitation, [CSLItem]) {
        guard isConnected else {
            throw ZoteroError.notRunning
        }

        print("[ZoteroService] Editing citation with citekeys: \(citekeys)")

        // Build zotero://select URL to select items in Zotero's library pane
        // Format: zotero://select/items/@citekey1,@citekey2
        let keyList = citekeys.map { "@\($0)" }.joined(separator: ",")
        let selectURLString = "zotero://select/items/\(keyList)"

        guard let selectURL = URL(string: selectURLString) else {
            throw ZoteroError.invalidResponse("Invalid Zotero select URL")
        }

        print("[ZoteroService] Opening \(selectURLString)")

        // Open Zotero with items selected
        NSWorkspace.shared.open(selectURL)

        // Show dialog asking user to confirm when done editing in Zotero
        // This gives the user time to modify their selection (Cmd+click to add/remove)
        let shouldContinue = await MainActor.run { () -> Bool in
            let alert = NSAlert()
            alert.messageText = "Edit Citation"
            alert.informativeText = "Modify your selection in Zotero (Cmd+click to add/remove items), then click Done."
            alert.addButton(withTitle: "Done")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            return response == .alertFirstButtonReturn
        }

        guard shouldContinue else {
            throw ZoteroError.userCancelled
        }

        // Now call CAYW with ?selected=1 to get the current selection
        // This returns whatever is currently selected in Zotero (user may have modified)
        guard let url = URL(string: "\(baseURL)/better-bibtex/cayw?format=pandoc&brackets=true&selected=1") else {
            throw ZoteroError.invalidResponse("Invalid CAYW URL")
        }

        print("[ZoteroService] Fetching current selection via CAYW...")

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw ZoteroError.noResponse
            }

            let responseText = String(data: data, encoding: .utf8) ?? ""
            let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)

            print("[ZoteroService] CAYW selected response: '\(trimmed)'")

            // Empty response means no selection
            if trimmed.isEmpty {
                throw ZoteroError.userCancelled
            }

            // Parse the Pandoc citation syntax
            guard let parsed = parsePandocCitation(trimmed) else {
                throw ZoteroError.invalidResponse("Failed to parse CAYW response: \(trimmed)")
            }

            print("[ZoteroService] Parsed citekeys from selection: \(parsed.citekeys)")

            // Fetch CSL items for the citekeys
            let items = try await fetchItemsForCitekeys(parsed.citekeys)

            print("[ZoteroService] Fetched \(items.count) CSL items")

            return (parsed, items)
        } catch let error as ZoteroError {
            throw error
        } catch {
            throw ZoteroError.networkError(error)
        }
    }

    /// Open Zotero's native CAYW citation picker
    /// Returns parsed citation data and CSL items for the selected references
    /// - Throws: ZoteroError.notRunning if Zotero is not available
    /// - Throws: ZoteroError.userCancelled if user closes picker without selecting
    func openCAYWPicker() async throws -> (ParsedCitation, [CSLItem]) {
        // Build CAYW URL with pandoc format and brackets
        guard let url = URL(string: "\(baseURL)/better-bibtex/cayw?format=pandoc&brackets=true") else {
            throw ZoteroError.invalidResponse("Invalid CAYW URL")
        }

        print("[ZoteroService] Opening CAYW picker...")

        do {
            // This call blocks until user selects references and closes Zotero's picker
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw ZoteroError.noResponse
            }

            let responseText = String(data: data, encoding: .utf8) ?? ""
            let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)

            print("[ZoteroService] CAYW response: '\(trimmed)'")

            // Empty response means user cancelled
            if trimmed.isEmpty {
                throw ZoteroError.userCancelled
            }

            // Parse the Pandoc citation syntax
            guard let parsed = parsePandocCitation(trimmed) else {
                throw ZoteroError.invalidResponse("Failed to parse CAYW response: \(trimmed)")
            }

            print("[ZoteroService] Parsed citekeys: \(parsed.citekeys)")

            // Fetch CSL items for the citekeys
            let items = try await fetchItemsForCitekeys(parsed.citekeys)

            print("[ZoteroService] Fetched \(items.count) CSL items")

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
