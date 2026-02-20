# LanguageTool Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add LanguageTool as an optional proofing provider alongside the built-in NSSpellChecker, with three modes (built-in, LT Free, LT Premium), a Proofing preferences tab, and a click-triggered popover for grammar/style errors.

**Architecture:** Protocol-based `ProofingProvider` system where `SpellCheckService` dispatches to the active provider. `BuiltInProvider` wraps NSSpellChecker (spelling only). `LanguageToolProvider` makes HTTP POST requests to `/v2/check`. Web editors get a new popover UI for grammar/style errors alongside the existing context menu for spelling.

**Tech Stack:** Swift (URLSession, Keychain Services), TypeScript (shared popover module), SwiftUI (Proofing preferences pane)

**Design Doc:** `docs/plans/2026-02-20-languagetool-design.md`

---

### Task 1: ProofingProvider Protocol + BuiltInProvider

Extract the existing NSSpellChecker logic into a `BuiltInProvider` behind a `ProofingProvider` protocol. No behavior change — this is a refactor-only step.

**Files:**
- Create: `final final/Services/ProofingProvider.swift`
- Create: `final final/Services/BuiltInProvider.swift`
- Modify: `final final/Services/SpellCheckService.swift`

**Step 1: Create the ProofingProvider protocol**

Create `final final/Services/ProofingProvider.swift`:

```swift
//
//  ProofingProvider.swift
//  final final
//
//  Protocol for proofing backends (NSSpellChecker, LanguageTool, etc.)
//

import Foundation

@MainActor
protocol ProofingProvider {
    func check(segments: [SpellCheckService.TextSegment]) async -> [SpellCheckService.SpellCheckResult]
    func learnWord(_ word: String)
    func ignoreWord(_ word: String)
}
```

**Step 2: Update SpellCheckResult with new fields**

In `SpellCheckService.swift` (line 25-32), update the struct:

```swift
struct SpellCheckResult: Codable, Sendable {
    let from: Int
    let to: Int
    let word: String
    let type: String       // "spelling", "grammar", or "style"
    let suggestions: [String]
    let message: String?   // Grammar/style explanation (nil for spelling)
    let ruleId: String?    // LT rule ID (nil for built-in)
    let isPicky: Bool      // true for picky-mode-only matches
}
```

Update the existing `allResults.append(...)` in the `check()` method to include `ruleId: nil, isPicky: false`.

**Step 3: Extract BuiltInProvider**

Create `final final/Services/BuiltInProvider.swift` — move the NSSpellChecker logic out of SpellCheckService:

```swift
//
//  BuiltInProvider.swift
//  final final
//
//  Wraps NSSpellChecker for spelling-only proofing.
//

import AppKit

@MainActor
final class BuiltInProvider: ProofingProvider {
    private let checker = NSSpellChecker.shared
    private var documentTag: Int = 0

    func openDocument() {
        documentTag = NSSpellChecker.uniqueSpellDocumentTag()
    }

    func closeDocument() {
        checker.closeSpellDocument(withTag: documentTag)
        documentTag = 0
    }

    func check(segments: [SpellCheckService.TextSegment]) async -> [SpellCheckService.SpellCheckResult] {
        var allResults: [SpellCheckService.SpellCheckResult] = []

        for segment in segments {
            guard !Task.isCancelled else { return allResults }
            await Task.yield()

            let nsString = segment.text as NSString
            let range = NSRange(location: 0, length: nsString.length)

            var orthography: NSOrthography?
            var wordCount: Int = 0
            let results = checker.check(
                segment.text, range: range,
                types: NSTextCheckingAllTypes,
                options: [:],
                inSpellDocumentWithTag: documentTag,
                orthography: &orthography,
                wordCount: &wordCount)

            for result in results where result.resultType == .spelling {
                let word = nsString.substring(with: result.range)
                let jsFrom = segment.from + result.range.location
                let jsTo = segment.from + NSMaxRange(result.range)
                let suggestions = checker.guesses(
                    forWordRange: result.range, in: segment.text,
                    language: nil, inSpellDocumentWithTag: documentTag) ?? []
                allResults.append(SpellCheckService.SpellCheckResult(
                    from: jsFrom, to: jsTo, word: word,
                    type: "spelling", suggestions: suggestions,
                    message: nil, ruleId: nil, isPicky: false))
            }
        }
        return allResults
    }

    func learnWord(_ word: String) {
        checker.learnWord(word)
    }

    func ignoreWord(_ word: String) {
        checker.ignoreWord(word, inSpellDocumentWithTag: documentTag)
    }
}
```

**Step 4: Refactor SpellCheckService to delegate**

Replace `SpellCheckService.swift` to become a thin dispatcher:

