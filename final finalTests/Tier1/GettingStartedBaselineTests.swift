//
//  GettingStartedBaselineTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for the Getting Started false-edit-prompt fix: the loaded-content baseline is
//  captured lazily from the first editor-settled content event (not the pre-round-trip
//  Swift string), and only editor-originated syncs may set or check that baseline.
//  DocumentManager is a singleton (@MainActor, DocumentManager.swift:13-15), so this suite
//  is .serialized (mirrors ProjectLifecycleTests.swift's convention for the same singleton)
//  and each test saves/restores the GS fields around itself to avoid cross-test bleed.
//

import Testing
import Foundation
@testable import final_final

@Suite("Getting Started baseline capture — Tier 1: Silent Killers", .serialized)
struct GettingStartedBaselineTests {

    // MARK: - checkGettingStartedEdited baseline capture

    @Test("First settled event becomes the baseline, not an edit")
    @MainActor
    func firstSettledEventBecomesBaseline() {
        let dm = DocumentManager.shared
        let savedIsGS = dm.isGettingStartedProject
        let savedHash = dm.gettingStartedLoadedHash
        let savedEdited = dm.gettingStartedUserEdited
        defer {
            dm.isGettingStartedProject = savedIsGS
            dm.gettingStartedLoadedHash = savedHash
            dm.gettingStartedUserEdited = savedEdited
        }

        dm.isGettingStartedProject = true
        dm.gettingStartedLoadedHash = nil
        dm.gettingStartedUserEdited = false

        dm.checkGettingStartedEdited(currentMarkdown: "settled A")

        #expect(dm.isGettingStartedModified() == false, "The first settled call must adopt the baseline, not flag an edit")
        #expect(dm.gettingStartedLoadedHash != nil, "The baseline hash must now be captured")
    }

    @Test("Identical later content is not an edit")
    @MainActor
    func identicalLaterContentIsNotAnEdit() {
        let dm = DocumentManager.shared
        let savedIsGS = dm.isGettingStartedProject
        let savedHash = dm.gettingStartedLoadedHash
        let savedEdited = dm.gettingStartedUserEdited
        defer {
            dm.isGettingStartedProject = savedIsGS
            dm.gettingStartedLoadedHash = savedHash
            dm.gettingStartedUserEdited = savedEdited
        }

        dm.isGettingStartedProject = true
        dm.gettingStartedLoadedHash = nil
        dm.gettingStartedUserEdited = false

        dm.checkGettingStartedEdited(currentMarkdown: "settled A")
        dm.checkGettingStartedEdited(currentMarkdown: "settled A")

        #expect(dm.isGettingStartedModified() == false, "Re-syncing identical settled content must never flag an edit")
    }

    @Test("Different later content is a real edit")
    @MainActor
    func differentLaterContentIsARealEdit() {
        let dm = DocumentManager.shared
        let savedIsGS = dm.isGettingStartedProject
        let savedHash = dm.gettingStartedLoadedHash
        let savedEdited = dm.gettingStartedUserEdited
        let savedWindow = dm.gettingStartedBaselineWindow
        let savedCapturedAt = dm.gettingStartedBaselineCapturedAt
        defer {
            dm.isGettingStartedProject = savedIsGS
            dm.gettingStartedLoadedHash = savedHash
            dm.gettingStartedUserEdited = savedEdited
            dm.gettingStartedBaselineWindow = savedWindow
            dm.gettingStartedBaselineCapturedAt = savedCapturedAt
        }

        dm.isGettingStartedProject = true
        dm.gettingStartedLoadedHash = nil
        dm.gettingStartedUserEdited = false

        dm.checkGettingStartedEdited(currentMarkdown: "settled A")
        // Disable the baseline noise window -- these two calls happen back-to-back with no
        // elapsed time, and this test is specifically about a genuine edit being flagged,
        // not about the noise-window widening covered by
        // withinWindowDifferingSettleIsNotAnEdit below.
        dm.gettingStartedBaselineWindow = 0
        dm.checkGettingStartedEdited(currentMarkdown: "settled A plus user words")

        #expect(dm.isGettingStartedModified() == true, "Content differing from the settled baseline must flag a real edit")
    }

    @Test("A differing settle within the baseline window is noise, not an edit")
    @MainActor
    func withinWindowDifferingSettleIsNotAnEdit() {
        let dm = DocumentManager.shared
        let savedIsGS = dm.isGettingStartedProject
        let savedHash = dm.gettingStartedLoadedHash
        let savedEdited = dm.gettingStartedUserEdited
        let savedWindow = dm.gettingStartedBaselineWindow
        let savedCapturedAt = dm.gettingStartedBaselineCapturedAt
        defer {
            dm.isGettingStartedProject = savedIsGS
            dm.gettingStartedLoadedHash = savedHash
            dm.gettingStartedUserEdited = savedEdited
            dm.gettingStartedBaselineWindow = savedWindow
            dm.gettingStartedBaselineCapturedAt = savedCapturedAt
        }

        dm.isGettingStartedProject = true
        dm.gettingStartedLoadedHash = nil
        dm.gettingStartedUserEdited = false
        dm.gettingStartedBaselineWindow = 2.0

        dm.checkGettingStartedEdited(currentMarkdown: "settled A")
        // Simulate a second settle within the window (e.g. Milkdown's second
        // re-serialization pass) that differs from the first -- this is baseline noise,
        // not a user edit, and must be re-adopted as the new baseline rather than flagged.
        dm.checkGettingStartedEdited(currentMarkdown: "settled A (reformatted)")

        #expect(
            dm.isGettingStartedModified() == false,
            "A differing settle within the baseline window must be absorbed as noise, not flagged as an edit"
        )

