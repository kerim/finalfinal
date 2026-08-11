//
//  ExportService+Diagnostics.swift
//  final final
//

import Foundation
import GRDB     // TransactionObserver for the writer-activity diagnostic (see dumpExportDiagnostics)

// MARK: - Export Diagnostics (temporary, opt-in)
//
// DIAGNOSTIC CODE — see docs/plans/mossy-tumbling-stroustrup.md.
// Investigates a PDF-only page-1 reordering bug. This whole extension, the
// `stderrCaptureURL:` parameter on `runPandoc`, and its call site in `export(...)`
// are removed once Step 3 of that plan lands a targeted fix. Off by default, gated by
// `isDiagnosticCaptureEnabled` (Preferences -> Diagnostics -> Export Diagnostic Capture
// toggle) — see ExportDiagnosticCaptureGatingTests.swift for the gating coverage.

/// Parameters for `dumpExportDiagnostics`, grouped to keep the call site under the
/// function-parameter-count limit. Constructed in `export()`, consumed here.
struct ExportDiagnosticsRequest {
    let rawContent: String
    let inputURL: URL
    let pandocPath: String
    let arguments: [String]
    let format: ExportFormat
    let projectURL: URL?
}

extension ExportService {

    static let diagnosticSubdirectory = "com.kerim.final-final/pdf-export-debug"
    private static let diagnosticRetentionLimit = 20

    /// UserDefaults key backing the "Enable export diagnostic capture" toggle in
    /// Preferences -> Diagnostics (see DiagnosticsSettings.exportDiagnosticCaptureEnabled).
    static let diagnosticCaptureEnabledDefaultsKey = "com.kerim.final-final.exportDiagnosticCaptureEnabled"

    /// Test seam: `ExportDiagnosticCaptureGatingTests` overrides this to a per-test isolated
    /// `UserDefaults(suiteName:)` instance so tests never read/write the real
    /// `com.kerim.final-final` defaults domain. Defaults to `AppDefaults.store` — `.standard`
    /// in production, an isolated test-only suite while any kind of test is running — so a
    /// unit test run that never overrides this seam still shares the same domain as
    /// `DiagnosticsSettings.userDefaults` (both back `exportDiagnosticCaptureEnabled`) instead
    /// of silently reading/writing two different `UserDefaults` instances.
    /// `nonisolated(unsafe)` — same idiom as `DiagnosticLogFile.userDefaults` — because static
    /// members of an actor are not actor-isolated by default.
    nonisolated(unsafe) static var userDefaults: UserDefaults = AppDefaults.store

    static var isDiagnosticCaptureEnabled: Bool { userDefaults.bool(forKey: diagnosticCaptureEnabledDefaultsKey) }

    /// Captures everything needed to distinguish "GRDB returned a stale block list" from
    /// "a writer fired during the export window" from "assembly/pandoc/xelatex produced
    /// wrong bytes given identical input" — see the plan's Step 2 decision tree.
    ///
    /// Off by default, gated by `isDiagnosticCaptureEnabled`. When enabled, fires for every
    /// export format and writes into
    /// `~/Library/Caches/com.kerim.final-final/pdf-export-debug/<timestamp>-<uuid8>/`.
    ///
    /// - Returns: The created dump directory URL on success; `nil` when gated off or on any
    ///   internal failure. Failures are logged via `DebugLog` only and never surfaced to the
    ///   user — a diagnostic capture failing is not itself an export warning.
    func dumpExportDiagnostics(_ request: ExportDiagnosticsRequest) async -> URL? {
        guard Self.isDiagnosticCaptureEnabled else { return nil }

        let fm = FileManager.default

        guard let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            DebugLog.log(.fileOps, "[ExportService] Export diagnostic failed to save: could not resolve caches directory")
            return nil
        }
        let baseDir = cachesDir.appendingPathComponent(Self.diagnosticSubdirectory, isDirectory: true)

        // Prune BEFORE creating the new directory so retention counts pre-existing dumps only.
        pruneOldDiagnosticDumps(in: baseDir, keeping: Self.diagnosticRetentionLimit)

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = isoFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let uuid8 = String(UUID().uuidString.prefix(8))
        let dirURL = baseDir.appendingPathComponent("\(timestamp)-\(uuid8)", isDirectory: true)

        // Directory creation + the first artifact write: failure aborts the capture (logged
        // only — see the doc comment above on why this never surfaces to the user).
        do {
            try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
            try request.rawContent.write(to: dirURL.appendingPathComponent("input-raw.md"), atomically: true, encoding: .utf8)
        } catch {
            DebugLog.log(.fileOps, "[ExportService] Export diagnostic failed to save: \(error.localizedDescription)")
            return nil
        }

        // Begin observing GRDB writer activity as early as possible in the capture window.
        let database = await DocumentManager.shared.projectDatabase
        let writerRecorder = WriterActivityRecorder()
        if let database {
            database.dbWriter.add(transactionObserver: writerRecorder)
        }
        defer {
            if let database {
                database.dbWriter.remove(transactionObserver: writerRecorder)
            }
        }

