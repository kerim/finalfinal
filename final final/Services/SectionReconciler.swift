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
struct ParsedHeader {
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
class SectionReconciler {

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
        for section in sortedDB where !matchedDBIds.contains(section.id) {
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
        let available = sections.filter { !excluding.contains($0.id) }

        // Tier 1: Exact position match (most common - edits within a section)
        if let match = available.first(where: { $0.sortOrder == header.position }) {
            return match
        }

        // Tier 2: Same title anywhere (handles drag-drop reordering)
        // Skip for pseudo-sections which all have similar generated titles
        if !header.isPseudoSection,
           let match = available.first(where: { $0.title == header.title && $0.headerLevel == header.level }) {
            return match
        }

        // Tier 3: Closest position within ±3 (handles batch deletes/inserts)
        return available
            .filter { abs($0.sortOrder - header.position) <= 3 }
            .min { abs($0.sortOrder - header.position) < abs($1.sortOrder - header.position) }
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
