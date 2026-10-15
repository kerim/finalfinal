//
//  MarkdownSwitchThenCloseTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C7a (slice-3a-1b-everyday.md section 7.2 "C7a", user steps 6 and 7): U7(b).
//
//  Rich Text -> Markdown -> switch to project B -> close B. Each project's database must end up with ITS OWN text:
//  B's database gets B's text (CodeMirror's), project A is left with the text the switch saved, and nothing of A's
//  Markdown content leaks into B through state that outlives the switch (the staged `switchInProgressContent`, the
//  retired writer, the flush-done marker).
//
//  Both lifecycles run through the REAL `ProjectCommands` and `LifecycleEntry.run` against one editor state, the way
//  the app does: the editor state, the block-sync service and the WebView survive the switch, the open tail
//  retires A's writer, resets the project state and re-points everything at B. The test host's open tail does
//  exactly that part (retire, reset, reconfigure for B); the real tail's reconfigure-and-push is the code the
//  deleted `handleProjectOpened` ran, now `ContentView.runOpenTail` (ContentView+LifecycleTails.swift), covered by
//  its own suites.
//
//  Item 32: both lifecycles assert their `.armed` event.
//

import Foundation
import Testing
@testable import final_final

extension LifecycleEntryStatic {
    @Suite("Markdown: switch to B, then close B — Tier 2 (t-94369a83 3a-1b C7a, U7(b))", .serialized, .timeLimit(.minutes(1)))
    @MainActor
    struct MarkdownSwitchThenCloseTests {

        private static let aSeed = "# Alpha\n\nA original paragraph.\n"
        private static let bSeed = "# Bravo\n\nB original paragraph.\n"
        private static let aTyped = "# Alpha\n\nFrom markdown seven.\n"
        private static let bTyped = "# Bravo\n\nIn B seven.\n"

        private func paragraphs(of database: ProjectDatabase) throws -> [String] {
            try TestFixtureFactory.fetchBlocks(from: database).filter { $0.blockType == .paragraph }.map(\.textContent)
        }

        @Test("""
            U7(b): Rich Text -> Markdown -> switch to B -> close B: A keeps the sentence typed in A, B's database gets \
            B's text, and neither project receives the other's
            """)
        func markdownSwitchThenClose_eachProjectKeepsItsOwnText() async throws {
            let rig = try LifecycleFlushHarness(content: Self.aSeed)
            let dbA = rig.db
            let dbB = try TestFixtureFactory.createTemporary(content: Self.bSeed)
            let pidB = try TestFixtureFactory.getProjectId(from: dbB)
            let view = try #require(rig.webView)

            // Rich Text -> Markdown: the user toggles the editor in project A, then types in CodeMirror.
            #expect(rig.editorState.editorMode == .wysiwyg, "precondition: the project starts in Rich Text")
            rig.editorState.editorMode = .source
            rig.fetchAnswer = Self.aTyped

            // The host the app installs, with the open and close tails reduced to the part that changes who owns the
            // editor: retire the old writer (releasing the barrier), reset the project state, point at the next project.
            var host = rig.host
            host.runOpenTail = { _ in
                rig.note("tail:open")
                rig.editorState.retireForLifecycle(reason: .projectSwitch)
                rig.editorState.resetForProjectSwitch()
                rig.sync.configure(database: dbB, projectId: pidB, webView: view)   // a NEW writer for B
                rig.editorState.projectDatabase = dbB
                rig.editorState.currentProjectId = pidB
                rig.editorState.content = Self.bSeed
            }
            host.runCloseTail = { _, _ in
                rig.note("tail:close")
                rig.editorState.retireForLifecycle(reason: .close)
                rig.editorState.resetForProjectSwitch()
            }
            let recorder = ProjectCommandRecorder()
            var switchResult: ProjectCommandResult?
            var closeResult: ProjectCommandResult?
            var aAfterSwitch: [String] = []
            var stagedAfterSwitch: String?

            try await rig.withEntry {
                rig.editorState.lifecycleHost = host

                // Switch to B (Cmd-O): saves A through the queue in Markdown mode, then B opens.
                switchResult = await ProjectCommands.open(url: URL(fileURLWithPath: "/tmp/u7b-b.ff"), recorder.environment)
                aAfterSwitch = try paragraphs(of: dbA)
                stagedAfterSwitch = rig.editorState.switchInProgressContent

                // The user types in B (still Markdown), then closes it (Cmd-W).
                rig.fetchAnswer = Self.bTyped
                rig.editorState.content = Self.bSeed
                closeResult = await ProjectCommands.close(recorder.environment)
            }

            #expect(rig.entryEvents == [.armed(.projectSwitch), .armed(.close)], "both lifecycles ran guarded (item 32)")
            #expect(switchResult == .lifecycle(.performed))
            #expect(closeResult == .lifecycle(.performed))
            #expect(rig.log.filter { $0.hasPrefix("tail:") } == ["tail:open", "tail:close"], "log: \(rig.log)")

            // A: the switch saved CodeMirror's text, and B's close never touched A.
            #expect(aAfterSwitch.contains("From markdown seven."), "the switch must save A's Markdown text; got \(aAfterSwitch)")
            let aFinal = try paragraphs(of: dbA)
            #expect(aFinal == aAfterSwitch, "closing B must leave A exactly as the switch saved it; got \(aFinal)")
            #expect(!aFinal.contains("In B seven."))
            #expect(!aFinal.contains("B original paragraph."))

            // B: its own text, nothing of A.
            let bFinal = try paragraphs(of: dbB)
            #expect(bFinal.contains("In B seven."), "B's close must write B's text; got \(bFinal)")
            #expect(!bFinal.contains("From markdown seven."), "A's Markdown text must not leak into B; got \(bFinal)")
            #expect(!bFinal.contains("A original paragraph."))
            #expect(!bFinal.contains("B original paragraph."), "B's old text is replaced by what was typed; got \(bFinal)")

            // Nothing left staged or armed, no loss counted on either writer.
            #expect(stagedAfterSwitch == nil, "the staged Markdown text of A must not outlive the switch")
            #expect(rig.editorState.activeLifecycle == nil)
            #expect(rig.editorState.lifecycleBarrier == nil)
            #expect(!rig.entryEvents.contains(.safetyNetReleasedBarrier), "both tails retired the writer themselves")
            #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentLost == 0)
        }
    }
}
