//
//  ExportService.swift
//  final final
//
//  Core export service for converting markdown to Word/PDF/ODT via Pandoc.
//  Uses async/await with Process for non-blocking execution.
//

import AppKit  // NSImage/NSBitmapImageRep for image conversion — no main thread required
import Foundation
import GRDB     // TransactionObserver for the writer-activity diagnostic (see dumpExportDiagnostics)
import NaturalLanguage

/// Errors that can occur during export
enum ExportError: Error, LocalizedError {
    case pandocNotFound
    case pandocFailed(exitCode: Int, message: String)
    case luaScriptNotFound(String)
    case referenceDocNotFound(String)
    case tempFileCreationFailed
    case invalidOutputPath
    case noContent

    var errorDescription: String? {
        switch self {
        case .pandocNotFound:
            return "Pandoc is not installed. Please install Pandoc to export documents."
        case .pandocFailed(let code, let message):
            return "Pandoc failed with exit code \(code): \(message)"
        case .luaScriptNotFound(let path):
            return "Lua filter script not found: \(path)"
        case .referenceDocNotFound(let path):
            return "Reference document not found: \(path)"
        case .tempFileCreationFailed:
            return "Failed to create temporary file for export"
        case .invalidOutputPath:
            return "Invalid output file path"
        case .noContent:
            return "No content to export"
        }
    }
}

/// Result of an export operation
struct ExportResult: Sendable {
    let outputURL: URL
    let format: ExportFormat
    let zoteroStatus: ZoteroStatus
    let warnings: [String]
}

