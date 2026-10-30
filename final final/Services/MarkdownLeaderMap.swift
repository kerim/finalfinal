//
//  MarkdownLeaderMap.swift
//  final final
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 1, round 5, plan B1: the request for
//  `window.FinalFinal.markdownStructuralEditorFirst`, built from the database rows. The page does not know the database. Swift sends
//  the document's LEADERS (headings and section breaks) as the rows hold them, in document order, and the page checks them against the
//  live text before it touches anything (web/codemirror/src/api-structural-markdown.ts, "THE JSON CONTRACT" and "THE LEADER MATCH").
//
//  Per the contract:
//    - `leaders`: EVERY leader (heading or section break) in assembly order (`MarkdownBlockDiff.assemblyOrderedNonEmpty`, the order the
//      editor text is assembled in), including the Notes and Bibliography heading rows, which carry `managed`. `line` is the first
//      line of the row's markdown, trimmed, with any leading hidden marker removed; `level` is the heading level, a section break is 1.
//    - `stopLine`: the trimmed first line of the first Notes or Bibliography row (leader or not, e.g. the bibliography's own opening
//      marker row) after the root; nil when none.
//    - `endLeaderId`: the first later leader with level <= the root's (managed ones included); nil when none. A consistency check only.
//  `removedLeaderIds(rootId:)` is the database's end rule (Database+SectionOps.swift `resolveSectionSubtree`) applied to the same
//  leaders: the root and every following leader that is deeper, stopping at the first Notes or Bibliography leader. The sidebar hides
//  exactly those until the queued job applies (`EditorViewState.pendingRemovalIds`).
//
//  No page, no database handle: a pure value built from rows, unit-tested without either.
//

import Foundation

struct MarkdownLeaderMap: Equatable {

    struct Leader: Equatable {
        let id: String
        let line: String
        let level: Int
        /// "notes" or "bibliography" on the Notes / Bibliography heading rows.
        let managed: String?

        var jsonObject: [String: Any] {
            var object: [String: Any] = ["id": id, "line": line, "level": level]
            if let managed { object["managed"] = managed }
            return object
        }
    }

    /// The DELETE request the page takes (`ReorderRequest`, below, is the drag-reorder's). Its JSON is pinned byte for byte by
    /// MarkdownLeaderMapRequestJSONTests: do not change a key, a value or a null here without changing the page's reader with it.
    struct Request: Equatable {
        let opId: UUID
        let rootId: String
        let leaders: [Leader]
        let stopLine: String?
        let endLeaderId: String?

