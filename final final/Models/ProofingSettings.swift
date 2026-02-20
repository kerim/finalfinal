//
//  ProofingSettings.swift
//  final final
//
//  Settings for proofing mode and LanguageTool configuration.
//

import Foundation

enum ProofingMode: String, Codable, CaseIterable, Identifiable {
    case builtIn = "builtIn"
    case languageToolFree = "languageToolFree"
    case languageToolPremium = "languageToolPremium"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .builtIn: return "Built-in (spelling only)"
        case .languageToolFree: return "LanguageTool Free (spelling + grammar)"
        case .languageToolPremium: return "LanguageTool Premium (spelling + grammar + style)"
        }
    }

    var baseURL: URL? {
        switch self {
        case .builtIn: return nil
        case .languageToolFree: return URL(string: "https://api.languagetool.org")
        case .languageToolPremium: return URL(string: "https://api.languagetoolplus.com")
        }
    }

    var requiresApiKey: Bool {
        self == .languageToolPremium
    }

    var isLanguageTool: Bool {
        self != .builtIn
    }
}

@MainActor @Observable
final class ProofingSettings {
    static let shared = ProofingSettings()

    var mode: ProofingMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "proofingMode") }
    }

    var pickyMode: Bool {
        didSet { UserDefaults.standard.set(pickyMode, forKey: "ltPickyMode") }
    }

    var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "ltLanguage") }
    }

    var disabledRules: [String] {
        didSet { UserDefaults.standard.set(disabledRules, forKey: "ltDisabledRules") }
    }

    var apiKey: String {
        get { KeychainHelper.load(key: "ltApiKey") ?? "" }
        set { KeychainHelper.save(key: "ltApiKey", value: newValue) }
    }

    private init() {
        let modeString = UserDefaults.standard.string(forKey: "proofingMode") ?? ProofingMode.builtIn.rawValue
        self.mode = ProofingMode(rawValue: modeString) ?? .builtIn
        self.pickyMode = UserDefaults.standard.bool(forKey: "ltPickyMode")
        self.language = UserDefaults.standard.string(forKey: "ltLanguage") ?? "auto"
        self.disabledRules = UserDefaults.standard.stringArray(forKey: "ltDisabledRules") ?? []
    }

    func disableRule(_ ruleId: String) {
        if !disabledRules.contains(ruleId) {
            disabledRules.append(ruleId)
        }
    }

    func enableRule(_ ruleId: String) {
        disabledRules.removeAll { $0 == ruleId }
    }
}