/// Actor for performing exports (I/O work, off main thread)
actor ExportService {

    private let pandocLocator: PandocLocator
    private let zoteroChecker: ZoteroChecker

    /// Image formats that xelatex can handle natively
    private static let xelatexSupportedExtensions: Set<String> = ["png", "jpg", "jpeg", "bmp", "pdf"]

    /// Matches markdown image syntax: ![alt](media/filename)
    /// Anchored on `!\[` to avoid matching regular links
    private static let imagePathPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"!\[[^\]]*\]\(media/([^)]+)\)"#)
    }()

    init() {
        self.pandocLocator = PandocLocator()
        self.zoteroChecker = ZoteroChecker()
    }

    // MARK: - Configuration

    /// Configure Pandoc path from settings
    func configure(with settings: ExportSettings) async {
        await pandocLocator.setCustomPath(settings.customPandocPath)
    }

    // MARK: - Status Checks

    /// Check Pandoc status
    func checkPandoc() async -> PandocStatus {
        await pandocLocator.locate()
    }

    /// Check Zotero status
    func checkZotero() async -> ZoteroStatus {
        await zoteroChecker.check()
    }

    /// Refresh Pandoc status (clear cache and re-check)
    func refreshPandocStatus() async -> PandocStatus {
        await pandocLocator.clearCache()
        return await pandocLocator.locate()
    }

    // MARK: - Export

    /// Export markdown content to the specified format
    /// - Parameters:
    ///   - content: Markdown content to export
    ///   - outputURL: Destination file URL
    ///   - format: Export format (docx, pdf, odt)
    ///   - settings: Export settings
    /// - Returns: ExportResult with details
    func export(
        content: String,
        to outputURL: URL,
        format: ExportFormat,
        settings: ExportSettings,
        projectURL: URL? = nil
    ) async throws -> ExportResult {

        // Validate content
        guard !content.isEmpty else {
            throw ExportError.noContent
        }

        // Strip annotations if not including them
        var processedContent = content
        if !settings.includeAnnotations {
            processedContent = stripAnnotations(from: content)
        }

        // Check Pandoc availability
        guard let pandocPath = await pandocLocator.getPath() else {
            throw ExportError.pandocNotFound
        }

        // Only check Zotero if content appears to have citations
        let hasCitations = hasPandocCitations(in: processedContent)
        // Zotero status only matters for citation processing
        // When no citations, .running means "no issue" (status is irrelevant)
        let zoteroStatus: ZoteroStatus = hasCitations
            ? await zoteroChecker.check()
            : .running

        // Get resource paths
        let luaScriptPath = settings.effectiveLuaScriptPath
        let referenceDocPath = settings.effectiveReferenceDocPath(for: format)

        // Validate Lua script if needed (DOCX/ODT only; PDF uses --citeproc)
        if format != .pdf, let luaPath = luaScriptPath {
            guard FileManager.default.fileExists(atPath: luaPath) else {
                throw ExportError.luaScriptNotFound(luaPath)
            }
        }

        // Validate reference doc if specified
        if let refPath = referenceDocPath {
            guard FileManager.default.fileExists(atPath: refPath) else {
                throw ExportError.referenceDocNotFound(refPath)
            }
        }

        // Create temp files
        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent(UUID().uuidString + ".md")
        var tempBibURL: URL?
        var tempMediaDir: URL?

        do {
            try processedContent.write(to: inputURL, atomically: true, encoding: .utf8)
        } catch {
            throw ExportError.tempFileCreationFailed
        }

        defer {
            try? FileManager.default.removeItem(at: inputURL)
            if let bibURL = tempBibURL {
                try? FileManager.default.removeItem(at: bibURL)
            }
            if let mediaDir = tempMediaDir {
                try? FileManager.default.removeItem(at: mediaDir)
            }
        }

        // Collect warnings
        var warnings: [String] = []

        // For PDF export, convert unsupported images (WebP, HEIC, etc.) to PNG
        var effectiveResourceURL = projectURL
        if format == .pdf, let projURL = projectURL {
            let prep = prepareImagesForPDF(content: processedContent, projectURL: projURL)
            if prep.resourceDir != projURL {
                // Conversion happened — use temp dir and rewritten content
                processedContent = prep.content
                effectiveResourceURL = prep.resourceDir
                tempMediaDir = prep.resourceDir
                warnings.append(contentsOf: prep.warnings)
                // Re-write temp input file with updated image paths
                try processedContent.write(to: inputURL, atomically: true, encoding: .utf8)
            }
        }

        // Build Pandoc arguments
        var arguments = [
            inputURL.path,
            "--from", "markdown",
            "--to", format.pandocFormat,
            "--output", outputURL.path
        ]

        // Resource path for image resolution (media/ paths relative to .ff package)
        if let url = effectiveResourceURL {
            arguments.append(contentsOf: ["--resource-path", url.path])
        }

        // PDF: engine + font variables + figure placement pinning (fixes drift at page
        // breaks — see figure-placement.lua/float-package.tex). Both are optional: if the
        // bundled resources are somehow missing, PDF export still proceeds without the
        // placement fix rather than failing outright.
        if format == .pdf {
            arguments.append(contentsOf: pdfEngineArguments())
            arguments.append(contentsOf: fontArguments(for: processedContent))
            if let figurePlacementLuaPath = ExportService.bundledFigurePlacementLuaPath {
                arguments.append(contentsOf: ["--lua-filter", figurePlacementLuaPath])
            }
            if let floatPackagePath = ExportService.bundledFloatPackageTexPath {
                arguments.append(contentsOf: ["--include-in-header", floatPackagePath])
            }
        }

        // Reference document (DOCX/ODT only)
        if let refPath = referenceDocPath, format != .pdf {
            arguments.append(contentsOf: ["--reference-doc", refPath])
        }

        // Citations
        if hasCitations {
            let citation = await citationArguments(
                format: format,
                content: processedContent,
                zoteroStatus: zoteroStatus,
                luaScriptPath: luaScriptPath,
                tempDir: tempDir
            )
            arguments.append(contentsOf: citation.arguments)
            tempBibURL = citation.tempBibURL
            warnings.append(contentsOf: citation.warnings)
        }

        // DIAGNOSTIC (temporary, opt-in — see docs/plans/mossy-tumbling-stroustrup.md, removed
        // once the fix for the PDF page-1 reorder bug lands). Off by default; gated by
        // isDiagnosticCaptureEnabled (Preferences -> Diagnostics -> Export Diagnostic Capture).
        // When enabled, fires for every format so a PDF -> Word -> PDF reproduction sequence
        // captures three side-by-side dumps. Never contributes to `warnings` — a diagnostic
        // dump succeeding or failing is not itself a user-facing export warning.
        let diagnosticDirURL = await dumpExportDiagnostics(
            rawContent: content,
            inputURL: inputURL,
            pandocPath: pandocPath,
            arguments: arguments,
            format: format,
            projectURL: projectURL
        )

        // Run Pandoc
        try await runPandoc(
            at: pandocPath,
            arguments: arguments,
            stderrCaptureURL: diagnosticDirURL?.appendingPathComponent("pandoc-stderr.log")
        )

        // Zotero warnings (after export — export still runs, warnings inform after)
        if hasCitations {
            warnings.append(contentsOf: zoteroWarnings(for: zoteroStatus))
        }

        return ExportResult(
            outputURL: outputURL,
            format: format,
            zoteroStatus: zoteroStatus,
            warnings: warnings
        )
    }

    // MARK: - Extracted Helpers

    /// Build PDF engine arguments (bundled TinyTeX → bundled xelatex → system xelatex)
    private func pdfEngineArguments() -> [String] {
        if let tinyTeX = try? prepareBundledTinyTeX() {
            return ["--pdf-engine", tinyTeX.xelatexPath,
                    "--pdf-engine-opt", tinyTeX.outputDriverArg]
        } else if let bundledPath = ExportService.bundledXelatexPath {
            return ["--pdf-engine", bundledPath]
        } else {
            return ["--pdf-engine", "xelatex"]
        }
    }

    /// Build citation-related Pandoc arguments and fetch bibliography if needed.
    private func citationArguments(
        format: ExportFormat,
        content: String,
        zoteroStatus: ZoteroStatus,
        luaScriptPath: String?,
        tempDir: URL
    ) async -> (arguments: [String], tempBibURL: URL?, warnings: [String]) {
        var args: [String] = []
        var tempBibURL: URL?
        var warnings: [String] = []

        if format == .pdf {
            if zoteroStatus == .running {
                let citekeys = Array(Set(extractCitekeys(from: content)))
                if let bibJSON = await fetchBibliographyJSON(for: citekeys) {
                    let bibURL = tempDir.appendingPathComponent(UUID().uuidString + ".json")
                    do {
                        try bibJSON.write(to: bibURL, atomically: true, encoding: .utf8)
                        tempBibURL = bibURL
                        args.append(contentsOf: ["--citeproc", "--bibliography", bibURL.path])
                        if let cslPath = ExportService.bundledCSLStylePath {
                            args.append(contentsOf: ["--csl", cslPath])
                        }
                    } catch {
                        warnings.append("Could not write bibliography data. Citations were not resolved.")
                    }
                } else {
                    warnings.append("Could not fetch bibliography data from Zotero. Citations were not resolved.")
                }
            }
        } else {
            if let luaPath = luaScriptPath {
                args.append(contentsOf: ["--lua-filter", luaPath])
            }
        }

        return (args, tempBibURL, warnings)
    }

    /// Map Zotero status to user-facing warnings.
    private func zoteroWarnings(for status: ZoteroStatus) -> [String] {
        switch status {
        case .notRunning:
            return ["Zotero is not running. Citations were not resolved."]
        case .betterBibTeXMissing:
            return ["Better BibTeX is not installed. Citations were not resolved."]
        case .timeout:
            return ["Could not connect to Zotero. Citations may not be resolved."]
        case .error(let msg):
            return ["Zotero error: \(msg)"]
        case .running:
            return []
        }
    }

    // MARK: - Pandoc Execution

    /// Run Pandoc with the given arguments
    /// - Parameters:
    ///   - path: Path to Pandoc executable
    ///   - arguments: Command line arguments
    ///   - stderrCaptureURL: DIAGNOSTIC (temporary, see dumpExportDiagnostics) — when set,
    ///     the full pandoc stderr is written here regardless of exit status. Best-effort:
    ///     failure to write is silently ignored.
    private func runPandoc(at path: String, arguments: [String], stderrCaptureURL: URL? = nil) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments

                let stderrPipe = Pipe()
                process.standardError = stderrPipe
                process.standardOutput = Pipe()  // Discard stdout

                var hasResumed = false  // Guard against double-resume

                process.terminationHandler = { proc in
                    guard !hasResumed else { return }
                    hasResumed = true

                    // DIAGNOSTIC: always read stderr to disk, not just on failure, so a
                    // successful-but-wrong export (the PDF reorder bug) still leaves a trail.
                    let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    if let stderrCaptureURL {
                        try? errorData.write(to: stderrCaptureURL)
                    }

                    if proc.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let errorMessage = String(data: errorData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
                        continuation.resume(throwing: ExportError.pandocFailed(
                            exitCode: Int(proc.terminationStatus),
                            message: errorMessage
                        ))
                    }
                }

                do {
                    try process.run()
                } catch {
                    guard !hasResumed else { return }
                    hasResumed = true
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            // Task was cancelled - process will be terminated when it goes out of scope
            DebugLog.log(.fileOps, "[ExportService] Export cancelled")
        }
    }
}

