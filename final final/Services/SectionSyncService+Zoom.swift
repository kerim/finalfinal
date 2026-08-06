//
//  SectionSyncService+Zoom.swift
//  final final
//

import Foundation

// MARK: - Zoomed Sync Helpers

extension SectionSyncService {

    /// Match parsed headers to existing zoomed sections by position and build update changes
    /// for any that differ. Verbatim lift of the match/diff loop from `syncZoomedSections`.
    ///
    /// - Precondition: `zoomedExisting` must already be sorted ascending by `sortOrder`. The
    ///   match loop pairs `headers[index]` with `zoomedExisting[index]` positionally, so an
    ///   unsorted array pairs the wrong header with the wrong section.
    nonisolated static func zoomedUpdateChanges(headers: [ParsedHeader], zoomedExisting: [Section]) -> [SectionChange] {
        var changes: [SectionChange] = []
        let matchCount = min(headers.count, zoomedExisting.count)
        for index in 0..<matchCount {
            let header = headers[index]
            let existing = zoomedExisting[index]
            var updates = SectionUpdates()
            var hasChanges = false

            if header.title != existing.title {
                updates.title = header.title
                hasChanges = true
            }
            if header.level != existing.headerLevel {
                updates.headerLevel = header.level
                hasChanges = true
            }
            if header.markdownContent != existing.markdownContent {
                updates.markdownContent = header.markdownContent
                updates.wordCount = header.wordCount
                hasChanges = true
            }
            if header.startOffset != existing.startOffset {
                updates.startOffset = header.startOffset
                hasChanges = true
            }
            if hasChanges {
                changes.append(.update(id: existing.id, updates: updates))
            }
        }
        return changes
    }

    /// Handle NEW sections (user added headers while zoomed): shift trailing sections'
    /// sortOrder to make room, then build insert changes for the new headers. Verbatim lift
    /// of the `if headers.count > zoomedExisting.count` block from `syncZoomedSections`.
    ///
    /// - Precondition: `zoomedExisting` and `allSorted` must already be sorted ascending by
    ///   `sortOrder`. `zoomedExisting.last?.sortOrder` and `allSorted.first { $0.sortOrder > ... }`
    ///   both depend on ascending order to find the true last zoomed section and the first
    ///   section after it; the new-header loop also pairs positionally against that ordering.
    nonisolated static func zoomedInsertionChanges(
        headers: [ParsedHeader],
        zoomedExisting: [Section],
        allSorted: [Section],
        zoomedIds: Set<String>,
        pid: String
    ) -> (changes: [SectionChange], insertedIds: Set<String>) {
        var changes: [SectionChange] = []
        var insertedIds: Set<String> = []

        if headers.count > zoomedExisting.count {
            let newCount = headers.count - zoomedExisting.count
            let lastZoomedSortOrder = zoomedExisting.last?.sortOrder ?? 0
            let firstAfterZoomed = allSorted.first { $0.sortOrder > lastZoomedSortOrder && !zoomedIds.contains($0.id) }

            if let firstAfter = firstAfterZoomed {
                let sectionsToShift = allSorted.filter { $0.sortOrder >= firstAfter.sortOrder }
                for section in sectionsToShift {
                    changes.append(.update(id: section.id, updates: SectionUpdates(sortOrder: section.sortOrder + newCount)))
                }
            }

            for i in zoomedExisting.count..<headers.count {
                let header = headers[i]
                let newSortOrder = lastZoomedSortOrder + (i - zoomedExisting.count) + 1
                let newSection = Section(
                    projectId: pid, sortOrder: newSortOrder, headerLevel: header.level,
                    isPseudoSection: header.isPseudoSection, title: header.title,
                    markdownContent: header.markdownContent, wordCount: header.wordCount,
                    startOffset: header.startOffset
                )
                changes.append(.insert(newSection))
                insertedIds.insert(newSection.id)
            }
        }

        return (changes, insertedIds)
    }

    /// Handle DELETED sections (user removed headers while zoomed). Verbatim lift of the
    /// `if headers.count < zoomedExisting.count` block from `syncZoomedSections`.
    ///
    /// - Precondition: `zoomedExisting` must already be sorted ascending by `sortOrder`. The
    ///   trailing slice `zoomedExisting[headers.count..<zoomedExisting.count]` is only the set
    ///   of *removed* sections if the array is in ascending sort order.
    nonisolated static func zoomedDeletionChanges(
        headers: [ParsedHeader],
        zoomedExisting: [Section]
    ) -> (changes: [SectionChange], removedIds: Set<String>) {
        var changes: [SectionChange] = []
        var removedIds: Set<String> = []

        if headers.count < zoomedExisting.count {
            for i in headers.count..<zoomedExisting.count {
                let removedSection = zoomedExisting[i]
                changes.append(.delete(id: removedSection.id))
                removedIds.insert(removedSection.id)
            }
        }

        return (changes, removedIds)
    }
}
