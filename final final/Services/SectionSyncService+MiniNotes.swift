//
//  SectionSyncService+MiniNotes.swift
//  final final
//

import Foundation
import GRDB

// MARK: - Zoom Notes Helpers

extension SectionSyncService {

    /// Strip the `<!-- ::zoom-notes:: -->` marker and everything after it from zoomed markdown.
    /// Returns the stripped markdown and the mini #Notes content (if any).
    static func stripZoomNotes(from markdown: String) -> (stripped: String, miniNotes: String?) {
        let marker = "<!-- ::zoom-notes:: -->"
        guard let range = markdown.range(of: marker) else {
            return (markdown, nil)
        }
        let stripped = String(markdown[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let miniNotes = String(markdown[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (stripped, miniNotes.isEmpty ? nil : miniNotes)
    }

    /// Sync edited mini #Notes definitions back to the main Notes block in the database.
    /// Called when zoomed content contains `<!-- ::zoom-notes:: -->` marker with definitions.
    func syncMiniNotesBack(
        _ miniNotesContent: String,
        db: ProjectDatabase,
        pid: String
    ) {
        Self.syncMiniNotesBackImpl(miniNotesContent, db: db, pid: pid)
    }

    /// Static version of mini notes sync for use from detached tasks.
    nonisolated static func syncMiniNotesBackDetached(
        _ miniNotesContent: String,
        db: ProjectDatabase,
        pid: String
    ) {
        syncMiniNotesBackImpl(miniNotesContent, db: db, pid: pid)
    }

    /// Shared implementation for syncing mini notes back to DB: parses the definitions, then runs
    /// `syncMiniNotesBack(definitions:db:pid:)` in its own write transaction. A failure is logged,
    /// never thrown (every existing caller is fire-and-forget).
    nonisolated private static func syncMiniNotesBackImpl(
        _ miniNotesContent: String,
        db: ProjectDatabase,
        pid: String
    ) {
        // Extract definitions from the mini #Notes content
        let editedDefs = FootnoteSyncService.extractFootnoteDefinitions(from: miniNotesContent)
        guard !editedDefs.isEmpty else { return }

        do {
            try db.write { dbConn in
                try Self.syncMiniNotesBack(definitions: editedDefs, db: dbConn, pid: pid)
            }
        } catch {
            DebugLog.log(.sync, "[SectionSyncService] Error syncing mini notes back: \(error)")
        }
    }

    /// The mini-Notes write itself, on a `Database` the caller already holds (t-94369a83 Phase 3a-1b):
    /// every read and write goes through `db`, so a caller that is inside a write transaction (the
    /// lifecycle whole-document write, `LifecycleWholeDocumentWrite.body`) can run it in that same
    /// transaction. Never opens a transaction of its own and never calls `read`/`write` on the
    /// `ProjectDatabase` (GRDB does not allow that from inside a write). Throws on a database error;
    /// returns quietly when there is nothing to merge (no definitions, no Notes rows, or the merge
    /// changes nothing).
    ///
    /// `definitions` are the already-parsed mini-Notes definitions (`label -> text`).
    nonisolated static func syncMiniNotesBack(
        definitions editedDefs: [String: String],
        db dbConn: Database,
        pid: String
    ) throws {
        guard !editedDefs.isEmpty else { return }

        // Read current definitions from Block table (not Section table).
        let notesBlocks = try Block
            .filter(Block.Columns.projectId == pid)
            .filter(Block.Columns.isNotes == true)
            .order(Block.Columns.sortOrder)
            .fetchAll(dbConn)
        guard !notesBlocks.isEmpty else { return }
        let notesMd = BlockParser.assembleMarkdown(from: notesBlocks)
        let currentDefs = FootnoteSyncService.extractFootnoteDefinitions(from: notesMd)

        // Merge: edited definitions override current ones for matching labels
        var mergedDefs = currentDefs
        for (label, text) in editedDefs {
            mergedDefs[label] = text
        }

        guard mergedDefs != currentDefs else { return }

        let sortedLabels = mergedDefs.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }

        // C7: preserve the existing Notes heading's block ID (scroll stability, as
        // before) AND its title/level -- this used to hardcode `textContent: "Notes",
        // markdownFragment: "# Notes", headingLevel: 1` unconditionally, which was a
        // no-op before Stage C (the only heading that could ever be flagged `isNotes`
        // WAS already H1 "# Notes"). Now that `NotesOpeningSelector`-backed recognition
        // accepts H1 OR H2, a genuinely H2 "## Notes" heading -- or any DB-resolved,
        // already-recognized title (see `fetchNotesHeadingTitle`) -- reaching this path
        // would otherwise be silently DELETED and replaced with a fresh H1 "# Notes"
        // heading on every mini-Notes edit, directly violating the plan's settled
        // decision #2 ("heading level is kept as typed on adoption, never normalized").
        let existingHeading = try Block
            .filter(Block.Columns.projectId == pid)
            .filter(Block.Columns.isNotes == true)
            .filter(Block.Columns.blockType == BlockType.heading.rawValue)
            .fetchOne(dbConn)
        let existingHeadingId = existingHeading?.id
        let headingLevel = existingHeading?.headingLevel ?? 1
        let headingTitle = existingHeading?.textContent ?? "Notes"

        try Block.filter(Block.Columns.projectId == pid)
            .filter(Block.Columns.isNotes == true)
            .deleteAll(dbConn)

        let maxNonBibSort = try Block
            .filter(Block.Columns.projectId == pid)
            .filter(Block.Columns.isBibliography == false)
            .order(Block.Columns.sortOrder.desc)
            .fetchOne(dbConn)?.sortOrder ?? 0
        let baseSortOrder = maxNonBibSort + 0.5

        var heading = Block(
            id: existingHeadingId ?? UUID().uuidString,
            projectId: pid, sortOrder: baseSortOrder,
            blockType: .heading, textContent: headingTitle,
            markdownFragment: String(repeating: "#", count: headingLevel) + " " + headingTitle,
            headingLevel: headingLevel,
            status: .final_, isNotes: true
        )
        heading.recalculateWordCount()
        try heading.insert(dbConn)

        for (index, label) in sortedLabels.enumerated() {
            let def = mergedDefs[label] ?? ""
            var defBlock = Block(
                projectId: pid, sortOrder: baseSortOrder + Double(index + 1),
                blockType: .paragraph, textContent: def,
                markdownFragment: "[^\(label)]: \(def)", isNotes: true
            )
            defBlock.recalculateWordCount()
            try defBlock.insert(dbConn)
        }
    }
}
