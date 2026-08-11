//
//  ExportService+PandocProcess.swift
//  final final
//

import Foundation

extension ExportService {

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

    /// Runs pandoc and maps a citation-filter crash (pandoc exit 83) onto the
    /// user-facing `citationFilterFailed` error. Extracted from `export()` unchanged
    /// — same call, same catch, same DebugLog line, same rethrow.
    func runPandocMappingCitationErrors(
        at pandocPath: String, arguments: [String], format: ExportFormat,
        luaScriptPath: String?, stderrCaptureURL: URL?
    ) async throws {
        do {
            try await runPandoc(
                at: pandocPath,
                arguments: arguments,
                stderrCaptureURL: stderrCaptureURL
            )
        } catch let error as ExportError {
            if case .pandocFailed(let exitCode, let pandocStderr) = error,
               let mapped = Self.citationFilterErrorIfApplicable(
                   exitCode: exitCode,
                   format: format,
                   luaScriptPath: luaScriptPath
               ) {
                // Zotero WAS reachable when the pre-flight probe ran (requiresZoteroForExport,
                // checked in `export()`, didn't fire), so a raw exit-83 crash message here would
                // wrongly imply the probe was wrong. See citationFilterErrorIfApplicable's doc comment.
                //
                // The user-facing citationFilterFailed message deliberately omits the raw
                // pandoc traceback (see its doc comment) -- preserve it here instead, so a
                // real failure can still be diagnosed after the fact from the debug log.
                DebugLog.log(
                    .zotero,
                    "[ExportService] Citation filter failed for \(format.displayName) export " +
                    "(pandoc exit \(exitCode)): \(pandocStderr)"
                )
                throw mapped
            }
            throw error
        }
    }
}
