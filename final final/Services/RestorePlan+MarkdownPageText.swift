//
//  RestorePlan+MarkdownPageText.swift
//  final final
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 4: the three Version History restores in Markdown mode
//  (plan-v1 D1, plan-v1-addendum section 4). The text the CodeMirror page is handed for a restore, built from the plan's ROWS at the
//  click, BEFORE the database holds them.
//
//  WHY IT EXISTS. The page text of a Markdown document is not the rows' assembly: it carries hidden markers the rows do not hold, a
//  `<!-- @sid:ID -->` glued in front of every section leader (the Outline card click finds its section by the literal marker in
//  `sourceContent`, Views/ContentView+SectionManagement.swift) and one `<!-- ::auto-bibliography:: -->` in front of the bibliography
//  heading. The old Markdown restore pushed the DB-assembled text WITHOUT them, so a card click after a restore landed far away. Here
//  the plan's rows already carry the ids the queued job (`StructuralReplaceJob`) will write, so the markers can be written into the
//  text before the page is called: page text and rows then name the same ids from the first moment, and later rebuilds agree.
//
//  THE RECIPE IS THE REBUILD'S OWN, not a second implementation. It is `ContentView.updateSourceContentIfNeeded`
//  (Views/ContentView+ContentRebuilding.swift, "Get non-bibliography sections in sort order" to `sourceContent =`, and its twin in
//  ViewState/EditorViewState+Zoom.swift, the zoom-out `sourceContent` block) applied to `rows` instead of `editorState.content` and the
//  database's rows:
//    1. the editor text = `BlockParser.assembleMarkdownForEditor` (the rows joined by one blank line, empty fragments dropped, the
//       bibliography END marker after the last bibliography row);
//    2. a block-offset map over `MarkdownBlockDiff.assemblyOrderedNonEmpty` (the shared order: the rebuild uses the same function), in
//       Characters, "\n\n" between blocks, the fragment's `count`;
//    3. the sections the rebuild marks: `editorState.sections` filtered `!isBibliography`. That list is fed by the outline snapshot, whose rows come from
//       `fetchOutlineBlocks` (Database+Blocks.swift): EVERY `.heading` row of every level and every `isPseudoSection` row (the Notes
//       heading included), no level filter. A section gets a marker only where it has a block offset, that is only when its fragment is
//       not empty (`BlockParser.isEmptyFragment`);
//    4. `sectionSync.injectSectionAnchors(markdown:sections:)` writes `<!-- @sid:<id> -->` glued to the row's first character, on the
//       same line, no newline;
//    5. `sectionSync.injectBibliographyMarker(markdown:sections:)` with ALL the sections (the bibliography's too) writes the opening
//       bibliography marker. It bails on any marker already present, and `assembleMarkdownForEditor` writes only the END marker, so
//       the opening marker is in the result exactly once, and only when the rows have a bibliography heading.
//  Step 5 is for `.whole` only: a section restore's fragment refuses Notes and Bibliography text (`SnapshotService.fragmentRows`), so
//  it never holds a bibliography heading.
//
//  Duplicated rather than extracted: the rebuild's recipe sits inside two views' methods that read `editorState`, the database and the
//  zoom state, and extracting it would touch the paths Rich Text and the rebuild use. A unit test (round C2, U1) compares the result
//  with `updateSourceContentIfNeeded`'s output on the rows after the settle, so a drift between the two shows there.
//

import Foundation

extension RestorePlan {

    /// The ids `markdownPageText` writes a section anchor for, in document order: the rows that are a heading or a section break, are not
    /// the bibliography and have a non-empty fragment (the rebuild's rule, see the file header). What the page reports back as
    /// `insertedLeaderIds` is compared with this.
    var markedLeaderIds: [String] {
        BlockParser.assemblySorted(rows)
            .filter { ($0.blockType == .heading || $0.isPseudoSection) && !$0.isBibliography && !BlockParser.isEmptyFragment($0.markdownFragment) }
            .map(\.id)
    }

    /// The text the page inserts for this plan (see the file header): the plan's rows assembled for the editor, with a section anchor in
    /// front of every section leader and, for a whole restore, the bibliography opening marker. No trailing newline is added.
    @MainActor
    func markdownPageText(sectionSync: SectionSyncService) -> String {
        // 1. The editor text (the payload's `markdown` is the same string: `StructuralUndoController.editorPayload`).
        let assembled = BlockParser.assembleMarkdownForEditor(from: rows)

        // 2. Block offsets, as `updateSourceContentIfNeeded` computes them (Characters; "\n\n" between blocks).
        let nonEmpty = MarkdownBlockDiff.assemblyOrderedNonEmpty(rows)
        var blockOffset: [String: Int] = [:]
        var offset = 0
        for (index, block) in nonEmpty.enumerated() {
            if index > 0 { offset += 2 }   // "\n\n" separator
            blockOffset[block.id] = offset
            offset += block.markdownFragment.count
        }

        // 3. The sections the outline lists: every heading and section break row, Notes included (`fetchOutlineBlocks`). Only the
        // ones that are not the bibliography and have an offset get a marker.
        let leaders = BlockParser.assemblySorted(rows).filter { $0.blockType == .heading || $0.isPseudoSection }
        var anchored: [SectionViewModel] = []
        for row in leaders where !row.isBibliography {
            if let rowOffset = blockOffset[row.id] {
                anchored.append(SectionViewModel(from: row).withUpdates(startOffset: rowOffset))
            }
        }

        // 4. The section anchors, by the rebuild's own call.
        let withAnchors = sectionSync.injectSectionAnchors(markdown: assembled, sections: anchored)
        guard mode == .whole else { return withAnchors }

        // 5. The bibliography opening marker, by the rebuild's own call (given every section, the bibliography's included).
        return sectionSync.injectBibliographyMarker(markdown: withAnchors, sections: leaders.map { SectionViewModel(from: $0) })
    }
}
