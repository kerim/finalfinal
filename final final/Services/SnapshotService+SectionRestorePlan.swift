//
//  SnapshotService+SectionRestorePlan.swift
//  final final
//
//  t-18b7fa48 Phase 4b, slice 2, round 2d-ii (plan-v3 D3, D8, D15): the plans of the two SECTION Version History restores, worked out at
//  the click in one synchronous stretch, the way `wholeRestorePlan` (SnapshotService+RestorePlan.swift) does for the whole project.
//
//    - REPLACE (`sectionReplacePlan`, payload mode "section"): the FLAT range of the target heading (the heading and its own body, up to
//      the next heading of ANY level, a section break, the first Notes / Bibliography row or the end of the document) is replaced by
//      the snapshot section's text. The sub-sections under the target (the H2s under an H1) are not in the range and keep their ids.
//      The first row of the new text IS the target heading: it keeps the target's id and its sidebar metadata (status, tags, word goal,
//      goal type, aggregate goal), as the legacy restore kept the section's metadata; every other row gets a fresh id (D15).
//    - RESTORE AS DUPLICATE (`insertAfterPlan`, payload mode "insertAfter"): the snapshot section's text is inserted after the last
//      block of the section `insertAfterSectionId` names, or after the last block that is not Notes / Bibliography when it names none
//      (the legacy restore appended to the section table, which puts the new section last among the user's sections; t-c68433d6 stays
//      open). Every inserted row has a fresh id; the metadata is the snapshot section's (status `?? .next`, tags, word goal), as before.
//
//  D8, RESOLVING THE TARGET. The Version History window names a section by its row in the legacy `section` table; the editor and the
//  rows need the BLOCK that heads it. `resolveFlatSectionTarget` takes the target's index among the table's user sections (sorted by
//  `sortOrder`, Notes and Bibliography left out) and requires that the document's flat-section leader at the same index (headings and
//  section breaks that are not Notes or Bibliography, in assembly order) has the same title (the table keeps a heading's text as
//  written, the block without its Markdown marks, so the table's title is passed through the block parser's own stripping before the
//  two are compared). A position decides, the title only checks that the table and the document still agree, so two sections that
//  share a title are told apart by where they stand. Any
//  disagreement (a table that is behind the document, a heading typed since the last section sync, a section break, whose table title
//  "§ Section Break" is never the block's "§") returns `.unresolved(reason)` and the press takes the old restore.
//
//  WHEN THE PRESS TAKES THE OLD RESTORE (`.legacy(reason)`): the version's section is empty, does not start with a heading (a section
//  break, text before the first heading), or holds Notes / Bibliography content (those are machine-managed and never restored by hand).
//  The caller logs the reason (`[EF-STRUCT] <kind> fell back to the old path: <reason>`).
//

import Foundation

/// What building a section plan came to.
enum SectionPlanResult: Sendable {
    case plan(RestorePlan)
    /// The press takes the old restore, for this reason.
    case legacy(String)
}

/// What resolving a restore target came to (D8).
enum SectionTargetResolution: Sendable {
    /// The block that heads the section, and the ids of the editor's top-level nodes of its flat range (a list's rows are one node).
    case resolved(heading: Block, flatRangeNodeIds: [String])
    case unresolved(String)
}

extension SnapshotService {

    // MARK: - D8

