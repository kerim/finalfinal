//
//  MarkdownLifecycleSourceTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C4 (slice-3a-1b-everyday.md sections 4.2, 5.3 and 7.2 "C4"): the MARKDOWN
//  (source mode) branch of the lifecycle save sequence, `EditorViewState.runLifecycleFlush` with
//  `editorMode == .source`.
//
//  What F means in Markdown: nothing is polled from CodeMirror (block-sync's poll belongs to the Milkdown
//  editor) and the debounced re-parse that would have written its edits was cancelled at step 0, so there is NO
//  drain and NO forced poll. The fresh fetch at step 5 reads CodeMirror's live document itself, through the
//  CAPTURED view, and FB writes that.
//
//    - U7(a): a Markdown quit writes CodeMirror's text, fetched from the captured (active) view, never the
//      Milkdown view's and never through a Rich Text poll
//    - U7(c): writer nil (a launch straight into Markdown): the same body runs directly, the barrier is skipped,
//      the sequence is `.flushed` and `perform` is called (#2)
//    - U7(d): a fetch that answers nothing falls back to `editorState.content`
//    - N28: an empty answer is valid: no FB, no fallback to the stale content, the database untouched
//    - the bibliography marker is stripped from the fetched text, which is staged into `switchInProgressContent`
//      (as `flushAllPendingContent` does); a cancelled or failed lifecycle drops it again
//    - a quit with a section operation still running writes nothing in Markdown (parked P4) and still reaches
//      the barrier
//    - a zoomed Markdown close writes only the zoomed range
//
//  Harness: `LifecycleFlushHarness` (Helpers/). The entry-level tests nest under `LifecycleEntryStatic`, the
//  serialized parent of every suite that touches `LifecycleEntry`'s process-global state.
//

import Foundation
import Testing
import WebKit
@testable import final_final

/// Records which WebView each `evaluateJS` call of the block-sync service was made against.
@MainActor
private final class EvaluatedViewRecorder {
    var views: [ObjectIdentifier] = []
}

private struct MarkdownBoom: Error, Equatable {}

