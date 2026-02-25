//
//  UpdateChecker.swift
//  final final
//
//  Service to check GitHub for new releases.
//

import AppKit
import Foundation

/// Result of an update check
enum UpdateStatus: Sendable {
    case upToDate
    case updateAvailable(version: String, url: URL)
    case error(String)
}

/// Minimal struct for decoding GitHub release response
private struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let htmlUrl: URL
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
    }
}

/// Service to check for app updates via GitHub releases API
actor UpdateChecker {

    /// GitHub API endpoint for latest release
    private let endpoint = "https://api.github.com/repos/kerim/finalfinal/releases/latest"

    /// Timeout for the request
    private let timeoutInterval: TimeInterval = 5.0

    // MARK: - Check

    /// Check GitHub for a newer release
    func check() async -> UpdateStatus {
        guard let url = URL(string: endpoint) else {
            return .error("Invalid URL")
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutInterval
        config.timeoutIntervalForResource = timeoutInterval
        let session = URLSession(configuration: config)

        var request = URLRequest(url: url)
        request.setValue("FinalFinal", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .error("Invalid response")
            }

            guard httpResponse.statusCode == 200 else {
                return .error("GitHub API returned \(httpResponse.statusCode)")
            }

            let decoder = JSONDecoder()
            let release = try decoder.decode(GitHubRelease.self, from: data)

            // Strip "v" prefix from tag (e.g., "v0.2.54" → "0.2.54")
            let remoteVersion = release.tagName.hasPrefix("v")
                ? String(release.tagName.dropFirst())
                : release.tagName

            let localVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0.0.0"

            // .numeric handles multi-digit segments correctly (e.g., 54 > 9)
            if localVersion.compare(remoteVersion, options: .numeric) == .orderedAscending {
                return .updateAvailable(version: remoteVersion, url: release.htmlUrl)
            } else {
                return .upToDate
            }
        } catch is DecodingError {
            return .error("Could not parse release info")
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                return .error("Connection timed out")
            case .notConnectedToInternet, .networkConnectionLost:
                return .error("No internet connection")
            default:
                return .error(error.localizedDescription)
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Alert Helpers

    /// Show alert when an update is available
    @MainActor static func showUpdateAlert(version: String, url: URL) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        let current = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        alert.informativeText = "Version \(version) is available. You are currently running version \(current)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    /// Show alert when already up to date
    @MainActor static func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "You're Up to Date"
        alert.informativeText = "You are running the latest version (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"))."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Show alert when check failed
    @MainActor static func showErrorAlert(_ message: String? = nil) {
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = message ?? "Could not check for updates. Please try again later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