        // input.md — ground-truth bytes pandoc actually consumes (past annotation-strip +
        // image-prep rewrite + the UTF-8 file write).
        if let inputData = try? Data(contentsOf: request.inputURL) {
            try? inputData.write(to: dirURL.appendingPathComponent("input.md"))
        }

        // args.txt — pandoc path + format headers, then one argument per line (newline
        // separation preserves arguments containing spaces, e.g. `-V CJKmainfont=...`).
        var argsLines = ["pandoc=\(request.pandocPath)", "format=\(request.format.rawValue)"]
        argsLines.append(contentsOf: request.arguments)
        try? argsLines.joined(separator: "\n").write(
            to: dirURL.appendingPathComponent("args.txt"),
            atomically: true,
            encoding: .utf8
        )

        // env.txt — filtered environment snapshot.
        try? diagnosticEnvironmentSnapshot().write(
            to: dirURL.appendingPathComponent("env.txt"),
            atomically: true,
            encoding: .utf8
        )

        // system-info.txt
        try? diagnosticSystemInfo().write(
            to: dirURL.appendingPathComponent("system-info.txt"),
            atomically: true,
            encoding: .utf8
        )

        // blocks.tsv — out-of-process SQLite snapshot, deliberately decoupled from any
        // GRDB-internal cache/snapshot state (see plan for why this must be a subprocess).
        await dumpBlocksTable(projectURL: request.projectURL, to: dirURL.appendingPathComponent("blocks.tsv"))

        // writer-activity.log — GRDB writer-transaction completions observed during this
        // capture window (used to rule out a benign write race — see plan Step 2, 1a-prime).
        let writerLines: [String]
        if database != nil {
            writerLines = writerRecorder.snapshotLines()
        } else {
            writerLines = ["# no active project database — writer activity could not be observed"]
        }
        try? writerLines.joined(separator: "\n").write(
            to: dirURL.appendingPathComponent("writer-activity.log"),
            atomically: true,
            encoding: .utf8
        )

        DebugLog.log(.fileOps, "[ExportService] Export diagnostic dump saved to \(dirURL.path)")