// MARK: - Export Diagnostics (temporary, opt-in)
//
// DIAGNOSTIC CODE — see docs/plans/mossy-tumbling-stroustrup.md.
// Investigates a PDF-only page-1 reordering bug. This whole extension, the
// `stderrCaptureURL:` parameter on `runPandoc`, and its call site in `export(...)`
// are removed once Step 3 of that plan lands a targeted fix. Off by default, gated by
// `isDiagnosticCaptureEnabled` (Preferences -> Diagnostics -> Export Diagnostic Capture
// toggle) — see ExportDiagnosticCaptureGatingTests.swift for the gating coverage.

extension ExportService {

    static let diagnosticSubdirectory = "com.kerim.final-final/pdf-export-debug"
    private static let diagnosticRetentionLimit = 20

    /// UserDefaults key backing the "Enable export diagnostic capture" toggle in
    /// Preferences -> Diagnostics (see DiagnosticsSettings.exportDiagnosticCaptureEnabled).
    static let diagnosticCaptureEnabledDefaultsKey = "com.kerim.final-final.exportDiagnosticCaptureEnabled"

    /// Test seam: `ExportDiagnosticCaptureGatingTests` overrides this to a per-test isolated
    /// `UserDefaults(suiteName:)` instance so tests never read/write the real
    /// `com.kerim.final-final` defaults domain. Production code always leaves this at
    /// `.standard`. `nonisolated(unsafe)` — same idiom as `DiagnosticLogFile.userDefaults` —
    /// because static members of an actor are not actor-isolated by default.
    nonisolated(unsafe) static var userDefaults: UserDefaults = .standard

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
    private func dumpExportDiagnostics(
        rawContent: String,
        inputURL: URL,
        pandocPath: String,
        arguments: [String],
        format: ExportFormat,
        projectURL: URL?
    ) async -> URL? {
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
            try rawContent.write(to: dirURL.appendingPathComponent("input-raw.md"), atomically: true, encoding: .utf8)
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
        if let inputData = try? Data(contentsOf: inputURL) {
            try? inputData.write(to: dirURL.appendingPathComponent("input.md"))
        }

        // args.txt — pandoc path + format headers, then one argument per line (newline
        // separation preserves arguments containing spaces, e.g. `-V CJKmainfont=...`).
        var argsLines = ["pandoc=\(pandocPath)", "format=\(format.rawValue)"]
        argsLines.append(contentsOf: arguments)
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
        await dumpBlocksTable(projectURL: projectURL, to: dirURL.appendingPathComponent("blocks.tsv"))

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

    /// Runs `/usr/bin/sqlite3` as a subprocess and returns its stdout/stderr/exit code.
    /// `.timeout 5000` guards against `SQLITE_BUSY` if a GRDB writer is mid-commit when the
    /// subprocess opens its own connection (default sqlite3 busy timeout is 0 ms).
    private func runSQLite3Dump(dbPath: String, sql: String) async -> (stdout: String, stderr: String, exitCode: Int32) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(stdout: String, stderr: String, exitCode: Int32), Never>) in
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
                continuation.resume(returning: (
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
                continuation.resume(returning: (stdout: "", stderr: error.localizedDescription, exitCode: -1))
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

// MARK: - Bundle Resource Helpers

extension ExportService {

    /// Check if bundled export resources are available
    static func bundledResourcesAvailable() -> Bool {
        let luaPath = Bundle.main.url(forResource: "zotero", withExtension: "lua", subdirectory: "Export")
        let refPath = Bundle.main.url(forResource: "reference", withExtension: "docx", subdirectory: "Export")
        return luaPath != nil && refPath != nil
    }

    /// Get path to bundled Lua script
    static var bundledLuaScriptPath: String? {
        Bundle.main.url(forResource: "zotero", withExtension: "lua", subdirectory: "Export")?.path
    }

    /// Get path to the bundled PDF-only figure-placement Lua filter (pins captioned figures
    /// to `[H]` so they no longer float past following text at page breaks).
    static var bundledFigurePlacementLuaPath: String? {
        Bundle.main.url(forResource: "figure-placement", withExtension: "lua", subdirectory: "Export")?.path
    }

    /// Get path to the bundled `\usepackage{float}` header snippet required for the
    /// `[H]` placement specifier applied by figure-placement.lua to compile.
    static var bundledFloatPackageTexPath: String? {
        Bundle.main.url(forResource: "float-package", withExtension: "tex", subdirectory: "Export")?.path
    }

    /// Get path to bundled reference document
    static var bundledReferenceDocPath: String? {
        Bundle.main.url(forResource: "reference", withExtension: "docx", subdirectory: "Export")?.path
    }

    /// Get path to bundled CSL citation style
    static var bundledCSLStylePath: String? {
        Bundle.main.url(forResource: "chicago-author-date", withExtension: "csl", subdirectory: "Export")?.path
    }

    /// Get path to bundled TinyTeX xelatex binary (direct path, may fail if app path has spaces)
    static var bundledXelatexPath: String? {
        // xelatex is a symlink to xetex in TinyTeX
        Bundle.main.url(forResource: "xelatex", withExtension: nil, subdirectory: "TinyTeX/bin/universal-darwin")?.path
    }

    /// Get URL to bundled TinyTeX directory
    static var bundledTinyTeXURL: URL? {
        Bundle.main.url(forResource: "TinyTeX", withExtension: nil, subdirectory: nil)
    }
}

// MARK: - TinyTeX Symlink Preparation

extension ExportService {

    /// Prepare bundled TinyTeX for use via symlink and XeTeX's -output-driver option.
    /// This avoids issues when the app bundle path contains spaces (e.g., "final final.app").
    ///
    /// The problem: xelatex internally calls xdvipdfmx via shell without quoting the path.
    /// If the path contains spaces, the shell command breaks.
    ///
    /// The solution: XeTeX's documented `-output-driver` option specifies the command
    /// used to convert XDV to PDF. We create an xdvipdfmx wrapper at a space-free path
    /// and tell xelatex to use it via this option.
    ///
    /// Reference: https://mirrors.mit.edu/CTAN/info/xetexref/xetex-reference.pdf
    ///
    /// - Returns: Tuple of (xelatex path, output-driver argument), or nil if unavailable
    private func prepareBundledTinyTeX() throws -> (xelatexPath: String, outputDriverArg: String)? {
        guard let bundledTinyTeXURL = ExportService.bundledTinyTeXURL else {
            return nil
        }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory

        // Per-export unique suffix. These paths used to be fixed/shared across every PDF
        // export, so two overlapping exports would remove and recreate each other's symlink
        // and wrapper mid-flight — a real, demonstrated bug (concurrent exports crashing).
        // A unique suffix per call gives every export its own private symlink and wrapper,
        // eliminating the shared mutable state instead of trying to lock around it.
        let uniqueSuffix = UUID().uuidString

        // Create symlink to TinyTeX in temp directory (no spaces in path)
        let symlinkURL = tempDir.appendingPathComponent("TinyTeX-\(uniqueSuffix)")
        try? fm.removeItem(at: symlinkURL)
        try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: bundledTinyTeXURL)

        // Paths via symlink (no spaces)
        let tinyTeXBin = symlinkURL.appendingPathComponent("bin/universal-darwin").path

        // Create xdvipdfmx wrapper that properly calls the real binary
        // This wrapper is at a space-free path, so xelatex can invoke it safely
        let xdvipdfmxWrapperURL = tempDir.appendingPathComponent("xdvipdfmx-wrapper-\(uniqueSuffix)")
        let xdvipdfmxWrapper = """
            #!/bin/bash
            exec "\(tinyTeXBin)/xdvipdfmx" "$@"
            """
        try? fm.removeItem(at: xdvipdfmxWrapperURL)
        try xdvipdfmxWrapper.write(to: xdvipdfmxWrapperURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xdvipdfmxWrapperURL.path)

        // Return xelatex path via symlink (for package resolution) and output-driver argument
        let xelatexPath = tinyTeXBin + "/xelatex"
        let outputDriverArg = "-output-driver=\(xdvipdfmxWrapperURL.path)"

        return (xelatexPath, outputDriverArg)
    }
}

// MARK: - Citation Detection

extension ExportService {

    /// Detect Pandoc citations in content (skips code blocks and inline code)
    /// Matches any bracketed text containing @ followed by a citekey
    /// Pattern from citation-plugin.ts: \[([^\]]*@[\w:.-][^\]]*)\]
    private func hasPandocCitations(in content: String) -> Bool {
        let stripped = MarkdownUtils.stripCodeContent(from: content)
        return stripped.range(
            of: #"\[[^\]]*@[\w:.-]+[^\]]*\]"#,
            options: .regularExpression
        ) != nil
    }

    /// Extract citekeys from markdown content (skips code blocks and inline code).
    /// Duplicates BibliographySyncService.extractCitekeys regex to avoid @MainActor isolation.
    private func extractCitekeys(from content: String) -> [String] {
        let stripped = MarkdownUtils.stripCodeContent(from: content)
        let pattern = #"(?:\[|; )@([^\],;\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(stripped.startIndex..., in: stripped)
        return regex.matches(in: stripped, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: stripped) else { return nil }
            return String(stripped[r])
        }
    }

    /// Fetch bibliography as raw CSL-JSON string from Zotero/BBT for the given citekeys.
    /// Uses the same JSON-RPC endpoint as ZoteroService.fetchItemsForCitekeys()
    /// but returns the raw JSON string for pandoc to consume directly.
    private func fetchBibliographyJSON(for citekeys: [String]) async -> String? {
        guard !citekeys.isEmpty else { return nil }

        let url = URL(string: "http://127.0.0.1:23119/better-bibtex/json-rpc")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "item.export",
            "params": [citekeys, "Better CSL JSON"]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            // item.export returns JSON-RPC wrapper; extract the result
            guard let jsonObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            // Result may be a JSON string or an array
            if let resultString = jsonObj["result"] as? String, !resultString.isEmpty {
                return resultString
            } else if let resultArray = jsonObj["result"] as? [[String: Any]], !resultArray.isEmpty {
                let resultData = try JSONSerialization.data(withJSONObject: resultArray)
                return String(data: resultData, encoding: .utf8)
            }
            return nil
        } catch {
            DebugLog.log(.fileOps, "[ExportService] Failed to fetch bibliography JSON: \(error)")
            return nil
        }
    }

