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

    /// The request the page takes (any `kind` other than delete is a later slice).
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
