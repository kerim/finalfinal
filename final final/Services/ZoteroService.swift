//
//  ZoteroService.swift
//  final final
//
//  Observable service for Zotero/Better BibTeX integration.
//  Uses JSON-RPC endpoint for on-demand search (not bulk export).
//

import Foundation

/// Zotero connection errors
enum ZoteroError: LocalizedError {
    case notRunning
    case noResponse
    case invalidResponse(String)
    case networkError(Error)

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
        }
    }
}

/// JSON-RPC response wrapper for BBT item.search
private struct JSONRPCResponse: Decodable {
    let jsonrpc: String
    let result: [CSLItem]?
    let error: JSONRPCError?
}

private struct JSONRPCError: Decodable {
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
    private var baseURL: URL {
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

    // MARK: - API Methods

    /// Check if Zotero is running and Better BibTeX is accessible
    /// Uses the cayw?probe=true endpoint which returns "ready" when BBT is available
    func ping() async -> Bool {
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

            #if DEBUG
            // Debug: Print raw JSON response (first item only) to diagnose date format
            if let jsonObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = jsonObj["result"] as? [[String: Any]],
               let firstItem = result.first {
                print("[ZoteroService] DEBUG - First item raw JSON:")
                print("  id: \(firstItem["id"] ?? "nil")")
                print("  issued: \(firstItem["issued"] ?? "nil")")
                print("  citation-key: \(firstItem["citation-key"] ?? "nil")")
            }
            #endif

            // Decode JSON-RPC response
            let decoder = JSONDecoder()
            let rpcResponse = try decoder.decode(JSONRPCResponse.self, from: data)

            if let rpcError = rpcResponse.error {
                throw ZoteroError.invalidResponse("JSON-RPC error: \(rpcError.message)")
            }

            let items = rpcResponse.result ?? []

            #if DEBUG
            // Debug: Check if dates decoded properly
            if let firstItem = items.first {
                print("[ZoteroService] DEBUG - First decoded item:")
                print("  citekey: \(firstItem.citekey)")
                print("  issued: \(String(describing: firstItem.issued))")
                print("  year: \(firstItem.year)")
            }
            #endif

            // Cache results by citekey for later lookup
            for item in items {
                itemsByKey[item.citekey] = item
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

    /// Get a single item by citekey (from cache)
    func getItem(citekey: String) -> CSLItem? {
        itemsByKey[citekey]
    }

    /// Check if a citekey exists in the cache
    func hasItem(citekey: String) -> Bool {
        itemsByKey[citekey] != nil
    }

    /// Get multiple items by citekeys (from cache)
    func getItems(citekeys: [String]) -> [CSLItem] {
        citekeys.compactMap { itemsByKey[$0] }
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
            print("[ZoteroService] Failed to encode CSL-JSON: \(error)")
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
            print("[ZoteroService] Failed to encode cached items: \(error)")
            return "[]"
        }
    }

    /// Clear cached data
    func clearCache() {
        itemsByKey = [:]
    }
}
