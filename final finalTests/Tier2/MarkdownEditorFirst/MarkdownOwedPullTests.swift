//
//  MarkdownOwedPullTests.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 1, round 4, O29 and O31: the OWED PULL. Real writer, real
//  database, the REAL debounced re-parse scheduler (`MarkdownWriterRig.schedule`); the page is a stand-in that answers with the text
//  the user typed. The coordinator's drop sites are in `MarkdownContentPushDropTests`; the ContentView wiring (the idle hook, the
//  timer after the 150 ms grace) is shown by the VM run only.
//
//   T-U27  type during a rebuild, then stop: the dropped text is pulled at the next idle and the rows catch up with no further key.
//          BREAK: in `MarkdownOwedPull.runIfOwed` return `.notOwed` at once (no pull).    FAILS with: "rows behind editor at rest".
//   T-U29 run 1  a re-parse fire discarded ONLY because the content state was busy owes the pull; the pull then saves the stranded
//          keystroke with no further key. BREAK: delete the `notePullOwed` call at the discard site in
//          `ViewNotificationModifiers.scheduleFullDocumentReparse`.    FAILS with: "rows behind editor at rest".
//   T-U29 run 2  no other exit of that guard owes a pull: leaving Markdown mode, zoom, a lifecycle, a cancel, a newer generation, and a
//          fire HELD by a structural command (its refire waits for the release). BREAK: make `discardedFireOwesPull` return `true`
//          always.    FAILS with: "owed a pull for ...".
//   gates  a lifecycle, a project change, leaving Markdown and zoom never pull (and clear the flag); a busy state keeps the flag for the
//          next idle; a silent editor keeps it owed. BREAK: in `runIfOwed` drop the `.abandon` case's `takePullOwed()`.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import Testing
@testable import final_final

