//
//  SnapshotService+RestorePlan.swift
//  final final
//
//  t-18b7fa48 Phase 4b, slice 2, round 2d-i (plan-v3 D2, D3): what an editor-first Version History restore works out BEFORE it touches
//  anything, at the click, in one synchronous stretch: the rows it WILL write and the payload the editor is handed. The legacy restore
//  decides these inside the write (`SnapshotService.restoreEntireProject`: five separate writes, the last one `replaceBlocks`, which
//  parses the snapshot's Markdown and prepares the rows against the rows it finds). Here the rows are fixed first, so that
//
//    - the editor and the database are given the SAME ids: the editor replaces its document with the payload, whose `blockIds` are
//      the ids of `rows`, and the queued job writes exactly `rows` (`StructuralReplaceJob`, `ProjectDatabase.replaceProjectRows`);
//    - the text the user types after the click is typed into blocks whose ids the database will hold once the job has run.
//
//  `RestorePlan` is the whole plan. This file holds its type, the builder for the WHOLE-project restore (D2) and, from round 2d-ii, the
//  builders of the two section restores (D3: a flat range replaced, a fragment inserted) with the D8 target resolution they share. They
//  reuse the type and the job.
//
//  THE WHOLE BUILDER, step by step (each is the legacy restore's step, only moved to the click):
//    1. `existing` = the project's rows as the database holds them now (`fetchBlocks`). Read in the click's synchronous stretch: the
//       headings the restore keeps (by title) and the figures' metadata (by `src`) come from it.
//    2. `parsed` = `BlockParser.parse` of the snapshot's `previewMarkdown`, with the arguments `restoreEntireProject` passes: the
//       section metadata by title (status, tags, word goal) taken from the snapshot's sections, and the Notes heading title the
//       database resolves.
//    3. `rows` = `ProjectDatabase.preparedRowsForWholeReplace(existing:parsed:)`: a heading keeps its id (and its metadata) by title,
//       the managed flags and the bibliography carry-forward are restored, an image keeps its metadata by `src`. Every other row has a
//       fresh id. This is the very function `replaceBlocks` calls, so the rows are the rows the legacy restore would have written.
//    4. The payload = `StructuralUndoController.editorPayload(for: rows)` (the Markdown, one id per top-level node, what each is expected
//       to be, the image metadata, the bibliography span, the managed ids of the NEW document) plus `mode: "whole"` and `managedIds`
//       (the CURRENT document's Notes and Bibliography ids, read from `existing`: the editor never trusts its own managed set).
//
//  What the legacy restore wrote besides block rows stays equivalent: `content.markdown` = the snapshot's Markdown, and the `section`
//  table = the snapshot's sections (`sections`), both written by the job in the same transaction.
//

import Foundation

/// What an editor-first restore will do, worked out before anything is touched. Sendable: the queued job captures it.
struct RestorePlan: Sendable {

    enum Mode: String, Sendable {
        /// Restore the whole project (this round).
        case whole
        /// Replace one section's flat range by the snapshot's text (round 2d-ii).
        case section
        /// Insert a section's text after an anchor (round 2d-ii).
        case insertAfter
    }

    let mode: Mode
    /// The Markdown the editor parses (the payload's `markdown`).
    let markdown: String
    /// Exactly the rows the job writes: for `whole`, the project's rows after the restore.
    let rows: [Block]
    /// `section` mode: the id of the target heading. Nil otherwise.
    let rootBlockId: String?
    /// `insertAfter` mode: the id of the ROW the job inserts the fragment after (the last row of the range it goes after; the payload
    /// carries the editor's top-level NODE id, which for a list is its first item: see `SnapshotService.insertAfterPlan`). Nil: after
    /// the last block that is not managed.
    let anchorBlockId: String?

    /// `whole`: what the job writes into `content.markdown` (the snapshot's own Markdown, as the legacy restore saved it).
    let contentMarkdown: String
    /// `whole`: the `section` table after the restore, built from the snapshot's sections as the legacy restore built them.
    let sections: [Section]
    /// What the editor receives, encoded. The quick redo sends the SAME payload again (same ids), so it is kept on the plan.
    let payload: RestorePayload

    /// The project's leaders (headings and section breaks that are not Notes or Bibliography) BEFORE the restore, in document order, as
    /// the click read them: what the sidebar stops showing at once, and shows again when the restore is undone.
    let previousLeaders: [Block]
    /// The leaders of the document AFTER the restore, in document order (from `rows`): what the sidebar shows at once.
    let newLeaders: [Block]
    /// Where the restored leaders go in the sidebar's list while the database does not hold their rows yet (`SidebarRestoreOverlay`):
    /// the start of the outline for the whole project, right after the entry that stood before the replaced heading for a section
    /// replace, right after the section the fragment is inserted after for a restore as duplicate. nil: the leaders' sort orders decide.
    let sidebarAnchor: RestoreAnchor?

    /// The ids of the rows of the restored document, by id (the lookup the sidebar uses).
    var rowsById: [String: Block] {
        Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The editor's call for this plan: `JSON.stringify(window.FinalFinal.<function>("<opId>", {payload}))`. `function` is
    /// `replaceRangeEditorFirst` at the click and `redoReplaceRangeEditorFirst` at a quick redo (same payload, same ids).
    @MainActor
    func script(function: String, opId: UUID) -> String? {
        guard let opLiteral = StructuralUndoController.jsLiteral(opId.uuidString),
              let payloadLiteral = StructuralUndoController.jsLiteral(payload) else { return nil }
        return "JSON.stringify(window.FinalFinal.\(function)(\(opLiteral), \(payloadLiteral)))"
    }
}

/// The argument of `replaceRangeEditorFirst` (web/milkdown/src/api-structural-replace.ts, `ReplaceRangePayload`). The field names are those of
/// `ContentView.BlockFetchResult`, plus the mode and the anchors.
struct RestorePayload: Encodable, Sendable {
    struct Image: Encodable, Sendable {
        let id: String
        let width: Int?
        let caption: String?
        let alt: String?
        let src: String?
    }

