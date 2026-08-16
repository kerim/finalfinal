//
//  ExportService+MarkdownExport.swift
//  final final
//

import Foundation

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

    /// Export plain markdown text -- no images, no sidecar image folder. `content` is
    /// expected to already have image markup removed (see
    /// `BlockParser.assembleMarkdownOnlyForExport`); this just writes it out atomically as
    /// UTF-8, sibling to `exportMarkdownWithImages` but without any of its image-copying or
    /// path-rewriting work, since there is nothing left to copy or rewrite.
    /// - Parameters:
    ///   - content: Plain markdown content (already assembled, images already stripped)
    ///   - outputURL: Destination .md file URL
    func exportMarkdownOnly(
        content: String,
        outputURL: URL
    ) throws -> MarkdownExportResult {
        try content.write(to: outputURL, atomically: true, encoding: .utf8)
        return MarkdownExportResult(outputURL: outputURL, warnings: [])
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
