//
//  EditorFirstRig+Restore.swift
//  final finalTests
//
//  Tier 2 (t-18b7fa48 Phase 4b slice 2, round 2d-i): the scripted editor's answers for the editor-first Version History restore of the
//  WHOLE project: the click (`replaceRangeEditorFirst("<opId>", {payload})`, mode "whole") and its quick redo
//  (`redoReplaceRangeEditorFirst`). The quick undo of a restore is the delete's `undoSectionDeleteEditorFirst`, answered in
//  EditorFirstRig+QuickUndo.swift (it reads `replaceClicks`). The stored properties are in the class (EditorFirstDeleteTests.swift).
//
//  What the stand-in editor does at a click, as the real one does (api-structural-replace.ts, mode "whole"): it consumes the pending batch
//  (`replaceClickBatch`) and replaces its document with the payload's Markdown; it answers the batch, the ids it now holds (the payload's
//  `blockIds`), the leaders among them, and the ids it took out (the database's rows, which still lack the restore because the job has
//  not run). `rig.editorText`, `rig.quickEditorText` and `editorState.content` become the restored Markdown, as the editor's
//  `contentChanged` makes them.
//
//  The rig names no production type of the restore (it decodes the payload and builds its replies with its own structs), so a break
//  patch that sends `performRestoreProject` back to the legacy body leaves it compiling.
//
//  Also here: `RigLogScope` (the per-rig share of the always-persisted log), `projectWriteEpoch()` and `performRestore(_:from:)`.
//

import Foundation
import GRDB
import Testing
@testable import final_final

/// What the editor held at one restore click, kept so the quick undo and redo can be answered.
struct ReplaceClick {
    let opId: String
    /// The document the editor held just before the click (the pre-op checkpoint the quick undo swaps back in).
    let preText: String
    /// The restored document (what the click and the quick redo put into the editor).
    let newText: String
    /// The ids of the restored document's top-level nodes, and the leaders among them (the payload's).
    let newIds: [String]
    let newLeaderIds: [String]
    /// The database's rows at the click: the ids the editor took out (everything the restored document does not have back), and the
    /// leaders among them.
    let previousIds: [String]
    let previousLeaderIds: [String]
}

/// The always-persisted log lines of ONE rig: a private observer of `DebugLog.always` that keeps only the lines carrying the rig's project
/// id. The observer is removed with the scope, and it neither reads nor replaces `DebugLog.alwaysSink`.
final class RigLogScope: @unchecked Sendable {
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [String] = []
        func append(_ line: String) {
            lock.lock()
            kept.append(line)
            lock.unlock()
        }
        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return kept
        }
    }

    private let storage = Storage()
    private let token: UUID

    init(projectId: String) {
        let storage = storage
        token = DebugLog.addAlwaysObserver { line in
            if line.contains(projectId) { storage.append(line) }
        }
    }

    deinit { DebugLog.removeAlwaysObserver(token) }

    var lines: [String] { storage.lines }
}

/// The JSON `replaceRangeEditorFirst` and `redoReplaceRangeEditorFirst` answer (web/milkdown/src/api-structural-replace.ts).
private struct ReplaceStubReply: Encodable {
    var batch = BlockChanges()
    var succeeded = true
    var reason: String?
    var insertedIds: [String] = []
    var insertedLeaderIds: [String] = []
    var insertedSectionsSnapshot: [String] = []
    var removedIds: [String] = []
    var removedLeaderIds: [String] = []
    var predecessorId: String?

    private enum CodingKeys: String, CodingKey {
        case batch
        case succeeded = "ok"
        case reason
        case insertedIds
        case insertedLeaderIds
        case insertedSectionsSnapshot
        case removedIds
        case removedLeaderIds
        case predecessorId
    }
}

/// The part of the editor's argument the stand-in needs.
private struct ReplaceStubPayload: Decodable {
    struct Expected: Decodable {
        let blockType: String
    }

