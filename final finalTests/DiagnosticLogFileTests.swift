//
//  DiagnosticLogFileTests.swift
//  final finalTests
//
//  Exercises DiagnosticLogFile via its non-private init(logDirectory:maxFileSize:maxRotatedFiles:)
//  seam — throwaway instances pointed at a temp directory with a tiny maxFileSize, so rotation
//  is exercised in a handful of append() calls instead of writing 2 MiB per test.
//
//  `.serialized`: every test flips the shared `DiagnosticLogFile.userDefaults` static (the
//  isolated-UserDefaults test seam) for its duration, so tests in this suite must not run
//  concurrently with one another.
//

import Testing
import Foundation
@testable import final_final

@Suite(.serialized)
struct DiagnosticLogFileTests {

    /// append() early-returns when disabled, regardless of which DiagnosticLogFile instance is
    /// used (the enabled check reads `DiagnosticLogFile.userDefaults`, a shared key). Points
    /// that seam at a fresh isolated `UserDefaults` suite for the duration of `body`, instead of
    /// touching the real `com.kerim.final-final` defaults domain, and tears the suite down after.
    private func withLoggingEnabled(_ enabled: Bool, _ body: () -> Void) {
        let suiteName = "com.kerim.final-final.tests.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        let originalUserDefaults = DiagnosticLogFile.userDefaults
        DiagnosticLogFile.userDefaults = testDefaults
        testDefaults.set(enabled, forKey: DiagnosticLogFile.loggingEnabledDefaultsKey)
        defer {
            DiagnosticLogFile.userDefaults = originalUserDefaults
            testDefaults.removePersistentDomain(forName: suiteName)
        }
        body()
    }

    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test func disabledProducesNoFile() {
        let tempDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let logFile = DiagnosticLogFile(logDirectory: tempDir, maxFileSize: 200, maxRotatedFiles: 1)

        withLoggingEnabled(false) {
            logFile.append("hello")
        }

        #expect(logFile.existingLogFileURLs().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("diagnostic.log").path))
    }

    @Test func enabledAppendCreatesFileContainingTheLine() {
        let tempDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let logFile = DiagnosticLogFile(logDirectory: tempDir, maxFileSize: 2000, maxRotatedFiles: 1)

        withLoggingEnabled(true) {
            logFile.append("hello world")
        }

        let activeURL = tempDir.appendingPathComponent("diagnostic.log")
        #expect(FileManager.default.fileExists(atPath: activeURL.path))
        let contents = try? String(contentsOf: activeURL, encoding: .utf8)
        #expect(contents?.contains("hello world") == true)
    }

    @Test func rotationNeverExceedsMaxRotatedFilesPlusOne() {
        let tempDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        // maxFileSize (50) is smaller than any single timestamped line, so every append
        // after the first forces a rotation — deterministic without needing exact byte math.
        let logFile = DiagnosticLogFile(logDirectory: tempDir, maxFileSize: 50, maxRotatedFiles: 1)

        withLoggingEnabled(true) {
            for i in 0..<5 {
                logFile.append("line \(i) padding to comfortably exceed the fifty byte cap")
            }
        }

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
        #expect(Set(entries) == Set(["diagnostic.log", "diagnostic.log.1"]))
    }

    @Test func existingLogFileURLsReturnsExistingFilesCurrentFirst() {
        let tempDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let logFile = DiagnosticLogFile(logDirectory: tempDir, maxFileSize: 50, maxRotatedFiles: 2)

        withLoggingEnabled(true) {
            for i in 0..<8 {
                logFile.append("line \(i) padding to comfortably exceed the fifty byte cap")
            }
        }

        let names = logFile.existingLogFileURLs().map(\.lastPathComponent)
        #expect(names == ["diagnostic.log", "diagnostic.log.1", "diagnostic.log.2"])
    }

    @Test func copyLogFilesCopiesRotatedFilesAndReturnsDestinationURLs() {
        let tempDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let logFile = DiagnosticLogFile(logDirectory: tempDir, maxFileSize: 50, maxRotatedFiles: 1)

        withLoggingEnabled(true) {
            for i in 0..<5 {
                logFile.append("line \(i) padding to comfortably exceed the fifty byte cap")
            }
        }

        let destinationDir = tempDir.appendingPathComponent("copy-destination")
        let copied = try? logFile.copyLogFiles(to: destinationDir)

        #expect(Set((copied ?? []).map(\.lastPathComponent)) == Set(["diagnostic.log", "diagnostic.log.1"]))
        for url in copied ?? [] {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        let activeContents = try? String(
            contentsOf: destinationDir.appendingPathComponent("diagnostic.log"), encoding: .utf8
        )
        #expect(activeContents?.contains("line 4") == true)
    }

    @Test func copyLogFilesReturnsEmptyWhenNoLogsExistYetCreatesDestinationDirectory() {
        let tempDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let logFile = DiagnosticLogFile(logDirectory: tempDir, maxFileSize: 200, maxRotatedFiles: 1)

        let destinationDir = tempDir.appendingPathComponent("copy-destination")
        let copied = try? logFile.copyLogFiles(to: destinationDir)

        #expect(copied == [])
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: destinationDir.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}
