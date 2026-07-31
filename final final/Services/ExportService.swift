//
//  ExportService.swift
//  final final
//
//  Core export service for converting markdown to Word/PDF/ODT via Pandoc.
//  Uses async/await with Process for non-blocking execution.
//

import Foundation

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

    init() {
        self.pandocLocator = PandocLocator()
        self.zoteroChecker = ZoteroChecker()
    }
}

// Everything below is in its own `extension` (rather than the primary actor declaration
// above) purely to keep `type_body_length` under its limit — SwiftLint counts an
// extension's body separately from the type's own declaration. Matches the "MARK/extension
// seam" convention the rest of this file's sibling ExportService+*.swift files already use;
// this just applies it one level further in, within the core file itself. No behavior
// change: methods and nested types are identical whether declared in the primary actor body
// or an extension of it.
extension ExportService {

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

        // Get and validate resource paths (lua filter, reference doc)
        let resourcePaths = try resolveAndValidateResourcePaths(format: format, settings: settings)

        // Create temp files
        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent(UUID().uuidString + ".md")

        do {
            try processedContent.write(to: inputURL, atomically: true, encoding: .utf8)
        } catch {
            throw ExportError.tempFileCreationFailed
        }

        // Cleanup fires on every exit path — including thrown errors — because the defer is
        // placed immediately after the artifacts are created, not deferred to function end.
        var artifacts = TempExportArtifacts(inputURL: inputURL)
        defer { artifacts.cleanup() }

        // Collect warnings
        var warnings: [String] = []

        // For PDF export, convert unsupported images (WebP, HEIC, etc.) to PNG
        let pdfPrep = try prepareContentForPDFIfNeeded(
            format: format,
            content: processedContent,
            projectURL: projectURL,
            inputURL: inputURL
        )
        processedContent = pdfPrep.content
        artifacts.tempMediaDir = pdfPrep.tempMediaDir
        warnings.append(contentsOf: pdfPrep.warnings)

        // Build Pandoc arguments
        var arguments = buildBaseArguments(
            inputURL: inputURL,
            outputURL: outputURL,
            format: format,
            pdfPrep: pdfPrep,
            resourcePaths: resourcePaths
        )

        // Citations
        if hasCitations {
            let citation = await citationArguments(
                format: format,
                content: processedContent,
                zoteroStatus: zoteroStatus,
                luaScriptPath: resourcePaths.luaScriptPath,
                tempDir: tempDir
            )
            arguments.append(contentsOf: citation.arguments)
            artifacts.tempBibURL = citation.tempBibURL
            warnings.append(contentsOf: citation.warnings)
        }

        // DIAGNOSTIC (temporary, opt-in — see docs/plans/mossy-tumbling-stroustrup.md, removed
        // once the fix for the PDF page-1 reorder bug lands). Off by default; gated by
        // isDiagnosticCaptureEnabled (Preferences -> Diagnostics -> Export Diagnostic Capture).
        // When enabled, fires for every format so a PDF -> Word -> PDF reproduction sequence
        // captures three side-by-side dumps. Never contributes to `warnings` — a diagnostic
        // dump succeeding or failing is not itself a user-facing export warning.
        let diagnosticDirURL = await dumpExportDiagnostics(ExportDiagnosticsRequest(
            rawContent: content,
            inputURL: inputURL,
            pandocPath: pandocPath,
            arguments: arguments,
            format: format,
            projectURL: projectURL
        ))

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

    /// Resolved lua-script and reference-doc paths for an export.
    private struct ResourcePaths {
        let luaScriptPath: String?
        let referenceDocPath: String?
    }

    /// Resolves the lua-script and reference-doc paths from settings and validates that any
    /// path that was specified actually exists on disk (DOCX/ODT use the lua filter; PDF uses
    /// `--citeproc` instead, so its lua path is not checked).
    private func resolveAndValidateResourcePaths(
        format: ExportFormat,
        settings: ExportSettings
    ) throws -> ResourcePaths {
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

        return ResourcePaths(luaScriptPath: luaScriptPath, referenceDocPath: referenceDocPath)
    }

    /// Groups the temp filesystem artifacts an export can create (the temp markdown input
    /// file, a temp bibliography JSON, and a temp media directory for converted images) so a
    /// single `defer` can clean up whichever of them ended up populated by the time of exit.
    private struct TempExportArtifacts {
        let inputURL: URL
        var tempBibURL: URL?
        var tempMediaDir: URL?

        func cleanup() {
            try? FileManager.default.removeItem(at: inputURL)
            if let tempBibURL {
                try? FileManager.default.removeItem(at: tempBibURL)
            }
            if let tempMediaDir {
                try? FileManager.default.removeItem(at: tempMediaDir)
            }
        }
    }