    /// Finds the document's block for the section-table row `sectionId` (see the file header). Pure: `sections` are the table's rows and
    /// `blocks` the project's block rows, both read in the click's synchronous stretch.
    nonisolated static func resolveFlatSectionTarget(sectionId: String, sections: [Section], blocks: [Block]) -> SectionTargetResolution {
        let userSections = sections.filter { !$0.isBibliography && !$0.isNotes }.sorted { $0.sortOrder < $1.sortOrder }
        guard let index = userSections.firstIndex(where: { $0.id == sectionId }) else {
            return .unresolved("the section is not in the section table (or it is Notes or Bibliography)")
        }
        let sorted = BlockParser.assemblySorted(blocks)
        let leaders = sorted.filter { ($0.blockType == .heading || $0.isPseudoSection) && !$0.isNotes && !$0.isBibliography }
        guard index < leaders.count else {
            return .unresolved("the section table lists a section at position \(index) and the document has \(leaders.count) sections")
        }
        let leader = leaders[index]
        // The table keeps the heading line's text as written ("The *Quiet* Archive"); the block keeps it with the Markdown marks taken
        // out ("The Quiet Archive"). The table's title goes through the block parser's own stripping first, so a heading with
        // emphasis, a citation or a footnote mark is not mistaken for a heading that has changed.
        let tableTitle = userSections[index].title
        let tableTitleAsBlockText = BlockParser.extractTextContent(from: "# " + tableTitle, blockType: .heading)
        guard leader.outlineTitle == tableTitle || (leader.blockType == .heading && leader.textContent == tableTitleAsBlockText) else {
            return .unresolved(
                "position \(index): the section table says '\(tableTitle.prefix(60))', the document has '\(leader.outlineTitle.prefix(60))'")
        }
        let range = flatRange(of: leader.id, in: sorted)
        let nodeIds = BlockParser.alignmentPairs(range).map(\.id)
        return .resolved(heading: leader, flatRangeNodeIds: nodeIds.isEmpty ? [leader.id] : nodeIds)
    }

    /// The rows of the FLAT range headed by `headingId` in `sorted` (assembly order): the heading and its own body up to the next leader
    /// or Notes / Bibliography row. The in-memory twin of `ProjectDatabase.flatSectionBlockIds`.
    nonisolated static func flatRange(of headingId: String, in sorted: [Block]) -> [Block] {
        guard let start = sorted.firstIndex(where: { $0.id == headingId }) else { return [] }
        var range = [sorted[start]]
        for row in sorted[(start + 1)...] {
            let isManaged = row.isNotes || row.isBibliography || row.blockType == .bibliography
            let isLeader = row.blockType == .heading || row.isPseudoSection
            if isLeader || isManaged { break }
            range.append(row)
        }
        return range
    }

    // MARK: - The plans

    /// The plan for replacing the flat range headed by `target` with `snapshotSection`'s text (see the file header). `existing` are the
    /// project's rows as the click reads them.
    static func sectionReplacePlan( // swiftlint:disable:this function_parameter_count
        database: ProjectDatabase, projectId: String, snapshotSection: SnapshotSection, target: Block, existing: [Block],
        sidebarAnchor: RestoreAnchor?
    ) -> SectionPlanResult {
        let metadata = [snapshotSection.title: SectionMetadata(status: target.status, tags: target.tags, wordGoal: target.wordGoal)]
        var rows: [Block]
        do {
            rows = try fragmentRows(
                database: database, projectId: projectId, snapshotSection: snapshotSection, existing: existing, metadata: metadata)
        } catch {
            return .legacy((error as? FragmentRefusal)?.reason ?? "\(error)")
        }
        // D3: the first row IS the target heading. Its id and its sidebar-only metadata are the target's.
        rows[0].id = target.id
        rows[0].status = target.status
        rows[0].tags = target.tags
        rows[0].wordGoal = target.wordGoal
        rows[0].goalType = target.goalType
        rows[0].aggregateGoal = target.aggregateGoal
        rows[0].aggregateGoalType = target.aggregateGoalType
        let fetch = StructuralUndoController.editorPayload(for: rows)
        let payload = RestorePayload(mode: .section, rootBlockId: target.id, fetch: fetch, managedIds: managedIds(of: existing))
        return .plan(RestorePlan(
            mode: .section, markdown: fetch.markdown, rows: rows, rootBlockId: target.id, anchorBlockId: nil,
            contentMarkdown: "", sections: [], payload: payload,
            previousLeaders: [target], newLeaders: sidebarLeaders(of: rows), sidebarAnchor: sidebarAnchor))
    }

