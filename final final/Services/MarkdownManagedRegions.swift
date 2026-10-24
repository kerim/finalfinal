//
//  MarkdownManagedRegions.swift
//  final final
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), round 4, O28: the Notes and Bibliography REGIONS of a Markdown text,
//  in the NORMAL FORM the page's region replace compares in (web/codemirror/src/api-managed-region.ts, `normalizeRegionText`):
//  hidden markers removed (section anchors, the bibliography opening and end markers, the zoom-notes marker), whitespace-only lines
//  emptied, runs of blank lines collapsed to one, trimmed at both ends.
//
//  Swift finds a region the way the database finds it: it PARSES the text (`BlockParser.parse`, the parse every Markdown save already
//  makes) and takes the blocks flagged `isNotes` / `isBibliography`. The same function reads the editor's text (the content record,
//  at the moment a rebuild reads the rows: the `expectedOld` the page checks) and the text the rebuild assembled from the rows (the
//  `newText` the page writes), so the two sides are described by one rule. The page finds the same region by its markers and its
//  leader-line rule (heading line to the next heading, or to the bibliography opening marker, or the end).
//

import Foundation

/// The two machine-managed regions of a Markdown document.
enum MarkdownManagedRegion: String, Sendable {
    case notes
    case bibliography
}

/// What each region holds in one version of the document, in normal form. nil: the document has no such region.
struct MarkdownRegionSnapshot: Equatable, Sendable {
    var notes: String?
    /// The Notes heading's line (trimmed, markers removed), which the page uses to find the region ("## Notes", or the user's own title).
    var notesHeadingLine: String?
    var bibliography: String?

    func text(_ region: MarkdownManagedRegion) -> String? {
        switch region {
        case .notes: return notes
        case .bibliography: return bibliography
        }
    }
}

enum MarkdownManagedRegions {

    private static func compile(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            fatalError("Invalid managed-region regex pattern: \(error)")
        }
    }

    private static let hiddenMarkers = compile(
        "<!-- @sid:[0-9a-fA-F-]+ -->|<!-- ::auto-bibliography:: -->|<!-- ::auto-bibliography-end:: -->|<!-- ::zoom-notes:: -->")
    private static let whitespaceOnlyLine = compile("\n[ \t]+(?=\n)")
    private static let blankRuns = compile("\n{3,}")

    private static func replacing(_ text: String, _ regex: NSRegularExpression, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// The normal form of a region's text (`normalizeRegionText` in api-managed-region.ts).
    static func normalized(_ text: String) -> String {
        var result = replacing(text, hiddenMarkers, with: "")
        result = result.replacingOccurrences(of: "\r\n", with: "\n")
        result = replacing(result, whitespaceOnlyLine, with: "\n")
        result = replacing(result, blankRuns, with: "\n\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Both regions of `markdown`, from a parse. `notesTitle` is the Notes heading title the database knows (`fetchNotesHeadingTitle`);
    /// the two bibliography parameters exist so a test can isolate itself from the process-wide export settings (give both or neither).
    static func snapshot(
        markdown: String,
        projectId: String,
        notesTitle: String?,
        bibliographyHeaderName: String? = nil,
        graceNames: [String]? = nil
    ) -> MarkdownRegionSnapshot {
        let blocks = BlockParser.parse(
            markdown: markdown, projectId: projectId, bibliographyHeaderName: bibliographyHeaderName, graceNames: graceNames,
            notesHeaderName: notesTitle)
        return snapshot(blocks: blocks)
    }

    /// Both regions of an assembled block list (document order).
    static func snapshot(blocks: [Block]) -> MarkdownRegionSnapshot {
        let ordered = MarkdownBlockDiff.assemblyOrderedNonEmpty(blocks)
        let notes = ordered.filter(\.isNotes)
        let bibliography = ordered.filter(\.isBibliography)
        var snapshot = MarkdownRegionSnapshot()
        if !notes.isEmpty {
            snapshot.notes = normalized(notes.map(\.markdownFragment).joined(separator: "\n\n"))
            let heading = notes.first { $0.blockType == .heading }
            snapshot.notesHeadingLine = heading.flatMap { block in
                normalized(block.markdownFragment).components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces)
            }
        }
        if !bibliography.isEmpty {
            snapshot.bibliography = normalized(bibliography.map(\.markdownFragment).joined(separator: "\n\n"))
        }
        return snapshot
    }
}
