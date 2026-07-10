//
//  SectionReconciler.swift
//  final final
//
//  Position-based section reconciliation for editor ↔ database sync.
//  Matches parsed headers to database sections using a three-tier strategy:
//  1. Exact position match (most common - edits within a section)
//  2. Same title anywhere (handles drag-drop reordering)
//  3. Closest position within ±3 (handles batch deletes/inserts)
//

import Foundation

/// Parsed header information from markdown content
struct ParsedHeader: Sendable {
    let position: Int           // 0-indexed position among headers
    let title: String
    let level: Int              // Header level (1-6, pseudo-sections inherit from preceding)
    let isPseudoSection: Bool   // True for break markers (<!-- ::break:: -->)
    let startOffset: Int        // Character offset where section starts
    let markdownContent: String // Full markdown content of this section
    let wordCount: Int
}

/// Core reconciliation engine for section sync
/// Compares parsed headers with database sections to produce surgical changes
struct SectionReconciler: Sendable {

    /// Reconcile parsed headers with existing database sections
    /// Returns the minimal set of changes needed to update the database
    /// - Parameters:
    ///   - headers: Headers parsed from the current markdown content
    ///   - dbSections: Existing sections from the database
    ///   - projectId: Project ID for new sections
    /// - Returns: Array of changes to apply (insert/update/delete)
    func reconcile(
        headers: [ParsedHeader],
        dbSections: [Section],
        projectId: String
    ) -> [SectionChange] {
        var changes: [SectionChange] = []
        var matchedDBIds: Set<String> = []

        // Sort DB sections by position for matching
        let sortedDB = dbSections.sorted { $0.sortOrder < $1.sortOrder }

        // Match each parsed header to a database section
        for (index, header) in headers.enumerated() {
            if let match = findMatch(header, in: sortedDB, excluding: matchedDBIds) {
                matchedDBIds.insert(match.id)

                // Check if section needs updating
                let updates = buildUpdates(header: header, existing: match, newPosition: index)
                if updates != nil {
                    changes.append(.update(id: match.id, updates: updates!))
                }
            } else {
                // New section - create with new UUID
                let newSection = Section(
                    projectId: projectId,
                    sortOrder: index,
                    headerLevel: header.level,
                    isPseudoSection: header.isPseudoSection,
                    title: header.title,
                    markdownContent: header.markdownContent,
                    wordCount: header.wordCount,
                    startOffset: header.startOffset
                )
                changes.append(.insert(newSection))
            }
        }

        // Unmatched DB sections were deleted from markdown
        // EXCEPT bibliography/notes sections which are managed separately by their sync services
        for section in sortedDB where !matchedDBIds.contains(section.id) && !section.isBibliography && !section.isNotes {
            changes.append(.delete(id: section.id))
        }

        return changes
    }

    // MARK: - Private Matching Logic

