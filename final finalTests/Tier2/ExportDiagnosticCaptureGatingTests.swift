//
//  ExportDiagnosticCaptureGatingTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//
//  Regression coverage for the "Export Complete with Warnings" alert firing on every export.
//  Root cause: ExportService.export() used to unconditionally append the diagnostic capture's
//  result message into `warnings`, so `warnings` was never empty even on a clean export. The
//  fix: (1) the diagnostic capture is now gated behind an opt-in, off-by-default toggle
//  (ExportService.isDiagnosticCaptureEnabled / DiagnosticsSettings.exportDiagnosticCaptureEnabled),
//  and (2) the capture's outcome never feeds into `warnings` at all, regardless of the toggle.
//
//  Real-pandoc integration tests, matching ImageCaptionExportTests.swift's pandoc-lookup +
//  XCTSkip idiom, calling ExportService().export(...) directly (the same call the app makes).
//

import XCTest
import Foundation
@testable import final_final

final class ExportDiagnosticCaptureGatingTests: XCTestCase {

    // MARK: - Pandoc helper (mirrors ImageCaptionExportTests.swift)

    private static func findPandocPath() -> String? {
        let candidates = ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc", "/usr/bin/pandoc"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Isolated UserDefaults helper

    /// Points `ExportService.userDefaults` at a fresh isolated `UserDefaults` suite for the
    /// duration of `body`, instead of touching the real `com.kerim.final-final` defaults domain
    /// through the shared actor-static test seam, and tears the suite down after — same idiom as
    /// `DiagnosticsSettingsTests.withIsolatedUserDefaults`, adapted to an async body since
    /// `ExportService.export(...)` is async.
    private func withIsolatedUserDefaults(_ body: (UserDefaults) async throws -> Void) async throws {
        let suiteName = "com.kerim.final-final.tests.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        let originalUserDefaults = ExportService.userDefaults
        ExportService.userDefaults = testDefaults
        defer {
            ExportService.userDefaults = originalUserDefaults
            testDefaults.removePersistentDomain(forName: suiteName)
        }
        try await body(testDefaults)
    }

    /// Citation-free, image-free markdown — isolates the test from Zotero/citeproc and image
    /// conversion codepaths so the only thing that could produce a warning is the diagnostic
    /// capture gate under test.
    private func plainMarkdown() -> String {
        "# Plain Document\n\nSome ordinary paragraph text with no citations or images.\n"
    }

    // MARK: - Toggle OFF (default)

    func testDiagnosticCaptureOff_NoWarningsAndNoNewDumpDirectory() async throws {
        guard Self.findPandocPath() != nil else {
            throw XCTSkip("Pandoc not installed — skipping export diagnostic gating verification")
        }

        try await withIsolatedUserDefaults { testDefaults in
            testDefaults.set(false, forKey: ExportService.diagnosticCaptureEnabledDefaultsKey)
            XCTAssertFalse(ExportService.isDiagnosticCaptureEnabled)

            let before = Set(ExportService.recentExportDiagnosticDirectories(limit: 1000))

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("diagnostic-gating-off-\(UUID().uuidString).docx")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let service = ExportService()
            let result = try await service.export(
                content: plainMarkdown(),
                to: tempURL,
                format: .word,
                settings: ExportSettings(),
                projectURL: nil
            )

            XCTAssertTrue(result.warnings.isEmpty,
                           "A clean export with the capture toggle off should have no warnings: \(result.warnings)")

            let after = Set(ExportService.recentExportDiagnosticDirectories(limit: 1000))
            XCTAssertEqual(before, after,
                            "No new diagnostic dump directory should appear when the toggle is off")
        }
    }

    // MARK: - Toggle ON

    func testDiagnosticCaptureOn_CreatesDumpDirectoryButStillNoWarnings() async throws {
        guard Self.findPandocPath() != nil else {
            throw XCTSkip("Pandoc not installed — skipping export diagnostic gating verification")
        }

        try await withIsolatedUserDefaults { testDefaults in
            testDefaults.set(true, forKey: ExportService.diagnosticCaptureEnabledDefaultsKey)
            XCTAssertTrue(ExportService.isDiagnosticCaptureEnabled)

            let before = Set(ExportService.recentExportDiagnosticDirectories(limit: 1000))

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("diagnostic-gating-on-\(UUID().uuidString).docx")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let service = ExportService()
            let result = try await service.export(
                content: plainMarkdown(),
                to: tempURL,
                format: .word,
                settings: ExportSettings(),
                projectURL: nil
            )

            // This is the direct regression test for the alert-wording bug: the diagnostic
            // capture succeeding (and producing a dump) must never itself count as a warning.
            XCTAssertTrue(result.warnings.isEmpty,
                           "Diagnostic capture succeeding must never surface as an export warning: \(result.warnings)")

            let after = Set(ExportService.recentExportDiagnosticDirectories(limit: 1000))
            let newDirectories = after.subtracting(before)
            XCTAssertEqual(newDirectories.count, 1,
                            "Exactly one new diagnostic dump directory should appear when the toggle is on")

            // Clean up whatever this test created so repeated runs don't accumulate cache state.
            for directory in newDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }
}
