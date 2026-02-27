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
        settings: ExportSettings
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
        let referenceDocPath = settings.effectiveReferenceDocPath

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
        }

        // Collect warnings
        var warnings: [String] = []

        // Build Pandoc arguments
        var arguments = [
            inputURL.path,
            "--from", "markdown",
            "--to", format.pandocFormat,
            "--output", outputURL.path
        ]

        // Add PDF engine for PDF exports
        if format == ExportFormat.pdf {
            // Use bundled TinyTeX with -output-driver to work around spaces in path
            // Reference: XeTeX's -output-driver option specifies the XDV-to-PDF driver
            if let tinyTeX = try? prepareBundledTinyTeX() {
                arguments.append(contentsOf: ["--pdf-engine", tinyTeX.xelatexPath])
                arguments.append(contentsOf: ["--pdf-engine-opt", tinyTeX.outputDriverArg])
            } else if let bundledPath = ExportService.bundledXelatexPath {
                // Direct path fallback (may fail if app path has spaces)
                arguments.append(contentsOf: ["--pdf-engine", bundledPath])
            } else {
                // System xelatex fallback
                arguments.append(contentsOf: ["--pdf-engine", "xelatex"])
            }
        }

        // Add reference document for docx/odt (not applicable for PDF)
        if let refPath = referenceDocPath, format != ExportFormat.pdf {
            arguments.append(contentsOf: ["--reference-doc", refPath])
        }

        // Citation handling: branch by format
        if hasCitations {
            if format == .pdf {
                // PDF: use pandoc's --citeproc with bibliography from Zotero
                if zoteroStatus == .running {
                    let citekeys = Array(Set(extractCitekeys(from: processedContent)))
                    if let bibJSON = await fetchBibliographyJSON(for: citekeys) {
                        let bibURL = tempDir.appendingPathComponent(UUID().uuidString + ".json")
                        do {
                            try bibJSON.write(to: bibURL, atomically: true, encoding: .utf8)
                            tempBibURL = bibURL
                            arguments.append(contentsOf: ["--citeproc", "--bibliography", bibURL.path])
                            if let cslPath = ExportService.bundledCSLStylePath {
                                arguments.append(contentsOf: ["--csl", cslPath])
                            }
                        } catch {
                            warnings.append("Could not write bibliography data. Citations were not resolved.")
                        }
                    } else {
                        warnings.append("Could not fetch bibliography data from Zotero. Citations were not resolved.")
                    }
                }
                // If Zotero not running, warnings are added below
            } else {
                // DOCX/ODT: use Lua filter for Zotero field codes
                if let luaPath = luaScriptPath {
                    arguments.append(contentsOf: ["--lua-filter", luaPath])
                }
            }
        }

        // Run Pandoc
        try await runPandoc(at: pandocPath, arguments: arguments)

        // Add Zotero status warnings (only for documents with citations)
        if hasCitations {
            switch zoteroStatus {
            case .notRunning:
                warnings.append("Zotero is not running. Citations were not resolved.")
            case .betterBibTeXMissing:
                warnings.append("Better BibTeX is not installed. Citations were not resolved.")
            case .timeout:
                warnings.append("Could not connect to Zotero. Citations may not be resolved.")
            case .error(let msg):
                warnings.append("Zotero error: \(msg)")
            case .running:
                break  // All good
            }
        }

        return ExportResult(
            outputURL: outputURL,
            format: format,
            zoteroStatus: zoteroStatus,
            warnings: warnings
        )
    }

    // MARK: - Pandoc Execution

    /// Run Pandoc with the given arguments
    /// - Parameters:
    ///   - path: Path to Pandoc executable
    ///   - arguments: Command line arguments
    private func runPandoc(at path: String, arguments: [String]) async throws {
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

                    if proc.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
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
            print("[ExportService] Export cancelled")
        }
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

        // Create symlink to TinyTeX in temp directory (no spaces in path)
        let symlinkURL = tempDir.appendingPathComponent("TinyTeX")
        try? fm.removeItem(at: symlinkURL)
        try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: bundledTinyTeXURL)

        // Paths via symlink (no spaces)
        let tinyTeXBin = symlinkURL.appendingPathComponent("bin/universal-darwin").path

        // Create xdvipdfmx wrapper that properly calls the real binary
        // This wrapper is at a space-free path, so xelatex can invoke it safely
        let xdvipdfmxWrapperURL = tempDir.appendingPathComponent("xdvipdfmx-wrapper")
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

    /// Detect Pandoc citations in content
    /// Matches any bracketed text containing @ followed by a citekey
    /// Pattern from citation-plugin.ts: \[([^\]]*@[\w:.-][^\]]*)\]
    private func hasPandocCitations(in content: String) -> Bool {
        content.range(
            of: #"\[[^\]]*@[\w:.-]+[^\]]*\]"#,
            options: .regularExpression
        ) != nil
    }

    /// Extract citekeys from markdown content.
    /// Duplicates BibliographySyncService.extractCitekeys regex to avoid @MainActor isolation.
    private func extractCitekeys(from content: String) -> [String] {
        let pattern = #"(?:\[|; )@([^\],;\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(content.startIndex..., in: content)
        return regex.matches(in: content, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: content) else { return nil }
            return String(content[r])
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
            print("[ExportService] Failed to fetch bibliography JSON: \(error)")
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
