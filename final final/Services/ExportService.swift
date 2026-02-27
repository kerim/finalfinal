//
//  ExportService.swift
//  final final
//
//  Core export service for converting markdown to Word/PDF/ODT via Pandoc.
//  Uses async/await with Process for non-blocking execution.
//

import Foundation
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

        // PDF: engine + font variables
        if format == .pdf {
            arguments.append(contentsOf: pdfEngineArguments())
            arguments.append(contentsOf: fontArguments(for: processedContent))
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

        // Run Pandoc
        try await runPandoc(at: pandocPath, arguments: arguments)

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
            print("[ExportService] Font arguments: \(args)")
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
            (.thai,       "Thonburi"),
            (.bengali,    "Bangla Sangam MN"),
            (.tamil,      "Tamil Sangam MN"),
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