    /// Strip annotation HTML comments from markdown content
    /// Matches patterns like <!-- ::task:: text --> or <!-- ::comment:: notes -->
    private func stripAnnotations(from content: String) -> String {
        // Match annotation comments: <!-- ::type:: text -->
        // Annotations can span multiple lines and contain various content
        // Use .dotMatchesLineSeparators so .*? can span newlines
        content.replacingOccurrences(
            of: #"<!--\s*::\w+::\s*[\s\S]*?-->"#,
            with: "",
            options: .regularExpression
        )
    }
}

// MARK: - Script Detection & Font Mapping

extension ExportService {

    private struct DetectedScripts: OptionSet, Sendable {
        let rawValue: UInt16
        static let cjk        = DetectedScripts(rawValue: 1 << 0)
        static let hiragana   = DetectedScripts(rawValue: 1 << 1)
        static let katakana   = DetectedScripts(rawValue: 1 << 2)
        static let hangul     = DetectedScripts(rawValue: 1 << 3)
        static let devanagari = DetectedScripts(rawValue: 1 << 4)
        static let thai       = DetectedScripts(rawValue: 1 << 5)
        static let bengali    = DetectedScripts(rawValue: 1 << 6)
        static let tamil      = DetectedScripts(rawValue: 1 << 7)
        static let all: DetectedScripts = [.cjk, .hiragana, .katakana, .hangul,
                                            .devanagari, .thai, .bengali, .tamil]
    }

