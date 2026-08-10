//
//  ZoteroChecker.swift
//  final final
//
//  Service to check if Zotero + Better BibTeX is running.
//  Required for live citation support during export.
//

import Foundation

/// Status of Zotero + Better BibTeX
enum ZoteroStatus: Sendable, Equatable {
    case running
    case notRunning
    case betterBibTeXMissing
    case timeout
    case error(String)
}

/// Service to check Zotero availability
actor ZoteroChecker {

    /// Better BibTeX JSON-RPC endpoint (status check only, no side effects)
    /// Note: We use JSON-RPC instead of CAYW because CAYW triggers the citation picker UI
    private let statusEndpoint = "http://127.0.0.1:23119/better-bibtex/json-rpc"

    /// Timeout for connection (fast since it's localhost)
    private let timeoutInterval: TimeInterval = 2.0

    // MARK: - Status Check

    /// Check if Zotero with Better BibTeX is running
    ///
    /// Uses `URLSession.shared` with a per-request timeout, matching every other Zotero
    /// network call in this codebase (`ZoteroService`, `ZoteroService+CAYW`,
    /// `ZoteroService+LibraryScope` — none of which construct their own `URLSession`). This
    /// used to build its own ad-hoc `URLSession(configuration: .ephemeral)` instead, which is
    /// NOT just a cosmetic difference: a custom-configured `URLSession` does not automatically
    /// pick up classes registered via `URLProtocol.registerClass(_:)` the way `URLSession.shared`
    /// does, so this call was silently unmockable by `MockBBTURLProtocol` (the shared test
    /// double every other Zotero-network test in this codebase relies on) — any test exercising
    /// this path actually hit the real, local Zotero/BBT install (or a real connection failure)
    /// regardless of what the test intended to simulate. Switching to `URLSession.shared`
    /// fixes that silently-broken test seam by aligning with the codebase's one established,
    /// working pattern for testable Zotero networking.
    func check() async -> ZoteroStatus {
        guard let url = URL(string: statusEndpoint) else {
            return .error("Invalid URL")
        }

        // Minimal JSON-RPC request to check if BBT is responding
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutInterval
        request.httpBody = Data(#"{"jsonrpc":"2.0","method":"item.search","params":{"query":""},"id":1}"#.utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .notRunning
            }

            switch httpResponse.statusCode {
            case 200:
                // Check if response contains valid JSON-RPC result
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["result"] != nil || json["error"] != nil {
                    return .running
                }
                return .running
            case 404:
                // Zotero running but Better BibTeX not installed or not at expected path
                return .betterBibTeXMissing
            default:
                DebugLog.log(.zotero, "[ZoteroChecker] Unexpected status code: \(httpResponse.statusCode)")
                return .notRunning
            }
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                return .timeout
            case .cannotConnectToHost, .networkConnectionLost:
                return .notRunning
            default:
                DebugLog.log(.zotero, "[ZoteroChecker] URL error: \(error.code.rawValue) - \(error.localizedDescription)")
                return .notRunning
            }
        } catch {
            DebugLog.log(.zotero, "[ZoteroChecker] Error: \(error.localizedDescription)")
            return .error(error.localizedDescription)
        }
    }

    /// Check with human-readable result message
    func checkWithMessage() async -> (status: ZoteroStatus, message: String) {
        let status = await check()
        let message: String

        switch status {
        case .running:
            message = "Zotero with Better BibTeX is running"
        case .notRunning:
            message = "Zotero is not running. Citations will not be resolved."
        case .betterBibTeXMissing:
            message = "Zotero is running but Better BibTeX is not detected. Install Better BibTeX for citation support."
        case .timeout:
            message = "Could not connect to Zotero (timeout). Make sure Zotero is running."
        case .error(let errorMessage):
            message = "Error checking Zotero: \(errorMessage)"
        }

        return (status, message)
    }
}

// MARK: - User Information

extension ZoteroChecker {

    /// Requirements text for display in UI
    static let requirements = """
        For live citation support:

        1. Install Zotero from https://www.zotero.org
        2. Install Better BibTeX plugin from https://retorque.re/zotero-better-bibtex/
        3. Make sure Zotero is running before exporting

        Without Zotero, citation keys like [@Smith2020] will appear as-is in the exported document.
        """

    /// Zotero download URL
    static let zoteroURL = URL(string: "https://www.zotero.org/download/")!

    /// Better BibTeX download URL
    static let betterBibTeXURL = URL(string: "https://retorque.re/zotero-better-bibtex/installation/")!
}
