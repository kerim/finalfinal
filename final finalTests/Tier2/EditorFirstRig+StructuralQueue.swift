//
//  EditorFirstRig+StructuralQueue.swift
//  final finalTests
//
//  Tier 2 (t-18b7fa48 Phase 4b slice 3, round 1e-i): the scripted editor's answers for the editor-first structural operations that are
//  not a delete -- for now Duplicate Section: the click (`duplicateSectionEditorFirst`) and its quick redo
//  (`redoSectionDuplicateEditorFirst`). The quick undo of a duplicate is the delete's `undoSectionDeleteEditorFirst`, answered in
//  EditorFirstRig+QuickUndo.swift (it reads `duplicateClicks`). The stored properties are in the class (EditorFirstDeleteTests.swift):
//  `duplicateClickBatch`, `forceNextJobFailure`, `duplicateScripts`, `redoDuplicateScripts`, `duplicateClicks`.
//
//  What the stand-in editor does at a click, as the real one does (api-section-duplicate.ts): it consumes the pending batch
//  (`duplicateClickBatch`), inserts a copy of the section's blocks after the section (here: it works out the document it would hold, from
//  the database's rows, which still lack the copy because the job has not run), gives each copied top-level node a new permanent id, and
//  answers the batch, `copies`, the copy's leaders and a snapshot of them. `rig.editorText`, `rig.quickEditorText` and
//  `editorState.content` become the post-duplicate Markdown, as the editor's `contentChanged` makes them.
//
//  Round 1e-ii adds `forceEditorRefusal` (the editor answers the click with ok:false and still hands back its batch) and
//  `duplicateInsertsIntoEditorText` (the document the editor holds after the click is its own text with the copy inserted, not the
//  database's rows plus the copy). Both are stored properties of the class, in EditorFirstDeleteTests.swift.
//
//  The rig names no production type of the duplicate (it builds its replies from its own `Encodable` structs), so a break patch that
//  sends `performSectionDuplicate` back to the legacy body leaves it compiling.
//

import Foundation
import GRDB
import Testing
@testable import final_final

/// What the editor held at one Duplicate Section click, kept so the quick undo and redo can be answered.
struct DuplicateClick {
    let opId: String
    let rootId: String
    /// The document the editor held just before the click (the pre-op checkpoint the quick undo swaps back in).
    let preText: String
    /// The new ids of the copy's leaders, in document order (what the undo of the duplicate takes out).
    let copyLeaderIds: [String]
    /// The new id of every copied top-level node, in document order (what the quick redo hands back and reuses: S9).
    let copyIds: [String]
    /// The copy's rows as the editor holds them (round 1g-A): a later click on the copy, before its job has committed, finds its
    /// section here because the database does not have the rows yet.
    var copyRows: [Block] = []
}

/// The JSON `duplicateSectionEditorFirst` and `redoSectionDuplicateEditorFirst` answer (web/milkdown/src/api-section-duplicate.ts).
private struct DuplicateStubReply: Encodable {
    struct Copy: Encodable {
        let sourceId: String
        let newId: String
    }

    struct Inserted: Encodable {
        let id: String
        let kind: String
        let level: Int
        let title: String
    }

    var batch = BlockChanges()
    var succeeded = true
    var reason: String?
    var copies: [Copy] = []
    var insertedLeaderIds: [String] = []
    var insertedSectionsSnapshot: [Inserted] = []
    var predecessorId: String?

    private enum CodingKeys: String, CodingKey {
        case batch
        case succeeded = "ok"
        case reason
        case copies
        case insertedLeaderIds
        case insertedSectionsSnapshot
        case predecessorId
    }
}

extension EditorFirstRig {

    // MARK: - The click and the quick redo

    /// `duplicateSectionEditorFirst("<opId>", "<rootId>", [...])`.
    func answerDuplicateClick(_ script: String) -> String? {
        duplicateScripts.append(script)
        events.note("js " + script)
        let literals = Self.stringLiterals(in: script)
        guard literals.count >= 2 else { return nil }
        let batch = duplicateClickBatch ?? BlockChanges()
        duplicateClickBatch = nil
        if forceEditorRefusal {
            // The editor refuses and puts everything back; the batch is on EVERY path, even a failed one (api-section-duplicate.ts).
            forceEditorRefusal = false
            return Self.json(DuplicateStubReply(batch: batch, succeeded: false, reason: "managedRoot"))
        }
        if forceEditorRootNotFound {
            // Round 1g-A (review A7): the editor's id for the root heading is still a temporary one, so it finds no node with the id
            // Swift names. Nothing changed; the batch is on the reply.
            forceEditorRootNotFound = false
            return Self.json(DuplicateStubReply(batch: batch, succeeded: false, reason: "rootNotFound"))
        }
        return duplicateReply(opId: literals[0], rootId: literals[1], batch: batch, reusing: [])
    }

