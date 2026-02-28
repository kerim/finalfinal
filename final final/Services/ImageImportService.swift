//
//  ImageImportService.swift
//  final final
//
//  Handles image import: validation, copy to media/, unique naming.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

struct ImageImportService {

    /// Allowed image UTTypes
    static let allowedTypes: [UTType] = [
        .png, .jpeg, .gif, .webP, .heic, .tiff, .svg, .bmp
    ]

    /// Allowed file extensions (for quick validation)
    static let allowedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "svg", "bmp"
    ]

    /// Size thresholds
    static let warnSizeBytes = 10 * 1024 * 1024      // 10 MB
    static let blockSizeBytes = 25 * 1024 * 1024      // 25 MB

    enum ImportError: Error, LocalizedError {
        case unsupportedFormat(String)
        case fileTooLarge(Int)
        case noMediaDirectory
        case copyFailed(Error)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext):
                return "Unsupported image format: \(ext)"
            case .fileTooLarge(let bytes):
                let mb = bytes / (1024 * 1024)
                return "Image is too large (\(mb) MB). Maximum size is 25 MB."
            case .noMediaDirectory:
                return "No project media directory available"
            case .copyFailed(let err):
                return "Failed to copy image: \(err.localizedDescription)"
            }
        }
    }

    /// Import an image from a file URL into the project's media directory.
    /// - Parameters:
    ///   - url: Source file URL
    ///   - mediaDir: The project's media/ directory URL
    /// - Returns: The relative path (e.g., "media/photo.png")
    @MainActor
    static func importFromURL(_ url: URL, mediaDir: URL) throws -> String {
        let ext = url.pathExtension.lowercased()

        // Validate format
        guard allowedExtensions.contains(ext) else {
            throw ImportError.unsupportedFormat(ext)
        }

        // Check file size
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attrs[.size] as? Int ?? 0

        if fileSize > blockSizeBytes {
            throw ImportError.fileTooLarge(fileSize)
        }

        if fileSize > warnSizeBytes {
            let mb = fileSize / (1024 * 1024)
            let alert = NSAlert()
            alert.messageText = "Large Image"
            alert.informativeText = "This image is \(mb) MB. Large images may slow down the editor. Continue?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Insert")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                throw ImportError.fileTooLarge(fileSize)
            }
        }

        // Ensure media directory exists
        try ensureMediaDir(mediaDir)

        // Generate unique filename
        let filename = uniqueFilename(for: url.lastPathComponent, in: mediaDir)
        let destURL = mediaDir.appendingPathComponent(filename)

        // Copy file
        do {
            try FileManager.default.copyItem(at: url, to: destURL)
        } catch {
            throw ImportError.copyFailed(error)
        }

        return "media/\(filename)"
    }

    /// Import an image from raw data (clipboard paste).
    /// - Parameters:
    ///   - data: Image data
    ///   - suggestedName: Optional original filename
    ///   - mimeType: MIME type (e.g., "image/png")
    ///   - mediaDir: The project's media/ directory URL
    /// - Returns: The relative path (e.g., "media/pasted-image.png")
    @MainActor
    static func importFromData(_ data: Data, suggestedName: String?, mimeType: String?, mediaDir: URL) throws -> String {
        // Determine extension from mime type
        let ext: String
        if let mime = mimeType, let utType = UTType(mimeType: mime) {
            ext = utType.preferredFilenameExtension ?? "png"
        } else if let name = suggestedName {
            ext = (name as NSString).pathExtension.lowercased()
        } else {
            ext = "png"
        }

        guard allowedExtensions.contains(ext) else {
            throw ImportError.unsupportedFormat(ext)
        }

        // Check size
        if data.count > blockSizeBytes {
            throw ImportError.fileTooLarge(data.count)
        }

        if data.count > warnSizeBytes {
            let mb = data.count / (1024 * 1024)
            let alert = NSAlert()
            alert.messageText = "Large Image"
            alert.informativeText = "This image is \(mb) MB. Large images may slow down the editor. Continue?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Insert")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                throw ImportError.fileTooLarge(data.count)
            }
        }

        // Ensure media directory exists
        try ensureMediaDir(mediaDir)

        // Generate filename
        let baseName = suggestedName ?? "pasted-image.\(ext)"
        let filename = uniqueFilename(for: baseName, in: mediaDir)
        let destURL = mediaDir.appendingPathComponent(filename)

        // Write data
        do {
            try data.write(to: destURL)
        } catch {
            throw ImportError.copyFailed(error)
        }

        return "media/\(filename)"
    }

    // MARK: - Private Helpers

    /// Ensure the media directory exists (handles pre-v13 packages)
    private static func ensureMediaDir(_ mediaDir: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: mediaDir.path) {
            try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        }
    }

    /// Generate a unique filename by sanitizing and adding collision suffixes.
    /// "My Photo.PNG" → "my-photo.png" → "my-photo-1.png" on collision.
    static func uniqueFilename(for originalName: String, in directory: URL) -> String {
        let name = (originalName as NSString).deletingPathExtension
        let ext = (originalName as NSString).pathExtension.lowercased()

        // Sanitize: lowercase, replace spaces/underscores with hyphens, remove non-alphanumeric
        var sanitized = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")

        // Remove characters that aren't alphanumeric or hyphens
        sanitized = sanitized.filter { $0.isLetter || $0.isNumber || $0 == "-" }

        // Remove leading/trailing hyphens and collapse multiple hyphens
        while sanitized.contains("--") {
            sanitized = sanitized.replacingOccurrences(of: "--", with: "-")
        }
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        if sanitized.isEmpty {
            sanitized = "image"
        }

        let candidate = ext.isEmpty ? sanitized : "\(sanitized).\(ext)"
        let candidateURL = directory.appendingPathComponent(candidate)

        if !FileManager.default.fileExists(atPath: candidateURL.path) {
            return candidate
        }

        // Add collision suffix
        var counter = 1
        while true {
            let numbered = ext.isEmpty ? "\(sanitized)-\(counter)" : "\(sanitized)-\(counter).\(ext)"
            let numberedURL = directory.appendingPathComponent(numbered)
            if !FileManager.default.fileExists(atPath: numberedURL.path) {
                return numbered
            }
            counter += 1
        }
    }
}
