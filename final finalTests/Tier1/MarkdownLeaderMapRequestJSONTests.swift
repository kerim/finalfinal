//
//  MarkdownLeaderMapRequestJSONTests.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 2 (the sidebar drag-reorder), round 3a: the JSON the Swift side
//  sends to the CodeMirror page, pinned. No database and no page: the rows are built by hand with fixed ids, so the expected text is a
//  literal. `JSONSerialization` writes the keys of a dictionary in no fixed order, so each request's JSON is read back and written again
//  with sorted keys before it is compared with the literal; every key, every value and every null is still pinned.
//
//  Two pins:
//    - the DELETE request (`MarkdownLeaderMap.Request`) must stay exactly as slice 1 shipped it; the page's `markdownStructuralEditorFirst`
//      reads it (round 3a added the reorder request beside it and must not have touched this one);
//    - the REORDER request (`MarkdownLeaderMap.ReorderRequest`), the contract of `markdownStructuralReorder` (web/codemirror/src/
//      api-structural-markdown-reorder.ts): `kind`, `opId`, `rootId`, every leader, the order with a `level` only where the drop changed
//      it, and a `stopLine` that is the first Notes/Bibliography row of the WHOLE document, an explicit null when there is none. It has no
//      `endLeaderId`.
//
//  Break patches (a 1-5 line change in `MarkdownLeaderMap.swift`) and the failure each makes:
//
//   delete JSON   BREAK: in `Request.json` write `"kind": "remove"` instead of `"kind": "delete"`.
//                 FAILS: "delete request JSON changed".
//   reorder JSON  BREAK: in `ReorderRequest.json` write `item["level"] = entry.level ?? 0` (a level on every order entry).
//                 FAILS: "reorder request JSON shape changed".
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import Testing
@testable import final_final

