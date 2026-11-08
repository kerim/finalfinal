//
//  EditorFirstReorderRig.swift
//  final finalTests
//
//  Tier 2 (t-0b70d1e9): the scripted editor's answer for the editor-first drag-reorder, and the small rig around it. Support for
//  EditorFirstReorderTests.swift; nothing here is a test.
//
//  `ReorderRig` wraps an `EditorFirstRig` (EditorFirstDeleteTests.swift) and does two things the rig does not:
//    1. It answers `reorderSectionsEditorFirst(opId, rootId, managedIds, order)` the way the real editor does
//       (web/milkdown/src/api-section-reorder.ts): consume the pending batch (`clickBatch`, typing up to the click), move the run of
//       sections to the order Swift sent, set the planned heading levels (headings only), and answer
//       `{batch, ok, skippedIds, moved, levelChanges}`. The document it then holds is worked out from the database's rows, which still
//       have the OLD order because the queued job has not run; `rig.editorText`, `rig.quickEditorText` and `editorState.content` become
//       that text, as the editor's `contentChanged` makes them. The answer is installed IN FRONT of the rig's evaluator by wrapping
//       `sync.testJSEvaluator`, so no existing rig file changes.
//    2. It keeps a `SectionSyncService` alive and configures the controller with it. The controller's reference is weak and the rig
//       passes it a temporary, so in a plain rig the controller has none: the in-gate re-plan and the hierarchy check are skipped.
//       A drag in the app has both, so these tests do too.
//
//  The rig names no production symbol of the editor-first reorder except `SectionReorderRequest` and `SectionReorderPlanner` (the
//  drag's own inputs), so a break patch that sends the reorder back to the old body leaves it compiling.
//

import Foundation
import GRDB
import Testing
@testable import final_final

/// The JSON `reorderSectionsEditorFirst` answers.
private struct ReorderStubReply: Encodable {
    var batch = BlockChanges()
    var succeeded = true
    var reason: String?
    var skippedIds: [String] = []
    var moved = 0
    var levelChanges = 0

    private enum CodingKeys: String, CodingKey {
        case batch
        case succeeded = "ok"
        case reason
        case skippedIds
        case moved
        case levelChanges
    }
}

/// One entry of the `order` argument the click sends.
private struct ReorderStubEntry: Decodable {
    let id: String
    let level: Int?
}

/// What the editor was asked at one reorder click, and what it held before and after.
struct ReorderClick {
    let opId: String
    let rootId: String
    /// Every id of the `order` argument, in the order sent, and the levels it carried.
    let sentOrder: [String]
    let sentLevels: [String: Int]
    /// The document the editor held just before the click, and just after.
    let preText: String
    let newText: String
}

@MainActor
final class ReorderRig {
    let rig: EditorFirstRig
    /// Kept alive here: the controller holds it weakly.
    let sectionSync = SectionSyncService()
    /// The pending edits the next click consumes and returns as its `batch` (typing up to the click). nil: an empty batch. Spent by the call.
    var clickBatch: BlockChanges?
    /// Every click the editor answered, in order.
    private(set) var clicks: [ReorderClick] = []
    /// The editor refuses the next click with this reason (`planMismatch`, `rootNotFound`, ...): nothing moves, the batch is still handed
    /// back, as the real editor does on every path. Spent by the call.
    var refuseNextClickWith: String?
    /// The reasons of the clicks the editor refused, in order.
    private(set) var refusedClicks: [String] = []
    /// Runs inside the next clicks' answers, before the reply is built: whatever arrives while the editor's JavaScript runs (a card the
    /// outline observation adds to the sidebar's list, say).
    var onClick: (() -> Void)?
    /// The rows of the document the editor holds after this stub's last move, in the editor's order, each with the editor's text.
    private var modeledRows: [Block]?

    /// A rig on `markdown` whose sidebar has been read once (`editorState.sections` is the document's outline).
    static func make(markdown: String) async throws -> ReorderRig {
        let reorderRig = try ReorderRig(markdown: markdown)
        await reorderRig.rig.editorState.refreshSectionsAwaiting()
        return reorderRig
    }

    private init(markdown: String) throws {
        rig = try EditorFirstRig(markdown: markdown)
        sectionSync.configure(database: rig.db, projectId: rig.pid)
        rig.controller.configure(
            editorState: rig.editorState, blockSyncService: rig.sync, sectionSyncService: sectionSync,
            bibliographySyncService: rig.bibliography, footnoteSyncService: rig.footnotes,
            annotationSyncService: AnnotationSyncService(), unifiedUndoService: rig.unifiedUndo, findBarState: rig.findBar)
        let previous = rig.sync.testJSEvaluator
        rig.sync.testJSEvaluator = { [weak self] script in
            if script.contains("reorderSectionsEditorFirst") { return self?.answerClick(EditorFirstRig.innerRouteScript(script)) }
            return try await previous?(script)
        }
    }

    // MARK: - Driving a drag

