//
//  DiagnosticLogFile.swift
//  final final
//
//  Persistent, size-rotated log sink for DebugLog. Off by default; gated by a
//  runtime UserDefaults toggle (see DiagnosticsSettings) rather than a compile-time
//  DEBUG flag, so it also compiles into (and can run in) Release builds.
//

import Foundation
import os

/// Appends `DebugLog` lines to disk at
/// `~/Library/Application Support/com.kerim.final-final/Diagnostics/diagnostic.log`,
/// chosen over `~/Library/Caches/...` (where `ExportService`'s diagnostic dumps live)
/// because Caches is evictable under storage pressure and this log must survive until
/// the user notices a problem and generates a report.
///
/// **Rotation** is size-capped, not time-capped: `maxFileSize` per file, `maxRotatedFiles`
/// rotated slots (`diagnostic.log`, `.log.1`, `.log.2`, ...) — a small, concrete total disk
/// footprint (2 MiB × 3 files = ~6 MiB with the production defaults) instead of unbounded growth.
///
/// **Thread-safety:** `DebugLog.log()` is called from arbitrary threads (the 500ms
/// BlockSyncService polling loop, the GRDB writer queue, the main thread, etc.). This type
/// is `@unchecked Sendable`, guarded by an `NSLock` — same idiom as `WriterActivityRecorder`/
/// `PipeDataAccumulator` in `ExportService.swift`. `isEnabled` deliberately reads the raw
/// UserDefaults key directly (thread-safe for reads) instead of going through the `@MainActor`
/// `DiagnosticsSettings` singleton, so gating a background-thread log call never forces an
/// actor hop or an `async` `DebugLog.log()`. That read is cached (`enabledCache`, an
/// `OSAllocatedUnfairLock`) rather than hitting UserDefaults on every call — see `isEnabled`.
///
/// **Write mechanism:** `append(_:)` uses `FileHandle.write(contentsOf:)` — an unbuffered
/// call straight to the `write(2)` syscall. The kernel has the bytes before the call returns,
/// so a SIGTRAP crash immediately after does not lose the line (unlike accumulating a Swift
/// `String`/buffer and flushing periodically).
final class DiagnosticLogFile: @unchecked Sendable {
    static let shared = DiagnosticLogFile()
    static let loggingEnabledDefaultsKey = "com.kerim.final-final.diagnosticsLoggingEnabled"

    /// Test seam: `DiagnosticLogFileTests` overrides this to a per-test isolated
    /// `UserDefaults(suiteName:)` instance so tests never read/write the real
    /// `com.kerim.final-final` defaults domain. Defaults to `AppDefaults.store` — `.standard`
    /// in production, an isolated test-only suite while any kind of test is running — so a
    /// unit test run that never overrides this seam still can't wipe the real domain's
    /// `loggingEnabled` key via `TestMode.clearTestState()`. `nonisolated(unsafe)` because
    /// `isEnabled` (like the rest of this type) must remain readable from arbitrary threads;
    /// `UserDefaults` itself is thread-safe. Today only `DiagnosticLogFileTests` and
    /// `DiagnosticsSettingsTests` write this property, each `.serialized` within itself — but
    /// `.serialized` only orders a suite against its own tests, not against other suites, which
    /// Swift Testing runs concurrently by default. That gives no protection between those two
    /// suites, or against a future suite that also writes this property; any such suite needs
    /// the same single-writer-at-a-time discipline, not a false sense of safety from
    /// `.serialized` alone. Swapping this seam invalidates `enabledCache` below (via the
    /// setter), so a test that points it at a different store never observes a value cached from
    /// the previous one.
    nonisolated(unsafe) private static var _userDefaults: UserDefaults = AppDefaults.store
    static var userDefaults: UserDefaults {
        get { _userDefaults }
        set {
            _userDefaults = newValue
            invalidateEnabledCache()
        }
    }