```swift
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

    // MARK: - Dispatch

    func check(segments: [TextSegment]) async -> [SpellCheckResult] {
        await activeProvider.check(segments: segments)
    }

    func learnWord(_ word: String) {
        activeProvider.learnWord(word)
    }

    func ignoreWord(_ word: String) {
        activeProvider.ignoreWord(word)
    }
}
```

**Step 5: Run xcodegen and build**

```bash
cd /Users/niyaro/Documents/Code/ff-dev/spellcheck && xcodegen generate
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED. No behavior change — built-in provider is used by default.

**Step 6: Commit**

```bash
git add "final final/Services/ProofingProvider.swift" \
        "final final/Services/BuiltInProvider.swift" \
        "final final/Services/SpellCheckService.swift" \
        "final final.xcodeproj/project.pbxproj" \
        project.yml
git commit -m "Refactor SpellCheckService to protocol-based provider dispatch" \
           -m "Extract BuiltInProvider, add ProofingProvider protocol." \
           -m "No behavior change — built-in provider active by default."
```

---

### Task 2: Proofing Settings + Keychain Helper

Create the settings model for proofing mode, LT configuration, and Keychain storage for the API key.

**Files:**
- Create: `final final/Models/ProofingSettings.swift`
- Create: `final final/Services/KeychainHelper.swift`

**Step 1: Create ProofingSettings model**

Create `final final/Models/ProofingSettings.swift`:

```swift
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
```

**Step 2: Create KeychainHelper**

Create `final final/Services/KeychainHelper.swift`:

```swift
//
//  KeychainHelper.swift
//  final final
//
//  Simple Keychain wrapper for storing API keys.
//

import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.finalfinal.app"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var addQuery = query
        addQuery[kSecValueData] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

**Step 3: Build and verify**

```bash
xcodegen generate
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

**Step 4: Commit**

```bash
git add "final final/Models/ProofingSettings.swift" \
        "final final/Services/KeychainHelper.swift" \
        "final final.xcodeproj/project.pbxproj" \
        project.yml
git commit -m "Add ProofingSettings model and KeychainHelper" \
           -m "ProofingMode enum, UserDefaults persistence, Keychain for API key."
```

---

### Task 3: Proofing Preferences Pane

Add "Proofing" as a new tab in PreferencesView with mode picker, API key field, picky toggle, language picker, and disabled rules list.

**Files:**
- Create: `final final/Views/Preferences/ProofingPreferencesPane.swift`
- Modify: `final final/Views/Preferences/PreferencesView.swift` (lines 12-63)

**Step 1: Add the proofing tab to PreferencesTab enum**

In `PreferencesView.swift`, add `.proofing` case to the enum (line ~15) and corresponding `title`/`icon`:

```swift
case proofing

// In title:
case .proofing: return "Proofing"

// In icon:
case .proofing: return "textformat.abc"
```

Add the tab to the `TabView` body (after the goals tab):

```swift
ProofingPreferencesPane()
    .tabItem {
        Label(PreferencesTab.proofing.title, systemImage: PreferencesTab.proofing.icon)
    }
    .tag(PreferencesTab.proofing)
```

**Step 2: Create ProofingPreferencesPane**

Create `final final/Views/Preferences/ProofingPreferencesPane.swift`:

```swift
//
//  ProofingPreferencesPane.swift
//  final final
//
//  Preferences pane for spell/grammar checking mode and LanguageTool settings.
//

import SwiftUI

struct ProofingPreferencesPane: View {
    @State private var settings = ProofingSettings.shared
    @State private var apiKeyInput: String = ""
    @State private var connectionStatus: ConnectionTestStatus = .idle

