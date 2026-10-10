//
//  MarkdownSwitchSavesLatestTextTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Keys typed in the Markdown editor in the instant before a switch to Rich Text were not saved. The switch reads the Markdown editor
//  first (`CodeMirrorCoordinator.saveAndNotify`), but that read refreshes only `editorState.sourceContent` (the text with the section
//  anchors in it); `editorState.content` (the same text with the anchors stripped) is refreshed by the page's own push, which runs 50 ms
//  after the last key (web/codemirror/src/main.ts). `handleEditorModeToggle` saved `content`, so keys typed in that last 50 ms never
//  reached the database, and the incoming Rich Text editor loads its document from the database.
//
//  The switch now goes through `EditorViewState.commitMarkdownTextForRichTextSwitch`, which strips the anchors from `sourceContent`
//  and saves and hands on THAT text. These tests drive it with the state at the moment of the switch: `content` is what the page last
//  pushed, `sourceContent` is what the read just returned. The first test fails against the old behaviour (saving `content`):
//  the typed words would be missing from the stored rows and from the text handed to Rich Text.
//

import Foundation
import Testing
@testable import final_final

@Suite("A Markdown to Rich Text switch saves the text just read from the editor — Tier 1: Silent Killers", .serialized)
@MainActor
struct MarkdownSwitchSavesLatestTextTests {

    private static let firstAnchor = "11111111-1111-1111-1111-111111111111"
    private static let secondAnchor = "22222222-2222-2222-2222-222222222222"
    private static let storedText = "# Chapter One\n\nThe first paragraph.\n\n# Chapter Two\n\nThe second paragraph."

    private struct Setup {
        let state: EditorViewState
        let db: ProjectDatabase
        let pid: String
    }

    private func makeState(storedText: String) throws -> Setup {
        let db = try TestFixtureFactory.createTemporary(content: storedText)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let state = EditorViewState()
        state.projectDatabase = db
        state.currentProjectId = pid
        return Setup(state: state, db: db, pid: pid)
    }

    private func savedText(_ db: ProjectDatabase, _ pid: String) throws -> String {
        BlockParser.assembleMarkdownForEditor(from: try db.fetchBlocks(projectId: pid))
    }

    @Test("keys typed after the page's last push are saved to the database and handed to Rich Text")
    func keysTypedJustBeforeTheSwitchAreSaved() throws {
        let setup = try makeState(storedText: Self.storedText)
        let (state, db, pid) = (setup.state, setup.db, setup.pid)
        let typed = " Words typed in the last fifty milliseconds."

        // The state at the moment of the switch. `content`: what the page last pushed (before those words). `sourceContent`: what the
        // pre-switch read of the Markdown editor just returned, section anchors included, with the words in it.
        state.content = Self.storedText
        state.sourceContent = "<!-- @sid:\(Self.firstAnchor) --># Chapter One\n\nThe first paragraph.\(typed)\n\n"
            + "<!-- @sid:\(Self.secondAnchor) --># Chapter Two\n\nThe second paragraph."

        state.commitMarkdownTextForRichTextSwitch(sectionSyncService: SectionSyncService())

        #expect(state.content.contains(typed), "the text handed to Rich Text must include the words typed just before the switch")
        #expect(!state.content.contains("@sid"), "the anchors are stripped from the text handed to Rich Text")
        #expect(state.sourceAnchors.count == 2, "both anchors were extracted for the switch back")
        let saved = try savedText(db, pid)
        #expect(
            saved.contains(typed),
            "the database must hold the words typed just before the switch: the incoming editor loads from it (saved: \(saved))")
        #expect(!saved.contains("@sid"), "no anchor reaches the database")
    }

    @Test("an unchanged Markdown text still writes nothing: every row keeps its id")
    func anUnchangedMarkdownTextWritesNothing() throws {
        let setup = try makeState(storedText: Self.storedText)
        let (state, db, pid) = (setup.state, setup.db, setup.pid)
        let before = try db.fetchBlocks(projectId: pid).sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
        let editorText = BlockParser.assembleMarkdownForEditor(from: before)

        state.content = editorText
        state.sourceContent = editorText

        state.commitMarkdownTextForRichTextSwitch(sectionSyncService: SectionSyncService())

        let after = try db.fetchBlocks(projectId: pid).sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
        #expect(after.map(\.id) == before.map(\.id), "no edit since the last save: nothing is written, so no row id changes")
        #expect(state.content == editorText)
    }
}
