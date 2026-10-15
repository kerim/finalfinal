//
//  SnapshotService+Transaction.swift
//  final final
//
//  t-94369a83 Phase 4b, slice 2a (plan D2.2(b), addendum A8): what `SnapshotService.createUndoPointSnapshot()`
//  does -- fetch every block, assemble the whole Markdown, write the content row, write the automatic
//  Version History snapshot with its section list -- but on an open GRDB `Database`, so a system-write body
//  (`SectionDeleteJob`) can run it INSIDE the same write transaction that deletes the section's rows. Nothing here
//  opens a `ProjectDatabase.write`/`read` (a nested one would trap), and nothing here is `@MainActor`: the body
//  runs on the writer's executor, not the MainActor.
//
//  WHY THE SECTION LIST IS DERIVED, NOT READ FROM THE `section` TABLE. `createUndoPointSnapshot()` stores
//  `fetchSections()`: the legacy `section` table, which `SectionSyncService` reconciles on its own schedule,
//  outside the writer queue. In the queue the job must snapshot exactly the block rows it is about to delete
//  from, in queue order, so the section list is derived from those same rows (the assembled Markdown is parsed
//  with the section sync's own `parseHeaders`). A8 asks that the derived list equal today's `fetchSections()`
//  field for field; the fields the block rows cannot give are read from the matching `section` row inside the
//  same transaction. Which fields come from where is spelled out on `derivedSnapshotSections`.
//

import Foundation
import GRDB

extension SnapshotService {

    /// What `writeUndoPointSnapshot` hands back: the snapshot row, plus the exact rows and section list it was
    /// assembled from (the same reads, in the same transaction), so a caller that goes on to delete rows works
    /// against precisely what the snapshot holds.
    struct InTransactionSnapshot: Sendable {
        let snapshot: Snapshot
        /// Every block of the project in `sortOrder`, as of the snapshot.
        let blocks: [Block]
        /// The section list written into the snapshot (`SnapshotSection(from:)` copies of these).
        let sections: [Section]
    }

    /// `createUndoPointSnapshot()` on an open `Database`: never skips on an unchanged-content hash (same rule),
    /// and does NOT pin the snapshot -- pinning is the caller's job, after the transaction commits and only when the
    /// timeline slot is still live (`SectionDeleteSlotStore.recordApplied`). Writes the content row and outline
    /// cache exactly as `saveContent` does, then the snapshot and its sections.
    nonisolated static func writeUndoPointSnapshot(
        db: Database,
        projectId: String,
        fallbackBibliographyTitle: String
    ) throws -> InTransactionSnapshot {
        let blocks = try Block
            .filter(Block.Columns.projectId == projectId)
            .order(Block.Columns.sortOrder)
            .fetchAll(db)
        // assembleMarkdownForEditor (not plain assembleMarkdown): see `createManualSnapshot`'s comment.
        let assembledMarkdown = BlockParser.assembleMarkdownForEditor(from: blocks)

        try ProjectDatabase.saveContent(db: db, markdown: assembledMarkdown, projectId: projectId)
        guard let content = try ProjectDatabase.fetchContent(db: db, projectId: projectId) else {
            throw SnapshotError.noContent
        }

        let sections = try derivedSnapshotSections(
            db: db, projectId: projectId, markdown: assembledMarkdown,
            fallbackBibliographyTitle: fallbackBibliographyTitle)
        DebugLog.log(
            .undo,
            "[SnapshotService] writeUndoPointSnapshot (in transaction): \(sections.count) sections, "
                + "\(blocks.count) blocks (no dedup skip)")

        let snapshot = try ProjectDatabase.createSnapshot(
            db: db,
            projectId: projectId,
            name: nil,
            isAutomatic: true,
            content: content,
            sections: sections,
            contentHash: computeHash(assembledMarkdown)
        )
        return InTransactionSnapshot(snapshot: snapshot, blocks: blocks, sections: sections)
    }

    /// The section list a snapshot of `markdown` (the whole document assembled from the block rows) holds,
    /// derived from those rows rather than read from the `section` table (addendum A8).
    ///
    /// FROM THE BLOCK ROWS (through `SectionSyncService.parseHeaders` on the assembled Markdown, the same parse
    /// the section sync reconciles the table from, with the bibliography/Notes heading titles resolved the way
    /// `fetchSectionSyncSnapshot` resolves them): `title`, `headerLevel`, `isPseudoSection`, `isBibliography`,
    /// `isNotes`, `sortOrder` (the header's position), `markdownContent`, `startOffset`, `wordCount`.
    ///
    /// FROM THE MATCHING `section` ROW, read inside this same transaction (a field the block rows cannot give with
    /// parity): `id` (the snapshot's `originalSectionId`: the table's own independently generated UUID, there is no
    /// shared id space with `block`), `parentId` (the legacy table's own parent link), `status`, `tags`, `wordGoal`,
    /// `goalType`, `aggregateGoal`, `aggregateGoalType`, `createdAt`, `updatedAt`. Today's snapshot takes status,
    /// tags and goals from the table too, so this keeps today's values; the sidebar reads them from the heading
    /// block rows instead (SectionCardView), and the two sources can differ, which is why they are NOT taken from
    /// the block rows here. A row matches a header when position, title and level agree, else when title, level
    /// and kind agree and the row is still unclaimed. A header with no matching row (a heading typed since the
    /// last section sync) gets a fresh id and the defaults a newly reconciled row would have: exactly what the
    /// next section sync will create for it, where today's snapshot would not list it at all.
    ///
    /// A `section` row with no header any more (a heading deleted since the last section sync) is not listed:
    /// the snapshot follows the block rows.
    nonisolated static func derivedSnapshotSections(
        db: Database,
        projectId: String,
        markdown: String,
        fallbackBibliographyTitle: String
    ) throws -> [Section] {
        let inputs = try ProjectDatabase.sectionSyncSnapshot(db: db, projectId: projectId)
        let headers = SectionSyncService.parseHeaders(
            from: markdown,
            existingBibTitle: inputs.existingBibTitle,
            existingNotesTitle: inputs.existingNotesTitle,
            fallbackBibTitle: fallbackBibliographyTitle
        )

        var claimedRowIds = Set<String>()
        var sections: [Section] = []
        sections.reserveCapacity(headers.count)
        let now = Date()
        for header in headers {
            let row = inputs.dbSections.first {
                !claimedRowIds.contains($0.id) && $0.sortOrder == header.position
                    && $0.title == header.title && $0.headerLevel == header.level
            } ?? inputs.dbSections.first {
                !claimedRowIds.contains($0.id) && $0.title == header.title && $0.headerLevel == header.level
                    && $0.isPseudoSection == header.isPseudoSection
            }
            if let row { claimedRowIds.insert(row.id) }

            sections.append(Section(
                id: row?.id ?? UUID().uuidString,
                projectId: projectId,
                parentId: row?.parentId,
                sortOrder: header.position,
                headerLevel: header.level,
                isPseudoSection: header.isPseudoSection,
                isBibliography: header.isBibliography,
                isNotes: header.isNotes,
                title: header.title,
                markdownContent: header.markdownContent,
                status: row?.status ?? .next,
                tags: row?.tags ?? [],
                wordGoal: row?.wordGoal,
                goalType: row?.goalType ?? .approx,
                aggregateGoal: row?.aggregateGoal,
                aggregateGoalType: row?.aggregateGoalType ?? .approx,
                wordCount: header.wordCount,
                startOffset: header.startOffset,
                createdAt: row?.createdAt ?? now,
                updatedAt: row?.updatedAt ?? now
            ))
        }
        return sections
    }
}