    let mode: String
    let rootBlockId: String?
    let anchorBlockId: String?
    let markdown: String
    let blockIds: [String]
    let expectedBlocks: [BlockParser.BlockAlignmentMeta]
    /// The CURRENT document's Notes and Bibliography ids at the click (read from the database).
    let managedIds: [String]
    let imageMeta: [Image]
    let bibBoundaryIndex: Int?
    let bibBoundaryEndIndex: Int?
    /// The ids that are Notes or Bibliography content in the PAYLOAD's document. `whole` only.
    let managedBlockIds: [String]?

    init(
        mode: RestorePlan.Mode, rootBlockId: String? = nil, anchorBlockId: String? = nil, fetch: ContentView.BlockFetchResult,
        managedIds: [String]
    ) {
        self.mode = mode.rawValue
        self.rootBlockId = rootBlockId
        self.anchorBlockId = anchorBlockId
        markdown = fetch.markdown
        blockIds = fetch.blockIds
        expectedBlocks = fetch.expectedBlocks
        self.managedIds = managedIds
        imageMeta = fetch.imageMeta.map { Image(id: $0.id, width: $0.width, caption: $0.caption, alt: $0.alt, src: $0.src) }
        bibBoundaryIndex = fetch.bibBoundaryIndex
        bibBoundaryEndIndex = fetch.bibBoundaryEndIndex
        // Sorted so the payload is the same bytes every time it is built from the same rows (a Set has no order).
        managedBlockIds = mode == .whole ? fetch.managedBlockIds.sorted() : nil
    }
}

extension SnapshotService {

    /// The plan for restoring the WHOLE project of `projectId` from `snapshotId` (see the file header). Static: it needs no service
    /// state, only the database. Reads the database now, on the caller's thread
    /// (the click's synchronous stretch). Returns nil when the restored document has no blocks at all (an empty snapshot): the editor
    /// cannot take an empty document through this call, so the press takes the legacy restore. Throws `snapshotNotFound` for an id that
    /// no longer resolves, as the legacy restore's precheck does.
    static func wholeRestorePlan(database: ProjectDatabase, projectId: String, snapshotId: String) throws -> RestorePlan? {
        guard let snapshot = try database.fetchSnapshot(id: snapshotId) else { throw SnapshotError.snapshotNotFound }
        let snapshotSections = try database.fetchSnapshotSections(snapshotId: snapshotId)
        // 1. The rows as they are now.
        let existing = try database.fetchBlocks(projectId: projectId)

        // 2. `restoreEntireProject`'s own arguments: section metadata by title, the Notes heading title the database resolves.
        var metadata: [String: SectionMetadata] = [:]
        for snapshotSection in snapshotSections {
            metadata[snapshotSection.title] = SectionMetadata(
                status: snapshotSection.status,
                tags: snapshotSection.tags.isEmpty ? nil : snapshotSection.tags,
                wordGoal: snapshotSection.wordGoal
            )
        }
        let parsed = BlockParser.parse(
            markdown: snapshot.previewMarkdown,
            projectId: projectId,
            existingSectionMetadata: metadata.isEmpty ? nil : metadata,
            notesHeaderName: try? database.fetchNotesHeadingTitle(projectId: projectId)
        )

        // 3. The rows the legacy `replaceBlocks` would have inserted.
        let rows = ProjectDatabase.preparedRowsForWholeReplace(existing: existing, parsed: parsed)
        guard !rows.isEmpty else { return nil }

        // The `section` table the legacy restore rebuilt from the snapshot's sections.
        let sections = snapshotSections.map { snapshotSection in
            Section(
                projectId: projectId,
                sortOrder: snapshotSection.sortOrder,
                headerLevel: snapshotSection.headerLevel,
                title: snapshotSection.title,
                markdownContent: snapshotSection.markdownContent,
                status: snapshotSection.status ?? .next,
                tags: snapshotSection.tags,
                wordGoal: snapshotSection.wordGoal,
                wordCount: MarkdownUtils.wordCount(for: snapshotSection.markdownContent)
            )
        }

        // 4. The payload.
        let fetch = StructuralUndoController.editorPayload(for: rows)
        let managedIds = existing.filter { $0.isBibliography || $0.isNotes }.map(\.id)
        let payload = RestorePayload(mode: .whole, fetch: fetch, managedIds: managedIds)
        return RestorePlan(
            mode: .whole, markdown: fetch.markdown, rows: rows, rootBlockId: nil, anchorBlockId: nil,
            contentMarkdown: snapshot.previewMarkdown, sections: sections, payload: payload,
            previousLeaders: sidebarLeaders(of: existing), newLeaders: sidebarLeaders(of: rows), sidebarAnchor: .documentStart)
    }

    /// The headings and section breaks of `rows` that the sidebar lists as user sections (not Notes, not Bibliography), in document
    /// order.
    nonisolated static func sidebarLeaders(of rows: [Block]) -> [Block] {
        BlockParser.assemblySorted(rows).filter {
            ($0.blockType == .heading || $0.isPseudoSection) && !$0.isNotes && !$0.isBibliography
        }
    }
}
