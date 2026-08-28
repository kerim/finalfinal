//
//  BibliographySyncService+EntryFormatting.swift
//  final final
//

import Foundation

// MARK: - Bibliography Markdown / Entry Formatting

extension BibliographySyncService {

    func generateBibliographyMarkdown(citekeys: [String]) -> String {
        let zoteroService = ZoteroService.shared

        // Get items for citekeys
        let items = zoteroService.getItems(citekeys: citekeys)
        guard !items.isEmpty else { return "" }

        // Sort by author name, then year
        let sorted = items.sorted { a, b in
            let aName = a.firstAuthorName.lowercased()
            let bName = b.firstAuthorName.lowercased()
            if aName != bName {
                return aName < bName
            }
            return a.year < b.year
        }

        // Generate formatted entries
        var entries: [String] = []
        for item in sorted {
            let entry = formatBibliographyEntry(item)
            entries.append(entry)
        }

        // Build markdown WITHOUT marker (marker is injected only for CodeMirror source mode)
        // This follows the section anchor pattern: store clean content, inject markers for source view
        let headerName = ExportSettingsManager.shared.effectiveBibliographyHeaderName
        var markdown = "# \(headerName)\n\n"
        markdown += entries.joined(separator: "\n\n")
        markdown += "\n\n"

        return markdown
    }

    /// Format a single bibliography entry
    /// Uses Chicago author-date format as default
    private func formatBibliographyEntry(_ item: CSLItem) -> String {
        var parts: [String] = []

        // Authors
        if let authors = item.author, !authors.isEmpty {
            parts.append(formatAuthorList(authors))
        }

        // Year
        parts.append("(\(item.year)).")

        // Title
        if let title = item.title {
            parts.append(formatTitle(title, type: item.type))
        }

        // Container title (journal, book for chapters)
        if let container = item.containerTitle {
            parts.append(contentsOf: formatContainerParts(
                container: container,
                volume: item.volume,
                issue: item.issue,
                page: item.page
            ))
        }

        // Publisher
        if let publisher = item.publisher {
            parts.append(formatPublisher(publisher, place: item.publisherPlace))
        }

        // DOI/URL
        if let doi = item.DOI {
            parts.append("https://doi.org/\(doi)")
        } else if let url = item.URL {
            parts.append(url)
        }

        return parts.joined(separator: " ")
    }

    /// Formats the author list for a bibliography entry (Chicago author-date style):
    /// single author, two authors joined with "and", or three-plus with a serial comma.
    private func formatAuthorList(_ authors: [CSLName]) -> String {
        let authorNames = authors.map(formatAuthorName)

        if authorNames.count == 1 {
            return authorNames[0] + "."
        } else if authorNames.count == 2 {
            return "\(authorNames[0]), and \(authorNames[1])."
        } else {
            let allButLast = authorNames.dropLast().joined(separator: ", ")
            let last = authorNames.last ?? ""
            return "\(allButLast), and \(last)."
        }
    }

    /// Formats a single author as "Family, Given", falling back to whichever name part
    /// is present, or the literal name for institutional authors.
    private func formatAuthorName(_ author: CSLName) -> String {
        if let literal = author.literal {
            return literal
        }
        let family = author.family ?? ""
        let given = author.given ?? ""
        if !family.isEmpty && !given.isEmpty {
            return "\(family), \(given)"
        }
        return family.isEmpty ? given : family
    }

    /// Formats the title, italicized for books/theses or quoted for articles.
    private func formatTitle(_ title: String, type: CSLItemType) -> String {
        let isBook = type.rawValue == "book" || type.rawValue == "thesis"
        if isBook {
            return "*\(title)*."
        } else {
            return "\"\(title).\""
        }
    }

    /// Formats the container title (journal, or book for chapters) along with its
    /// volume/issue and page range, ensuring the section ends with a trailing period.
    private func formatContainerParts(
        container: String,
        volume: String?,
        issue: String?,
        page: String?
    ) -> [String] {
        var parts: [String] = ["*\(container)*"]

        // Volume/issue
        var volIssue: [String] = []
        if let volume {
            volIssue.append(volume)
        }
        if let issue {
            volIssue.append("(\(issue))")
        }
        if !volIssue.isEmpty {
            parts.append(volIssue.joined())
        }

        // Page
        if let page {
            parts.append(": \(page).")
        } else {
            // Ensure period after container/volume
            if let last = parts.last, !last.hasSuffix(".") {
                parts[parts.count - 1] = last + "."
            }
        }

        return parts
    }

    /// Formats the publisher, with an optional place prefixed before a colon.
    private func formatPublisher(_ publisher: String, place: String?) -> String {
        var pubParts: [String] = []
        if let place {
            pubParts.append(place)
        }
        pubParts.append(publisher)
        return pubParts.joined(separator: ": ") + "."
    }
}