        // The next settle after the window closes must still correctly flag a real edit.
        dm.gettingStartedBaselineWindow = 0
        dm.checkGettingStartedEdited(currentMarkdown: "settled A (reformatted) plus a real user edit")

        #expect(dm.isGettingStartedModified() == true, "A settle after the noise window closes must still flag a genuine edit")
    }

    @Test("Non-GS project is inert")
    @MainActor
    func nonGettingStartedProjectIsInert() {
        let dm = DocumentManager.shared
        let savedIsGS = dm.isGettingStartedProject
        let savedHash = dm.gettingStartedLoadedHash
        let savedEdited = dm.gettingStartedUserEdited
        defer {
            dm.isGettingStartedProject = savedIsGS
            dm.gettingStartedLoadedHash = savedHash
            dm.gettingStartedUserEdited = savedEdited
        }

        dm.isGettingStartedProject = false
        dm.gettingStartedLoadedHash = nil
        dm.gettingStartedUserEdited = false

        dm.checkGettingStartedEdited(currentMarkdown: "settled A")
        dm.checkGettingStartedEdited(currentMarkdown: "settled A plus user words")

        #expect(dm.isGettingStartedModified() == false, "A non-Getting-Started project must never be flagged as edited")
        #expect(dm.gettingStartedLoadedHash == nil, "A non-Getting-Started project must never capture a baseline")
    }

    // MARK: - fromEditorChange gating (addendum must-fix #2: the Save Version flush)
    //
    // handleSaveVersion() (Cmd+Shift+S) flushes via sectionSyncService.syncNow(...,
    // fromEditorChange: true) specifically so an edit that hasn't debounced yet still reaches
    // Getting Started edit-detection. These exercise that exact mechanism end-to-end through
    // SectionSyncService, not just the DocumentManager primitive the four tests above cover.

    @Test("syncNow(fromEditorChange: true) reaches Getting Started edit-detection — the Save Version fix")
    @MainActor
    func syncNowWithFromEditorChangeFlagsRealEdit() async throws {
        let dm = DocumentManager.shared
        let savedIsGS = dm.isGettingStartedProject
        let savedHash = dm.gettingStartedLoadedHash
        let savedEdited = dm.gettingStartedUserEdited
        let savedWindow = dm.gettingStartedBaselineWindow
        let savedCapturedAt = dm.gettingStartedBaselineCapturedAt
        defer {
            dm.isGettingStartedProject = savedIsGS
            dm.gettingStartedLoadedHash = savedHash
            dm.gettingStartedUserEdited = savedEdited
            dm.gettingStartedBaselineWindow = savedWindow
            dm.gettingStartedBaselineCapturedAt = savedCapturedAt
        }

        let baseline = "# Getting Started\n\nOriginal settled content."
        let db = try TestFixtureFactory.createTemporary(content: baseline)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let syncService = SectionSyncService()
        syncService.configure(database: db, projectId: projectId)

        dm.isGettingStartedProject = true
        dm.gettingStartedLoadedHash = nil
        dm.gettingStartedUserEdited = false

        // First editor-settled sync establishes the baseline, as contentChanged's debounce would.
        await syncService.syncNow(baseline, fromEditorChange: true)
        #expect(dm.isGettingStartedModified() == false, "First settled sync must adopt the baseline, not flag an edit")

        // User edits, then immediately triggers Save Version before the 500ms debounce fires —
        // handleSaveVersion's syncNow(fromEditorChange: true) must still flag it. Disable the
        // baseline noise window: these two syncs happen back-to-back with no elapsed time, and
        // this test is about a genuine edit being flagged, not the noise-window widening.
        dm.gettingStartedBaselineWindow = 0
        let edited = "# Getting Started\n\nOriginal settled content, plus a user edit."
        await syncService.syncNow(edited, fromEditorChange: true)

        #expect(dm.isGettingStartedModified() == true, "An immediate Save Version flush of real edited content must flag the edit")
    }

    @Test("syncNow's default fromEditorChange: false never touches Getting Started edit-detection")
    @MainActor
    func syncNowDefaultDoesNotTouchGettingStartedState() async throws {
        let dm = DocumentManager.shared
        let savedIsGS = dm.isGettingStartedProject
        let savedHash = dm.gettingStartedLoadedHash
        let savedEdited = dm.gettingStartedUserEdited
        defer {
            dm.isGettingStartedProject = savedIsGS
            dm.gettingStartedLoadedHash = savedHash
            dm.gettingStartedUserEdited = savedEdited
        }

        let baseline = "# Getting Started\n\nOriginal settled content."
        let db = try TestFixtureFactory.createTemporary(content: baseline)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let syncService = SectionSyncService()
        syncService.configure(database: db, projectId: projectId)

        dm.isGettingStartedProject = true
        dm.gettingStartedLoadedHash = nil
        dm.gettingStartedUserEdited = false

        // A programmatic sync (default fromEditorChange: false) — e.g.
        // configureForCurrentProject's initial "populate section table" call — must never
        // touch GS edit-detection at all, even on its very first call.
        await syncService.syncNow(baseline)

        #expect(dm.gettingStartedLoadedHash == nil, "A non-editor-originated sync must never capture the baseline")
        #expect(dm.isGettingStartedModified() == false)
    }
}