    /// `redoSectionDuplicateEditorFirst("<opId>", "<rootId>", [...], [{"sourceId":..,"newId":..}, ...])`: a fresh duplicate of the
    /// document as it stands now, whose copies take the new ids the call hands back (S9).
    func answerQuickRedoOfDuplicate(_ script: String) -> String? {
        redoDuplicateScripts.append(script)
        events.note("js " + script)
        let literals = Self.stringLiterals(in: script)
        guard literals.count >= 2 else { return nil }
        if let reason = refuseNextDuplicateRedoWith {
            // Round 1g-B (review A3): the editor refuses the redo and changes nothing.
            refuseNextDuplicateRedoWith = nil
            return Self.json(DuplicateStubReply(batch: BlockChanges(), succeeded: false, reason: reason))
        }
        // The ids of the first click's copies, as the script carries them: each "newId" key is followed by its value.
        let handedBack = literals.enumerated().compactMap { index, literal in
            literal == "newId" && index + 1 < literals.count ? literals[index + 1] : nil
        }
        return duplicateReply(opId: literals[0], rootId: literals[1], batch: BlockChanges(), reusing: handedBack)
    }

    /// The editor's answer to a duplicate of the section rooted at `rootId`. The database still holds the document without the copy
    /// (the queued job has not run), so the copy is worked out from its rows; `reusing` are the new ids a redo hands back.
    private func duplicateReply(opId: String, rootId: String, batch: BlockChanges, reusing: [String]) -> String? {
        let databaseRows = (try? blocks()) ?? []
        // Round 1g-A (review A1): the copies of earlier duplicates whose jobs have not committed are in the editor's document but not in
        // the database; a Duplicate of such a copy works from the rows the editor holds.
        let storedIds = Set(databaseRows.map(\.id))
        let overlayIds = Set(editorState.pendingRestoreSections.values.flatMap { $0.map(\.id) })
        let pendingRows = duplicateClicks.values
            .filter { $0.copyLeaderIds.contains { overlayIds.contains($0) } }
            .flatMap(\.copyRows).filter { !storedIds.contains($0.id) }
        let rows = (databaseRows + pendingRows).sorted { $0.sortOrder < $1.sortOrder }
        let subtreeIds = (try? db.sectionBlockIds(rootId: rootId, projectId: pid)) ?? []
        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var subtree = subtreeIds.compactMap { byId[$0] }
        if subtree.isEmpty, let pending = pendingDuplicateCopy(rootId: rootId) { subtree = pending.copyRows }
        guard let lastRow = subtree.last else {
            return Self.json(DuplicateStubReply(batch: batch, succeeded: false, reason: "rootNotLeader"))
        }
        let preText = editorText ?? quickEditorText ?? ((try? assembledMarkdown()) ?? editorState.content)

        // One copy per top-level editor node, in document order; the id of a node is its first row's.
        let pairs = BlockParser.alignmentPairs(subtree)
        let newIds = pairs.indices.map { index in index < reusing.count ? reusing[index] : UUID().uuidString }
        var reply = DuplicateStubReply(batch: batch)
        var newIdBySource: [String: String] = [:]
        for (index, pair) in pairs.enumerated() {
            reply.copies.append(.init(sourceId: pair.id, newId: newIds[index]))
            newIdBySource[pair.id] = newIds[index]
        }
        addCopyWithoutRowIfAsked(to: &reply)
        let rootIsHeading = subtree.first?.blockType == .heading
        for row in subtree where row.blockType == .heading || row.isPseudoSection {
            guard let newId = newIdBySource[row.id] else { continue }
            reply.insertedLeaderIds.append(newId)
            let isRoot = row.id == subtree.first?.id
            reply.insertedSectionsSnapshot.append(.init(
                id: newId, kind: row.isPseudoSection ? "section_break" : "heading", level: row.headingLevel ?? 1,
                title: row.blockType == .heading ? row.textContent + (isRoot && rootIsHeading ? " copy" : "") : ""))
        }
        reply.predecessorId = lastRow.id

        // The document the editor now holds: the rows plus the copy right after the section (the job's own placement).
        let upperBound = rows.first { $0.sortOrder > lastRow.sortOrder }?.sortOrder ?? (lastRow.sortOrder + Double(subtree.count) + 1)
        let step = (upperBound - lastRow.sortOrder) / Double(subtree.count + 1)
        var copyRows: [Block] = []
        for (index, row) in subtree.enumerated() {
            var copy = row
            copy.id = newIdBySource[row.id] ?? UUID().uuidString
            copy.sortOrder = lastRow.sortOrder + step * Double(index + 1)
            if index == 0, row.blockType == .heading {
                copy.textContent += " copy"
                copy.markdownFragment += " copy"
            }
            copyRows.append(copy)
        }
        let after = (rows + copyRows).sorted {
            ($0.sortOrder, $0.blockType == .heading ? 0 : 1) < ($1.sortOrder, $1.blockType == .heading ? 0 : 1)
        }
        var text = BlockParser.assembleMarkdownForEditor(from: after)
        if duplicateInsertsIntoEditorText,
           let inserted = Self.insertingCopy(into: editorText ?? quickEditorText, subtree: subtree, copyRows: copyRows) {
            text = inserted
        }
        quickEditorText = text
        editorText = text
        if !withholdContentUpdate { editorState.content = text }   // `contentChanged` after the insertion

        duplicateClicks[opId] = DuplicateClick(
            opId: opId, rootId: rootId, preText: preText, copyLeaderIds: reply.insertedLeaderIds, copyIds: newIds, copyRows: copyRows)

        // A database fault in the queued job (round 1g-A, review T1): every insert of a row of the copy aborts, so the job throws while
        // it copies and its whole transaction rolls back. The section's root row, and everything else, stays exactly as it was.
        if forceNextJobFailure {
            forceNextJobFailure = false
            let copyIdList = copyRows.map { "'\($0.id)'" }.joined(separator: ", ")
            _ = try? db.dbWriter.write { database in
                try database.execute(sql: """
                    CREATE TRIGGER failDuplicateJobInsert BEFORE INSERT ON block WHEN NEW.id IN (\(copyIdList))
                    BEGIN SELECT RAISE(ABORT, 'forced duplicate job failure (test)'); END
                    """)
            }
        }
        return Self.json(reply)
    }