    /// The request the sidebar sends when the card titled `title` is dropped right after the card titled `target` (nil: at the very top).
    /// `parentTitle`: the card the dropped one becomes a sub-section of (a drop at a deeper level); nil keeps the target's own parent.
    func request(
        moving title: String, after target: String?, level: Int? = nil, asChildOf parentTitle: String? = nil
    ) throws -> SectionReorderRequest {
        let cards = rig.editorState.sections
        let moved = try #require(cards.first { $0.title == title }, "no card titled \(title): \(cards.map(\.title))")
        let after = target.flatMap { name in cards.first { $0.title == name } }
        if target != nil { _ = try #require(after, "no card titled \(target ?? ""): \(cards.map(\.title))") }
        let parent = parentTitle.flatMap { name in cards.first { $0.title == name } }
        if parentTitle != nil { _ = try #require(parent, "no card titled \(parentTitle ?? ""): \(cards.map(\.title))") }
        return SectionReorderRequest(
            sectionId: moved.id, targetSectionId: after?.id, newLevel: level ?? moved.headerLevel,
            newParentId: parent?.id ?? after?.parentId)
    }

    /// A drop, as `ContentView.dispatchSectionReorder` makes it: the plan worked out against the list the sidebar shows now (the pre-gate
    /// plan) goes in with the request, and the controller works it out again under the structural gate.
    @discardableResult
    func reorder(
        _ title: String, after target: String?, level: Int? = nil, asChildOf parentTitle: String? = nil
    ) async throws -> StructuralUndoController.StructuralOpOutcome {
        let request = try request(moving: title, after: target, level: level, asChildOf: parentTitle)
        return await drop(request, preGatePlanAgainst: rig.editorState.sections)
    }

    /// The same drop for a request made earlier, with the pre-gate plan worked out against `cards`.
    func drop(
        _ request: SectionReorderRequest, preGatePlanAgainst cards: [SectionViewModel]
    ) async -> StructuralUndoController.StructuralOpOutcome {
        var preGatePlan = cards
        if case .plan(let planned) = SectionReorderPlanner.plan(request: request, in: cards, syncService: sectionSync) {
            preGatePlan = planned
        }
        return await rig.controller.performSectionReorder(sections: preGatePlan, request: request)
    }

    // MARK: - Reading the state

    /// The titles of the sidebar's cards, in order.
    var sidebarTitles: [String] { rig.editorState.sections.map(\.title) }

    /// The titles of the headings the editor shows, in order (a line starting with `#`, the markers and the space dropped).
    var editorHeadingTitles: [String] { Self.headingTitles(in: rig.editorText ?? "") }

    /// The titles of the headings in the database, in document order.
    func databaseHeadingTitles() throws -> [String] {
        BlockParser.assemblySorted(try rig.blocks()).filter { $0.blockType == .heading }.map(\.textContent)
    }

    /// `databaseHeadingTitles()` for a failure message (a read that fails shows as an empty list).
    var databaseTitles: [String] { (try? databaseHeadingTitles()) ?? [] }

    static func headingTitles(in markdown: String) -> [String] {
        markdown.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard line.hasPrefix("#") else { return nil }
            return String(line.drop { $0 == "#" }.drop { $0 == " " })
        }
    }

    /// The non-empty lines of a Markdown text: what the screen and the table are compared by (blank lines carry no content).
    static func contentLines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Waits for every job and settle, then polls until the typing queue is empty (a poll carries one batch per cycle).
    func settleThenCarryTyping() async {
        _ = await rig.waitUntilSettled()
        var cycles = 0
        repeat {
            #expect(await rig.awaitRuns([rig.startReport()]), "a poll did not end")
            cycles += 1
        } while !rig.typingQueue.isEmpty && cycles < 6
        _ = await rig.waitUntilSettled()
    }

    // MARK: - The scripted editor

    /// `reorderSectionsEditorFirst("<opId>", "<rootId>", [managed ids], [{"id":..,"level":..}, ...])`.
    func answerClick(_ script: String) -> String? {
        rig.events.note("js " + script)
        let literals = EditorFirstRig.stringLiterals(in: script)
        guard literals.count >= 2, let order = Self.orderEntries(in: script) else { return nil }
        let batch = clickBatch ?? BlockChanges()
        clickBatch = nil
        onClick?()   // whatever arrives while the editor's JavaScript runs (the reply is read after it)
        if let reason = refuseNextClickWith {
            // The editor refuses and puts everything back; the batch is on EVERY path, even a failed one (api-section-reorder.ts).
            refuseNextClickWith = nil
            refusedClicks.append(reason)
            return EditorFirstRig.json(ReorderStubReply(batch: batch, succeeded: false, reason: reason))
        }

        // The document the editor holds: its OWN text carried through the move, never rebuilt from the database (which has not seen
        // typing that is still waiting, nor the earlier move whose job is still queued). The rows say which block is which: those of
        // the editor's last move when this stub made it and nobody has changed the document's structure since, else the database's.
        // A block is a leader if and only if its id is in the order, every other block belongs to the leader before it, and blocks
        // before the first leader are the preamble.
        let dbRows = BlockParser.assemblySorted((try? rig.blocks()) ?? [])
        let liveText = rig.editorText ?? rig.quickEditorText
        let preText = liveText ?? ((try? rig.assembledMarkdown()) ?? rig.editorState.content)
        let rows = Self.rowsCarryingEditorText(liveText, modeled: modeledRows, database: dbRows)
        let present = Set(rows.map(\.id))
        let working = order.filter { present.contains($0.id) }
        var after = Self.rowsInOrder(rows, working: working)

        // The planned levels: headings only, and only where the level really changes.
        var levelChanges = 0
        for entry in working {
            guard let level = entry.level, let index = after.firstIndex(where: { $0.id == entry.id }),
                  after[index].blockType == .heading, after[index].headingLevel != level else { continue }
            after[index].headingLevel = level
            after[index].markdownFragment = SectionSyncService.updateHeaderLevel(in: after[index].markdownFragment, to: level)
            levelChanges += 1
        }
        for index in after.indices { after[index].sortOrder = Double(index + 1) }
        let text = BlockParser.assembleMarkdownForEditor(from: after)
        modeledRows = after

        rig.quickEditorText = text
        rig.editorText = text
        if !rig.withholdContentUpdate { rig.editorState.content = text }   // `contentChanged` after the move

        var sentLevels: [String: Int] = [:]
        for entry in order { if let level = entry.level { sentLevels[entry.id] = level } }
        clicks.append(ReorderClick(
            opId: literals[0], rootId: literals[1], sentOrder: order.map(\.id), sentLevels: sentLevels, preText: preText, newText: text))

        var reply = ReorderStubReply(batch: batch)
        reply.skippedIds = order.map(\.id).filter { !present.contains($0) }
        reply.moved = zip(rows, after).filter { $0.id != $1.id }.count
        reply.levelChanges = levelChanges
        return EditorFirstRig.json(reply)
    }

    /// `rows` regrouped into the order of `working`: a block is a leader if and only if its id is in the order, every other block belongs
    /// to the leader before it, and blocks before the first leader are the preamble (which stays first).
    private static func rowsInOrder(_ rows: [Block], working: [ReorderStubEntry]) -> [Block] {
        let leaders = Set(working.map(\.id))
        var preamble: [Block] = []
        var groups: [String: [Block]] = [:]
        var currentLeader: String?
        for row in rows {
            if leaders.contains(row.id) {
                currentLeader = row.id
                groups[row.id] = [row]
            } else if let leaderId = currentLeader {
                groups[leaderId, default: []].append(row)
            } else {
                preamble.append(row)
            }
        }
        return preamble + working.flatMap { groups[$0.id] ?? [] }
    }

    /// The rows the editor's document is made of, each carrying the editor's own text for it. `modeled` (the rows after this stub's last
    /// move) is used when the live text still has one chunk per non-empty row; otherwise the database's rows. When the live text has one
    /// chunk per non-empty row of the chosen list, every row takes its chunk as its `markdownFragment` (typing that is still waiting,
    /// a level the user changed in the editor); when it does not, the rows are returned as they are.
    private static func rowsCarryingEditorText(_ live: String?, modeled: [Block]?, database: [Block]) -> [Block] {
        guard let live else { return database }
        let chunks = live.components(separatedBy: "\n\n").filter { $0 != BlockParser.bibliographyEndMarker }
        func nonEmptyCount(_ rows: [Block]) -> Int { rows.filter { !BlockParser.isEmptyFragment($0.markdownFragment) }.count }
        let base: [Block]
        if let modeled, nonEmptyCount(modeled) == chunks.count {
            base = modeled
        } else if nonEmptyCount(database) == chunks.count {
            base = database
        } else {
            return modeled ?? database
        }
        var rows = base
        var next = 0
        for index in rows.indices where !BlockParser.isEmptyFragment(rows[index].markdownFragment) {
            rows[index].markdownFragment = chunks[next]
            next += 1
        }
        return rows
    }

    /// The user types `suffix` at the end of `block`'s text and the editor has NOT handed it to Swift yet: the editor's text changes
    /// (and `contentChanged` with it), the database does not, and the returned batch is what the next click will consume (assign it to
    /// `clickBatch`).
    func typeWithoutHandingItOver(into block: Block, appending suffix: String) throws -> BlockChanges {
        let live = try #require(rig.editorText ?? rig.quickEditorText ?? (try? rig.assembledMarkdown()), "the editor holds no document")
        let range = try #require(live.range(of: block.markdownFragment), "the editor does not show '\(block.markdownFragment)'")
        let typed = live.replacingCharacters(in: range, with: block.markdownFragment + suffix)
        rig.editorText = typed
        rig.quickEditorText = typed
        rig.editorState.content = typed
        return BlockChanges(updates: [BlockUpdate(
            id: block.id, textContent: block.textContent + suffix, markdownFragment: block.markdownFragment + suffix, headingLevel: nil)])
    }

    /// The `order` argument: the last array of objects in the script.
    private static func orderEntries(in script: String) -> [ReorderStubEntry]? {
        guard let open = script.range(of: "[{", options: .backwards), let close = script.lastIndex(of: "]"),
              open.lowerBound < close else { return nil }
        return try? JSONDecoder().decode([ReorderStubEntry].self, from: Data(script[open.lowerBound...close].utf8))
    }
}