    enum ConnectionTestStatus: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                providerSection
                if settings.mode.isLanguageTool {
                    languageToolOptionsSection
                }
                if !settings.disabledRules.isEmpty {
                    disabledRulesSection
                }
            }
            .padding()
        }
        .onAppear {
            apiKeyInput = settings.apiKey
        }
    }

    // MARK: - Provider Section

    @ViewBuilder
    private var providerSection: some View {
        GroupBox("Proofing Provider") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Provider", selection: $settings.mode) {
                    ForEach(ProofingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: settings.mode) { _, newMode in
                    NotificationCenter.default.post(
                        name: .proofingModeChanged, object: nil)
                }

                if settings.mode.requiresApiKey {
                    HStack {
                        Text("API Key:")
                        SecureField("Enter API key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 300)
                            .onChange(of: apiKeyInput) { _, newValue in
                                settings.apiKey = newValue
                            }
                        Button("Test Connection") {
                            testConnection()
                        }
                        .disabled(apiKeyInput.isEmpty || connectionStatus == .testing)
                        connectionStatusView
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - LanguageTool Options

    @ViewBuilder
    private var languageToolOptionsSection: some View {
        GroupBox("LanguageTool Options") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Picky mode (stricter style checks)", isOn: $settings.pickyMode)
                    .onChange(of: settings.pickyMode) { _, _ in
                        NotificationCenter.default.post(
                            name: .proofingSettingsChanged, object: nil)
                    }

                HStack {
                    Text("Language:")
                    Picker("", selection: $settings.language) {
                        Text("Auto-detect").tag("auto")
                        Divider()
                        Text("English").tag("en")
                        Text("English (US)").tag("en-US")
                        Text("English (UK)").tag("en-GB")
                        Text("French").tag("fr")
                        Text("German").tag("de")
                        Text("Spanish").tag("es")
                        Text("Portuguese").tag("pt")
                    }
                    .frame(width: 200)
                    .onChange(of: settings.language) { _, _ in
                        NotificationCenter.default.post(
                            name: .proofingSettingsChanged, object: nil)
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Disabled Rules

    @ViewBuilder
    private var disabledRulesSection: some View {
        GroupBox("Disabled Rules") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(settings.disabledRules, id: \.self) { ruleId in
                    HStack {
                        Text(ruleId)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Button {
                            settings.enableRule(ruleId)
                            NotificationCenter.default.post(
                                name: .proofingSettingsChanged, object: nil)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Re-enable this rule")
                    }
                }
                Text("Rules disabled via the editor context menu appear here. Click x to re-enable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    // MARK: - Connection Test

    @ViewBuilder
    private var connectionStatusView: some View {
        switch connectionStatus {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
                .controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func testConnection() {
        connectionStatus = .testing
        Task {
            guard let baseURL = settings.mode.baseURL else {
                connectionStatus = .failure("No server URL")
                return
            }
            let url = baseURL.appendingPathComponent("v2/check")
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            var body = "text=test&language=auto"
            if !settings.apiKey.isEmpty {
                body += "&apiKey=\(settings.apiKey)"
            }
            request.httpBody = body.data(using: .utf8)

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse {
                    switch httpResponse.statusCode {
                    case 200: connectionStatus = .success
                    case 401, 403: connectionStatus = .failure("Invalid API key")
                    default: connectionStatus = .failure("HTTP \(httpResponse.statusCode)")
                    }
                }
            } catch {
                connectionStatus = .failure("Unreachable")
            }
        }
    }
}
```

**Step 3: Add notification names**

Add these notification names wherever the project keeps its notification extensions (or create a new file if needed — check if there's an existing `Notification+Names.swift` or similar):

```swift
extension Notification.Name {
    static let proofingModeChanged = Notification.Name("proofingModeChanged")
    static let proofingSettingsChanged = Notification.Name("proofingSettingsChanged")
}
```

**Step 4: Build and verify**

```bash
xcodegen generate
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

Launch app, open Preferences, verify the Proofing tab appears with the mode picker.

**Step 5: Commit**

```bash
git add "final final/Views/Preferences/ProofingPreferencesPane.swift" \
        "final final/Views/Preferences/PreferencesView.swift" \
        "final final.xcodeproj/project.pbxproj" \
        project.yml
git commit -m "Add Proofing preferences tab" \
           -m "Mode picker, API key field with connection test, picky toggle," \
           -m "language picker, disabled rules list."
```

---

### Task 4: LanguageToolProvider HTTP Client

Create the LanguageTool provider that makes HTTP requests to `/v2/check`, consolidates segments, and maps offsets back to editor positions.

**Files:**
- Create: `final final/Services/LanguageToolProvider.swift`

**Step 1: Create LanguageToolProvider**

Create `final final/Services/LanguageToolProvider.swift`:

```swift
//
//  LanguageToolProvider.swift
//  final final
//
//  LanguageTool HTTP API provider for spelling + grammar + style checking.
//

import Foundation

enum LTConnectionStatus: Equatable {
    case connected
    case disconnected
    case authError
    case rateLimited
    case checking
}

@MainActor
final class LanguageToolProvider: ProofingProvider {
    private let settings = ProofingSettings.shared
    private var ignoredWords: Set<String> = []
    private(set) var connectionStatus: LTConnectionStatus = .disconnected

    // MARK: - ProofingProvider

    func check(segments: [SpellCheckService.TextSegment]) async -> [SpellCheckService.SpellCheckResult] {
        guard let baseURL = settings.mode.baseURL else { return [] }
        guard !segments.isEmpty else { return [] }

        connectionStatus = .checking

        // Consolidate segments into a single text with offset map
        let (fullText, offsetMap) = consolidateSegments(segments)

        // Build request
        let url = baseURL.appendingPathComponent("v2/check")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var params: [String] = [
            "text=\(urlEncode(fullText))",
            "language=\(urlEncode(settings.language))"
        ]
        if settings.pickyMode {
            params.append("level=picky")
        }
        if !settings.apiKey.isEmpty {
            params.append("apiKey=\(urlEncode(settings.apiKey))")
        }
        if !settings.disabledRules.isEmpty {
            params.append("disabledRules=\(urlEncode(settings.disabledRules.joined(separator: ",")))")
        }
        request.httpBody = params.joined(separator: "&").data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled else { return [] }

            guard let httpResponse = response as? HTTPURLResponse else {
                connectionStatus = .disconnected
                return []
            }

            switch httpResponse.statusCode {
            case 200:
                connectionStatus = .connected
            case 401, 403:
                connectionStatus = .authError
                return []
            case 429:
                connectionStatus = .rateLimited
                return []
            default:
                connectionStatus = .disconnected
                return []
            }

            return parseResponse(data: data, offsetMap: offsetMap, segments: segments)
        } catch {
            guard !Task.isCancelled else { return [] }
            connectionStatus = .disconnected
            return []
        }
    }

    func learnWord(_ word: String) {
        // Always add to macOS dictionary
        NSSpellChecker.shared.learnWord(word)
        ignoredWords.remove(word)

        // For Premium: also sync to LT cloud dictionary
        if settings.mode == .languageToolPremium && !settings.apiKey.isEmpty {
            Task {
                await syncWordToCloud(word: word, action: "add")
            }
        }
    }

    func ignoreWord(_ word: String) {
        ignoredWords.insert(word)
    }

    // MARK: - Segment Consolidation

    private func consolidateSegments(
        _ segments: [SpellCheckService.TextSegment]
    ) -> (String, [(index: Int, fullTextOffset: Int, segment: SpellCheckService.TextSegment)]) {
        var fullText = ""
        var offsetMap: [(index: Int, fullTextOffset: Int, segment: SpellCheckService.TextSegment)] = []

        for (i, segment) in segments.enumerated() {
            if !fullText.isEmpty {
                fullText += "\n\n"
            }
            offsetMap.append((index: i, fullTextOffset: fullText.utf16.count, segment: segment))
            fullText += segment.text
        }

        return (fullText, offsetMap)
    }

    // MARK: - Response Parsing

    private func parseResponse(
        data: Data,
        offsetMap: [(index: Int, fullTextOffset: Int, segment: SpellCheckService.TextSegment)],
        segments: [SpellCheckService.TextSegment]
    ) -> [SpellCheckService.SpellCheckResult] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let matches = json["matches"] as? [[String: Any]] else {
            return []
        }

        var results: [SpellCheckService.SpellCheckResult] = []

        for match in matches {
            guard let offset = match["offset"] as? Int,
                  let length = match["length"] as? Int,
                  length > 0 else { continue }

            // Find which segment this match belongs to
            guard let mapping = findSegment(for: offset, in: offsetMap) else { continue }

            let localOffset = offset - mapping.fullTextOffset
            let word = extractWord(from: mapping.segment.text, offset: localOffset, length: length)

            // Skip ignored words
            if ignoredWords.contains(word) { continue }

            // Map to editor positions
            let editorFrom = mapping.segment.from + localOffset
            let editorTo = mapping.segment.from + localOffset + length

            // Classify error type
            let type = classifyMatch(match)
            let isPicky = (match["ignoreForIncompleteSentence"] as? Bool) == true
                || (type == "style" && settings.pickyMode)

            // Extract suggestions
            let replacements = match["replacements"] as? [[String: Any]] ?? []
            let suggestions = replacements.compactMap { $0["value"] as? String }

            // Extract rule ID and message
            let rule = match["rule"] as? [String: Any]
            let ruleId = rule?["id"] as? String
            let message = match["message"] as? String

            results.append(SpellCheckService.SpellCheckResult(
                from: editorFrom, to: editorTo, word: word,
                type: type, suggestions: Array(suggestions.prefix(5)),
                message: message, ruleId: ruleId, isPicky: isPicky))
        }

        return results
    }

    private func findSegment(
        for offset: Int,
        in offsetMap: [(index: Int, fullTextOffset: Int, segment: SpellCheckService.TextSegment)]
    ) -> (index: Int, fullTextOffset: Int, segment: SpellCheckService.TextSegment)? {
        var best: (index: Int, fullTextOffset: Int, segment: SpellCheckService.TextSegment)?
        for mapping in offsetMap {
            if mapping.fullTextOffset <= offset {
                best = mapping
            } else {
                break
            }
        }
        return best
    }

    private func extractWord(from text: String, offset: Int, length: Int) -> String {
        let nsString = text as NSString
        let range = NSRange(location: offset, length: length)
        guard NSMaxRange(range) <= nsString.length else { return "" }
        return nsString.substring(with: range)
    }

    private func classifyMatch(_ match: [String: Any]) -> String {
        if let rule = match["rule"] as? [String: Any],
           let category = rule["category"] as? [String: Any],
           let categoryId = category["id"] as? String {
            if categoryId == "TYPOS" || categoryId == "SPELLING" {
                return "spelling"
            }
        }
        if let rule = match["rule"] as? [String: Any],
           let issueType = rule["issueType"] as? String {
            if issueType == "misspelling" {
                return "spelling"
            }
            if issueType == "style" || issueType == "typographical" {
                return "style"
            }
        }
        return "grammar"
    }

    // MARK: - Cloud Dictionary Sync

    private func syncWordToCloud(word: String, action: String) async {
        guard let baseURL = settings.mode.baseURL else { return }
        let url = baseURL.appendingPathComponent("v2/words/\(action)")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "word=\(urlEncode(word))&apiKey=\(urlEncode(settings.apiKey))"
        request.httpBody = body.data(using: .utf8)
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Helpers

    private func urlEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }
}
```

**Step 2: Build and verify**

```bash
xcodegen generate
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

**Step 3: Commit**

```bash
git add "final final/Services/LanguageToolProvider.swift" \
        "final final.xcodeproj/project.pbxproj" \
        project.yml
git commit -m "Add LanguageToolProvider HTTP client" \
           -m "Segment consolidation, offset mapping, error classification," \
           -m "connection status tracking, Premium dictionary sync."
```

---

### Task 5: Wire Up Mode Switching

Connect ProofingSettings to SpellCheckService so changing the mode in preferences swaps the active provider and triggers a re-check.

**Files:**
- Modify: `final final/Services/SpellCheckService.swift`
- Modify: `final final/Editors/MilkdownCoordinator+MessageHandlers.swift` (or Content)
- Modify: `final final/Editors/CodeMirrorCoordinator+Handlers.swift`

**Step 1: Add mode observation to SpellCheckService**

Add a `languageToolProvider` property and a mode-switching method:

```swift
// Add to SpellCheckService:
private let languageToolProvider = LanguageToolProvider()

func updateProviderForCurrentMode() {
    switch ProofingSettings.shared.mode {
    case .builtIn:
        activeProvider = builtInProvider
    case .languageToolFree, .languageToolPremium:
        activeProvider = languageToolProvider
    }
}
```

**Step 2: Observe mode changes in coordinators**

In both MilkdownCoordinator and CodeMirrorCoordinator, observe `proofingModeChanged` and `proofingSettingsChanged` notifications. When received:
1. Call `SpellCheckService.shared.updateProviderForCurrentMode()`
2. Trigger a re-check by calling the existing spellcheck trigger (post a JS call to `window.FinalFinal.triggerSpellcheck()` or equivalent)

Add a `triggerSpellcheck()` method to the `window.FinalFinal` API in both editors.

**Step 3: Build, verify, and commit**

```bash
xcodegen generate
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

Test: Change mode in preferences, then verify the editor re-checks with the new provider.

```bash
git add -u
git commit -m "Wire up proofing mode switching" \
           -m "Changing mode in preferences swaps provider and triggers re-check."
```

---

### Task 6: Web-Side Type and CSS Updates

Update the web types to include new SpellCheckResult fields, add style-error CSS, and update decoration logic for 3 error types.

**Files:**
- Modify: `web/milkdown/src/types.ts` (lines 129-139)
- Modify: `web/codemirror/src/types.ts` (lines 65-75)
- Modify: `web/milkdown/src/styles.css` (lines 641-711)
- Modify: `web/codemirror/src/styles.css` (lines 127-197)
- Modify: `web/milkdown/src/spellcheck-plugin.ts` — update decoration logic for 3 types
- Modify: `web/codemirror/src/spellcheck-plugin.ts` — update decoration logic for 3 types

**Step 1: Update TypeScript types**

In both `types.ts` files, update the SpellCheckResult in the `setSpellcheckResults` signature:

```typescript
setSpellcheckResults: (
  requestId: number,
  results: Array<{
    from: number;
    to: number;
    word: string;
    type: string;        // "spelling" | "grammar" | "style"
    suggestions: string[];
    message?: string | null;
    ruleId?: string | null;   // NEW
    isPicky?: boolean;        // NEW
  }>
) => void;
```

**Step 2: Add style-error CSS**

In `web/milkdown/src/styles.css`, after `.grammar-error` (line ~655):

```css
.style-error {
  text-decoration: underline dotted #22c55e;
  text-decoration-thickness: 2px;
  text-underline-offset: 3px;
  cursor: pointer;
}
```

In `web/codemirror/src/styles.css`, after `.cm-grammar-error` (line ~141):

```css
.cm-style-error {
  text-decoration: underline dotted #22c55e;
  text-decoration-thickness: 2px;
  text-underline-offset: 3px;
  cursor: pointer;
}
```

**Step 3: Update decoration logic in spellcheck plugins**

In both `spellcheck-plugin.ts` files, update the decoration application to use the result `type` field to select the CSS class:
- `"spelling"` -> `.spell-error` / `.cm-spell-error`
- `"grammar"` -> `.grammar-error` / `.cm-grammar-error`
- `"style"` -> `.style-error` / `.cm-style-error`

**Step 4: Build and verify**

```bash
cd web && pnpm build && cd ..
xcodegen generate
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

**Step 5: Commit**

```bash
git add web/milkdown/src/types.ts web/codemirror/src/types.ts \
        web/milkdown/src/styles.css web/codemirror/src/styles.css \
        web/milkdown/src/spellcheck-plugin.ts web/codemirror/src/spellcheck-plugin.ts \
        "final final/Resources/editor/"
git commit -m "Add style-error decoration and new SpellCheckResult fields" \
           -m "Three decoration types: spelling (red wavy), grammar (blue dashed), style (green dotted)."
```

---

### Task 7: Grammar/Style Popover Component

Create a shared HTML popover component that appears when clicking on grammar/style underlines, inspired by the LanguageTool Google Docs UI.

**Files:**
- Create: `web/milkdown/src/spellcheck-popover.ts`
- Create: `web/codemirror/src/spellcheck-popover.ts`
- Modify: `web/milkdown/src/spellcheck-plugin.ts` — add click handler for grammar/style decorations
- Modify: `web/codemirror/src/spellcheck-plugin.ts` — add click handler for grammar/style decorations
- Modify: `web/milkdown/src/styles.css` — popover CSS
- Modify: `web/codemirror/src/styles.css` — popover CSS

**Step 1: Create the popover module**

The popover shows:
- Rule name header with disable button
- Explanation message text
- Suggestion buttons (click to apply correction)
- Ignore button
- "Picky Suggestion" label when isPicky is true

Create `web/milkdown/src/spellcheck-popover.ts` (and copy with class adjustments for CodeMirror):

```typescript
// Popover for grammar/style errors — shows rule info, suggestions, ignore, disable.
// Triggered on click (not right-click) of grammar/style decorations.

interface PopoverOptions {
  x: number;
  y: number;
  word: string;
  type: string;
  message: string;
  ruleId: string;
  isPicky: boolean;
  suggestions: string[];
  onReplace: (suggestion: string) => void;
  onIgnore: () => void;
  onDisableRule: (ruleId: string) => void;
}

let activePopover: HTMLElement | null = null;

export function showProofingPopover(options: PopoverOptions): void {
  dismissPopover();

  const popover = document.createElement('div');
  popover.className = 'proofing-popover';

  // Header: rule name + disable button
  const header = document.createElement('div');
  header.className = 'proofing-popover-header';

  const ruleName = document.createElement('span');
  ruleName.className = 'proofing-popover-rule';
  // Use first sentence of message as the header title
  const shortMessage = options.message ? options.message.split('.')[0] : options.type;
  ruleName.textContent = shortMessage;
  header.appendChild(ruleName);

  if (options.ruleId) {
    const disableBtn = document.createElement('button');
    disableBtn.className = 'proofing-popover-disable';
    disableBtn.title = 'Disable this rule';
    disableBtn.textContent = '\u2298'; // ⊘ character
    disableBtn.addEventListener('click', () => {
      options.onDisableRule(options.ruleId);
      dismissPopover();
    });
    header.appendChild(disableBtn);
  }
  popover.appendChild(header);

  // Message
  if (options.message) {
    const msg = document.createElement('div');
    msg.className = 'proofing-popover-message';
    msg.textContent = options.message;
    popover.appendChild(msg);
  }

  // Suggestions + Ignore row
  const actions = document.createElement('div');
  actions.className = 'proofing-popover-actions';

  for (const suggestion of options.suggestions.slice(0, 3)) {
    const btn = document.createElement('button');
    btn.className = 'proofing-popover-suggestion';
    btn.textContent = suggestion;
    btn.addEventListener('click', () => {
      options.onReplace(suggestion);
      dismissPopover();
    });
    actions.appendChild(btn);
  }

  const ignoreBtn = document.createElement('button');
  ignoreBtn.className = 'proofing-popover-ignore';
  ignoreBtn.textContent = 'Ignore';
  ignoreBtn.addEventListener('click', () => {
    options.onIgnore();
    dismissPopover();
  });
  actions.appendChild(ignoreBtn);

  popover.appendChild(actions);

  // Picky label
  if (options.isPicky) {
    const footer = document.createElement('div');
    footer.className = 'proofing-popover-footer';
    const pickyLabel = document.createElement('span');
    pickyLabel.className = 'proofing-popover-picky';
    pickyLabel.textContent = 'Picky Suggestion';
    footer.appendChild(pickyLabel);
    popover.appendChild(footer);
  }

  // Position and show
  popover.style.left = `${options.x}px`;
  popover.style.top = `${options.y}px`;
  document.body.appendChild(popover);
  activePopover = popover;

  // Dismiss on click outside
  setTimeout(() => {
    document.addEventListener('click', handleOutsideClick);
  }, 0);
}

export function dismissPopover(): void {
  if (activePopover) {
    activePopover.remove();
    activePopover = null;
    document.removeEventListener('click', handleOutsideClick);
  }
}

function handleOutsideClick(e: MouseEvent): void {
  if (activePopover && !activePopover.contains(e.target as Node)) {
    dismissPopover();
  }
}
```

**Step 2: Add popover CSS**

Add to both editor style files:

```css
/* Proofing popover for grammar/style errors */
.proofing-popover {
  position: absolute;
  z-index: 1000;
  background: var(--bg-color, #fff);
  border: 1px solid var(--border-color, #e0e0e0);
  border-radius: 8px;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
  padding: 12px;
  max-width: 350px;
  min-width: 200px;
  font-size: 13px;
}

.proofing-popover-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 8px;
}

.proofing-popover-rule {
  font-weight: 600;
  color: var(--text-color, #333);
}

.proofing-popover-disable {
  background: none;
  border: none;
  cursor: pointer;
  font-size: 18px;
  color: var(--secondary-text, #999);
  padding: 0 4px;
}

.proofing-popover-disable:hover {
  color: var(--text-color, #333);
}

.proofing-popover-message {
  color: var(--secondary-text, #666);
  margin-bottom: 10px;
  line-height: 1.4;
}

.proofing-popover-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
}

.proofing-popover-suggestion {
  background: #3b82f6;
  color: white;
  border: none;
  border-radius: 4px;
  padding: 4px 10px;
  cursor: pointer;
  font-size: 13px;
}

.proofing-popover-suggestion:hover {
  background: #2563eb;
}

.proofing-popover-ignore {
  background: var(--bg-color, #f5f5f5);
  border: 1px solid var(--border-color, #ddd);
  border-radius: 4px;
  padding: 4px 10px;
  cursor: pointer;
  font-size: 13px;
}

.proofing-popover-footer {
  margin-top: 8px;
  padding-top: 8px;
  border-top: 1px solid var(--border-color, #e0e0e0);
  font-size: 12px;
}

.proofing-popover-picky {
  color: var(--secondary-text, #999);
}
```

**Step 3: Wire click handler in spellcheck plugins**

In both `spellcheck-plugin.ts` files, add a click handler that:
1. Checks if clicked position intersects a grammar/style decoration
2. If yes, finds the matching result from the stored results array
3. Calls `showProofingPopover()` with the result data and callbacks for replace/ignore/disableRule
4. If the type is `"spelling"`, does nothing (right-click context menu handles it)

**Step 4: Add disableRule message to Swift**

The `onDisableRule` callback posts: `window.webkit.messageHandlers.spellcheck.postMessage({ action: "disableRule", ruleId: "..." })`

**Step 5: Handle disableRule in coordinators**

In both coordinator message handlers (MilkdownCoordinator+MessageHandlers.swift line ~267 and CodeMirrorCoordinator+Handlers.swift line ~311), add a case:

```swift
case "disableRule":
    guard let ruleId = body["ruleId"] as? String else { return }
    ProofingSettings.shared.disableRule(ruleId)
    // Trigger re-check
    NotificationCenter.default.post(name: .proofingSettingsChanged, object: nil)
```

**Step 6: Build and verify**

```bash
cd web && pnpm build && cd ..
xcodegen generate
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

Test: With LT mode active, click on a grammar/style underline to verify the popover appears.

**Step 7: Commit**

```bash
git add web/milkdown/src/spellcheck-popover.ts web/codemirror/src/spellcheck-popover.ts \
        web/milkdown/src/spellcheck-plugin.ts web/codemirror/src/spellcheck-plugin.ts \
        web/milkdown/src/styles.css web/codemirror/src/styles.css \
        "final final/Editors/MilkdownCoordinator+MessageHandlers.swift" \
        "final final/Editors/CodeMirrorCoordinator+Handlers.swift" \
        "final final/Resources/editor/"
git commit -m "Add grammar/style proofing popover and disable-rule flow" \
           -m "Click-triggered HTML popover with suggestions, ignore, disable rule." \
           -m "Inspired by LanguageTool Google Docs UI."
```

---

### Task 8: Status Bar Proofing Indicator

Add a small colored dot to the editor status bar that shows LanguageTool connection status, with a click-to-popover for details.

**Files:**
- Modify: `final final/ViewState/EditorViewState.swift` — add proofing status property
- Modify: The status bar view (find exact file — likely in `ContentView.swift` or a status bar subview)

**Step 1: Add proofing status to EditorViewState**

Add an observable property that tracks the LanguageToolProvider's connection status:

```swift
var proofingConnectionStatus: LTConnectionStatus = .disconnected
```

Observe changes from the LanguageToolProvider (via SpellCheckService) and update this property.

**Step 2: Add status bar indicator**

In the status bar area (near word count), add a small circle view:
- Only shown when proofing mode is LT (not built-in)
- Green: `.connected`
- Yellow: `.checking`
- Red: `.disconnected`, `.authError`, `.rateLimited`
- Clickable: shows a popover with status text + "Open Proofing Preferences" button

**Step 3: Build, verify, and commit**

```bash
xcodegen generate
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

```bash
git add -u
git commit -m "Add proofing status indicator to status bar" \
           -m "Colored dot shows LT connection status, click for details."
```

---

### Task 9: Integration Testing and Final Verification

End-to-end verification of all features.

**Manual Test Checklist:**

1. **Built-in mode (default):**
   - [ ] Misspelled words get red wavy underlines
   - [ ] Right-click shows suggestions, Learn, Ignore
   - [ ] Learn adds to macOS dictionary
   - [ ] No status bar indicator shown

2. **Switch to LT Free:**
   - [ ] Open Preferences -> Proofing -> select "LanguageTool Free"
   - [ ] Editor re-checks with LT
   - [ ] Grammar errors get blue dashed underlines
   - [ ] Click on grammar underline -> popover appears
   - [ ] Suggestion buttons work (click to replace)
   - [ ] Ignore button works
   - [ ] Status bar shows green dot

3. **Switch to LT Premium:**
   - [ ] Enter API key -> Test Connection -> shows green checkmark
   - [ ] Style errors get green dotted underlines (requires picky mode)
   - [ ] Enable picky mode -> re-check -> more style suggestions appear
   - [ ] "Picky Suggestion" label appears in popover for picky results

4. **Disable Rule:**
   - [ ] Click disable button in popover -> rule disappears from results
   - [ ] Rule appears in Preferences -> Disabled Rules list
   - [ ] Click x next to rule -> re-enabled -> re-check shows it again

5. **Error states:**
   - [ ] Invalid API key -> status bar red dot -> popover says "Invalid API key"
   - [ ] Server unreachable -> red dot -> "Server unreachable"

6. **Mode switching:**
   - [ ] Switch from LT back to built-in -> only spelling underlines remain
   - [ ] Grammar/style decorations clear

**Step: Final commit if any fixes needed**

```bash
git add -u
git commit -m "Polish LanguageTool integration" \
           -m "Fix issues found during integration testing."
```

---

## File Summary

| Action | File |
|--------|------|
| Create | `final final/Services/ProofingProvider.swift` |
| Create | `final final/Services/BuiltInProvider.swift` |
| Create | `final final/Models/ProofingSettings.swift` |
| Create | `final final/Services/KeychainHelper.swift` |
| Create | `final final/Services/LanguageToolProvider.swift` |
| Create | `final final/Views/Preferences/ProofingPreferencesPane.swift` |
| Create | `web/milkdown/src/spellcheck-popover.ts` |
| Create | `web/codemirror/src/spellcheck-popover.ts` |
| Modify | `final final/Services/SpellCheckService.swift` |
| Modify | `final final/Views/Preferences/PreferencesView.swift` |
| Modify | `final final/Editors/MilkdownCoordinator+MessageHandlers.swift` |
| Modify | `final final/Editors/CodeMirrorCoordinator+Handlers.swift` |
| Modify | `final final/ViewState/EditorViewState.swift` |
| Modify | `web/milkdown/src/types.ts` |
| Modify | `web/codemirror/src/types.ts` |
| Modify | `web/milkdown/src/styles.css` |
| Modify | `web/codemirror/src/styles.css` |
| Modify | `web/milkdown/src/spellcheck-plugin.ts` |
| Modify | `web/codemirror/src/spellcheck-plugin.ts` |
| Modify | `web/milkdown/src/spellcheck-menu.ts` |
| Modify | `web/codemirror/src/spellcheck-menu.ts` |
| Modify | `web/milkdown/src/main.ts` |
| Modify | `web/codemirror/src/main.ts` |