        return dirURL
    }

    /// Keep at most `limit` most-recent (lexicographically-descending, i.e. newest-first
    /// since names are ISO8601-timestamp-prefixed) dump subdirectories.
    private func pruneOldDiagnosticDumps(in baseDir: URL, keeping limit: Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return  // Base directory doesn't exist yet (first-ever export) — nothing to prune.
        }

        let dumpDirs = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        guard dumpDirs.count > limit else { return }
        for staleDir in dumpDirs.dropFirst(limit) {
            try? fm.removeItem(at: staleDir)
        }
    }

    /// Read-only listing for the Diagnostics report generator — does not prune or mutate anything.
    static func recentExportDiagnosticDirectories(limit: Int) -> [URL] {
        let fm = FileManager.default
        guard let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return [] }
        let baseDir = cachesDir.appendingPathComponent(diagnosticSubdirectory, isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }   // ISO8601 names sort newest-first
            .prefix(limit)
            .map { $0 }
    }

    /// Filtered `ProcessInfo.processInfo.environment` snapshot — PATH, HOME, TMPDIR, USER,
    /// PWD, SHELL, LANG, LC_*, TEXMF*, FONTCONFIG_PATH, OSFONTDIR, PANDOC_*.
    private func diagnosticEnvironmentSnapshot() -> String {
        let exactKeys: Set<String> = ["PATH", "HOME", "TMPDIR", "USER", "PWD", "SHELL", "LANG",
                                       "FONTCONFIG_PATH", "OSFONTDIR"]
        let prefixes = ["LC_", "TEXMF", "PANDOC_"]

        return ProcessInfo.processInfo.environment
            .filter { key, _ in exactKeys.contains(key) || prefixes.contains { key.hasPrefix($0) } }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }

    /// macOS version, hostname, locale, preferred languages, time zone, current date.
    private func diagnosticSystemInfo() -> String {
        let info = ProcessInfo.processInfo
        return [
            "macOSVersion=\(info.operatingSystemVersionString)",
            "hostname=\(info.hostName)",
            "locale=\(Locale.current.identifier)",
            "preferredLanguages=\(Locale.preferredLanguages.joined(separator: ","))",
            "timeZone=\(TimeZone.current.identifier)",
            "date=\(ISO8601DateFormatter().string(from: Date()))"
        ].joined(separator: "\n")
    }

    /// Dumps the `block` table via a fresh out-of-process `/usr/bin/sqlite3` connection
    /// (no shared statement cache, connection pool, or WAL snapshot with GRDB — so if GRDB
    /// itself returns a stale view, this subprocess dump shows the on-disk truth instead of
    /// silently agreeing with the buggy view).
    private func dumpBlocksTable(projectURL: URL?, to fileURL: URL) async {
        guard let projectURL else {
            try? "# blocks.tsv capture failed: no project URL available for this export\n".write(
                to: fileURL, atomically: true, encoding: .utf8
            )
            return
        }

        guard FileManager.default.fileExists(atPath: "/usr/bin/sqlite3") else {
            try? "# blocks.tsv capture failed: /usr/bin/sqlite3 not found\n".write(
                to: fileURL, atomically: true, encoding: .utf8
            )
            return
        }

        let dbPath = projectURL.appendingPathComponent("content.sqlite").path
        let sql = """
            SELECT id, projectId, sortOrder, blockType, headingLevel, isBibliography,
                   isPseudoSection, isNotes, length(markdownFragment) AS frag_len,
                   updatedAt, substr(markdownFragment, 1, 80) AS preview
              FROM block
              ORDER BY sortOrder, blockType;
            """

        let result = await runSQLite3Dump(dbPath: dbPath, sql: sql)

        var output = result.stdout
        if !result.stderr.isEmpty {
            output += "\n# stderr:\n" + result.stderr
        }
        if result.exitCode != 0 {
            output = "# blocks.tsv capture failed: sqlite3 exited with status \(result.exitCode)\n" + output
        }
        try? output.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Result of running `/usr/bin/sqlite3` as a subprocess.
    private struct SQLite3DumpResult: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    /// Runs `/usr/bin/sqlite3` as a subprocess and returns its stdout/stderr/exit code.
    /// `.timeout 5000` guards against `SQLITE_BUSY` if a GRDB writer is mid-commit when the
    /// subprocess opens its own connection (default sqlite3 busy timeout is 0 ms).
    private func runSQLite3Dump(dbPath: String, sql: String) async -> SQLite3DumpResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<SQLite3DumpResult, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [
                "-bail",
                "-cmd", ".timeout 5000",
                "-cmd", ".mode tabs",
                "-cmd", ".headers on",
                dbPath,
                sql
            ]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Drain both pipes concurrently while the process runs. macOS pipes have a
            // ~64KB kernel buffer; a full `block` table dump can exceed that for an
            // ordinary document. Reading only after termination would let the child block
            // on write() to the full pipe and never exit, so `terminationHandler` would
            // never fire and the continuation would hang forever.
            let stdoutBuffer = PipeDataAccumulator()
            let stderrBuffer = PipeDataAccumulator()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil  // EOF
                } else {
                    stdoutBuffer.append(data)
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil  // EOF
                } else {
                    stderrBuffer.append(data)
                }
            }

            var hasResumed = false  // Guard against double-resume

            process.terminationHandler = { proc in
                guard !hasResumed else { return }
                hasResumed = true
                let stdoutData = stdoutBuffer.data
                let stderrData = stderrBuffer.data
                continuation.resume(returning: SQLite3DumpResult(
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? "",
                    exitCode: proc.terminationStatus
                ))
            }

            do {
                try process.run()
            } catch {
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(returning: SQLite3DumpResult(stdout: "", stderr: error.localizedDescription, exitCode: -1))
            }
        }
    }
}

/// Accumulates bytes read from a `Pipe` off of a `FileHandle.readabilityHandler`, which fires
/// on a background dispatch queue — not necessarily the same thread as `terminationHandler`,
/// which later reads the accumulated result. Guarded by `NSLock`, matching the discipline
/// `WriterActivityRecorder` below uses for its own cross-thread mutable state.
private final class PipeDataAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ newData: Data) {
        lock.lock()
        buffer.append(newData)
        lock.unlock()
    }

    /// Snapshot of the bytes accumulated so far, under lock.
    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

/// Records GRDB writer-transaction completions for `writer-activity.log`.
///
/// `databaseDidChange(with:)`/`databaseDidCommit(_:)` fire on GRDB's writer dispatch queue,
/// not on the export's async context — a naive `Array` append-then-read-later would be a
/// data race. The accumulator is guarded by `NSLock`; `@unchecked Sendable` documents that
/// this class's thread-safety is manually verified, not compiler-inferred.
private final class WriterActivityRecorder: TransactionObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingEvents: [(kind: String, table: String)] = []
    private var lines: [String] = []

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        true  // Observe every table — autosave/editor-bridge writes may touch tables besides `block`.
    }

    func databaseDidChange(with event: DatabaseEvent) {
        let kind: String
        switch event.kind {
        case .insert: kind = "insert"
        case .update: kind = "update"
        case .delete: kind = "delete"
        }
        lock.lock()
        pendingEvents.append((kind, event.tableName))
        lock.unlock()
    }

    func databaseDidCommit(_ db: Database) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        lock.lock()
        let events = pendingEvents
        pendingEvents.removeAll()
        for event in events {
            lines.append("\(timestamp)\t\(event.kind)\t\(event.table)")
        }
        lock.unlock()
    }

    func databaseDidRollback(_ db: Database) {
        lock.lock()
        pendingEvents.removeAll()
        lock.unlock()
    }

    /// Snapshot of completed writer-transaction lines observed so far, under lock.
    func snapshotLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
