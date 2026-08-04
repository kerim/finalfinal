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
        // Write the key BEFORE swapping the seam, not after: swapping `userDefaults` invalidates
        // `enabledCache` (see its setter), so any read that lands between the swap and the write
        // below would re-cache a fresh-but-wrong `false` (the key is absent in `testDefaults`
        // until we write it) -- and nothing would invalidate that cache again before `body()`
        // reads it.
        testDefaults.set(enabled, forKey: DiagnosticLogFile.loggingEnabledDefaultsKey)
        let originalUserDefaults = DiagnosticLogFile.userDefaults
        DiagnosticLogFile.userDefaults = testDefaults
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

    /// `isEnabled` caches its UserDefaults read (see `DiagnosticLogFile.enabledCache`).
    /// Swapping the `userDefaults` seam must invalidate that cache, so a value cached against
    /// the old store is never returned for the new one.
    ///
    /// Note: deliberately does NOT assert the reverse ("without a swap, the cached value stays
    /// stuck") -- `TestMode.clearTestState()` calls `DiagnosticLogFile.invalidateEnabledCache()`
    /// and is invoked from setup helpers across many other test suites (e.g.
    /// `Tier2/FocusModeTests`, `Tier2/ProjectLifecycleTests`, `AppDefaultsTests`). Swift Testing
    /// runs suites in parallel and `.serialized` here only orders this suite against itself, so
    /// a concurrent suite's `clearTestState()` call could invalidate the process-global cache
    /// mid-test and flip such an assertion. This test only relies on values it itself wrote
    /// being observable after ITS OWN seam swap, which holds regardless of any concurrent
    /// invalidation elsewhere.
    @Test func seamSwapInvalidatesEnabledCache() {
        let suiteNameA = "com.kerim.final-final.tests.\(UUID().uuidString)"
        let suiteNameB = "com.kerim.final-final.tests.\(UUID().uuidString)"
        let defaultsA = UserDefaults(suiteName: suiteNameA)!
        let defaultsB = UserDefaults(suiteName: suiteNameB)!
        defaultsA.set(false, forKey: DiagnosticLogFile.loggingEnabledDefaultsKey)
        defaultsB.set(true, forKey: DiagnosticLogFile.loggingEnabledDefaultsKey)

        let originalUserDefaults = DiagnosticLogFile.userDefaults
        defer {
            DiagnosticLogFile.userDefaults = originalUserDefaults
            defaultsA.removePersistentDomain(forName: suiteNameA)
            defaultsB.removePersistentDomain(forName: suiteNameB)
        }

        DiagnosticLogFile.userDefaults = defaultsA
        #expect(DiagnosticLogFile.isEnabled == false)

        // Swapping the seam must invalidate the cache -- if it didn't, this would still read
        // the cached `false` from defaultsA instead of defaultsB's `true`.
        DiagnosticLogFile.userDefaults = defaultsB
        #expect(DiagnosticLogFile.isEnabled == true)
    }

    /// With the seam held fixed on one store, flipping the underlying key in place is only
    /// observed once `invalidateEnabledCache()` is called.
    @Test func invalidateEnabledCachePicksUpAnInPlaceKeyChange() {
        let suiteName = "com.kerim.final-final.tests.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        testDefaults.set(false, forKey: DiagnosticLogFile.loggingEnabledDefaultsKey)

        let originalUserDefaults = DiagnosticLogFile.userDefaults
        DiagnosticLogFile.userDefaults = testDefaults
        defer {
            DiagnosticLogFile.userDefaults = originalUserDefaults
            testDefaults.removePersistentDomain(forName: suiteName)
        }

        #expect(DiagnosticLogFile.isEnabled == false)

        testDefaults.set(true, forKey: DiagnosticLogFile.loggingEnabledDefaultsKey)
        DiagnosticLogFile.invalidateEnabledCache()

        #expect(DiagnosticLogFile.isEnabled == true)
    }

    /// `TestMode.clearTestState()` is a third production call site that invalidates
    /// `enabledCache` (alongside the `userDefaults` seam swap above and
    /// `DiagnosticsSettings.loggingEnabled`'s didSet, covered in
    /// `DiagnosticsSettingsTests.loggingEnabledDidSetInvalidatesDiagnosticLogFileCache`) --
    /// deleting its `invalidateEnabledCache()` call would pass the rest of this suite
    /// unchanged, so it needs its own direct coverage.
    ///
    /// Unlike every other test above, this one can't route through a private isolated
    /// `UserDefaults` suite: `clearTestState()` always operates on `AppDefaults.store` directly,
    /// not through the `DiagnosticLogFile.userDefaults` seam. So this points the seam AT
    /// `AppDefaults.store` itself (its default value during a unit test run, but pinned
    /// explicitly here so the test doesn't depend on no other suite having it mid-swap) rather
    /// than a throwaway suite. `AppDefaults.store` is a single domain shared by the whole test
    /// process and `clearTestState()` is called from setup helpers across many other suites
    /// (see the note on `seamSwapInvalidatesEnabledCache` above) -- like those existing
    /// cross-suite-invalidation risks, this test only relies on the value it itself wrote being
    /// observable immediately after its own `set`/prime/`clearTestState()` sequence, not on the
    /// key staying untouched for the test's full duration.
    @Test func clearTestStateInvalidatesEnabledCache() {
        let originalUserDefaults = DiagnosticLogFile.userDefaults
        DiagnosticLogFile.userDefaults = AppDefaults.store
        defer { DiagnosticLogFile.userDefaults = originalUserDefaults }

        AppDefaults.store.set(true, forKey: DiagnosticLogFile.loggingEnabledDefaultsKey)
        DiagnosticLogFile.invalidateEnabledCache()
        #expect(DiagnosticLogFile.isEnabled == true)  // primes the cache with the pre-clear value

        TestMode.clearTestState()

        #expect(DiagnosticLogFile.isEnabled == false)
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
