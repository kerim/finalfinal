//
//  DiagnosticReportGeneratorTests.swift
//  final finalTests
//
//  Exercises DiagnosticReportGenerator.generateReport via its injected-parameter seam
//  (copyLogFiles / exportDiagnosticDirectories), not the real DiagnosticLogFile/ExportService
//  singletons — so tests never touch real user state or copy multi-megabyte real logs.
//

import Testing
import Foundation
@testable import final_final

struct DiagnosticReportGeneratorTests {

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Stand-in for the production `DiagnosticLogFile.copyLogFiles(to:)` seam: creates the
    /// destination directory and copies `sourceURLs` into it, mirroring the real method's
    /// contract without touching `DiagnosticLogFile` itself.
    private func copyFixtures(_ sourceURLs: [URL]) -> (URL) throws -> [URL] {
        { destinationDirectory in
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            var copiedURLs: [URL] = []
            for sourceURL in sourceURLs {
                let destinationFileURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
                try FileManager.default.copyItem(at: sourceURL, to: destinationFileURL)
                copiedURLs.append(destinationFileURL)
            }
            return copiedURLs
        }
    }

    @Test func generatesReportWithLogFixtureSystemInfoAndReadme() async {
        let workDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let fixtureLog = workDir.appendingPathComponent("fixture.log")
        try? "2024-01-01T00:00:00Z [sync] fixture line\n".write(to: fixtureLog, atomically: true, encoding: .utf8)

        let destination = workDir.appendingPathComponent("report")

        let result = await DiagnosticReportGenerator.generateReport(
            to: destination,
            copyLogFiles: copyFixtures([fixtureLog]),
            exportDiagnosticDirectories: []
        )

        guard case .success(let reportURL) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(reportURL == destination)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)

        let copiedLog = destination.appendingPathComponent("logs").appendingPathComponent("fixture.log")
        #expect(FileManager.default.fileExists(atPath: copiedLog.path))
        let copiedContents = try? String(contentsOf: copiedLog, encoding: .utf8)
        #expect(copiedContents?.contains("fixture line") == true)

        let systemInfoURL = destination.appendingPathComponent("system-info.txt")
        #expect(FileManager.default.fileExists(atPath: systemInfoURL.path))
        let systemInfoContents = (try? String(contentsOf: systemInfoURL, encoding: .utf8)) ?? ""
        #expect(!systemInfoContents.isEmpty)

        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("README.txt").path))
    }

    @Test func emptyLogFileURLsProducesExplanatoryReadme() async {
        let workDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let destination = workDir.appendingPathComponent("report")

        let result = await DiagnosticReportGenerator.generateReport(
            to: destination,
            copyLogFiles: copyFixtures([]),
            exportDiagnosticDirectories: []
        )

        guard case .success = result else {
            Issue.record("Expected success, got \(result)")
            return
        }

        let logsDirectory = destination.appendingPathComponent("logs")
        let logsReadme = logsDirectory.appendingPathComponent("README.txt")
        #expect(FileManager.default.fileExists(atPath: logsReadme.path))
        let contents = (try? String(contentsOf: logsReadme, encoding: .utf8)) ?? ""
        #expect(contents.contains("Diagnostic logging was off"))

        // No log data means logs/ should contain only the explanatory README.
        let logsDirEntries = (try? FileManager.default.contentsOfDirectory(atPath: logsDirectory.path)) ?? []
        #expect(logsDirEntries == ["README.txt"])
    }

    @Test func exportDiagnosticDirectoryIsCopiedUnderExportDiagnostics() async {
        let workDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let exportDumpDir = workDir.appendingPathComponent("2024-01-01T00-00-00-abcd1234")
        try? FileManager.default.createDirectory(at: exportDumpDir, withIntermediateDirectories: true)
        try? "sample input".write(
            to: exportDumpDir.appendingPathComponent("input.md"), atomically: true, encoding: .utf8
        )

        let destination = workDir.appendingPathComponent("report")

        let result = await DiagnosticReportGenerator.generateReport(
            to: destination,
            copyLogFiles: copyFixtures([]),
            exportDiagnosticDirectories: [exportDumpDir]
        )

        guard case .success = result else {
            Issue.record("Expected success, got \(result)")
            return
        }

        let copiedDumpDir = destination
            .appendingPathComponent("export-diagnostics")
            .appendingPathComponent(exportDumpDir.lastPathComponent)
        let copiedInputFile = copiedDumpDir.appendingPathComponent("input.md")
        #expect(FileManager.default.fileExists(atPath: copiedInputFile.path))
        let contents = try? String(contentsOf: copiedInputFile, encoding: .utf8)
        #expect(contents == "sample input")
    }
}