    /// Backing cache for `isEnabled`. `nil` means "not cached, next read must hit UserDefaults".
    private static let enabledCache = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    /// Whether diagnostic logging is enabled. **Cached**, not a live UserDefaults read on every
    /// call: `append()` below is invoked from arbitrary threads at high frequency (the 500ms
    /// BlockSyncService polling loop, etc.), and a Time Profiler-verified investigation (see
    /// `AppDelegate.flushWindowFrame`'s doc comment) found that a `UserDefaults.bool(forKey:)`
    /// read immediately after a write to the same UserDefaults domain reliably triggers a
    /// multi-second cfprefsd hang — exactly the failure mode a "just read it every time, it's
    /// cheap" approach walks into. The cache is refreshed only by `invalidateEnabledCache()`,
    /// called from this app's own known writers of the underlying key or the `userDefaults`
    /// seam: the `DiagnosticsSettings.loggingEnabled` setter, `TestMode.clearTestState()`, and
    /// the `userDefaults` seam's own setter above (used by tests) — never on a timer or read
    /// count. An external change to the same UserDefaults domain that doesn't go through one of
    /// those three (e.g. `defaults write` from Terminal, or any other process writing this
    /// app's UserDefaults domain directly) is NOT observed until one of them happens to run
    /// afterward and invalidate the cache.
    ///
    /// **Non-recursion invariant:** the UserDefaults read below runs *inside* `enabledCache`'s
    /// lock, and on this process's first-ever access to `userDefaults` also triggers `AppDefaults
    /// .store`'s lazy initialization (see its own doc comment). `enabledCache`'s lock is not
    /// recursive, so nothing reachable from `AppDefaults.store`'s init path, and nothing reachable
    /// from `TestMode.isTesting` (which that init path reads), may ever call `DebugLog.log()` or
    /// `isEnabled` itself — that would deadlock this thread against itself. Not a bug today
    /// (verified: neither does), but an invariant a future change to either path must preserve.
    static var isEnabled: Bool {
        // Investigative-only override for the doc-open-blank-regression task: lets a UI test
        // force logging on without touching UserDefaults/AppDefaults.store at all, sidestepping
        // TestMode.clearTestState()'s unconditional wipe of loggingEnabledDefaultsKey. Pure env
        // read -- no lock interaction, so it can't touch this function's documented
        // non-recursion invariant below.
        if ProcessInfo.processInfo.environment["FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING"] == "1" {
            return true
        }
        return enabledCache.withLock { cached in
            if let cached { return cached }
            // The UserDefaults read MUST happen inside the lock, not before it: reading outside
            // and only storing the result inside would let a descheduled reader resume after a
            // concurrent invalidate+flip and clobber the cache with its own now-stale value,
            // latching the wrong answer until the next invalidation (which may never come).
            let value = userDefaults.bool(forKey: loggingEnabledDefaultsKey)
            cached = value
            return value
        }
    }

    /// Forces the next `isEnabled` read to re-fetch from UserDefaults instead of returning the
    /// cached value. Callers MUST invoke this AFTER the underlying value has actually changed
    /// (the UserDefaults write has landed, or the `userDefaults` seam has been swapped) — never
    /// before. Invalidating first, then writing, reopens the same stale-cache race described on
    /// `isEnabled`: a reader could repopulate the cache from the pre-write value in the gap.
    static func invalidateEnabledCache() {
        enabledCache.withLock { $0 = nil }
    }