    /// Result of `prepareContentForPDFIfNeeded`: possibly-rewritten content (with converted
    /// image paths), the resource directory Pandoc should resolve `media/` paths against, the
    /// temp media directory to clean up afterward (if image conversion created one), and any
    /// conversion warnings.
    private struct PDFContentPreparation {
        let content: String
        let effectiveResourceURL: URL?
        let tempMediaDir: URL?
        let warnings: [String]
    }

    /// For PDF export, convert unsupported images (WebP, HEIC, etc.) to PNG and rewrite the
    /// temp input file in place if any conversion happened. No-op for non-PDF formats or when
    /// there's no project to resolve `media/` paths against — `effectiveResourceURL` then
    /// simply passes `projectURL` through unchanged, mirroring the original default.
    private func prepareContentForPDFIfNeeded(
        format: ExportFormat,
        content: String,
        projectURL: URL?,
        inputURL: URL
    ) throws -> PDFContentPreparation {
        guard format == .pdf, let projURL = projectURL else {
            return PDFContentPreparation(content: content, effectiveResourceURL: projectURL, tempMediaDir: nil, warnings: [])
        }

        let prep = prepareImagesForPDF(content: content, projectURL: projURL)
        guard prep.resourceDir != projURL else {
            return PDFContentPreparation(content: content, effectiveResourceURL: projectURL, tempMediaDir: nil, warnings: [])
        }

        // Conversion happened — use temp dir and rewritten content.
        // Re-write temp input file with updated image paths.
        try prep.content.write(to: inputURL, atomically: true, encoding: .utf8)

        return PDFContentPreparation(
            content: prep.content,
            effectiveResourceURL: prep.resourceDir,
            tempMediaDir: prep.resourceDir,
            warnings: prep.warnings
        )
    }

    /// Assembles the base Pandoc arguments shared by all formats: input/output paths,
    /// resource path, PDF engine + font + figure-placement arguments (PDF only), and the
    /// reference document (DOCX/ODT only). Citations and the diagnostic dump are layered on
    /// separately by `export()` since they need async work this function doesn't.
    ///
    /// Takes `pdfPrep`/`resourcePaths` (rather than their individual fields) to stay at or
    /// under the function-parameter-count limit — both are already constructed by the time
    /// `export()` calls this, and `pdfPrep.content` is always identical to `processedContent`
    /// at the call site (it was just assigned from it).
    private func buildBaseArguments(
        inputURL: URL,
        outputURL: URL,
        format: ExportFormat,
        pdfPrep: PDFContentPreparation,
        resourcePaths: ResourcePaths
    ) -> [String] {
        var arguments = [
            inputURL.path,
            "--from", "markdown",
            "--to", format.pandocFormat,
            "--output", outputURL.path
        ]

        // Resource path for image resolution (media/ paths relative to .ff package)
        if let url = pdfPrep.effectiveResourceURL {
            arguments.append(contentsOf: ["--resource-path", url.path])
        }

        // PDF: engine + font variables + figure placement pinning (fixes drift at page
        // breaks — see figure-placement.lua/float-package.tex). Both are optional: if the
        // bundled resources are somehow missing, PDF export still proceeds without the
        // placement fix rather than failing outright.
        if format == .pdf {
            arguments.append(contentsOf: pdfEngineArguments())
            arguments.append(contentsOf: fontArguments(for: pdfPrep.content))
            if let figurePlacementLuaPath = ExportService.bundledFigurePlacementLuaPath {
                arguments.append(contentsOf: ["--lua-filter", figurePlacementLuaPath])
            }
            if let floatPackagePath = ExportService.bundledFloatPackageTexPath {
                arguments.append(contentsOf: ["--include-in-header", floatPackagePath])
            }
        }

        // Reference document (DOCX/ODT only)
        if let refPath = resourcePaths.referenceDocPath, format != .pdf {
            arguments.append(contentsOf: ["--reference-doc", refPath])
        }

        return arguments
    }

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

    /// Result of `citationArguments`: the Pandoc arguments to append, the temp bibliography
    /// file to clean up afterward (if one was written), and any warnings.
    private struct CitationBuildResult {
        let arguments: [String]
        let tempBibURL: URL?
        let warnings: [String]
    }

    /// Build citation-related Pandoc arguments and fetch bibliography if needed.
    private func citationArguments(
        format: ExportFormat,
        content: String,
        zoteroStatus: ZoteroStatus,
        luaScriptPath: String?,
        tempDir: URL
    ) async -> CitationBuildResult {
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

        return CitationBuildResult(arguments: args, tempBibURL: tempBibURL, warnings: warnings)
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