@Suite("Markdown owed pull — Tier 2 (t-4a8fd8af round 4, O29/O31)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MarkdownOwedPullTests {

    private static let base = "# Alpha\n\nOne.\n\n# Beta\n\nFour."
    private static let typed = "# Alpha\n\nOne, typed.\n\n# Beta\n\nFour."

    /// Runs the pull the way ContentView does, with the page standing in as `live`. The re-parse is armed through the real scheduler.
    private func pull(
        _ rig: MarkdownWriterRig, live: String?, gate: MarkdownOwedPull.Gate = .proceed
    ) async -> MarkdownOwedPull.Outcome {
        await MarkdownOwedPull.runIfOwed(
            writer: rig.markdownWriter,
            gate: { gate },
            readLive: { live },
            adopt: { rig.editorState.content = $0 },
            arm: { _ = rig.schedule(rig.editorState.content) })
    }

    // MARK: - T-U27

    @Test("T-U27: typing dropped during a rebuild is pulled at the next idle and saved with no further key")
    func droppedTypingIsPulledAndTheRowsCatchUp() async throws {
        let rig = try MarkdownWriterRig(content: Self.base)
        rig.editorState.contentState = .bibliographyUpdate     // the rebuild runs; the page's contentChanged is dropped
        rig.markdownWriter.notePullOwed("a page contentChanged was dropped")
        rig.editorState.contentState = .idle                   // the rebuild ends: the idle hook runs the pull

        let outcome = await pull(rig, live: Self.typed)
        await rig.editorState.blockReparseTask?.value          // the re-armed re-parse fires on its own debounce

        #expect(outcome == .pulled)
        #expect(rig.editorState.content == Self.typed, "the record did not take the page's live text")
        await rig.settle()
        #expect(try rig.storedText() == Self.typed, "rows behind editor at rest")
        #expect(!rig.markdownWriter.isPullOwed)
    }

    // MARK: - T-U29

    @Test("T-U29 run 1: a re-parse fire discarded because the content state was busy owes the pull, and the pull saves the stranded keystroke")
    func discardedFireOwesThePullAndThePullSavesTheKeystroke() async throws {
        let rig = try MarkdownWriterRig(content: Self.base)
        rig.editorState.contentState = .bibliographyUpdate     // a bibliography update is running when the 1 s timer fires
        let fire = rig.schedule(Self.typed)
        await fire?.value
        #expect(try rig.storedText() == Self.base, "premise: the busy fire wrote nothing")
        #expect(rig.markdownWriter.isPullOwed, "the discarded fire did not owe a pull")

        rig.editorState.contentState = .idle                   // the update ends; no further key
        _ = await pull(rig, live: Self.typed)
        await rig.editorState.blockReparseTask?.value
        await rig.settle()
        #expect(try rig.storedText() == Self.typed, "rows behind editor at rest")
    }

    @Test("T-U29 run 2: no other exit of the re-parse gate owes a pull")
    func otherExitsOweNothing() async throws {
        // The gate's three terms, as the fire reads them.
        #expect(MarkdownOwedPull.discardedFireOwesPull(contentIsIdle: false, isSourceMode: true, isZoomed: false))
        #expect(!MarkdownOwedPull.discardedFireOwesPull(contentIsIdle: false, isSourceMode: false, isZoomed: false),
                "owed a pull for a fire discarded after leaving Markdown mode")
        #expect(!MarkdownOwedPull.discardedFireOwesPull(contentIsIdle: false, isSourceMode: true, isZoomed: true),
                "owed a pull for a fire discarded while zoomed")
        #expect(!MarkdownOwedPull.discardedFireOwesPull(contentIsIdle: true, isSourceMode: true, isZoomed: false),
                "owed a pull for a fire the gate let through")

        // The same through the real scheduler: each exit, the content state busy at fire time.
        func owedAfterFire(_ prepare: (MarkdownWriterRig) -> Void) async throws -> Bool {
            let rig = try MarkdownWriterRig(content: Self.base)
            let fire = rig.schedule(Self.typed)               // scheduled in Markdown mode, idle
            rig.editorState.contentState = .bibliographyUpdate
            prepare(rig)
            await fire?.value
            return rig.markdownWriter.isPullOwed
        }
        let busyDiscard = try await owedAfterFire { _ in }
        let leftMarkdown = try await owedAfterFire { $0.editorState.editorMode = .wysiwyg }
        let zoomed = try await owedAfterFire { $0.editorState.zoomedSectionId = "zoomed-section" }
        let cancelled = try await owedAfterFire { $0.editorState.blockReparseTask?.cancel() }
        let superseded = try await owedAfterFire { $0.editorState.blockReparseGeneration += 1 }
        let lifecycle = try await owedAfterFire {
            $0.editorState.activeLifecycle = LifecycleToken(kind: .close, wasGettingStarted: false)   // a close armed since the schedule
        }
        let otherProject = try await owedAfterFire { $0.editorState.currentProjectId = "another-project" }
        #expect(!lifecycle, "owed a pull for a fire dropped by a lifecycle")
        #expect(!otherProject, "owed a pull for a fire dropped after a project change")
        #expect(busyDiscard, "control: the plain busy discard owes the pull")
        #expect(!leftMarkdown, "owed a pull for leaving Markdown mode")
        #expect(!zoomed, "owed a pull for a zoom")
        #expect(!cancelled, "owed a pull for a cancelled fire")
        #expect(!superseded, "owed a pull for a superseded fire")

        // A fire HELD by a structural command is not a discard: its refire waits for the release.
        let rig = try MarkdownWriterRig(content: Self.base)
        let hold = rig.markdownWriter.beginStructuralHold()
        defer {
            hold.release()
            rig.editorState.blockReparseTask?.cancel()   // the release re-armed the held fire; this test does not wait for it
        }
        let fire = rig.schedule(Self.typed)
        await fire?.value
        #expect(!rig.markdownWriter.isPullOwed, "owed a pull for a held fire")
    }

    // MARK: - The gates

    @Test("a lifecycle, a project change, leaving Markdown or a zoom never pull and clear the flag; a busy state keeps it for the next idle")
    func gatesDecideWhetherThePullRuns() async throws {
        let rig = try MarkdownWriterRig(content: Self.base)
        rig.markdownWriter.notePullOwed("test")
        let busy = await pull(rig, live: Self.typed, gate: .retryAtIdle)
        #expect(busy == .deferred)
        #expect(rig.markdownWriter.isPullOwed, "a busy state must keep the flag for the next idle")
        #expect(rig.editorState.content == Self.base, "nothing was adopted while busy")

        let gone = await pull(rig, live: Self.typed, gate: .abandon)
        #expect(gone == .abandoned)
        #expect(!rig.markdownWriter.isPullOwed, "an abandoned pull must clear the flag")
        #expect(rig.editorState.content == Self.base, "a pull after teardown must not adopt anything")

        #expect(await pull(rig, live: Self.typed) == .notOwed, "nothing owed, nothing pulled")
    }

    @Test("a silent editor keeps the pull owed, and a drop during the read owes a new one")
    func silentEditorKeepsThePullOwed() async throws {
        let rig = try MarkdownWriterRig(content: Self.base)
        rig.markdownWriter.notePullOwed("test")
        #expect(await pull(rig, live: nil) == .editorSilent)
        #expect(rig.markdownWriter.isPullOwed, "the editor did not answer: the pull is still owed")

        let outcome = await MarkdownOwedPull.runIfOwed(
            writer: rig.markdownWriter, gate: { .proceed },
            readLive: {
                rig.markdownWriter.notePullOwed("dropped during the read")
                return Self.typed
            },
            adopt: { rig.editorState.content = $0 }, arm: {})
        #expect(outcome == .pulled)
        #expect(rig.markdownWriter.isPullOwed, "a drop that happens during the read owes a new pull")
    }

    @Test("a project reset clears a pull owed to the old document")
    func resetClearsTheOwedPull() async throws {
        let rig = try MarkdownWriterRig(content: Self.base)
        rig.markdownWriter.notePullOwed("test")
        rig.markdownWriter.reset()
        #expect(!rig.markdownWriter.isPullOwed)
    }
}
