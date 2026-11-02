//
//  MarkdownWriterLifecycleOrderTests.swift
//  final finalTests
//
//  t-94369a83 Phase 4a, plan v2 section 3, tests U3 (b) and (c), with judge verdict 2 note C1 and review M5: how the
//  per-block Markdown save and a close / switch / quit (the lifecycle) order themselves on the one write queue.
//
//    - (b) a Markdown write reserved BEFORE a lifecycle arms is applied before the lifecycle's own whole-document
//          save (FB), and nothing Markdown is reserved or applied after it
//    - C1  the reservation is synchronous with the fire's gate check: a lifecycle armed in the same main-actor turn as
//          a scheduled fire never lets that fire reserve anything behind FB
//    - (c) a lifecycle that arms while `writeNow` waits for the write in flight: no reservation, and the bibliography
//          update that called it carries on, as it does today when a guard fails (in MarkdownBibliographyFlushTests)
//    - M5  every guard of the bibliography flush is re-checked AFTER that wait: each one, broken during the wait, stops
//          the write (nothing reserved, nothing written)
//
//  "Applied before FB" is shown by what a write applied AFTER FB would look like: FB moves the project's write epoch, so a
//  Markdown batch applied behind it would be refused whole (`markdownStaleEpochRejections`, `outcome=stale-epoch`).
//

import Foundation
import SwiftUI
import Testing
@testable import final_final