    let mode: String
    /// `section`: the target heading's id. `insertAfter`: the id of the block the fragment goes after (nil: the last block that is not managed).
    let rootBlockId: String?
    let anchorBlockId: String?
    let markdown: String
    let blockIds: [String]
    let expectedBlocks: [Expected]
    let managedBlockIds: [String]?
}

extension EditorFirstRig {

    // MARK: - Reading the rig's state

    /// The project's block-write epoch (`project.blockWriteEpoch`). A restore job that stamps (`replaceBlocks`) moves it.
    func projectWriteEpoch() throws -> Int64 {
        try db.currentBlockWriteEpoch(projectId: pid)
    }

    /// Presses a Version History restore the way the window does. `mode` "project" is the whole-project restore; "replace" is
    /// "Replace Current Section" (the section of `title` in the version over the live section of that title); "duplicate" is "Restore as
    /// Duplicate" (that section of the version, inserted after the LAST row of the section table, which is what the window passes).
    /// `title` defaults to the document's second chapter (its first when it has only one).
    ///
    /// `target`: the title of the live section "replace" writes over, when it is not `title` (a section only the editor has, say).
    func performRestore(
        _ mode: String, from snapshot: Snapshot, section title: String? = nil, target targetTitle: String? = nil
    ) async -> StructuralUndoController.StructuralOpOutcome {
        if mode == "project" {
            return await controller.performRestoreProject(snapshotId: snapshot.id, requestingProjectId: pid)
        }
        let chapters = (try? chapterHeadings()) ?? []
        let wanted = title ?? (chapters.dropFirst().first ?? chapters.first)?.textContent ?? ""
        guard let snapshotSection = try? db.fetchSnapshotSections(snapshotId: snapshot.id).first(where: { $0.title == wanted }) else {
            Issue.record("the version has no section titled '\(wanted)' (fill the section table before saving the version)")
            return .refused
        }
        let liveSections = ((try? db.fetchSections(projectId: pid)) ?? []).sorted { $0.sortOrder < $1.sortOrder }
        switch mode {
        case "replace":
            guard let target = liveSections.first(where: { $0.title == (targetTitle ?? wanted) }) else {
                Issue.record("the section table has no section titled '\(targetTitle ?? wanted)' (call fillSectionTable first)")
                return .refused
            }
            return await controller.performSectionRestoreReplace(
                snapshotSectionId: snapshotSection.id, targetSectionId: target.id, requestingProjectId: pid)
        case "duplicate":
            return await controller.performRestoreSectionDuplicate(
                snapshotSectionId: snapshotSection.id, insertAfterSectionId: liveSections.last?.id, requestingProjectId: pid)
        default:
            Issue.record("unknown restore mode \(mode)")
            return .refused
        }
    }

    /// Makes the `section` table say what the document says, the way opening Version History does (it syncs the table from the editor's
    /// text first): `editorState.content` becomes the document the database holds (`fromEditor`: the document the scripted editor holds,
    /// which is ahead of the database while a job is queued), and the section sync writes the table from it.
    /// The controller's own `sectionSyncService` is weak and the rig keeps none, so a private one is configured here.
    func fillSectionTable(fromEditor: Bool = false) async throws {
        let assembled = try assembledMarkdown()
        editorState.content = fromEditor ? (editorText ?? quickEditorText ?? assembled) : assembled
        let service = SectionSyncService()
        service.configure(database: db, projectId: pid)
        await service.syncNow(editorState.content)
    }

    // MARK: - The click and the quick redo

    /// `replaceRangeEditorFirst("<opId>", {payload})`.
    func answerReplaceClick(_ script: String) -> String? {
        replaceScripts.append(script)
        events.note("js " + script)
        return replaceReply(script, isRedo: false)
    }