        /// The JSON text of the request. `stopLine` and `endLeaderId` are sent as explicit nulls when absent (the page reads a null
        /// `endLeaderId` as "no later leader ends the section" and checks that).
        var json: String? {
            let object: [String: Any] = [
                "kind": "delete",
                "opId": opId.uuidString,
                "rootId": rootId,
                "leaders": leaders.map(\.jsonObject),
                "stopLine": stopLine ?? NSNull(),
                "endLeaderId": endLeaderId ?? NSNull()
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    /// The request `window.FinalFinal.markdownStructuralReorder` takes (t-4a8fd8af slice 2, round 3a; web/codemirror/src/
    /// api-structural-markdown-reorder.ts, "THE JSON CONTRACT"). The leaders are the same as the delete's, built from the rows AFTER the
    /// typing was flushed; `order` is the plan (every section leader in final order, Notes and Bibliography last); a `level` is present
    /// only on the headings whose level the drop changed.
    struct ReorderRequest: Equatable {
        let opId: UUID
        let rootId: String
        let leaders: [Leader]
        let order: [ReorderOrderEntry]
        let stopLine: String?

        /// The JSON text of the request. `stopLine` is an explicit null when there is no Notes or Bibliography row. An order entry
        /// without a changed level carries no `level` key at all.
        var json: String? {
            let object: [String: Any] = [
                "kind": "reorder",
                "opId": opId.uuidString,
                "rootId": rootId,
                "leaders": leaders.map(\.jsonObject),
                "order": order.map { entry -> [String: Any] in
                    var item: [String: Any] = ["id": entry.id]
                    if let level = entry.level { item["level"] = level }
                    return item
                },
                "stopLine": stopLine ?? NSNull()
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    /// One pair of a Duplicate's `copyIds`: the id a leader of the section has now (`source`) and the id its copy gets (`new`). Swift
    /// mints `new` BEFORE the page is called; the page writes it into the copy's `<!-- @sid:NEW -->` marker and the queued
    /// `SectionDuplicateJob` gives the copy row the same id (t-4a8fd8af slice 3).
    struct DuplicateCopyId: Equatable {
        let source: String
        let new: String
    }

    /// The request `window.FinalFinal.markdownStructuralDuplicate` takes (t-4a8fd8af slice 3; web/codemirror/src/api-structural-markdown-duplicate.ts
    /// and slice3-duplicate/page-contract.md in docs/architecture/write-queue-plan/phase4b-markdown). The Delete's request with
    /// `kind` "duplicate" and one more field, `copyIds`: one pair per leader of the section's subtree, root first, in document order.
    /// Its JSON is pinned by the Swift tests: do not change a key, a value or a null here without changing the page's reader with it.
    struct DuplicateRequest: Equatable {
        let opId: UUID
        let rootId: String
        let leaders: [Leader]
        let stopLine: String?
        let endLeaderId: String?
        let copyIds: [DuplicateCopyId]

        /// The JSON text of the request. `stopLine` and `endLeaderId` are explicit nulls when absent, as the Delete's.
        var json: String? {
            let object: [String: Any] = [
                "kind": "duplicate",
                "opId": opId.uuidString,
                "rootId": rootId,
                "leaders": leaders.map(\.jsonObject),
                "stopLine": stopLine ?? NSNull(),
                "endLeaderId": endLeaderId ?? NSNull(),
                "copyIds": copyIds.map { ["source": $0.source, "new": $0.new] }
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    /// The request `window.FinalFinal.markdownStructuralRestore` takes (t-4a8fd8af slice 4; web/codemirror/src/api-structural-markdown-restore.ts
    /// "THE JSON CONTRACT" and slice4-restores/page-contract.md in docs/architecture/write-queue-plan/phase4b-markdown). The Delete's leader
    /// fields with `kind` "restore", a `mode` (whole, section, insertAfter), a `rootId` (the target heading of a section restore, the anchor
    /// leader of an insertAfter, nil for whole or for an insertAfter without an anchor), an always-null `endLeaderId` and the `text` the page
    /// inserts (`RestorePlan.markdownPageText`, markers included).
    ///
    /// Its JSON is pinned by `slice4-restores/request-golden.json` (a Swift test and a web test read it): CANONICAL form, keys sorted at
    /// every level, compact, `rootId` / `stopLine` / `endLeaderId` as explicit nulls when absent, `managed` only on the Notes and
    /// Bibliography leaders. Do not change a key, a value or a null here without changing the page's reader and the golden with it.
    struct RestoreRequest: Equatable {
        let opId: UUID
        let mode: RestorePlan.Mode
        let rootId: String?
        let leaders: [Leader]
        let stopLine: String?
        let text: String

        var json: String? {
            let object: [String: Any] = [
                "kind": "restore",
                "opId": opId.uuidString,
                "mode": mode.rawValue,
                "rootId": rootId ?? NSNull(),
                "leaders": leaders.map(\.jsonObject),
                "stopLine": stopLine ?? NSNull(),
                "endLeaderId": NSNull(),
                "text": text
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
    }

    /// Every leader of the document, in document order.
    let leaders: [Leader]
    /// The rows in document order (empty fragments dropped): what `stopLine` is looked up in.
    private let ordered: [Block]

    init(rows: [Block]) {
        let ordered = MarkdownBlockDiff.assemblyOrderedNonEmpty(rows)
        self.ordered = ordered
        leaders = ordered.compactMap(Self.leader(of:))
    }

    /// The leader a row is, if any. The app's rows are `.heading` rows and section breaks (`isPseudoSection`): the bibliography
    /// heading `BibliographySyncService` writes is a plain `# Bibliography` `.heading` row flagged `isBibliography` (it is written
    /// WITHOUT the opening marker, which is only injected into the Markdown editor's text), and the Notes heading is a `.heading` row
    /// flagged `isNotes`.
    ///
    /// One more shape is read, because the page reads it: a row whose fragment carries the bibliography opening marker glued to its
    /// heading (`<!-- ::auto-bibliography:: --># Bibliography`, what `BlockParser` makes of text that still holds the marker). The parser
    /// types such a row `.bibliography`, not `.heading` (a fragment starting with `<!--` fails the heading rule), so the page, which
    /// strips leading markers and sees an ATX heading line, counts a leader that a `.heading`-only map would not: a count mismatch on
    /// every delete in that document. The row is the bibliography's heading, so it is a MANAGED leader.
    private static func leader(of block: Block) -> Leader? {
        let managed = block.isNotes ? "notes" : (block.isBibliography ? "bibliography" : nil)
        let line = leaderLine(of: block.markdownFragment)
        if block.blockType == .heading || block.isPseudoSection {
            return Leader(id: block.id, line: line, level: block.headingLevel ?? 1, managed: managed)
        }
        if block.blockType == .bibliography, let level = atxLevel(of: line) {
            return Leader(id: block.id, line: line, level: level, managed: managed ?? "bibliography")
        }
        return nil
    }

    /// The level (1 to 6) of an ATX heading line (`#` characters then a blank), nil for any other line.
    private static func atxLevel(of line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        return rest.first == " " || rest.first == "\t" ? hashes : nil
    }

    // MARK: - The request

    /// The request for deleting the section rooted at `rootId`. nil when `rootId` is no leader, or is the Notes or Bibliography heading.
    func request(opId: UUID, rootId: String) -> Request? {
        guard let rootIndex = leaders.firstIndex(where: { $0.id == rootId }), leaders[rootIndex].managed == nil,
              let rootRow = ordered.firstIndex(where: { $0.id == rootId }) else { return nil }
        let root = leaders[rootIndex]
        let endLeader = leaders[(rootIndex + 1)...].first { $0.level <= root.level }
        let stopLine = ordered[(rootRow + 1)...].first { $0.isNotes || $0.isBibliography }
            .map { Self.firstLine(of: $0.markdownFragment) }
        return Request(opId: opId, rootId: rootId, leaders: leaders, stopLine: stopLine, endLeaderId: endLeader?.id)
    }

    /// The request for duplicating the section rooted at `rootId`: the Delete's request (same leaders, `stopLine`, `endLeaderId`) plus
    /// `copyIds`. nil when `rootId` is no leader, is the Notes or Bibliography heading, or when `copyIds` is not exactly one pair per
    /// leader of the subtree (`removedLeaderIds(rootId:)`), in that order: the page checks the same thing against the live text, and
    /// a request that cannot pass is not worth a page call. The ids in `copyIds` are minted by the CALLER (`mintDuplicateCopyIds`), so
    /// the flush-and-retry sends the same ones.
    func duplicateRequest(opId: UUID, rootId: String, copyIds: [DuplicateCopyId]) -> DuplicateRequest? {
        guard copyIds.map(\.source) == removedLeaderIds(rootId: rootId), let base = request(opId: opId, rootId: rootId) else { return nil }
        return DuplicateRequest(
            opId: opId, rootId: rootId, leaders: base.leaders, stopLine: base.stopLine, endLeaderId: base.endLeaderId, copyIds: copyIds)
    }

    /// The request for a Version History restore (t-4a8fd8af slice 4). `rootId`: the target heading of a `section` restore (required: a
    /// non-managed leader of these rows), the anchor leader of an `insertAfter` (nil: no anchor, the page inserts before the first managed
    /// leader), ignored (sent as null) for `whole`. `stopLine` is the trimmed first line of the first Notes or Bibliography row after the
    /// root (after the start of the document when there is no root), null when there is none and always null for `whole`, which the page
    /// does not locate. nil when a section's root is no leader, or when a root is the Notes or Bibliography heading (the page refuses
    /// such a root too: `rootIsManaged`).
    func restoreRequest(opId: UUID, mode: RestorePlan.Mode, rootId: String?, text: String) -> RestoreRequest? {
        if mode == .whole {
            return RestoreRequest(opId: opId, mode: mode, rootId: nil, leaders: leaders, stopLine: nil, text: text)
        }
        var searchFrom = 0
        if let rootId {
            guard let leader = leaders.first(where: { $0.id == rootId }), leader.managed == nil,
                  let rootRow = ordered.firstIndex(where: { $0.id == rootId }) else { return nil }
            searchFrom = rootRow + 1
        } else if mode == .section {
            return nil
        }
        let stopLine = ordered[searchFrom...].first { $0.isNotes || $0.isBibliography }
            .map { Self.firstLine(of: $0.markdownFragment) }
        return RestoreRequest(opId: opId, mode: mode, rootId: rootId, leaders: leaders, stopLine: stopLine, text: text)
    }

    /// The `copyIds` for duplicating the section rooted at `rootId`: one pair per leader of its subtree, each new id taken from `minted`
    /// (source id -> new id) when it is already there and freshly made otherwise, and recorded in `minted`. The caller keeps `minted`
    /// across the flush-and-retry, so a second call after the typing was flushed reuses every id it sent the first time (a heading
    /// typed meanwhile is a new source and gets a new id). Empty when `rootId` is no duplicable leader.
    func mintDuplicateCopyIds(rootId: String, minted: inout [String: String]) -> [DuplicateCopyId] {
        removedLeaderIds(rootId: rootId).map { source in
            let new = minted[source] ?? UUID().uuidString
            minted[source] = new
            return DuplicateCopyId(source: source, new: new)
        }
    }

    /// What the sidebar shows at once for the copy (the overlay `showDuplicateInSidebar` takes), built from the ROWS of the subtree: one
    /// entry per pair of `copyIds`, `id` = the copy's new id, `kind` "section_break" for a section break and "heading" otherwise, the
    /// row's level, and the row's own `textContent` as the title (with " copy" for a heading root, as `duplicateSections` adds it to
    /// the copy row; a section break has no title). The page's own list (`insertedLeaders`) is only a cross-check. Empty when `copyIds`
    /// is not exactly the subtree's leaders in order or a row is missing.
    func duplicateInsertedSections(rootId: String, copyIds: [DuplicateCopyId]) -> [EditorFirstDuplicateReply.InsertedSection] {
        guard copyIds.map(\.source) == removedLeaderIds(rootId: rootId) else { return [] }
        var sections: [EditorFirstDuplicateReply.InsertedSection] = []
        for (index, pair) in copyIds.enumerated() {
            guard let row = ordered.first(where: { $0.id == pair.source }) else { return [] }
            let isBreak = row.isPseudoSection
            let suffix = index == 0 && row.blockType == .heading ? " copy" : ""
            sections.append(
                EditorFirstDuplicateReply.InsertedSection(
                    id: pair.new, kind: isBreak ? "section_break" : "heading", level: row.headingLevel ?? 1,
                    title: isBreak ? "" : row.textContent + suffix))
        }
        return sections
    }

    /// The request for a drag-reorder whose dragged card is `rootId`. `order` is the plan's ids (every section leader in final order,
    /// Notes and Bibliography last); `changedLevels` is id -> new level for the headings the drop re-levelled. `stopLine` is the first
    /// line of the FIRST Notes or Bibliography row of the whole document (a consistency check on the page's side only). nil when
    /// `rootId` is no leader, or is the Notes or Bibliography heading (neither can be dragged).
    func reorderRequest(opId: UUID, rootId: String, order: [String], changedLevels: [String: Int]) -> ReorderRequest? {
        guard let root = leaders.first(where: { $0.id == rootId }), root.managed == nil else { return nil }
        let stopLine = ordered.first { $0.isNotes || $0.isBibliography }.map { Self.firstLine(of: $0.markdownFragment) }
        return ReorderRequest(
            opId: opId, rootId: rootId, leaders: leaders,
            order: order.map { ReorderOrderEntry(id: $0, level: changedLevels[$0]) }, stopLine: stopLine)
    }

    /// The leaders the section rooted at `rootId` takes with it: the root and every following leader that is deeper, up to the first
    /// Notes or Bibliography leader or the first leader whose level is not deeper (the database's end rule). Empty when `rootId` is no
    /// deletable leader.
    func removedLeaderIds(rootId: String) -> [String] {
        guard let rootIndex = leaders.firstIndex(where: { $0.id == rootId }), leaders[rootIndex].managed == nil else { return [] }
        let rootLevel = leaders[rootIndex].level
        var removed = [rootId]
        for leader in leaders[(rootIndex + 1)...] {
            guard leader.managed == nil, leader.level > rootLevel else { break }
            removed.append(leader.id)
        }
        return removed
    }

    // MARK: - Finding a section's root again after its rows were re-created

    /// Where a section's root heading stands in a leader list, by what survives a slow undo: a slow Cmd-Z puts the section back by
    /// replacing the project's rows with a snapshot's (`SnapshotService.wholeRestorePlan`), and the rows of a section that was not in
    /// the table get FRESH ids, so the id the Delete clicked on names no row any more. The heading line and which occurrence of that
    /// line it is (two chapters can carry the same title) do survive.
    struct RootReference: Equatable {
        let id: String
        let line: String
        /// How many leaders with the same `line` stand before it.
        let occurrence: Int
    }

    /// The reference to the root `rootId` in this map, or nil when `rootId` is no deletable leader here.
    func rootReference(of rootId: String) -> RootReference? {
        guard let index = leaders.firstIndex(where: { $0.id == rootId }), leaders[index].managed == nil else { return nil }
        let line = leaders[index].line
        return RootReference(id: rootId, line: line, occurrence: leaders[..<index].filter { $0.line == line && $0.managed == nil }.count)
    }

    /// The id, in THIS map, of the leader `reference` names: its own id while that row still exists, otherwise the same occurrence of
    /// the same heading line. nil when neither is there: a root that cannot be found again is refused, never guessed at (a delete
    /// of the wrong section is worse than no delete).
    func currentRootId(for reference: RootReference) -> String? {
        if leaders.contains(where: { $0.id == reference.id && $0.managed == nil }) { return reference.id }
        let sameLine = leaders.filter { $0.line == reference.line && $0.managed == nil }
        return reference.occurrence < sameLine.count ? sameLine[reference.occurrence].id : nil
    }

    // MARK: - Lines and text

    /// The first line of `fragment`, trimmed.
    static func firstLine(of fragment: String) -> String {
        (fragment.components(separatedBy: "\n").first ?? "").trimmingCharacters(in: .whitespaces)
    }

    private static let leadingHidden = try? NSRegularExpression(
        pattern: "^(?:<!-- @sid:[0-9a-fA-F-]+ -->|<!-- ::auto-bibliography:: -->|<!-- ::auto-bibliography-end:: -->)\\s*")

    /// A leader's line: the first line, with every leading hidden marker (section anchor, bibliography opening or end marker) removed, trimmed.
    static func leaderLine(of fragment: String) -> String {
        var rest = firstLine(of: fragment)
        guard let leadingHidden else { return rest }
        while let match = leadingHidden.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
              let range = Range(match.range, in: rest), !range.isEmpty {
            rest.removeSubrange(range)
        }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// The text of the content record for a raw page text: the section anchors and the bibliography opening marker removed (the end
    /// marker stays, as in `editorState.content`). What the click hands the writer as "the text up to the click".
    @MainActor
    static func recordText(fromRaw raw: String) -> String {
        let anchorless = SectionSyncService.anchorPattern.stringByReplacingMatches(
            in: raw, options: [], range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
        return SectionSyncService.stripBibliographyMarker(from: anchorless)
    }
}
