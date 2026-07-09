//
//  DiagnosticReportGenerator.swift
//  final final
//
//  Bundles the persistent diagnostic log, a system-info snapshot, and recent export
//  diagnostic captures into a folder the user chooses via NSSavePanel.
//

import Foundation

enum DiagnosticReportError: LocalizedError {
    case directoryCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let reason):
            return "Could not create the diagnostic report folder: \(reason)"
        }
    }
}

enum DiagnosticReportGenerator {
    static let recentExportDumpsToInclude = 3

    /// `copyLogFiles` / `exportDiagnosticDirectories` are dependency-injected (default to the
    /// real singletons) purely so tests can pass temp-directory fixtures instead of touching
    /// real app state.
    ///
    /// `copyLogFiles` receives the destination `logs/` directory and must create it, copy
    /// whatever log data is available into it, and return the URLs of what it actually copied.
    /// Production uses `DiagnosticLogFile.copyLogFiles(to:)`, which holds the same `NSLock`
    /// that guards `append()`/`rotate()` around the entire listing+copy sequence, so a report
    /// generated while a background thread is mid-append or mid-rotation never captures a
    /// half-written file or silently drops the active log. Tests inject a closure over plain
    /// fixture files instead, bypassing `DiagnosticLogFile` entirely.
    ///
    /// Works regardless of whether diagnostic logging is currently on — see
    /// `DiagnosticsPreferencesPane`'s design-decision note. When nothing gets copied, the
    /// generated `logs/` folder gets an explanatory `README.txt` instead of log data.
    static func generateReport(
        to destinationURL: URL,
        copyLogFiles: (URL) throws -> [URL] = { try DiagnosticLogFile.shared.copyLogFiles(to: $0) },
        exportDiagnosticDirectories: [URL] = ExportService.recentExportDiagnosticDirectories(limit: recentExportDumpsToInclude)
    ) async -> Result<URL, DiagnosticReportError> {
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        } catch {
            return .failure(.directoryCreationFailed(error.localizedDescription))
        }

        // logs/ subfolder — copied via the injected closure, or explain why there's nothing
        // to copy if it came back empty.
        let logsDirectory = destinationURL.appendingPathComponent("logs", isDirectory: true)
        let copiedLogURLs: [URL]
        do {
            copiedLogURLs = try copyLogFiles(logsDirectory)
        } catch {
            return .failure(.directoryCreationFailed(error.localizedDescription))
        }
        if copiedLogURLs.isEmpty {
            let readme = """
                No diagnostic log data is available.

                Diagnostic logging was off when this report was generated (or the app has \
                never logged anything since it was enabled). Turn on "Enable diagnostic \
                logging" in Preferences \u{2192} Diagnostics, reproduce the issue, then \
                generate a new report.
                """
            try? readme.write(
                to: logsDirectory.appendingPathComponent("README.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        // system-info.txt
        try? diagnosticSystemInfo().write(
            to: destinationURL.appendingPathComponent("system-info.txt"),
            atomically: true,
            encoding: .utf8
        )

        // export-diagnostics/ subfolder — whole per-export capture directories, if any exist.
        if !exportDiagnosticDirectories.isEmpty {
            let exportDiagnosticsDirectory = destinationURL.appendingPathComponent("export-diagnostics", isDirectory: true)
            try? fm.createDirectory(at: exportDiagnosticsDirectory, withIntermediateDirectories: true)
            for sourceDirectory in exportDiagnosticDirectories {
                let destination = exportDiagnosticsDirectory.appendingPathComponent(
                    sourceDirectory.lastPathComponent, isDirectory: true
                )
                try? fm.removeItem(at: destination)
                try? fm.copyItem(at: sourceDirectory, to: destination)
            }
        }

        // Top-level README.txt summarizing contents.
        let readme = """
            final final Diagnostic Report
            Generated: \(ISO8601DateFormatter().string(from: Date()))

            Contents:
            - logs/                Persistent diagnostic log, if diagnostic logging was enabled
            - system-info.txt      macOS version, locale, app version, and other environment details
            - export-diagnostics/  Up to \(recentExportDumpsToInclude) most recent export capture(s), if any

            Log entries may include short snippets of your document text (e.g. heading \
            previews) — review before sharing this report with anyone else.
            """
        try? readme.write(
            to: destinationURL.appendingPathComponent("README.txt"),
            atomically: true,
            encoding: .utf8
        )

        return .success(destinationURL)
    }

    /// A small local duplicate of `ExportService`'s private `diagnosticSystemInfo()` — not
    /// shared, since that function is private and this is a one-time few-line duplication,
    /// not worth coupling the two services together.
    private static func diagnosticSystemInfo() -> String {
        let info = ProcessInfo.processInfo
        let bundle = Bundle.main
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let appBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return [
            "macOSVersion=\(info.operatingSystemVersionString)",
            "hostname=\(info.hostName)",
            "locale=\(Locale.current.identifier)",
            "timeZone=\(TimeZone.current.identifier)",
            "appVersion=\(appVersion)",
            "appBuild=\(appBuild)",
            "generatedAt=\(ISO8601DateFormatter().string(from: Date()))",
            "loggingEnabledAtGeneration=\(DiagnosticLogFile.isEnabled)"
        ].joined(separator: "\n")
    }
}
