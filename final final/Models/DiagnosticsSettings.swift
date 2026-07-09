//
//  DiagnosticsSettings.swift
//  final final
//
//  Settings for the Diagnostics preferences pane: persistent-logging toggle
//  and last-report-generated timestamp.
//

import Foundation

/// Follows the `ProofingSettings` pattern (plain `@MainActor @Observable` class, per-property
/// UserDefaults `didSet`, no JSON blob) rather than the `FocusModeSettings` JSON-blob pattern —
/// there is exactly one real setting today (a Bool) plus a display-only timestamp, so a
/// `Codable` struct + manager wrapper would be unwarranted machinery.
@MainActor @Observable
final class DiagnosticsSettings {
    static let shared = DiagnosticsSettings()

    /// Test seam: `DiagnosticsSettingsTests` overrides this to a per-test isolated
    /// `UserDefaults(suiteName:)` instance so tests never read/write the real
    /// `com.kerim.final-final` defaults domain through the shared singleton. Production code
    /// always leaves this at `.standard`.
    static var userDefaults: UserDefaults = .standard

    /// Off by default. Gates DiagnosticLogFile writes (all 17+1 DebugLog categories),
    /// independent of DebugLog's existing #if DEBUG console path.
    var loggingEnabled: Bool {
        didSet { Self.userDefaults.set(loggingEnabled, forKey: DiagnosticLogFile.loggingEnabledDefaultsKey) }
    }

    /// Display-only: "Last generated: <date>" in the pane. Nil until first report.
    var lastReportGeneratedAt: Date? {
        didSet {
            if let lastReportGeneratedAt {
                Self.userDefaults.set(lastReportGeneratedAt, forKey: Keys.lastReportGeneratedAt)
            } else {
                Self.userDefaults.removeObject(forKey: Keys.lastReportGeneratedAt)
            }
        }
    }

    private enum Keys {
        static let lastReportGeneratedAt = "com.kerim.final-final.diagnosticsLastReportGeneratedAt"
    }

    private init() {
        loggingEnabled = Self.userDefaults.bool(forKey: DiagnosticLogFile.loggingEnabledDefaultsKey)
        lastReportGeneratedAt = Self.userDefaults.object(forKey: Keys.lastReportGeneratedAt) as? Date
    }
}