    /// `redoReplaceRangeEditorFirst("<opId>", {payload})`: the same payload as the click, the same ids (S9).
    func answerQuickRedoOfReplace(_ script: String) -> String? {
        redoReplaceScripts.append(script)
        events.note("js " + script)
        return addingTypedFlag(to: replaceReply(script, isRedo: true))
    }

    private func replaceReply(_ script: String, isRedo: Bool) -> String? {
        let literals = Self.stringLiterals(in: script)
        guard let opId = literals.first, let payload = Self.replacePayload(in: script) else { return nil }
        let batch = isRedo ? (redoReplyBatch ?? BlockChanges()) : (replaceClickBatch ?? BlockChanges())
        if isRedo { redoReplyBatch = nil }   // t-d2061b27: the typing done in the redo's wait, as batch N
        if !isRedo {
            replaceClickBatch = nil
            if forceEditorRefusal {
                // The editor refuses (the payload and its parse disagree) and puts everything back; the batch is on EVERY path.
                forceEditorRefusal = false
                return Self.json(ReplaceStubReply(batch: batch, succeeded: false, reason: "idAlignment"))
            }
        }

        let rows = BlockParser.assemblySorted((try? blocks()) ?? [])
        // The rows the change takes out of the document: all of them (`whole`), the target's flat range (`section`), none (`insertAfter`).
        let removed = Self.rowsTheStandInTakesOut(for: payload, from: rows)
        let previousIds = removed.map(\.id)
        let previousLeaderIds = removed.filter { $0.blockType == .heading || $0.isPseudoSection }.map(\.id)
        let first = replaceClicks[opId]
        let preText = first?.preText ?? editorText ?? quickEditorText ?? ((try? assembledMarkdown()) ?? editorState.content)
        let leaderTypes: Set<String> = ["heading", "section_break"]
        let newLeaderIds = zip(payload.blockIds, payload.expectedBlocks).filter { leaderTypes.contains($0.1.blockType) }.map(\.0)

        var reply = ReplaceStubReply(batch: batch)
        reply.insertedIds = payload.blockIds
        reply.insertedLeaderIds = newLeaderIds
        reply.removedIds = first?.previousIds ?? previousIds
        reply.removedLeaderIds = first?.previousLeaderIds ?? previousLeaderIds

        // The document the editor holds afterwards. A redo puts back what the click made (the same payload, the same ids: S9).
        let newText = first?.newText ?? Self.documentAfter(payload: payload, rows: rows, removed: removed, editorText: preText)
        quickEditorText = newText
        editorText = newText
        if !withholdContentUpdate { editorState.content = newText }   // `contentChanged` after the replacement
        emulateDebouncedContentPush()   // the footnote service's check of the new text, 50 ms later (a no-op unless a test asks for it)

        if first == nil {
            replaceClicks[opId] = ReplaceClick(
                opId: opId, preText: preText, newText: newText, newIds: payload.blockIds, newLeaderIds: newLeaderIds,
                previousIds: previousIds, previousLeaderIds: previousLeaderIds)
        }

        // A database fault in the queued job: every insert of a row of the restored document aborts, so the job throws while it writes
        // the rows and its whole transaction (the Version History copy, the content row, the section table, the deletes) rolls back.
        // The database is left EXACTLY as it was, so "the document is back as it was" is what the test sets up, and no row a test needs
        // is deleted (the earlier delete seam removed the root row).
        if !isRedo, forceNextJobFailure {
            forceNextJobFailure = false
            let idList = payload.blockIds.map { "'\($0)'" }.joined(separator: ", ")
            _ = try? db.dbWriter.write { database in
                try database.execute(sql: """
                    CREATE TRIGGER failRestoreJobInsert BEFORE INSERT ON block WHEN NEW.id IN (\(idList))
                    BEGIN SELECT RAISE(ABORT, 'forced restore job failure (test)'); END
                    """)
            }
        }
        return Self.json(reply)
    }