    /// The plan for inserting `snapshotSection`'s text after the editor node `anchorBlockId` (nil: after the last block that is not
    /// Notes or Bibliography). Every inserted row has a fresh id.
    ///
    /// TWO anchors, because the editor and the database count differently (fix round F1, review A1): the editor inserts after a
    /// top-level NODE, and a list of several items is ONE node that `BlockParser.alignmentPairs` stands for with its FIRST item's id;
    /// the job inserts after a ROW. `anchorBlockId` is the node's id (the payload's: what the editor receives). `jobAnchorBlockId` is
    /// the id of the LAST ROW of the same range (the plan's: what the job inserts after), so the copy lands after the whole list and not
    /// between its first and second item. Both nil: after the last block that is not Notes or Bibliography.
    static func insertAfterPlan( // swiftlint:disable:this function_parameter_count
        database: ProjectDatabase, projectId: String, snapshotSection: SnapshotSection, anchorBlockId: String?, jobAnchorBlockId: String?,
        existing: [Block], sidebarAnchor: RestoreAnchor?
    ) -> SectionPlanResult {
        let metadata = [snapshotSection.title: SectionMetadata(
            status: snapshotSection.status ?? .next, tags: snapshotSection.tags.isEmpty ? nil : snapshotSection.tags,
            wordGoal: snapshotSection.wordGoal)]
        let rows: [Block]
        do {
            rows = try fragmentRows(
                database: database, projectId: projectId, snapshotSection: snapshotSection, existing: existing, metadata: metadata)
        } catch {
            return .legacy((error as? FragmentRefusal)?.reason ?? "\(error)")
        }
        let fetch = StructuralUndoController.editorPayload(for: rows)
        let payload = RestorePayload(
            mode: .insertAfter, anchorBlockId: anchorBlockId, fetch: fetch, managedIds: managedIds(of: existing))
        return .plan(RestorePlan(
            mode: .insertAfter, markdown: fetch.markdown, rows: rows, rootBlockId: nil, anchorBlockId: jobAnchorBlockId,
            contentMarkdown: "", sections: [], payload: payload,
            previousLeaders: [], newLeaders: sidebarLeaders(of: rows), sidebarAnchor: sidebarAnchor))
    }

    /// The ids of the CURRENT document's Notes and Bibliography rows: the editor never trusts its own managed set.
    private static func managedIds(of existing: [Block]) -> [String] {
        existing.filter { $0.isBibliography || $0.isNotes }.map(\.id)
    }

    /// Why the snapshot section's text cannot go through the editor-first path.
    private struct FragmentRefusal: Error {
        let reason: String
    }

    /// The rows of `snapshotSection`'s text, parsed as the legacy restore parses it (`BlockParser.parse` with the Notes heading title the
    /// database resolves), with the image metadata of the document carried over by `src`. Every row has a fresh id. Throws a
    /// `FragmentRefusal` when the text cannot go through the editor-first path (see the file header).
    private static func fragmentRows(
        database: ProjectDatabase, projectId: String, snapshotSection: SnapshotSection, existing: [Block],
        metadata: [String: SectionMetadata]
    ) throws -> [Block] {
        var rows = BlockParser.parse(
            markdown: snapshotSection.markdownContent, projectId: projectId, existingSectionMetadata: metadata,
            notesHeaderName: try? database.fetchNotesHeadingTitle(projectId: projectId))
        guard let first = rows.first else { throw FragmentRefusal(reason: "the version's section has no text") }
        guard first.blockType == .heading else {
            throw FragmentRefusal(reason: "the version's section does not start with a heading")
        }
        guard rows.allSatisfy({ !$0.isNotes && !$0.isBibliography && $0.blockType != .bibliography }) else {
            throw FragmentRefusal(reason: "the version's section holds Notes or Bibliography text")
        }
        var imageMeta = ProjectDatabase.buildImageMetadataIndex(from: existing)
        for index in rows.indices where rows[index].blockType == .image {
            ProjectDatabase.applyPreservedImageMetadata(to: &rows[index], index: &imageMeta)
        }
        return rows
    }
}