@Suite("Markdown writes and the lifecycle — Tier 2 (t-94369a83 Phase 4a, U3 b c, C1, M5)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MarkdownWriterLifecycleOrderTests {

    private static let base = "# Alpha\n\nOne.\n\nTwo.\n\n# Beta\n\nFour."
    private static let typed = base.replacingOccurrences(of: "One.", with: "One, typed.")
    private static let fetched = base.replacingOccurrences(of: "Two.", with: "Two, newest.")

    private func sourceRig() throws -> LifecycleFlushHarness {
        let rig = try LifecycleFlushHarness(content: Self.base)
        rig.editorState.editorMode = .source
        rig.editorState.sourceReparseDebounce = .milliseconds(30)
        return rig
    }

    private func settle(_ rig: LifecycleFlushHarness) async {
        while let pending = rig.editorState.markdownWriter.inFlight {
            await pending.value
        }
    }

    /// The real scheduler, pointed at the rig's project for the one synchronous call (see `MarkdownWriterRig.schedule`).
    private func schedule(_ rig: LifecycleFlushHarness, _ text: String) -> Task<Void, Never>? {
        rig.editorState.content = text
        let documentManager = DocumentManager.shared
        let priorDatabase = documentManager.projectDatabase
        let priorProjectId = documentManager.projectId
        documentManager.projectDatabase = rig.db
        documentManager.projectId = rig.pid
        defer {
            documentManager.projectDatabase = priorDatabase
            documentManager.projectId = priorProjectId
        }
        let services = ContentSyncServices(
            sectionSync: SectionSyncService(),
            annotationSync: AnnotationSyncService(),
            bibliographySync: BibliographySyncService(),
            footnoteSync: FootnoteSyncService(),
            autoBackup: AutoBackupService(),
            documentManager: documentManager,
            scanMemo: MarkdownScanMemo()
        )
        ContentSyncObserverHost<EmptyView>.scheduleSourceModeReparse(
            newValue: text, editorState: rig.editorState, services: services)
        return rig.editorState.blockReparseTask
    }

    // MARK: - (b) a write reserved before the lifecycle arms lands before FB

    @Test("""
        (b)/C1 a Markdown write reserved in the same main-actor turn the lifecycle arms in is applied BEFORE FB: it is not refused \
        for a stale epoch, FB's later text is what ends up stored, and FB's sequence is behind the write's
        """)
    func aWriteReservedBeforeTheLifecycleArmsLandsBeforeFB() async throws {
        let rig = try sourceRig()
        rig.editorState.content = Self.typed
        let reservedAt = rig.sync.testWriterHandle?.nextSequence ?? 0

        // The fire and the lifecycle's arming, one main-actor turn: the reservation is already made when the token is.
        let disposition = rig.editorState.markdownWriter.prepareAndStart(
            text: Self.typed, database: rig.db, projectId: rig.pid, service: rig.sync, refire: {})
        #expect(disposition == .started)
        #expect(rig.sync.testWriterHandle?.nextSequence == reservedAt + 1, "the sequence was reserved synchronously")
        rig.fetchAnswer = Self.fetched
        let result = await rig.run(.close)
        await settle(rig)

        #expect(result.outcome == .flushed)
        #expect(result.fbOutcome == .applied)
        let ledger = rig.sync.testWriterLedger
        #expect(ledger.markdownStaleEpochRejections == 0, "applied before FB: a write behind FB would have been refused whole")
        #expect(rig.editorState.markdownWriter.lastTimingLine?.contains("outcome=applied") == true)
        #expect(ledger.skippedConsumed == 0 && ledger.discardedAfterFetch == 0 && ledger.failedWrites == 0)
        let fbApplied = rig.writerEvents.events.compactMap { event -> UInt64? in
            if case .systemApplied(let seq) = event { return seq }
            return nil
        }
        #expect(fbApplied.contains { $0 > reservedAt }, "FB's sequence is behind the Markdown write's")
        #expect(try rig.paragraphTexts().contains("Two, newest."), "FB's text is what the project ends up holding")
        #expect(try !rig.paragraphTexts().contains("One, typed."), "and FB, being later, replaced the typed text with its own")
    }

    @Test("""
        C1 a lifecycle armed in the same main-actor turn as a SCHEDULED fire: the fire reserves nothing (no `[MdWrite]` line, no \
        sequence, FB's text is the final state)
        """)
    func aFireScheduledInTheSameTurnAsTheArmingReservesNothing() async throws {
        let rig = try sourceRig()
        rig.fetchAnswer = Self.fetched
        let fire = try #require(schedule(rig, Self.typed), "precondition: the fire was scheduled while idle")

        let result = await rig.run(.close)   // arms in the same turn, before the fire's sleep can end
        let sequenceAfterRun = rig.sync.testWriterHandle?.nextSequence
        await fire.value
        await settle(rig)

        #expect(result.outcome == .flushed)
        #expect(rig.editorState.markdownWriter.lastTimingLine == nil, "the fire never reached the write step")
        #expect(rig.sync.testWriterHandle?.nextSequence == sequenceAfterRun, "no Markdown reservation after FB")
        #expect(rig.sync.testWriterLedger.markdownStaleEpochRejections == 0)
        #expect(try rig.paragraphTexts().contains("Two, newest."))
        #expect(try !rig.paragraphTexts().contains("One, typed."))
    }

    // (c), a lifecycle arming while the bibliography update's `writeNow` waits, runs the REAL bibliography update, which needs
    // the process-wide Zotero singleton: it lives in `MarkdownBibliographyFlushTests`, the one serialized suite that owns it.

    // MARK: - M5: each guard, re-checked after the wait

    enum Guard: String, CaseIterable, CustomTestStringConvertible {
        case lifecycleArmed, contentNotIdle, richTextMode, zoomed, projectChanged
        var testDescription: String { rawValue }

        @MainActor
        func breakIt(_ editorState: EditorViewState) {
            switch self {
            case .lifecycleArmed: _ = editorState.armLifecycle(.close, wasGettingStarted: false)
            case .contentNotIdle: editorState.contentState = .bibliographyUpdate
            case .richTextMode: editorState.editorMode = .wysiwyg
            case .zoomed: editorState.zoomedSectionId = "some-section"
            case .projectChanged: editorState.currentProjectId = "another-project"
            }
        }
    }

    @Test("(M5) each guard of the bibliography flush, broken while `writeNow` waits for the write in flight, stops it", arguments: Guard.allCases)
    func everyGuardIsRecheckedAfterTheWait(_ broken: Guard) async throws {
        let rig = try MarkdownWriterRig(content: Self.base)
        let parked = rig.parkedSignal()
        let held = rig.hold()
        #expect(rig.fire(Self.typed) == .started)
        await parked.wait()
        let sequenceBefore = rig.writer.nextSequence
        let newer = Self.typed.replacingOccurrences(of: "Four.", with: "Four, newest.")
        rig.editorState.content = newer

        let flush = Task { @MainActor in await rig.writeNow() }
        await Task.yield()
        await Task.yield()
        broken.breakIt(rig.editorState)
        await rig.release(held)
        let outcome = await flush.value
        await rig.settle()

        #expect(outcome == .abandoned, "the guard (\(broken)) failed after the wait: nothing is written and the update continues")
        #expect(rig.writer.nextSequence == sequenceBefore, "nothing reserved after the wait")
        #expect(try rig.storedText().contains("One, typed."), "write 1 landed")
        #expect(try !rig.storedText().contains("Four, newest."), "the newer text did not")
    }
}