    /// Three-tier matching strategy for robust section identification
    /// - Parameters:
    ///   - header: The parsed header to match
    ///   - sections: Available database sections (sorted by sortOrder)
    ///   - excluding: IDs already matched (to prevent double-matching)
    /// - Returns: Matching section, or nil if no match found
    private func findMatch(
        _ header: ParsedHeader,
        in sections: [Section],
        excluding: Set<String>
    ) -> Section? {
        // Filter out already-matched IDs and bibliography sections.
        // Bibliography exclusion is needed because:
        // 1. OutlineParser markers prevent parsed headers FROM the bibliography
        // 2. But we also need to prevent parsed headers from matching TO the bibliography
        //    section via Tier 3 proximity matching. BibliographySyncService owns this section.
        let available = sections.filter { !excluding.contains($0.id) && !$0.isBibliography && !$0.isNotes }

        // Tier 1: Exact position match (most common - edits within a section)
        // Only honored when there's actual evidence the parsed header and the DB
        // row are the SAME logical section — not just co-located by sortOrder.
        // Without this gate, deleting a section's header+body causes whatever
        // follows to slide into the deleted section's old sortOrder slot and
        // silently inherit its identity (see meaningfulTextOverlap() in
        // web/milkdown/src/block-id-plugin.ts for the analogous fix on the
        // ProseMirror side of this exact bug).
        if let match = available.first(where: { $0.sortOrder == header.position }),
           header.title == match.title || contentRelated(header.markdownContent, match.markdownContent) {
            return match
        }

        // Tier 2: Same title anywhere (handles drag-drop reordering)
        // Skip for pseudo-sections which all have similar generated titles
        if !header.isPseudoSection,
           let match = available.first(where: { $0.title == header.title && $0.headerLevel == header.level }) {
            return match
        }

        // Tier 3: Closest position within ±3 (handles batch deletes/inserts)
        // Prefer a candidate with title/content evidence (the same relatedness gate
        // used by Tier 1) over a merely-closer unrelated one. Without this, a header
        // that lands within ±3 of an unrelated row (e.g. two sections deleted and a
        // third renamed in the same edit) can steal that row's identity while the
        // row that actually matches, now slightly farther away but still in range,
        // is left to be hard-deleted. Pseudo-sections rely on this exclusively,
        // since Tier 2 explicitly skips them (their titles are too generic to
        // trust) — but real pseudo-section content always includes at least the
        // break marker line and, in the common case, the distinguishing paragraph
        // that follows it, so the same gate that protects Tier 1 works here
        // unmodified. If NO candidate in range has any evidence at all, fall back
        // to the original pure-proximity behavior — Tier 3 exists specifically as
        // a last resort when a section's title AND content have both changed and
        // only position continuity remains as a signal (see closestPositionMatch).
        let inRange = available.filter { abs($0.sortOrder - header.position) <= 3 }
        let related = inRange.filter { header.title == $0.title || contentRelated(header.markdownContent, $0.markdownContent) }
        let candidates = related.isEmpty ? inRange : related
        return candidates
            .min { abs($0.sortOrder - header.position) < abs($1.sortOrder - header.position) }
    }

    /// Whether a parsed header's content looks like the same logical section as an
    /// existing DB row, rather than unrelated content that happens to occupy the
    /// same sortOrder slot. Byte-identical content (including both empty) always
    /// counts as related. Otherwise, a prefix/suffix relationship in either
    /// direction counts — this covers body-only edits, header-level conversions,
    /// and partial rewrites that preserve a leading or trailing run of text. One
    /// side empty and the other not does NOT count: every string is trivially a
    /// "prefix" of any string, so an empty section could otherwise claim any
    /// unrelated non-empty row (or vice versa) just by chance.
    private func contentRelated(_ headerContent: String, _ existingContent: String) -> Bool {
        if headerContent.isEmpty || existingContent.isEmpty { return false }
        if headerContent == existingContent { return true }
        return headerContent.hasPrefix(existingContent) || existingContent.hasPrefix(headerContent)
            || headerContent.hasSuffix(existingContent) || existingContent.hasSuffix(headerContent)
    }

    /// Build updates struct if any field changed
    /// Returns nil if no changes needed
    private func buildUpdates(
        header: ParsedHeader,
        existing: Section,
        newPosition: Int
    ) -> SectionUpdates? {
        var hasChanges = false
        var updates = SectionUpdates()

        // Title changed (rename)
        if header.title != existing.title {
            updates.title = header.title
            hasChanges = true
        }

        // Level changed
        if header.level != existing.headerLevel {
            updates.headerLevel = header.level
            hasChanges = true
        }

        // isPseudoSection changed
        if header.isPseudoSection != existing.isPseudoSection {
            updates.isPseudoSection = header.isPseudoSection
            hasChanges = true
        }

        // Position changed
        if newPosition != existing.sortOrder {
            updates.sortOrder = newPosition
            hasChanges = true
        }

        // Content changed
        if header.markdownContent != existing.markdownContent {
            updates.markdownContent = header.markdownContent
            updates.wordCount = header.wordCount
            hasChanges = true
        }

        // Offset changed
        if header.startOffset != existing.startOffset {
            updates.startOffset = header.startOffset
            hasChanges = true
        }

        return hasChanges ? updates : nil
    }
}
