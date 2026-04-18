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

        // Spelling from BuiltInProvider (macOS NSSpellChecker)
        var spellingResults: [SpellCheckResult] = []
        if spellingOn {
            spellingResults = await builtInProvider.check(segments: segments)
        }

        // Grammar/style from LanguageTool when configured and grammar is enabled
        var ltResults: [SpellCheckResult] = []
        if grammarOn && ProofingSettings.shared.mode.isLanguageTool {
            let raw = await languageToolProvider.check(segments: segments)
            let spellingDropped = raw.filter { $0.type == "spelling" }
            ltResults = raw.filter { $0.type != "spelling" }
            DebugLog.log(.proofing,
                "[Dispatch] LT post-filter: total=\(raw.count) " +
                "droppedSpellingBucket=\(spellingDropped.count) kept=\(ltResults.count)")
            if !spellingDropped.isEmpty {
                let sample = spellingDropped.prefix(10).map { "\($0.word)[\($0.ruleId ?? "?")]" }
                DebugLog.log(.proofing, "[Dispatch] spellingBucket sample: \(sample.joined(separator: ", "))")
            }
        }

        // When LT is active, suppress NSSpellChecker results whose range overlaps any LT
        // result. Keeps the underline colour and click-popup in agreement — otherwise the
        // word shows LT's blue underline but clicking opens NSSpellChecker's spell menu.
        if !ltResults.isEmpty {
            let before = spellingResults.count
            spellingResults = spellingResults.filter { spelling in
                !ltResults.contains { grammar in
                    spelling.from < grammar.to && grammar.from < spelling.to
                }
            }
            DebugLog.log(.proofing,
                "[Dispatch] spelling/LT overlap suppressed: \(before - spellingResults.count) " +
                "of \(before) spelling results")
        }

        var results: [SpellCheckResult] = []
        results.append(contentsOf: spellingResults)
        results.append(contentsOf: ltResults)

        var spellingCount = 0
        var grammarCount = 0
        var styleCount = 0
        for r in results {
            switch r.type {
            case "spelling": spellingCount += 1
            case "grammar": grammarCount += 1
            case "style": styleCount += 1
            default: break
            }
        }
        DebugLog.log(.proofing,
            "[Dispatch] final returned: total=\(results.count) " +
            "spelling=\(spellingCount) grammar=\(grammarCount) style=\(styleCount)")

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
