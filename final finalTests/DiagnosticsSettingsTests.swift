//
//  DiagnosticsSettingsTests.swift
//  final finalTests
//
//  `.serialized`: every test flips the shared `DiagnosticsSettings.userDefaults` static (the
//  isolated-UserDefaults test seam) for its duration, so tests in this suite must not run
//  concurrently with one another.
//

import Testing
import Foundation
@testable import final_final

@MainActor
@Suite(.serialized)
struct DiagnosticsSettingsTests {

    /// Points `DiagnosticsSettings.userDefaults` at a fresh isolated `UserDefaults` suite for
    /// the duration of `body`, instead of touching the real `com.kerim.final-final` defaults
    /// domain through the shared singleton, and tears the suite down after.
    private func withIsolatedUserDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "com.kerim.final-final.tests.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        let originalUserDefaults = DiagnosticsSettings.userDefaults
        DiagnosticsSettings.userDefaults = testDefaults
        defer {
            DiagnosticsSettings.userDefaults = originalUserDefaults
            testDefaults.removePersistentDomain(forName: suiteName)
        }
        body(testDefaults)
    }

    @Test func loggingEnabledRoundTripsThroughUserDefaults() {
        withIsolatedUserDefaults { testDefaults in
            let settings = DiagnosticsSettings.shared
            let originalValue = settings.loggingEnabled
            defer { settings.loggingEnabled = originalValue }

            settings.loggingEnabled = true
            #expect(testDefaults.bool(forKey: DiagnosticLogFile.loggingEnabledDefaultsKey) == true)

            settings.loggingEnabled = false
            #expect(testDefaults.bool(forKey: DiagnosticLogFile.loggingEnabledDefaultsKey) == false)
        }
    }

    /// `loggingEnabledRoundTripsThroughUserDefaults` above only proves `DiagnosticsSettings`
    /// writes the right key into its own seam -- it never touches `DiagnosticLogFile.isEnabled`,
    /// so it wouldn't catch a deleted or misplaced `invalidateEnabledCache()` call in the
    /// `loggingEnabled` didSet. This test proves that call actually wires through end-to-end:
    /// `DiagnosticsSettings.userDefaults` and `DiagnosticLogFile.userDefaults` are two distinct
    /// statics, so it points BOTH at the SAME isolated suite -- a test that swapped only one of
    /// them could not observe the other side's read.
    @Test func loggingEnabledDidSetInvalidatesDiagnosticLogFileCache() {
        let suiteName = "com.kerim.final-final.tests.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        let originalSettingsDefaults = DiagnosticsSettings.userDefaults
        let originalLogFileDefaults = DiagnosticLogFile.userDefaults
        DiagnosticsSettings.userDefaults = testDefaults
        DiagnosticLogFile.userDefaults = testDefaults
        defer {
            DiagnosticsSettings.userDefaults = originalSettingsDefaults
            DiagnosticLogFile.userDefaults = originalLogFileDefaults
            testDefaults.removePersistentDomain(forName: suiteName)
        }

        let settings = DiagnosticsSettings.shared
        let originalValue = settings.loggingEnabled
        defer { settings.loggingEnabled = originalValue }

        settings.loggingEnabled = true
        #expect(DiagnosticLogFile.isEnabled == true)

        settings.loggingEnabled = false
        #expect(DiagnosticLogFile.isEnabled == false)
    }

    @Test func exportDiagnosticCaptureEnabledRoundTripsThroughUserDefaults() {
        withIsolatedUserDefaults { testDefaults in
            let settings = DiagnosticsSettings.shared
            let originalValue = settings.exportDiagnosticCaptureEnabled
            defer { settings.exportDiagnosticCaptureEnabled = originalValue }

            settings.exportDiagnosticCaptureEnabled = true
            #expect(testDefaults.bool(forKey: ExportService.diagnosticCaptureEnabledDefaultsKey) == true)

            settings.exportDiagnosticCaptureEnabled = false
            #expect(testDefaults.bool(forKey: ExportService.diagnosticCaptureEnabledDefaultsKey) == false)
        }
    }

    @Test func lastReportGeneratedAtRoundTripsAndClearsOnNil() {
        withIsolatedUserDefaults { testDefaults in
            let settings = DiagnosticsSettings.shared
            let originalValue = settings.lastReportGeneratedAt
            defer { settings.lastReportGeneratedAt = originalValue }

            let key = "com.kerim.final-final.diagnosticsLastReportGeneratedAt"
            let date = Date(timeIntervalSince1970: 1_700_000_000)

            settings.lastReportGeneratedAt = date
            let stored = testDefaults.object(forKey: key) as? Date
            #expect(stored != nil)
            #expect(abs((stored ?? .distantPast).timeIntervalSince1970 - date.timeIntervalSince1970) < 1)

            settings.lastReportGeneratedAt = nil
            #expect(testDefaults.object(forKey: key) == nil)
        }
    }
}