    /// Single-pass Unicode range scan. Returns which non-Latin scripts are present.
    private func detectScripts(in content: String) -> DetectedScripts {
        var detected: DetectedScripts = []
        for scalar in content.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF,
                 0x20000...0x2A6DF:
                detected.insert(.cjk)
            case 0x3040...0x309F:
                detected.insert(.hiragana)
            case 0x30A0...0x30FF:
                detected.insert(.katakana)
            case 0xAC00...0xD7AF:
                detected.insert(.hangul)
            case 0x0900...0x097F:
                detected.insert(.devanagari)
            case 0x0E00...0x0E7F:
                detected.insert(.thai)
            case 0x0980...0x09FF:
                detected.insert(.bengali)
            case 0x0B80...0x0BFF:
                detected.insert(.tamil)
            default:
                break
            }
            if detected == .all { break }
        }
        return detected
    }

    /// Returns pandoc font variable arguments for PDF export.
    ///
    /// Uses a two-tier strategy:
    /// - Tier 1: Unicode range scanning determines WHETHER to add font support
    /// - Tier 2: NLLanguageRecognizer disambiguates WHICH CJK font (SC vs TC)
    private func fontArguments(for content: String) -> [String] {
        let scripts = detectScripts(in: content)
        var args = cjkFontArguments(for: scripts, content: content)
        args.append(contentsOf: mainFontArguments(for: scripts))
        if !args.isEmpty {
            DebugLog.log(.fileOps, "[ExportService] Font arguments: \(args)")
        }
        return args
    }

    private func cjkFontArguments(for scripts: DetectedScripts, content: String) -> [String] {
        let needsCJK = !scripts.isDisjoint(with: [.cjk, .hiragana, .katakana, .hangul])
        guard needsCJK else { return [] }

        let font: String
        if !scripts.isDisjoint(with: [.hiragana, .katakana]) {
            font = "Hiragino Mincho ProN"
        } else if scripts.contains(.hangul) {
            font = "Apple SD Gothic Neo"
        } else {
            font = disambiguateCJKFont(in: content)
        }
        return ["-V", "CJKmainfont=\(font)"]
    }

    private func mainFontArguments(for scripts: DetectedScripts) -> [String] {
        let mainFontMap: [(script: DetectedScripts, font: String)] = [
            (.devanagari, "Kohinoor Devanagari"),
            (.thai, "Thonburi"),
            (.bengali, "Bangla Sangam MN"),
            (.tamil, "Tamil Sangam MN")
        ]
        guard let match = mainFontMap.first(where: { scripts.contains($0.script) }) else {
            return []
        }
        return ["-V", "mainfont=\(match.font)"]
    }

    /// Use NLLanguageRecognizer on CJK-only text to distinguish Simplified vs Traditional Chinese.
    /// Filtering to CJK characters avoids the recognizer being overwhelmed by English content.
    /// Default: Traditional Chinese (most users writing about Taiwan/HK).
    private func disambiguateCJKFont(in content: String) -> String {
        // Extract only CJK characters for reliable SC vs TC detection
        let cjkText = String(content.unicodeScalars.filter {
            let codePoint = $0.value
            return (0x4E00...0x9FFF).contains(codePoint) ||
                   (0x3400...0x4DBF).contains(codePoint) ||
                   (0xF900...0xFAFF).contains(codePoint) ||
                   (0x20000...0x2A6DF).contains(codePoint)
        })

        guard !cjkText.isEmpty else { return "Songti TC" }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(cjkText)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 10)

        if let scConfidence = hypotheses[.simplifiedChinese],
           let tcConfidence = hypotheses[.traditionalChinese],
           scConfidence > tcConfidence {
            return "Songti SC"
        }
        // Default to Traditional Chinese
        return "Songti TC"
    }
}

