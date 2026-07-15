//
//  ExportService+PDFImages.swift
//  final final
//

import AppKit  // NSImage/NSBitmapImageRep for image conversion — no main thread required
import Foundation

// MARK: - PDF Image Conversion

extension ExportService {

    /// Image formats that xelatex can handle natively
    private static let xelatexSupportedExtensions: Set<String> = ["png", "jpg", "jpeg", "bmp", "pdf"]

    /// Matches markdown image syntax: ![alt](media/filename)
    /// Anchored on `!\[` to avoid matching regular links
    private static let imagePathPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"!\[[^\]]*\]\(media/([^)]+)\)"#)
    }()

    /// Result of `prepareImagesForPDF`: rewritten content, the resource directory for
    /// Pandoc, and any conversion warnings.
    struct PDFImagePreparationResult: Sendable {
        let content: String
        let resourceDir: URL
        let warnings: [String]
    }

    /// For PDF export, convert unsupported images (WebP, HEIC, GIF, TIFF, SVG) to PNG.
    /// Returns rewritten content, the resource directory for Pandoc, and any warnings.
    /// If all images are already xelatex-compatible, returns content unchanged with the original projectURL.
    func prepareImagesForPDF(
        content: String,
        projectURL: URL
    ) -> PDFImagePreparationResult {
        let imageFilenames = extractImageFilenames(from: content)

        guard !imageFilenames.isEmpty else {
            return PDFImagePreparationResult(content: content, resourceDir: projectURL, warnings: [])
        }

        // Check if any image needs conversion
        let needsConversion = imageFilenames.contains { filename in
            let ext = (filename as NSString).pathExtension.lowercased()
            return !ExportService.xelatexSupportedExtensions.contains(ext)
        }

        guard needsConversion else {
            return PDFImagePreparationResult(content: content, resourceDir: projectURL, warnings: [])
        }

        // Create temp directory structure: <UUID>/media/
        let fm = FileManager.default
        let tempBase = fm.temporaryDirectory.appendingPathComponent("media-\(UUID().uuidString)")
        let tempMedia = tempBase.appendingPathComponent("media")
        do {
            try fm.createDirectory(at: tempMedia, withIntermediateDirectories: true)
        } catch {
            return PDFImagePreparationResult(
                content: content,
                resourceDir: projectURL,
                warnings: ["Failed to create temp directory for image conversion"]
            )
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
            let result = convertImageIfNeeded(
                filename: filename,
                mediaURL: mediaURL,
                tempMediaDir: tempMedia,
                existingOutputFilenames: &outputFilenames
            )
            if let renamedTo = result.renamedTo {
                renames[filename] = renamedTo
            }
            warnings.append(contentsOf: result.warnings)
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

        return PDFImagePreparationResult(content: rewrittenContent, resourceDir: tempBase, warnings: warnings)
    }

    /// Extract image filenames referenced via markdown image syntax
    /// (`![alt](media/filename)`), URL-decoded for filesystem lookup.
    private func extractImageFilenames(from content: String) -> [String] {
        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)
        let matches = ExportService.imagePathPattern.matches(in: content, range: fullRange)

        var imageFilenames: [String] = []
        for match in matches {
            guard let range = Range(match.range(at: 1), in: content) else { continue }
            let filename = String(content[range])
            // Decode URL-encoded filenames for filesystem lookup
            let decoded = filename.removingPercentEncoding ?? filename
            imageFilenames.append(decoded)
        }
        return imageFilenames
    }

    /// Per-file symlink-or-convert step used by `prepareImagesForPDF`'s loop. xelatex-supported
    /// formats are symlinked into `tempMediaDir` untouched; unsupported formats are converted to
    /// PNG, handling filename collisions against `existingOutputFilenames`.
    /// - Returns: The renamed-to filename (if converted) and any warnings generated for this
    ///   file — a single SVG conversion failure can carry both a "converted, quality may vary"
    ///   warning and a "failed to convert" warning, so this is a list rather than one optional.
    private func convertImageIfNeeded(
        filename: String,
        mediaURL: URL,
        tempMediaDir: URL,
        existingOutputFilenames: inout Set<String>
    ) -> (renamedTo: String?, warnings: [String]) {
        let fm = FileManager.default
        let ext = (filename as NSString).pathExtension.lowercased()
        let sourceURL = mediaURL.appendingPathComponent(filename)

        if ExportService.xelatexSupportedExtensions.contains(ext) {
            // Supported format — symlink to avoid copying
            let destURL = tempMediaDir.appendingPathComponent(filename)
            // Create intermediate directories for filenames with subdirectories
            let destDir = destURL.deletingLastPathComponent()
            try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            try? fm.createSymbolicLink(at: destURL, withDestinationURL: sourceURL)
            return (nil, [])
        }

        // Needs conversion to PNG
        guard fm.fileExists(atPath: sourceURL.path) else {
            return (nil, ["Image not found: \(filename)"])
        }

        var warnings: [String] = []
        if ext == "svg" {
            warnings.append("SVG image converted to PNG — quality may vary: \(filename)")
        }

        // Determine output filename, handling collisions
        let baseName = (filename as NSString).deletingPathExtension
        var pngFilename = baseName + ".png"
        if existingOutputFilenames.contains(pngFilename) {
            pngFilename = baseName + "-converted.png"
        }
        existingOutputFilenames.insert(pngFilename)

        let destURL = tempMediaDir.appendingPathComponent(pngFilename)
        let destDir = destURL.deletingLastPathComponent()
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Convert using NSImage → PNG data
        guard let pngData = convertImageToPNG(at: sourceURL) else {
            warnings.append("Failed to convert image to PNG: \(filename)")
            return (nil, warnings)
        }
        do {
            try pngData.write(to: destURL)
            return (pngFilename, warnings)
        } catch {
            warnings.append("Failed to write converted image: \(filename)")
            return (nil, warnings)
        }
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