    static let defaultLogDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("com.kerim.final-final", isDirectory: true)
                    .appendingPathComponent("Diagnostics", isDirectory: true)
    }()

    private static let activeFileName = "diagnostic.log"

    private let lock = NSLock()              // same idiom as WriterActivityRecorder/PipeDataAccumulator
    private let logDirectory: URL
    private let maxFileSize: UInt64
    private let maxRotatedFiles: Int
    private var fileHandle: FileHandle?
    private var currentSize: UInt64 = 0

    /// Deliberately **not** `private` (unlike `ProofingSettings`/`DiagnosticsSettings`) —
    /// tests construct their own instance pointed at a temp directory with a tiny
    /// `maxFileSize` so rotation is exercised in a handful of `append()` calls, not
    /// 2 MiB of writes. `.shared` remains the only instance production code uses.
    init(
        logDirectory: URL = DiagnosticLogFile.defaultLogDirectory,
        maxFileSize: UInt64 = 2 * 1024 * 1024,
        maxRotatedFiles: Int = 2
    ) {
        self.logDirectory = logDirectory
        self.maxFileSize = maxFileSize
        self.maxRotatedFiles = maxRotatedFiles
    }

    /// Appends one line, timestamped. No-op (cached-enabled check, not a live UserDefaults read
    /// — see `isEnabled`) when disabled.
    func append(_ line: String) {
        guard Self.isEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        openIfNeeded()
        let data = Data((isoTimestamp() + " " + line + "\n").utf8)
        if currentSize + UInt64(data.count) > maxFileSize {
            rotate()
            openIfNeeded()
        }
        guard let fileHandle else { return }
        do {
            try fileHandle.write(contentsOf: data)
            currentSize += UInt64(data.count)
        } catch {
            // Best-effort logging: a failed write must never crash or throw up the call chain.
        }
    }

    /// All existing log file URLs (current-first: `diagnostic.log`, `.log.1`, `.log.2`, ...).
    /// Unlocked — for callers that only need to enumerate files, not copy them; the diagnostic
    /// report generator uses the lock-protected `copyLogFiles(to:)` below instead.
    static func allLogFileURLs() -> [URL] { shared.existingLogFileURLs() }

    /// Copies every existing log file into `destinationDirectory`, holding the same `lock`
    /// that guards `append()`/`rotate()` around the entire listing+copy sequence — so a
    /// report generated while a background thread is mid-`append()` or mid-rotation never
    /// captures a half-written file or silently drops the active log because it was mid-move.
    ///
    /// Throws only if `destinationDirectory` itself can't be created. Per-file copy failures
    /// (e.g. a file vanishing for an unrelated reason) are tolerated: that file is simply
    /// omitted from the returned array, which lists only the URLs of what was actually copied.
    func copyLogFiles(to destinationDirectory: URL) throws -> [URL] {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        var copiedURLs: [URL] = []
        for sourceURL in existingLogFileURLs() {
            let destinationFileURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            try? fm.removeItem(at: destinationFileURL)  // in case of a stale leftover from a prior report
            if (try? fm.copyItem(at: sourceURL, to: destinationFileURL)) != nil {
                copiedURLs.append(destinationFileURL)
            }
        }
        return copiedURLs
    }

    // MARK: - Private helpers

    /// Slot 0 is the active `diagnostic.log`; slot N>0 is `diagnostic.log.<N>`.
    private func fileURL(forSlot slot: Int) -> URL {
        slot == 0
            ? logDirectory.appendingPathComponent(Self.activeFileName)
            : logDirectory.appendingPathComponent("\(Self.activeFileName).\(slot)")
    }

    /// Opens (or creates) the active log file for appending if not already open.
    /// Must be called with `lock` held.
    private func openIfNeeded() {
        guard fileHandle == nil else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        } catch {
            return
        }
        let activeURL = fileURL(forSlot: 0)
        if !fm.fileExists(atPath: activeURL.path) {
            fm.createFile(atPath: activeURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: activeURL) else { return }
        handle.seekToEndOfFile()
        if let attributes = try? fm.attributesOfItem(atPath: activeURL.path),
           let size = attributes[.size] as? NSNumber {
            currentSize = size.uint64Value
        } else {
            currentSize = 0
        }
        fileHandle = handle
    }

    /// Shifts every rotated slot up by one, dropping the oldest, then the active file
    /// becomes `.log.1`. Must be called with `lock` held; closes `fileHandle` first.
    ///
    /// ```
    /// close fileHandle; fileHandle = nil
    /// remove diagnostic.log.<maxRotatedFiles>          // drop oldest, no-op if absent
    /// for i in stride(from: maxRotatedFiles, to: 1, by: -1):
    ///     move diagnostic.log.<i-1> -> diagnostic.log.<i>   (if i-1 == 0, source is "diagnostic.log" itself)
    /// currentSize = 0
    /// ```
    private func rotate() {
        try? fileHandle?.close()
        fileHandle = nil

        let fm = FileManager.default
        try? fm.removeItem(at: fileURL(forSlot: maxRotatedFiles))

        var slot = maxRotatedFiles
        while slot >= 1 {
            let source = fileURL(forSlot: slot - 1)
            let destination = fileURL(forSlot: slot)
            if fm.fileExists(atPath: source.path) {
                try? fm.moveItem(at: source, to: destination)
            }
            slot -= 1
        }
        currentSize = 0
    }

    /// Existing log file URLs (current-first). No locking needed: only reads immutable
    /// `let` properties (`logDirectory`, `maxRotatedFiles`) and on-disk state.
    ///
    /// Deliberately **not** `private` (same rationale as `init`) — tests construct their own
    /// instance pointed at a temp directory and need to inspect its file listing directly,
    /// without going through the `.shared` singleton (which is bound to real user state).
    func existingLogFileURLs() -> [URL] {
        let fm = FileManager.default
        return (0...maxRotatedFiles).compactMap { slot in
            let url = fileURL(forSlot: slot)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
    }

    private func isoTimestamp() -> String {
        Self.isoFormatter.string(from: Date())
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