// MARK: - PDF Image Conversion

extension ExportService {

    /// For PDF export, convert unsupported images (WebP, HEIC, GIF, TIFF, SVG) to PNG.
    /// Returns rewritten content, the resource directory for Pandoc, and any warnings.
    /// If all images are already xelatex-compatible, returns content unchanged with the original projectURL.
    private func prepareImagesForPDF(
        content: String,
        projectURL: URL
    ) -> (content: String, resourceDir: URL, warnings: [String]) {
        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)
        let matches = ExportService.imagePathPattern.matches(in: content, range: fullRange)

        // Extract image filenames from markdown image syntax
        var imageFilenames: [String] = []
        for match in matches {
            guard let range = Range(match.range(at: 1), in: content) else { continue }
            let filename = String(content[range])
            // Decode URL-encoded filenames for filesystem lookup
            let decoded = filename.removingPercentEncoding ?? filename
            imageFilenames.append(decoded)
        }

        guard !imageFilenames.isEmpty else {
            return (content, projectURL, [])
        }

        // Check if any image needs conversion
        let needsConversion = imageFilenames.contains { filename in
            let ext = (filename as NSString).pathExtension.lowercased()
            return !ExportService.xelatexSupportedExtensions.contains(ext)
        }

        guard needsConversion else {
            return (content, projectURL, [])
        }

