//
//  ExportService+Citations.swift
//  final final
//

import Foundation

// MARK: - Citation Detection

extension ExportService {

    /// Detect Pandoc citations in content (skips code blocks and inline code)
    /// Matches any bracketed text containing @ followed by a citekey
    /// Pattern from citation-plugin.ts: \[([^\]]*@[\w:.-][^\]]*)\]
    func hasPandocCitations(in content: String) -> Bool {
        let stripped = MarkdownUtils.stripCodeContent(from: content)
        return stripped.range(
            of: #"\[[^\]]*@[\w:.-]+[^\]]*\]"#,
            options: .regularExpression
        ) != nil
    }

    /// Extract citekeys from markdown content (skips code blocks and inline code).
    /// Duplicates BibliographySyncService.extractCitekeys regex to avoid @MainActor isolation.
    func extractCitekeys(from content: String) -> [String] {
        let stripped = MarkdownUtils.stripCodeContent(from: content)
        let pattern = #"(?:\[|; )@([^\],;\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(stripped.startIndex..., in: stripped)
        return regex.matches(in: stripped, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: stripped) else { return nil }
            return String(stripped[r])
        }
    }

    /// Fetch bibliography as raw CSL-JSON string from Zotero/BBT for the given citekeys, for
    /// pandoc's `--bibliography` argument.
    ///
    /// Routes through `ZoteroService.fetchRawItemsForCitekeys()` — the shared, library-scoped,
    /// RAW (undecoded) resolver — instead of making its own raw `item.export` JSON-RPC call
    /// (which used to be unscoped, silently "My Library"-only, the same defect as the old
    /// citekey resolver, so PDF export silently dropped group-library citations) and instead
    /// of the typed `fetchItemsForCitekeys()`/`CSLItem` resolver: `CSLItem` only models a
    /// subset of CSL-JSON fields, and re-encoding through it would silently drop every field
    /// it doesn't know about (translator, edition, collection-title, chapter-number, genre,
    /// original-date, etc.) — fields the bundled `chicago-author-date.csl` style actually
    /// uses. The raw resolver shares the exact same two-phase (personal-then-group) resolution
    /// and `item.pandoc_filter`-with-fallback behavior as CAYW/autocomplete, just without the
    /// lossy round trip.
    func fetchBibliographyJSON(for citekeys: [String]) async -> String? {
        guard !citekeys.isEmpty else { return nil }

        do {
            let items = try await ZoteroService.shared.fetchRawItemsForCitekeys(citekeys)
            guard !items.isEmpty else { return nil }

            let data = try JSONSerialization.data(withJSONObject: items)
            return String(data: data, encoding: .utf8)
        } catch {
            DebugLog.log(.fileOps, "[ExportService] Failed to fetch bibliography JSON: \(error)")
            return nil
        }
    }

    /// Strip annotation HTML comments from markdown content
    /// Matches patterns like <!-- ::task:: text --> or <!-- ::comment:: notes -->
    func stripAnnotations(from content: String) -> String {
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
