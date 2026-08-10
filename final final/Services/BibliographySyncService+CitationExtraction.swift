//
//  BibliographySyncService+CitationExtraction.swift
//  final final
//

import Foundation

// MARK: - Citekey Extraction

extension BibliographySyncService {

    /// Extract citekeys from markdown content (skips code blocks and inline code).
    /// Two-pass, bracket-span-scoped extraction identical to
    /// `ExportService.extractCitekeys(from:)` — see that function's doc comment for the full
    /// rationale (prose-before-@ / suppress-author forms, the closed-span requirement, the
    /// key character-class guards, and why a bare `@key` is never extracted here either).
    /// Regexes come from the shared, precompiled `ExportCitationRegex` (see its doc comment)
    /// rather than a private copy — precompilation still matters here since this runs on
    /// every live content change (a hot path — see
    /// `ViewNotificationModifiers.swift`/`ContentView+NotificationHandlers.swift`), and
    /// `ExportCitationRegex`'s patterns are themselves precompiled statics.
    nonisolated static func extractCitekeys(from markdown: String) -> [String] {
        let stripped = MarkdownUtils.stripCodeContent(from: markdown)
        let full = NSRange(stripped.startIndex..., in: stripped)
        return ExportCitationRegex.span.matches(in: stripped, range: full).flatMap { span -> [String] in
            ExportCitationRegex.key.matches(in: stripped, range: span.range).compactMap { match in
                guard let range = Range(match.range(at: 1), in: stripped) else { return nil }
                return String(stripped[range])
            }
        }
    }
}