@Suite("Markdown leader map request JSON — Tier 1 (t-4a8fd8af slice 2, round 3a)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MarkdownLeaderMapRequestJSONTests {

    private static let projectId = "project"
    private static let opId = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    /// The opId as the JSON writes it.
    private static let opIdText = "00000000-0000-0000-0000-0000000000A1"

    private static func heading(_ id: String, _ level: Int, _ title: String, at order: Double, notes: Bool = false) -> Block {
        Block(
            id: id, projectId: projectId, sortOrder: order, blockType: .heading, textContent: title,
            markdownFragment: String(repeating: "#", count: level) + " " + title, headingLevel: level, isNotes: notes)
    }

    private static func paragraph(_ id: String, _ text: String, at order: Double, notes: Bool = false) -> Block {
        Block(id: id, projectId: projectId, sortOrder: order, blockType: .paragraph, textContent: text, markdownFragment: text, isNotes: notes)
    }

    /// Alpha (with a level-2 Sub), Beta, then the Notes section.
    private static var rowsWithNotes: [Block] {
        [
            heading("h-alpha", 1, "Alpha", at: 0), paragraph("p-alpha", "Alpha text.", at: 1),
            heading("h-sub", 2, "Sub", at: 2), paragraph("p-sub", "Sub text.", at: 3),
            heading("h-beta", 1, "Beta", at: 4), paragraph("p-beta", "Beta text.", at: 5),
            heading("h-notes", 1, "Notes", at: 6, notes: true), paragraph("p-note", "[^1]: Note.", at: 7, notes: true)
        ]
    }

    /// The same without the Notes section.
    private static var rowsWithoutNotes: [Block] { Array(rowsWithNotes.prefix(6)) }

    // The leaders as the JSON writes them (keys sorted). The text holds the three characters `"##` (the Sub heading's line), so these
    // literals use three `#`; the other literals below hold at most `"#` and use two.
    private static let leadersWithNotes =
        ###"[{"id":"h-alpha","level":1,"line":"# Alpha"},{"id":"h-sub","level":2,"line":"## Sub"},"###
        + ###"{"id":"h-beta","level":1,"line":"# Beta"},{"id":"h-notes","level":1,"line":"# Notes","managed":"notes"}]"###

    private static let leadersWithoutNotes =
        ###"[{"id":"h-alpha","level":1,"line":"# Alpha"},{"id":"h-sub","level":2,"line":"## Sub"},{"id":"h-beta","level":1,"line":"# Beta"}]"###

    /// `json` read back and written again with sorted keys: the same data in one fixed byte order.
    private static func canonical(_ json: String?) throws -> String {
        let text = try #require(json, "the request has no JSON")
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try #require(String(data: data, encoding: .utf8), "the sorted JSON is not UTF-8")
    }

    // MARK: - The delete request

    @Test("the delete request JSON is exactly what slice 1 shipped")
    func deleteRequestJSONIsPinned() throws {
        let map = MarkdownLeaderMap(rows: Self.rowsWithNotes)
        let request = try #require(map.request(opId: Self.opId, rootId: "h-alpha"), "no delete request for a plain chapter")
        let expected = ##"{"endLeaderId":"h-beta","kind":"delete","leaders":"## + Self.leadersWithNotes
            + ##","opId":"\##(Self.opIdText)","rootId":"h-alpha","stopLine":"# Notes"}"##
        #expect(try Self.canonical(request.json) == expected, "delete request JSON changed")
    }

    @Test("the delete request JSON writes explicit nulls when there is no Notes section and no later leader")
    func deleteRequestJSONWritesNulls() throws {
        let map = MarkdownLeaderMap(rows: Self.rowsWithoutNotes)
        let request = try #require(map.request(opId: Self.opId, rootId: "h-beta"), "no delete request for the last chapter")
        let expected = ##"{"endLeaderId":null,"kind":"delete","leaders":"## + Self.leadersWithoutNotes
            + ##","opId":"\##(Self.opIdText)","rootId":"h-beta","stopLine":null}"##
        #expect(try Self.canonical(request.json) == expected, "delete request JSON changed")
    }

    // MARK: - The reorder request

    @Test("the reorder request JSON: kind, ids, every leader, the order with levels only where the drop changed them, the first managed line")
    func reorderRequestJSONShape() throws {
        let map = MarkdownLeaderMap(rows: Self.rowsWithNotes)
        // Alpha with its Sub dropped after Beta; the drop made Sub a level-3 heading. Notes stay last.
        let request = try #require(
            map.reorderRequest(
                opId: Self.opId, rootId: "h-alpha", order: ["h-beta", "h-alpha", "h-sub", "h-notes"], changedLevels: ["h-sub": 3]),
            "no reorder request for a plain chapter")
        let expected = ##"{"kind":"reorder","leaders":"## + Self.leadersWithNotes
            + ##","opId":"\##(Self.opIdText)","order":[{"id":"h-beta"},{"id":"h-alpha"},{"id":"h-sub","level":3},"##
            + ##"{"id":"h-notes"}],"rootId":"h-alpha","stopLine":"# Notes"}"##
        #expect(try Self.canonical(request.json) == expected, "reorder request JSON shape changed")
    }

    @Test("the reorder request JSON has an explicit null stopLine when there is no Notes or Bibliography row, and no endLeaderId")
    func reorderRequestJSONWithoutNotes() throws {
        let map = MarkdownLeaderMap(rows: Self.rowsWithoutNotes)
        let request = try #require(
            map.reorderRequest(opId: Self.opId, rootId: "h-beta", order: ["h-beta", "h-alpha", "h-sub"], changedLevels: [:]),
            "no reorder request for the last chapter")
        let expected = ##"{"kind":"reorder","leaders":"## + Self.leadersWithoutNotes
            + ##","opId":"\##(Self.opIdText)","order":[{"id":"h-beta"},{"id":"h-alpha"},{"id":"h-sub"}],"rootId":"h-beta","stopLine":null}"##
        #expect(try Self.canonical(request.json) == expected, "reorder request JSON shape changed")
    }

    @Test("a reorder request is built only for a draggable leader: not a paragraph, not the Notes heading, not an unknown id")
    func reorderRequestNeedsADraggableRoot() {
        let map = MarkdownLeaderMap(rows: Self.rowsWithNotes)
        let order = ["h-alpha", "h-sub", "h-beta", "h-notes"]
        #expect(map.reorderRequest(opId: Self.opId, rootId: "h-notes", order: order, changedLevels: [:]) == nil, "the Notes heading was draggable")
        #expect(map.reorderRequest(opId: Self.opId, rootId: "p-alpha", order: order, changedLevels: [:]) == nil, "a paragraph was draggable")
        #expect(map.reorderRequest(opId: Self.opId, rootId: "no-such-row", order: order, changedLevels: [:]) == nil, "an unknown id was draggable")
        #expect(map.reorderRequest(opId: Self.opId, rootId: "h-sub", order: order, changedLevels: [:]) != nil, "a sub-section was not draggable")
    }
}
