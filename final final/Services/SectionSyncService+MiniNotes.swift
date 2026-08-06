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

    /// Shared implementation for syncing mini notes back to DB.
    nonisolated private static func syncMiniNotesBackImpl(
        _ miniNotesContent: String,
        db: ProjectDatabase,
        pid: String
    ) {
        // Extract definitions from the mini #Notes content
        let editedDefs = FootnoteSyncService.extractFootnoteDefinitions(from: miniNotesContent)
        guard !editedDefs.isEmpty else { return }

        // Read current definitions from Block table (not Section table).
        let currentDefs: [String: String]
        do {
            let notesBlocks = try db.read { dbConn in
                try Block
                    .filter(Block.Columns.projectId == pid)
                    .filter(Block.Columns.isNotes == true)
                    .order(Block.Columns.sortOrder)
                    .fetchAll(dbConn)
            }
            guard !notesBlocks.isEmpty else { return }
            let notesMd = BlockParser.assembleMarkdown(from: notesBlocks)
            currentDefs = FootnoteSyncService.extractFootnoteDefinitions(from: notesMd)
        } catch {
            DebugLog.log(.sync, "[SectionSyncService] Error reading notes blocks: \(error)")
            return
        }

        // Merge: edited definitions override current ones for matching labels
        var mergedDefs = currentDefs
        for (label, text) in editedDefs {
            mergedDefs[label] = text
        }

        guard mergedDefs != currentDefs else { return }

        let sortedLabels = mergedDefs.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }

        do {
            try db.write { dbConn in
                // Preserve existing Notes heading block ID for scroll stability
                let existingHeadingId = try Block
                    .filter(Block.Columns.projectId == pid)
                    .filter(Block.Columns.isNotes == true)
                    .filter(Block.Columns.blockType == BlockType.heading.rawValue)
                    .fetchOne(dbConn)?.id

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
                    blockType: .heading, textContent: "Notes",
                    markdownFragment: "# Notes", headingLevel: 1,
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
        } catch {
            DebugLog.log(.sync, "[SectionSyncService] Error syncing mini notes back: \(error)")
        }
    }
}