    /// The rows the stand-in editor takes out for `payload` (`rows` in assembly order): the whole document, the flat range of the
    /// target heading (the heading and its own body, up to the next heading, section break or managed row), or nothing. Written from the
    /// rule in the editor's `findFlatSectionRange`, not from the production helper, so a break patch to the production range leaves the
    /// stand-in alone.
    private static func rowsTheStandInTakesOut(for payload: ReplaceStubPayload, from rows: [Block]) -> [Block] {
        switch payload.mode {
        case "section":
            guard let root = payload.rootBlockId, let start = rows.firstIndex(where: { $0.id == root }) else { return [] }
            var range = [rows[start]]
            for row in rows[(start + 1)...] {
                let managed = row.isNotes || row.isBibliography || row.blockType == .bibliography
                if row.blockType == .heading || row.isPseudoSection || managed { break }
                range.append(row)
            }
            return range
        case "insertAfter":
            return []
        default:
            return rows
        }
    }

    /// The Markdown the editor holds after the change: the payload's text for the whole document; for a section the editor's text with
    /// the removed range's text swapped for the fragment; for an insertion the fragment after the anchor's text. The editor's own text
    /// (`editorText`, the pre-click document) is edited in place when it holds the text being cut; otherwise the document is put together
    /// from the database's rows.
    private static func documentAfter(payload: ReplaceStubPayload, rows: [Block], removed: [Block], editorText: String) -> String {
        func assembled(_ part: [Block]) -> String { BlockParser.assembleMarkdownForEditor(from: part) }
        func joined(_ parts: [String]) -> String { parts.filter { !$0.isEmpty }.joined(separator: "\n\n") }
        switch payload.mode {
        case "section":
            let old = assembled(removed)
            if !old.isEmpty, let range = editorText.range(of: old) {
                return editorText.replacingCharacters(in: range, with: payload.markdown)
            }
            let removedIds = Set(removed.map(\.id))
            guard let firstIndex = rows.firstIndex(where: { removedIds.contains($0.id) }) else { return editorText }
            let before = rows[..<firstIndex].filter { !removedIds.contains($0.id) }
            let after = rows[firstIndex...].filter { !removedIds.contains($0.id) }
            return joined([assembled(Array(before)), payload.markdown, assembled(Array(after))])
        case "insertAfter":
            let isManaged: (Block) -> Bool = { $0.isNotes || $0.isBibliography || $0.blockType == .bibliography }
            var anchorIndex = payload.anchorBlockId.flatMap { id in rows.firstIndex { $0.id == id } }
                ?? rows.lastIndex { !isManaged($0) }
            // The editor inserts after a top-level NODE, and a list of several items is ONE node that carries its first item's id
            // (`BlockParser.alignmentPairs`): the copy goes after the whole list, as the real editor does (fix round F1, review A1).
            if let index = anchorIndex, rows[index].blockType == .bulletList || rows[index].blockType == .orderedList {
                var end = index
                while end + 1 < rows.count, rows[end + 1].blockType == rows[index].blockType { end += 1 }
                anchorIndex = end
            }
            let upTo = anchorIndex.map { Array(rows[...$0]) } ?? []
            let prefix = assembled(upTo)
            if editorText.hasPrefix(prefix) {
                return prefix + "\n\n" + payload.markdown + editorText.dropFirst(prefix.count)
            }
            return joined([prefix, payload.markdown, assembled(Array(rows[(anchorIndex.map { $0 + 1 } ?? 0)...]))])
        default:
            return payload.markdown
        }
    }

    /// The editor's argument: the JSON object between the first `{` and the last `}` of the script (the operation id before it holds no
    /// brace, and nothing follows the object but the closing parentheses).
    private static func replacePayload(in script: String) -> ReplaceStubPayload? {
        guard let open = script.firstIndex(of: "{"), let close = script.lastIndex(of: "}"), open < close else { return nil }
        return try? JSONDecoder().decode(ReplaceStubPayload.self, from: Data(script[open...close].utf8))
    }
}