    /// Round 1g-C (review A2), `duplicateReplyAddsCopyWithoutRow`: a copy of an editor node the table has no row for (no source id: the
    /// editor held none). Spent by the call.
    private func addCopyWithoutRowIfAsked(to reply: inout DuplicateStubReply) {
        guard duplicateReplyAddsCopyWithoutRow else { return }
        duplicateReplyAddsCopyWithoutRow = false
        reply.copies.append(.init(sourceId: "", newId: UUID().uuidString))
    }

    /// The Duplicate Section click whose copy has `rootId` as its root leader and whose job has not committed: the sidebar still shows
    /// the copy through an overlay (`pendingRestoreSections`), the editor holds it, the database does not (round 1g-A, review A1).
    func pendingDuplicateCopy(rootId: String) -> DuplicateClick? {
        let overlayIds = Set(editorState.pendingRestoreSections.values.flatMap { $0.map(\.id) })
        return duplicateClicks.values.first { $0.copyLeaderIds.first == rootId && overlayIds.contains(rootId) }
    }

    /// `editor` with the copy's text inserted right after the original section's text (the document the real editor holds after the
    /// click). Nil when the editor's text does not hold the section's text, in which case the caller falls back to the database's rows.
    private static func insertingCopy(into editor: String?, subtree: [Block], copyRows: [Block]) -> String? {
        guard let editor, !subtree.isEmpty else { return nil }
        let sectionText = BlockParser.assembleMarkdownForEditor(from: subtree)
        guard !sectionText.isEmpty, let range = editor.range(of: sectionText) else { return nil }
        var text = editor
        text.insert(contentsOf: "\n\n" + BlockParser.assembleMarkdownForEditor(from: copyRows), at: range.upperBound)
        return text
    }
}
