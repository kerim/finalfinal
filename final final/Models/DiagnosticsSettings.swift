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
    /// `com.kerim.final-final` defaults domain through the shared singleton. Defaults to
    /// `AppDefaults.store` — `.standard` in production, an isolated test-only suite while any
    /// kind of test is running — so a unit test run that never overrides this seam still can't
    /// wipe the real domain's `lastReportGeneratedAt` key via `TestMode.clearTestState()`.
    static var userDefaults: UserDefaults = AppDefaults.store

    /// Off by default. Gates DiagnosticLogFile writes (all 17+1 DebugLog categories),
    /// independent of DebugLog's existing #if DEBUG console path.
    var loggingEnabled: Bool {
        didSet { Self.userDefaults.set(loggingEnabled, forKey: DiagnosticLogFile.loggingEnabledDefaultsKey) }
    }

    /// Off by default. Gates ExportService's diagnostic capture dump — a temporary
    /// investigation aid for a still-open PDF export bug (see
    /// docs/plans/mossy-tumbling-stroustrup.md), independent of `loggingEnabled` above.
    var exportDiagnosticCaptureEnabled: Bool {
        didSet {
            Self.userDefaults.set(
                exportDiagnosticCaptureEnabled,
                forKey: ExportService.diagnosticCaptureEnabledDefaultsKey
            )
        }
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
        exportDiagnosticCaptureEnabled = Self.userDefaults.bool(
            forKey: ExportService.diagnosticCaptureEnabledDefaultsKey
        )
        lastReportGeneratedAt = Self.userDefaults.object(forKey: Keys.lastReportGeneratedAt) as? Date
    }
}
