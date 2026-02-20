//
//  SpellCheckService.swift
//  final final
//
//  Dispatches proofing requests to the active provider.
//  Coordinators call this; it delegates to BuiltInProvider or LanguageToolProvider.
//

import AppKit

@MainActor
final class SpellCheckService {
    static let shared = SpellCheckService()

    struct TextSegment: Codable, Sendable {
        let text: String
        let from: Int
        let to: Int
    }

    struct SpellCheckResult: Codable, Sendable {
        let from: Int
        let to: Int
        let word: String
        let type: String
        let suggestions: [String]
        let message: String?
        let ruleId: String?
        let isPicky: Bool
    }

    private let builtInProvider = BuiltInProvider()
    let languageToolProvider = LanguageToolProvider()
    private(set) var activeProvider: ProofingProvider

    private init() {
        activeProvider = builtInProvider
    }

    // MARK: - Document Tag Lifecycle

    func openDocument() {
        builtInProvider.openDocument()
    }

    func closeDocument() {
        builtInProvider.closeDocument()
    }

    // MARK: - Provider Switching

    func setProvider(_ provider: ProofingProvider) {
        activeProvider = provider
    }

    func resetToBuiltIn() {
        activeProvider = builtInProvider
    }

    /// Switch provider based on current ProofingSettings mode
    func updateProviderForCurrentMode() {
        switch ProofingSettings.shared.mode {
        case .builtIn:
            activeProvider = builtInProvider
        case .languageToolFree, .languageToolPremium:
            activeProvider = languageToolProvider
        }
    }

    /// Current LanguageTool connection status (for status bar display)
    var connectionStatus: LTConnectionStatus {
        languageToolProvider.connectionStatus
    }

    // MARK: - Dispatch

    func check(segments: [TextSegment]) async -> [SpellCheckResult] {
        let results = await activeProvider.check(segments: segments)
        // Post notification so status bar can update connection status
        NotificationCenter.default.post(name: .proofingConnectionStatusChanged, object: nil)
        return results
    }

    func learnWord(_ word: String) {
        activeProvider.learnWord(word)
    }

    func ignoreWord(_ word: String) {
        activeProvider.ignoreWord(word)
    }
}
