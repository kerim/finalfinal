//
//  SpellCheckService.swift
//  final final
//
//  Dual-provider dispatch: BuiltInProvider for spelling, LanguageToolProvider for grammar/style.
//  Coordinators call this; it routes to one or both providers based on user settings.
//

import AppKit

@MainActor
final class SpellCheckService {
    static let shared = SpellCheckService()

    struct TextSegment: Codable, Sendable {
        let text: String
        let from: Int
        let to: Int
        let blockId: Int?  // Paragraph ID for grouping related segments
    }

    struct SpellCheckResult: Codable, Sendable {
        let from: Int
        let to: Int
        let word: String
        let type: String
        let suggestions: [String]
        let message: String?
        let shortMessage: String?
        let ruleId: String?
        let isPicky: Bool
    }

    private let builtInProvider = BuiltInProvider()
    let languageToolProvider = LanguageToolProvider()

    private init() {}

    // MARK: - Document Tag Lifecycle

    func openDocument() {
        builtInProvider.openDocument()
    }

    func closeDocument() {
        builtInProvider.closeDocument()
    }

    /// Current LanguageTool connection status (for status bar display)
    var connectionStatus: LTConnectionStatus {
        languageToolProvider.connectionStatus
    }

    // MARK: - Dispatch

    func check(segments: [TextSegment]) async -> [SpellCheckResult] {
        let spellingOn = UserDefaults.standard.object(forKey: "isSpellingEnabled") == nil
            ? true : UserDefaults.standard.bool(forKey: "isSpellingEnabled")
        let grammarOn = UserDefaults.standard.object(forKey: "isGrammarEnabled") == nil
            ? true : UserDefaults.standard.bool(forKey: "isGrammarEnabled")

        var results: [SpellCheckResult] = []

        // Spelling: always use BuiltInProvider (macOS NSSpellChecker)
        if spellingOn {
            results.append(contentsOf: await builtInProvider.check(segments: segments))
        }

        // Grammar/style: use LanguageTool when configured and grammar is enabled
        if grammarOn && ProofingSettings.shared.mode.isLanguageTool {
            let ltResults = await languageToolProvider.check(segments: segments)
            results.append(contentsOf: ltResults.filter { $0.type != "spelling" })
        }

        // Post notification so status bar can update connection status
        NotificationCenter.default.post(name: .proofingConnectionStatusChanged, object: nil)
        return results
    }

    func learnWord(_ word: String) {
        builtInProvider.learnWord(word)
        languageToolProvider.learnWord(word)
    }

    func ignoreWord(_ word: String) {
        builtInProvider.ignoreWord(word)
        languageToolProvider.ignoreWord(word)
    }
}