@Suite("Lifecycle save sequence, Markdown branch — Tier 1 (t-94369a83 3a-1b C4)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MarkdownLifecycleSourceTests {

    /// What CodeMirror's live document says (the user typed it a moment ago).
    private static let codeMirrorText = "# Alpha\n\nCODEMIRROR typed paragraph.\n\n# Beta\n\nfour five six.\n"

    private func sourceRig(content: String = LifecycleFlushHarness.seed) throws -> LifecycleFlushHarness {
        let rig = try LifecycleFlushHarness(content: content)
        rig.editorState.editorMode = .source
        return rig
    }

    // MARK: - U7(a)

    @Test("""
        U7(a): a Markdown quit writes CodeMirror's text, fetched from the captured (active) view -- never the \
        Milkdown view's text, and never through a Rich Text poll
        """)
    func markdownQuit_writesCodeMirrorsText_notMilkdowns() async throws {
        let rig = try sourceRig()
        // The host's active view is CodeMirror's; the block-sync service's own view (`rig.webView`) stays the
        // Milkdown stand-in. They are different objects.
        let codeMirror = LifecycleFlushHarness.makeView()
        rig.swapHostView(to: codeMirror)
        let milkdown = try #require(rig.webView)
        let milkdownId = ObjectIdentifier(milkdown)
        let codeMirrorId = ObjectIdentifier(codeMirror)
        #expect(milkdownId != codeMirrorId, "precondition: two different views")
        rig.editorState.content = "# Alpha\n\nMILKDOWN stale paragraph.\n\n# Beta\n\nfour five six.\n"
        rig.fetchAnswer = Self.codeMirrorText
        let seen = EvaluatedViewRecorder()
        rig.sync.testJSWebViewObserver = { view in seen.views.append(ObjectIdentifier(view)) }

        let result = await rig.run(.quit)

        #expect(result.outcome == .flushed)
        #expect(result.fetchedContent == Self.codeMirrorText)
        #expect(!result.usedFallback)
        #expect(!seen.views.isEmpty, "precondition: the fetch reached the JS layer")
        #expect(seen.views.allSatisfy { $0 == codeMirrorId }, "every JS call must go to the CAPTURED view (CodeMirror)")
        #expect(!seen.views.contains(milkdownId), "the block-sync service's own (Milkdown) view must never be asked")
        #expect(!rig.log.contains("poll"), "Markdown has no F: no drain and no forced poll; log: \(rig.log)")
        let texts = try rig.paragraphTexts()
        #expect(texts.contains("CODEMIRROR typed paragraph."), "FB must write CodeMirror's text; got \(texts)")
        #expect(!texts.contains("MILKDOWN stale paragraph."))
        #expect(!texts.contains("one two three."), "the stale seed paragraph must be gone; got \(texts)")
        #expect(result.fbOutcome == .applied)
        #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentApplied == 1)
        #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentLost == 0)
        #expect(result.barrier == .waited(.reached), "the writer exists, so the barrier is held and reached")
        #expect(rig.barrierSeqHeldAtReturn != nil, "the barrier is left held for the caller (quit holds it to exit)")
    }

    // MARK: - U7(c)

    @Test("""
        U7(c): Markdown with NO writer (a launch straight into Markdown): FB is written directly, the barrier is \
        skipped, and the sequence is .flushed
        """)
    func markdownWriterNil_isWrittenDirectly_andFlushed() async throws {
        let rig = try sourceRig()
        rig.fetchAnswer = Self.codeMirrorText
        // A block-sync service that was never configured: it has no writer.
        let noWriter = BlockSyncService()
        noWriter.testJSEvaluator = rig.sync.testJSEvaluator
        rig.editorState.blockSyncService = noWriter
        #expect(noWriter.testWriterHandle == nil, "precondition: no writer")

        let result = await rig.run(.close)

        #expect(result.outcome == .flushed)
        #expect(result.barrier == .skippedNoWriter, "no writer: the barrier is skipped, not refused")
        #expect(result.fbStatus == .started)
        #expect(result.fbSettledOutcome == .appliedDirectly)
        #expect(try rig.paragraphTexts().contains("CODEMIRROR typed paragraph."), "FB was written directly")
        #expect(rig.barrierSeqHeldAtReturn == nil, "there was nothing to hold")
        withExtendedLifetime(noWriter) {}
    }

    // MARK: - U7(d), N28

    @Test("U7(d): when the CodeMirror fetch answers nothing, the content on hand (editorState.content) is what FB writes")
    func markdownFetchAnswersNothing_usesEditorStateContent() async throws {
        let rig = try sourceRig()
        rig.editorState.content = "# Alpha\n\nON-HAND paragraph.\n\n# Beta\n\nfour five six.\n"
        rig.fetchAnswer = nil

        let result = await rig.run(.close)

        #expect(result.outcome == .flushed)
        #expect(result.usedFallback)
        #expect(result.fetchedContent == nil)
        #expect(result.fbOutcome == .applied)
        let texts = try rig.paragraphTexts()
        #expect(texts.contains("ON-HAND paragraph."), "the fallback content must be written; got \(texts)")
        #expect(!texts.contains("one two three."))
    }

    @Test("""
        N28: an EMPTY CodeMirror answer is valid -- no FB, no fallback to the stale content, and the database is \
        left as it was (the content on hand is non-empty, so a fallback would have written it back)
        """)
    func markdownEmptyAnswer_isValid_noFallback_noWrite() async throws {
        let rig = try sourceRig()
        rig.fetchAnswer = ""
        #expect(!rig.editorState.content.isEmpty, "precondition: non-empty content on hand, or the test is vacuous")
        let before = try rig.paragraphTexts()

        let result = await rig.run(.close)

        #expect(result.outcome == .flushed)
        #expect(result.fetchedContent == "")
        #expect(!result.usedFallback, "an empty answer is an answer, not a failed fetch")
        #expect(result.fbStatus == .skippedEmptyContent)
        #expect(try rig.paragraphTexts() == before, "nothing may be written, least of all the stale content")
        #expect(rig.editorState.switchInProgressContent == "",
                "an empty answer is staged as empty, so a no-override flush writes nothing instead of the stale text")
    }

    @Test("""
        N28 in Markdown: an empty answer also skips step 7 -- FB wrote nothing and there is no F to clear the \
        blocks, so deriving from "" would delete the footnote definitions while the body stays
        """)
    func markdownEmptyAnswer_doesNotDeriveFromNothing() async throws {
        let seed = "Body[^1] text.\n\n# Notes\n\n[^1]: Typed definition one.\n"
        let rig = try sourceRig(content: seed)
        let footnotes = rig.attachFootnoteService()
        rig.fetchAnswer = ""
        #expect(try rig.notesDefinitions().keys.sorted() == ["1"], "precondition: [^1] has a definition row")

        let result = await rig.run(.close)

        #expect(result.fbStatus == .skippedEmptyContent)
        #expect(result.footnoteRefresh == .notRun, "step 7 must not run over an empty Markdown document")
        #expect(try rig.notesDefinitions().keys.sorted() == ["1"], "the definition row must survive")
        withExtendedLifetime(footnotes) {}
    }

    // MARK: - Marker and staging

    @Test("""
        the bibliography marker is stripped from CodeMirror's answer, and the answer is staged into \
        switchInProgressContent (Rich Text stages nothing)
        """)
    func markerIsStripped_andTheFreshTextIsStaged() async throws {
        let marker = "<!-- ::auto-bibliography:: -->"
        let withMarker = "# Alpha\n\nfresh paragraph.\n\n\(marker)\n\n# Beta\n\nfour five six.\n"
        let rig = try sourceRig()
        rig.fetchAnswer = withMarker
        #expect(rig.editorState.switchInProgressContent == nil, "precondition")

        let result = await rig.run(.close)

        let fetched = try #require(result.fetchedContent)
        #expect(!fetched.contains(marker), "the marker must be stripped; got \(fetched)")
        #expect(fetched == SectionSyncService.stripBibliographyMarker(from: withMarker))
        #expect(rig.editorState.switchInProgressContent == fetched, "staged as flushAllPendingContent stages")
        #expect(try rig.paragraphTexts().contains("fresh paragraph."))

        // Control: the same run in Rich Text stages nothing.
        let richText = try LifecycleFlushHarness()
        richText.js.answer("flushPendingBlockChanges", true)
        richText.fetchAnswer = withMarker
        _ = await richText.run(.close)
        #expect(richText.editorState.switchInProgressContent == nil, "Rich Text does not stage")
    }

    // MARK: - Quit with a section operation running (parked P4)

    @Test("""
        a Markdown QUIT whose section operation never clears writes nothing (there is no F in Markdown, and FB \
        would undo the operation), does not even fetch, and still reaches the barrier
        """)
    func markdownQuit_operationStillRunning_writesNothing() async throws {
        let rig = try sourceRig()
        rig.fetchAnswer = Self.codeMirrorText
        rig.controller.testSetIsPerforming(true)
        defer { rig.controller.testSetIsPerforming(false) }
        let before = try rig.paragraphTexts()

        let result = await rig.run(.quit, bounds: LifecycleBounds.production.scaled(0.1))

        #expect(result.opStillRunning)
        #expect(result.fbStatus == .skippedOpStillRunning)
        #expect(!rig.log.contains("fetch"), "no fetch: nothing would be written; log: \(rig.log)")
        #expect(!rig.log.contains("poll"))
        #expect(try rig.paragraphTexts() == before)
        #expect(result.barrier == .waited(.reached), "the barrier is step 8 and still runs")
    }

    // MARK: - Zoomed

    @Test("a zoomed Markdown close writes only the zoomed range: the other sections are untouched")
    func zoomedMarkdownClose_writesOnlyTheZoomedRange() async throws {
        let rig = try sourceRig()
        let alpha = try #require(try rig.blocks().first { $0.blockType == .heading && $0.textContent == "Alpha" })
        let beta = try #require(try rig.blocks().first { $0.blockType == .heading && $0.textContent == "Beta" })
        rig.editorState.zoomedSectionId = alpha.id
        rig.editorState.zoomedBlockRange = (start: alpha.sortOrder, end: beta.sortOrder)
        rig.fetchAnswer = "# Alpha\n\nzoomed edit.\n"

        let result = await rig.run(.close)

        #expect(result.outcome == .flushed)
        #expect(result.fbOutcome == .applied)
        let texts = try rig.paragraphTexts()
        #expect(texts.contains("zoomed edit."), "got \(texts)")
        #expect(texts.contains("four five six."), "Beta lies outside the zoom and must be untouched; got \(texts)")
        #expect(!texts.contains("one two three."), "the zoomed section's old text is replaced; got \(texts)")
    }
}

