//
//  PandocLocator.swift
//  final final
//
//  Service to locate and validate Pandoc installation.
//

import Foundation

/// Result of Pandoc detection
enum PandocStatus: Sendable, Equatable {
    case found(path: String, version: String)
    case notFound
    case invalidPath(String)
    case executionFailed(String)
}

/// Service to locate Pandoc on the system
actor PandocLocator {

    /// Common paths where Pandoc might be installed
    private let searchPaths: [String] = [
        "/opt/homebrew/bin/pandoc",      // Apple Silicon Homebrew
        "/usr/local/bin/pandoc",          // Intel Homebrew / manual install
        "/usr/bin/pandoc",                // System install
        "/opt/local/bin/pandoc"           // MacPorts
    ]

    /// User-configured custom path (from preferences)
    private var customPath: String?

    /// Cached status (invalidated when customPath changes)
    private var cachedStatus: PandocStatus?

    // MARK: - Configuration

    /// Set a custom Pandoc path from preferences
    func setCustomPath(_ path: String?) {
        if customPath != path {
            customPath = path
            cachedStatus = nil  // Invalidate cache
        }
    }

    // MARK: - Detection

    /// Locate Pandoc, checking custom path first then common locations
    func locate() async -> PandocStatus {
        // Return cached result if available
        if let cached = cachedStatus {
            return cached
        }

        // Try custom path first
        if let custom = customPath, !custom.isEmpty {
            let status = await validatePath(custom)
            if case .found = status {
                cachedStatus = status
                return status
            }
            // Custom path invalid - still try auto-detect
            print("[PandocLocator] Custom path invalid: \(custom)")
        }

        // Try each search path
        for path in searchPaths {
            let status = await validatePath(path)
            if case .found = status {
                cachedStatus = status
                return status
            }
        }

        // Not found anywhere
        let status = PandocStatus.notFound
        cachedStatus = status
        return status
    }

    /// Validate a specific Pandoc path
    func validatePath(_ path: String) async -> PandocStatus {
        let fileManager = FileManager.default

        // Check if file exists
        guard fileManager.fileExists(atPath: path) else {
            return .invalidPath("File does not exist: \(path)")
        }

        // Check if executable
        guard fileManager.isExecutableFile(atPath: path) else {
            return .invalidPath("File is not executable: \(path)")
        }

        // Try to get version
        do {
            let version = try await getVersion(at: path)
            return .found(path: path, version: version)
        } catch {
            return .executionFailed("Failed to run pandoc: \(error.localizedDescription)")
        }
    }

    /// Get Pandoc version string
    private func getVersion(at path: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["--version"]

            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()  // Discard stderr

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    let data = stdout.fileHandleForReading.readDataToEndOfFile()
                    if let output = String(data: data, encoding: .utf8),
                       let firstLine = output.components(separatedBy: "\n").first {
                        // Output is like "pandoc 3.1.11"
                        let version = firstLine.replacingOccurrences(of: "pandoc ", with: "")
                        continuation.resume(returning: version)
                    } else {
                        continuation.resume(throwing: PandocError.invalidVersionOutput)
                    }
                } else {
                    continuation.resume(throwing: PandocError.executionFailed(
                        exitCode: Int(proc.terminationStatus)
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Clear cached status (call when user might have installed Pandoc)
    func clearCache() {
        cachedStatus = nil
    }

    /// Get the path if Pandoc is found
    func getPath() async -> String? {
        let status = await locate()
        if case .found(let path, _) = status {
            return path
        }
        return nil
    }

    // MARK: - Errors

    enum PandocError: Error, LocalizedError {
        case invalidVersionOutput
        case executionFailed(exitCode: Int)

        var errorDescription: String? {
            switch self {
            case .invalidVersionOutput:
                return "Could not parse Pandoc version output"
            case .executionFailed(let code):
                return "Pandoc exited with code \(code)"
            }
        }
    }
}

// MARK: - Install Instructions

extension PandocLocator {

    /// Installation instructions for display in UI
    static let installInstructions = """
        Pandoc is required for exporting to Word, PDF, and ODT formats.

        Install via Homebrew (recommended):
        brew install pandoc

        Or download the installer from:
        https://pandoc.org/installing.html
        """

    /// Homebrew installation command
    static let homebrewCommand = "brew install pandoc"

    /// Download URL for Pandoc installer
    static let downloadURL = URL(string: "https://pandoc.org/installing.html")!
}