        // Create temp directory structure: <UUID>/media/
        let fm = FileManager.default
        let tempBase = fm.temporaryDirectory.appendingPathComponent("media-\(UUID().uuidString)")
        let tempMedia = tempBase.appendingPathComponent("media")
        do {
            try fm.createDirectory(at: tempMedia, withIntermediateDirectories: true)
        } catch {
            return (content, projectURL, ["Failed to create temp directory for image conversion"])
        }

        let mediaURL = projectURL.appendingPathComponent("media")
        var warnings: [String] = []
        // Maps original filename → new filename (only for converted files)
        var renames: [String: String] = [:]
        // Track all output filenames to detect collisions
        var outputFilenames: Set<String> = Set(imageFilenames.compactMap { filename in
            let ext = (filename as NSString).pathExtension.lowercased()
            return ExportService.xelatexSupportedExtensions.contains(ext) ? filename : nil
        })

        for filename in imageFilenames {
            let ext = (filename as NSString).pathExtension.lowercased()
            let sourceURL = mediaURL.appendingPathComponent(filename)

            if ExportService.xelatexSupportedExtensions.contains(ext) {
                // Supported format — symlink to avoid copying
                let destURL = tempMedia.appendingPathComponent(filename)
                // Create intermediate directories for filenames with subdirectories
                let destDir = destURL.deletingLastPathComponent()
                try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                try? fm.createSymbolicLink(at: destURL, withDestinationURL: sourceURL)
            } else {
                // Needs conversion to PNG
                guard fm.fileExists(atPath: sourceURL.path) else {
                    warnings.append("Image not found: \(filename)")
                    continue
                }

                if ext == "svg" {
                    warnings.append("SVG image converted to PNG — quality may vary: \(filename)")
                }

                // Determine output filename, handling collisions
                let baseName = (filename as NSString).deletingPathExtension
                var pngFilename = baseName + ".png"
                if outputFilenames.contains(pngFilename) {
                    pngFilename = baseName + "-converted.png"
                }
                outputFilenames.insert(pngFilename)

                let destURL = tempMedia.appendingPathComponent(pngFilename)
                let destDir = destURL.deletingLastPathComponent()
                try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)

                // Convert using NSImage → PNG data
                if let pngData = convertImageToPNG(at: sourceURL) {
                    do {
                        try pngData.write(to: destURL)
                        renames[filename] = pngFilename
                    } catch {
                        warnings.append("Failed to write converted image: \(filename)")
                    }
                } else {
                    warnings.append("Failed to convert image to PNG: \(filename)")
                }
            }
        }

        // Rewrite content: replace image paths for converted files
        var rewrittenContent = content
        for (oldFilename, newFilename) in renames {
            // Escape for regex
            let escapedOld = NSRegularExpression.escapedPattern(for: "media/" + oldFilename)
            // Only replace within image syntax: ![...](media/old)
            let pattern = #"(!\[[^\]]*\]\()"# + escapedOld
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(rewrittenContent.startIndex..., in: rewrittenContent)
                rewrittenContent = regex.stringByReplacingMatches(
                    in: rewrittenContent,
                    range: range,
                    withTemplate: "$1media/" + NSRegularExpression.escapedTemplate(for: newFilename)
                )
            }
        }

        return (rewrittenContent, tempBase, warnings)
    }

    /// Convert an image file to PNG data using NSImage.
    /// NSImage handles WebP, HEIC, GIF, TIFF, SVG, and other macOS-supported formats.
    /// NSImage data conversion does not require the main thread.
    private func convertImageToPNG(at url: URL) -> Data? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

