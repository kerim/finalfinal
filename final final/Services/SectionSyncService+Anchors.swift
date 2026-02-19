//
//  SectionSyncService+Anchors.swift
//  final final
//

import Foundation

// MARK: - Section Anchor Support

extension SectionSyncService {

    /// Regex pattern for section anchor comments
    /// Anchors are on the same line as headers (no newline in pattern)
    static let anchorPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(
                pattern: #"<!-- @sid:([0-9a-fA-F-]+) -->"#,
                options: []
            )
        } catch {
            fatalError("Invalid regex pattern: \(error)")
        }
    }()

    /// Inject section anchors before each header in markdown
    /// Used when switching from WYSIWYG to source mode
    /// Anchors are placed on the SAME LINE as headers (no newline after anchor)
    /// to prevent blank lines when CodeMirror hides the anchor comment
    /// - Parameters:
    ///   - markdown: The markdown content
    ///   - sections: Current sections with their IDs
    /// - Returns: Markdown with anchors injected before headers
    func injectSectionAnchors(markdown: String, sections: [SectionViewModel]) -> String {
        guard !sections.isEmpty else { return markdown }

        // Build a map of header text to section ID
        // We match by finding headers in the markdown and associating them with sections
        var result = markdown

        // Sort sections by startOffset in reverse order (inject from end to avoid offset drift)
        let sortedSections = sections.sorted { $0.startOffset > $1.startOffset }

        for section in sortedSections {
            // Find the header line at the section's start offset
            let offset = min(section.startOffset, result.count)
            let insertionIndex = result.index(result.startIndex, offsetBy: offset)

            // Inject anchor on SAME LINE as header (no newline)
            let anchor = "<!-- @sid:\(section.id) -->"
            result.insert(contentsOf: anchor, at: insertionIndex)
        }

        return result
    }

    /// Extract section anchors and their IDs from markdown
    /// Used when switching from source mode back to WYSIWYG
    /// Anchors are expected to be on the same line as headers: `<!-- @sid:UUID --># Header`
    /// - Parameter markdown: The markdown content with anchors
    /// - Returns: Tuple of (clean markdown, anchor mappings)
    func extractSectionAnchors(markdown: String) -> (markdown: String, anchors: [SectionAnchorMapping]) {
        var anchors: [SectionAnchorMapping] = []
        let nsRange = NSRange(markdown.startIndex..., in: markdown)

        // Find all anchors and their positions
        let matches = Self.anchorPattern.matches(in: markdown, options: [], range: nsRange)

        var offsetAdjustment = 0

        for match in matches {
            guard let idRange = Range(match.range(at: 1), in: markdown) else { continue }

            let anchorId = String(markdown[idRange])
            let originalOffset = match.range.location

            // Calculate the offset in the cleaned markdown (after previous anchors removed)
            let cleanedOffset = originalOffset - offsetAdjustment

            anchors.append(SectionAnchorMapping(
                sectionId: anchorId,
                headerOffset: cleanedOffset
            ))

            // Track how much we've removed for offset adjustment
            // match.range.length gives us the length of the full match
            offsetAdjustment += match.range.length
        }

        // Remove all anchors from the markdown
        let cleanedMarkdown = Self.anchorPattern.stringByReplacingMatches(
            in: markdown,
            options: [],
            range: nsRange,
            withTemplate: ""
        )

        return (cleanedMarkdown, anchors)
    }

    /// Strip all section anchors from markdown
    /// Used for clean export and display
    func stripSectionAnchors(from markdown: String) -> String {
        Self.anchorPattern.stringByReplacingMatches(
            in: markdown,
            options: [],
            range: NSRange(markdown.startIndex..., in: markdown),
            withTemplate: ""
        )
    }

    // MARK: - Bibliography Marker Support

    /// Inject bibliography marker before the bibliography section header
    /// Used when building sourceContent for CodeMirror (follows section anchor pattern)
    /// - Parameters:
    ///   - markdown: The markdown content (with section anchors already injected)
    ///   - sections: Current sections to identify bibliography
    /// - Returns: Markdown with bibliography marker injected before the bibliography header
    func injectBibliographyMarker(markdown: String, sections: [SectionViewModel]) -> String {
        // Find the bibliography section
        guard let bibSection = sections.first(where: { $0.isBibliography }) else {
            return markdown
        }

        // Find the bibliography header in the markdown
        // The header might be prefixed with a section anchor: <!-- @sid:UUID --># Bibliography
        let bibHeaderName = ExportSettingsManager.shared.bibliographyHeaderName

        // Try to find the header with or without anchor prefix
        // Pattern: optional anchor + "# HeaderName"
        let anchorPrefixPattern = #"(<!-- @sid:[0-9a-fA-F-]+ -->)?"#
        let headerPattern = anchorPrefixPattern + #"# \#(bibHeaderName)"#

        guard let regex = try? NSRegularExpression(pattern: headerPattern, options: []) else {
            return markdown
        }

        let nsRange = NSRange(markdown.startIndex..., in: markdown)
        guard let match = regex.firstMatch(in: markdown, options: [], range: nsRange),
              let range = Range(match.range, in: markdown) else {
            return markdown
        }

        // Insert the marker at the start of the matched range (before any anchor)
        var result = markdown
        let marker = "<!-- ::auto-bibliography:: -->"
        result.insert(contentsOf: marker, at: range.lowerBound)
        return result
    }

    /// Strip bibliography marker from markdown
    /// Used when cleaning content for Milkdown or export
    /// nonisolated: pure string operation, safe to call from any context (e.g. BlockParser)
    nonisolated static func stripBibliographyMarker(from markdown: String) -> String {
        markdown.replacingOccurrences(of: "<!-- ::auto-bibliography:: -->", with: "")
    }
}
