//
//  ProjectDatabase+MigrationHelpers.swift
//  final final
//
//  Raw-SQL/Row helpers used only by specific migrations in ProjectDatabase.swift's
//  `migrate()` -- split out to keep that class's body under SwiftLint's
//  type_body_length limit. Mechanical move only: `migrate()` itself, and the exact
//  order it registers migrations in, is unchanged in ProjectDatabase.swift -- these
//  two static functions are called BY those migration closures, not part of the
//  registration sequence itself, so moving their bodies here changes nothing about
//  migration ordering.
//

import Foundation
import GRDB

extension ProjectDatabase {
    /// Raw-SQL backfill for `sectionParentId`, used ONLY by the `v15_block_sectionParentId`
    /// migration (ProjectDatabase.swift) -- see the comment there for why this must not call
    /// `recomputeSectionParents(db:projectId:)` (Database+BlockParents.swift). Re-derives that
    /// helper's exact filter (heading OR pseudo-section) and ordering (`isBibliography ASC,
    /// sortOrder ASC`), matching `fetchOutlineBlocks` (Database+Blocks.swift), but selects and
    /// writes only the columns needed for that -- `id`, `headingLevel`, `sectionParentId`, plus
    /// `sortOrder`/`isBibliography`/`blockType`/`isPseudoSection` for the filter/order clauses --
    /// via `Row`, never through the `Block` record type. Not private: called from
    /// `migrate()` in ProjectDatabase.swift, and Swift's `private` is file-scoped.
    static func backfillSectionParentIdsAtV15(db: Database, projectId: String) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, headingLevel, sectionParentId FROM block
                WHERE projectId = ? AND (blockType = ? OR isPseudoSection = 1)
                ORDER BY isBibliography ASC, sortOrder ASC
                """,
            arguments: [projectId, BlockType.heading.rawValue]
        )

        // `?? 1` coalescing matches SectionViewModel.headerLevel / recomputeSectionParents
        // exactly -- see SectionHierarchy.parentIds' doc comment for why all callers must agree.
        let entries: [(id: String, level: Int)] = rows.map { row in
            let headingLevel: Int? = row["headingLevel"]
            return (id: row["id"], level: headingLevel ?? 1)
        }
        let newParentIds = SectionHierarchy.parentIds(for: entries)

        for (row, newParentId) in zip(rows, newParentIds) {
            let currentParentId: String? = row["sectionParentId"]
            guard currentParentId != newParentId else { continue }
            let id: String = row["id"]
            try db.execute(
                sql: "UPDATE block SET sectionParentId = ? WHERE id = ?",
                arguments: [newParentId, id]
            )
        }
    }

    /// Raw-`Row` reimplementation of `FootnoteSyncService.deleteOrphanedFootnoteDefinitions`'s
    /// B5 allowlist rule, used ONLY by the `v16_notes_orphan_sweep` migration
    /// (ProjectDatabase.swift) -- see that migration's comment for why this must not decode
    /// through the `Block` record type (same reasoning as `backfillSectionParentIdsAtV15`
    /// above). Reads only `id`/`markdownFragment`/`isNotes`/`isBibliography`/`blockType`, all
    /// present by v13 -- well before this migration runs for any database. Deletes a candidate
    /// ONLY on the exact same positive-evidence rule B5 states: an unparseable label, or no
    /// same-label `isNotes == true` twin, never deletes; a non-blank candidate body never
    /// loses to a blank twin; two differing non-blank bodies never delete either row. Not
    /// private: called from `migrate()` in ProjectDatabase.swift, and Swift's `private` is
    /// file-scoped.
    static func sweepOrphanedNotesDefinitionsAtV16(db: Database, projectId: String) throws {
        let candidateRows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, markdownFragment FROM block
                WHERE projectId = ? AND isNotes = 0 AND blockType = ?
                """,
            arguments: [projectId, BlockType.paragraph.rawValue]
        )
        guard !candidateRows.isEmpty else { return }

        let twinRows = try Row.fetchAll(
            db,
            sql: """
                SELECT markdownFragment FROM block
                WHERE projectId = ? AND isNotes = 1 AND isBibliography = 0 AND blockType = ?
                """,
            arguments: [projectId, BlockType.paragraph.rawValue]
        )
        var twinBodyByLabel: [String: String] = [:]
        for row in twinRows {
            let fragment: String = row["markdownFragment"]
            guard let parsed = FootnoteSyncService.parseNotesLabel(from: fragment) else { continue }
            twinBodyByLabel[parsed.label] = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for row in candidateRows {
            let id: String = row["id"]
            let fragment: String = row["markdownFragment"]
            guard let parsed = FootnoteSyncService.parseNotesLabel(from: fragment) else { continue }
            guard let twinBody = twinBodyByLabel[parsed.label] else { continue }
            let candidateBody = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)

            let shouldDelete: Bool
            if candidateBody.isEmpty {
                shouldDelete = true
            } else if twinBody.isEmpty {
                shouldDelete = false
            } else {
                shouldDelete = candidateBody == twinBody
            }

            guard shouldDelete else { continue }
            // t-561c4083: only the fragment's LENGTH is logged. The diagnostic file must never hold document text, so the
            // deleted footnote body can no longer be recovered from the log -- deliberately.
            DebugLog.log(.footnotes, "[ProjectDatabase] v16_notes_orphan_sweep: deleting orphaned Notes " +
                "definition id=\(id) fragment=\(DebugLog.docText(fragment))")
            try db.execute(sql: "DELETE FROM block WHERE id = ?", arguments: [id])
        }
    }
}