// MARK: - Markdown & TextBundle Export

extension ExportService {

    /// Result of a markdown/TextBundle export operation
    struct MarkdownExportResult: Sendable {
        let outputURL: URL
        let warnings: [String]
    }

    /// Export markdown with images in a sibling folder.
    /// - Parameters:
    ///   - content: Standard markdown content (already assembled)
    ///   - imageFilenames: Image filenames from media/ to copy
    ///   - projectURL: The .ff package URL containing media/
    ///   - outputURL: Destination .md file URL
    func exportMarkdownWithImages(
        content: String,
        imageFilenames: [String],
        projectURL: URL?,
        outputURL: URL
    ) throws -> MarkdownExportResult {
        var warnings: [String] = []

        if imageFilenames.isEmpty {
            // No images — just write the markdown file
            try content.write(to: outputURL, atomically: true, encoding: .utf8)
            return MarkdownExportResult(outputURL: outputURL, warnings: warnings)
        }

        // Create images folder: <name>_images/ sibling to the .md file
        let baseName = outputURL.deletingPathExtension().lastPathComponent
        let imagesFolder = outputURL.deletingLastPathComponent()
            .appendingPathComponent("\(baseName)_images")

        try FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)

        // Copy images
        let missing = copyImages(
            filenames: imageFilenames,
            from: projectURL,
            to: imagesFolder
        )
        warnings.append(contentsOf: missing.map { "Image not found: \($0)" })

        // Rewrite paths: media/X -> <name>_images/X
        let rewritten = rewriteImagePaths(
            in: content,
            from: "media/",
            to: "\(baseName)_images/"
        )

        try rewritten.write(to: outputURL, atomically: true, encoding: .utf8)
        return MarkdownExportResult(outputURL: outputURL, warnings: warnings)
    }

    /// Export as TextBundle package.
    /// - Parameters:
    ///   - content: Standard markdown content (already assembled)
    ///   - imageFilenames: Image filenames from media/ to copy
    ///   - projectURL: The .ff package URL containing media/
    ///   - outputURL: Destination .textbundle directory URL
    func exportTextBundle(
        content: String,
        imageFilenames: [String],
        projectURL: URL?,
        outputURL: URL
    ) throws -> MarkdownExportResult {
        let fm = FileManager.default
        var warnings: [String] = []

        // Create .textbundle directory
        try fm.createDirectory(at: outputURL, withIntermediateDirectories: true)

        // Create assets/ subdirectory and copy images
        if !imageFilenames.isEmpty {
            let assetsURL = outputURL.appendingPathComponent("assets")
            try fm.createDirectory(at: assetsURL, withIntermediateDirectories: true)

            let missing = copyImages(
                filenames: imageFilenames,
                from: projectURL,
                to: assetsURL
            )
            warnings.append(contentsOf: missing.map { "Image not found: \($0)" })
        }

        // Rewrite paths: media/X -> assets/X
        let rewritten = rewriteImagePaths(in: content, from: "media/", to: "assets/")

        // Write text.md
        let textURL = outputURL.appendingPathComponent("text.md")
        try rewritten.write(to: textURL, atomically: true, encoding: .utf8)

        // Write info.json
        let infoJSON = """
            {
                "version": 2,
                "type": "net.daringfireball.markdown",
                "creatorIdentifier": "com.kerim.final-final"
            }
            """
        let infoURL = outputURL.appendingPathComponent("info.json")
        try infoJSON.write(to: infoURL, atomically: true, encoding: .utf8)

        return MarkdownExportResult(outputURL: outputURL, warnings: warnings)
    }

    // MARK: - Private Image Helpers

    /// Copy image files from project media/ to destination folder.
    /// Returns list of filenames that were not found.
    private func copyImages(filenames: [String], from projectURL: URL?, to destinationFolder: URL) -> [String] {
        guard let projectURL = projectURL else {
            return filenames
        }

        let fm = FileManager.default
        let mediaURL = projectURL.appendingPathComponent("media")
        var missing: [String] = []

        for filename in filenames {
            let sourceURL = mediaURL.appendingPathComponent(filename)
            let destURL = destinationFolder.appendingPathComponent(filename)

            if fm.fileExists(atPath: sourceURL.path) {
                try? fm.copyItem(at: sourceURL, to: destURL)
            } else {
                missing.append(filename)
            }
        }

        return missing
    }

    /// Replace image path prefix in markdown content, scoped to image syntax only.
    private func rewriteImagePaths(in content: String, from oldPrefix: String, to newPrefix: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: oldPrefix)
        // Only match within ![...](...) image syntax to avoid corrupting regular links/prose
        let pattern = #"(!\[[^\]]*\]\()"# + escaped
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return content }
        let range = NSRange(content.startIndex..., in: content)
        return regex.stringByReplacingMatches(in: content, range: range, withTemplate: "$1" + newPrefix)
    }
}