extension LifecycleEntryStatic {
    @Suite("Lifecycle entry, Markdown — Tier 1 (t-94369a83 3a-1b C4)", .serialized, .timeLimit(.minutes(1)))
    @MainActor
    struct MarkdownLifecycleEntryTests {

        @Test("U7(c) through the entry: Markdown with no writer, perform IS called once and the tail runs")
        func markdownWriterNil_performIsCalled() async throws {
            let rig = try LifecycleFlushHarness()
            rig.editorState.editorMode = .source
            rig.fetchAnswer = "# Alpha\n\nCODEMIRROR typed paragraph.\n\n# Beta\n\nfour five six.\n"
            let noWriter = BlockSyncService()
            noWriter.testJSEvaluator = rig.sync.testJSEvaluator
            rig.editorState.blockSyncService = noWriter
            var performed = 0

            try await rig.withEntry {
                let outcome = try await LifecycleEntry.run(kind: .close) {
                    performed += 1
                    return .close
                }
                #expect(outcome == .performed)
            }

            #expect(rig.entryEvents.first == .armed(.close), "the guard path ran (item 32)")
            #expect(performed == 1, "no writer must NOT stop the close (#2)")
            #expect(rig.log.contains("tail:close"))
            #expect(try rig.paragraphTexts().contains("CODEMIRROR typed paragraph."), "FB was written directly")
            #expect(rig.editorState.lifecycleBarrier == nil)
            #expect(rig.editorState.activeLifecycle == nil)
            withExtendedLifetime(noWriter) {}
        }

        @Test("""
            a Markdown lifecycle whose perform throws drops the staged text: the editor stays open, and a later \
            no-override flush must not write the stale text over new typing
            """)
        func markdownPerformThrows_dropsTheStagedContent() async throws {
            let rig = try LifecycleFlushHarness()
            rig.editorState.editorMode = .source
            let fresh = "# Alpha\n\nCODEMIRROR typed paragraph.\n\n# Beta\n\nfour five six.\n"
            rig.fetchAnswer = fresh
            var stagedInsidePerform: String?

            await rig.withEntry {
                await #expect(throws: MarkdownBoom.self) {
                    try await LifecycleEntry.run(kind: .close) {
                        stagedInsidePerform = rig.editorState.switchInProgressContent
                        throw MarkdownBoom()
                    }
                }
            }

            #expect(rig.entryEvents.first == .armed(.close), "the guard path ran (item 32)")
            #expect(stagedInsidePerform == fresh, "positive control: step 5 staged the fresh text before perform ran")
            #expect(rig.editorState.switchInProgressContent == nil, "and it must be gone once the lifecycle failed")
            #expect(rig.editorState.activeLifecycle == nil)
        }
    }
}
