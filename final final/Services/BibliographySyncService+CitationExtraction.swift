//
//  BibliographySyncService+CitationExtraction.swift
//  final final
//

import Foundation

// MARK: - Citekey Extraction

extension BibliographySyncService {

    /// Pre-compiled regex for finding each complete `[...]` bracket span. See
    /// `extractCitekeys`'s doc comment (shared with `ExportService+Citations.swift`'s
    /// identical two-pass approach) for why scoping to a closed span matters.
    nonisolated(unsafe) private static let citationSpanPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"\[[^\]]*\]"#, options: [])
        } catch {
            fatalError("Invalid regex pattern: \(error)")
        }
    }()

    /// Pre-compiled regex for pulling every `@citekey` out of a bracket span found by
    /// `citationSpanPattern`. Called on every live content change (a hot path — see
    /// `ViewNotificationModifiers.swift`/`ContentView+NotificationHandlers.swift`), hence
    /// precompiled as a static rather than constructed per call.
    nonisolated(unsafe) private static let citationKeyPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(
                pattern: #"(?<![\w/])@(?![^\]{}\s]*/)([^\]{}/,;\s]+)"#,
                options: []
            )
        } catch {
            fatalError("Invalid regex pattern: \(error)")
        }
    }()

    /// Extract citekeys from markdown content (skips code blocks and inline code).
    /// Two-pass, bracket-span-scoped extraction identical to
    /// `ExportService.extractCitekeys(from:)` — see that function's doc comment for the full
    /// rationale (prose-before-@ / suppress-author forms, the closed-span requirement, the
    /// key character-class guards, and why a bare `@key` is never extracted here either).
    nonisolated static func extractCitekeys(from markdown: String) -> [String] {
        let stripped = MarkdownUtils.stripCodeContent(from: markdown)
        let full = NSRange(stripped.startIndex..., in: stripped)
        return citationSpanPattern.matches(in: stripped, range: full).flatMap { span -> [String] in
            citationKeyPattern.matches(in: stripped, range: span.range).compactMap { match in
                guard let range = Range(match.range(at: 1), in: stripped) else { return nil }
                return String(stripped[range])
            }
        }
    }
}
