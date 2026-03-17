//
//  MarkdownContentView.swift
//  final final
//
//  Renders raw markdown as clean prose with thumbnail images.
//  Reusable utility — not tied to version history.
//

import SwiftUI

// MARK: - Parsed Elements

enum MarkdownElement: Identifiable {
    case text(String)
    case image(alt: String, path: String)
    case lineBreak(Int)
    case code(String)

    var id: String {
        switch self {
        case .text(let content): return "text-\(content.hashValue)"
        case .image(_, let path): return "img-\(path)"
        case .lineBreak(let index): return "br-\(index)"
        case .code(let content): return "code-\(content.hashValue)"
        }
    }
}

// MARK: - Image Cache

private let imageCache = NSCache<NSString, NSImage>()

// MARK: - View

struct MarkdownContentView: View {
    let markdown: String

    @State private var loadedImages: [String: NSImage] = [:]

    private var elements: [MarkdownElement] {
        Self.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(elements) { element in
                switch element {
                case .text(let raw):
                    Text(MarkdownUtils.stripMarkdownSyntax(from: raw))
                        .font(.body)
                        .textSelection(.enabled)

                case .code(let content):
                    Text(content)
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(4)
                        .textSelection(.enabled)

                case .image(let alt, let path):
                    imageView(alt: alt, path: path)

                case .lineBreak:
                    Spacer().frame(height: 4)
                }
            }
        }
    }

    // MARK: - Image Rendering

    @ViewBuilder
    private func imageView(alt: String, path: String) -> some View {
        if let cached = loadedImages[path] {
            Image(nsImage: cached)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 120)
                .cornerRadius(4)
                .accessibilityLabel(alt)
        } else if path.hasPrefix("http://") || path.hasPrefix("https://") {
            AsyncImage(url: URL(string: path)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 120)
                        .cornerRadius(4)
                case .failure:
                    imagePlaceholder(alt: alt)
                default:
                    ProgressView()
                        .frame(height: 60)
                }
            }
            .accessibilityLabel(alt)
        } else {
            imagePlaceholder(alt: alt)
                .task(id: path) {
                    await loadLocalImage(path: path)
                }
        }
    }

    private func imagePlaceholder(alt: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
            if !alt.isEmpty {
                Text(alt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: 40)
    }

    @MainActor
    private func loadLocalImage(path: String) async {
        // Check NSCache first
        if let cached = imageCache.object(forKey: path as NSString) {
            loadedImages[path] = cached
            return
        }

        // Resolve projectmedia:// URLs
        let fileURL: URL?
        if path.hasPrefix("projectmedia://") {
            guard let mediaDir = MediaSchemeHandler.shared.mediaDirectoryURL,
                  let url = URL(string: path),
                  let host = url.host, !host.isEmpty else {
                return
            }
            var components = [host]
            let pathParts = url.pathComponents.filter { $0 != "/" }
            components.append(contentsOf: pathParts)
            let filename = components.joined(separator: "/")
            fileURL = mediaDir.appendingPathComponent(filename)
        } else {
            fileURL = URL(fileURLWithPath: path)
        }

        guard let resolvedURL = fileURL,
              let image = NSImage(contentsOf: resolvedURL) else {
            return
        }

        imageCache.setObject(image, forKey: path as NSString)
        loadedImages[path] = image
    }

    // MARK: - Parsing

    static func parse(_ markdown: String) -> [MarkdownElement] {
        let imagePattern = #"!\[([^\]]*)\]\(([^)]+)\)"#
        let imageRegex = try? NSRegularExpression(pattern: imagePattern)

        var elements: [MarkdownElement] = []
        var lineBreakIndex = 0

        // Pre-scan: extract fenced code blocks before paragraph splitting
        let blocks = extractCodeBlocks(from: markdown)

        for block in blocks {
            if case .code(let content) = block {
                elements.append(.code(content))
                continue
            }
            guard case .text(let raw) = block else { continue }
            elements.append(contentsOf: parseTextBlock(raw, imageRegex: imageRegex, lineBreakIndex: &lineBreakIndex))
        }

        return elements
    }

    /// Parse a text block (non-code) into elements
    private static func parseTextBlock(
        _ raw: String,
        imageRegex: NSRegularExpression?,
        lineBreakIndex: inout Int
    ) -> [MarkdownElement] {
        var elements: [MarkdownElement] = []
        let paragraphs = raw.components(separatedBy: "\n\n")

        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                elements.append(.lineBreak(lineBreakIndex))
                lineBreakIndex += 1
                continue
            }

            // Skip header-only lines (already shown as title)
            if trimmed.hasPrefix("#") && !trimmed.contains("\n") {
                continue
            }

            // Check for images in this paragraph
            let nsRange = NSRange(trimmed.startIndex..., in: trimmed)
            let matches = imageRegex?.matches(in: trimmed, range: nsRange) ?? []

            if matches.isEmpty {
                elements.append(.text(trimmed))
            } else {
                // Split around images
                var lastEnd = trimmed.startIndex
                for match in matches {
                    let matchRange = Range(match.range, in: trimmed)!

                    // Text before image
                    let before = String(trimmed[lastEnd..<matchRange.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !before.isEmpty {
                        elements.append(.text(before))
                    }

                    // Image
                    let altRange = Range(match.range(at: 1), in: trimmed)!
                    let pathRange = Range(match.range(at: 2), in: trimmed)!
                    let alt = String(trimmed[altRange])
                    let path = String(trimmed[pathRange])
                    elements.append(.image(alt: alt, path: path))

                    lastEnd = matchRange.upperBound
                }

                // Text after last image
                let after = String(trimmed[lastEnd...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !after.isEmpty {
                    elements.append(.text(after))
                }
            }
        }

        return elements
    }

    /// Extract fenced code blocks, returning interleaved .text and .code elements
    private static func extractCodeBlocks(from markdown: String) -> [MarkdownElement] {
        var result: [MarkdownElement] = []
        let lines = markdown.components(separatedBy: "\n")
        var currentText: [String] = []
        var codeLines: [String] = []
        var inCodeBlock = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    // End of code block
                    result.append(.code(codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCodeBlock = false
                } else {
                    // Start of code block — flush accumulated text
                    let text = currentText.joined(separator: "\n")
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        result.append(.text(text))
                    }
                    currentText = []
                    inCodeBlock = true
                }
            } else if inCodeBlock {
                codeLines.append(line)
            } else {
                currentText.append(line)
            }
        }

        // Flush remaining
        if inCodeBlock {
            // Unclosed code fence — treat as text
            currentText.append("```")
            currentText.append(contentsOf: codeLines)
        }
        let remaining = currentText.joined(separator: "\n")
        if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.text(remaining))
        }

        return result
    }
}
