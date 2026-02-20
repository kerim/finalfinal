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
                .onChange(of: settings.mode) { _, _ in
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
                Text("Rules disabled via the editor context menu appear here. Click \u{2715} to re-enable.")
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
