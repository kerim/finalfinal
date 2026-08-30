//
//  OutlineRefreshStalenessTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Guards `refreshSectionsAwaiting()` against a stale-fetch-wins race: it does two
//  `await`s (fetchOutlineBlocks, fetchBatchWordCounts) before merging into `sections`.
//  If some other write to `sections` (the live observation loop, a structural-undo
//  sequence, hierarchy enforcement) lands while this fetch is suspended, applying the
//  fetch's now-stale result afterward would merge superseded outline blocks/word counts
//  back over the newer data, and re-arm the outline equality cache with the stale set --
//  causing the sidebar to briefly flash superseded headings/word counts.
//

import Testing
import Foundation
@testable import final_final

@MainActor
@Suite("Outline Refresh Staleness — Tier 1: Silent Killers")
struct OutlineRefreshStalenessTests {

    private func heading(_ id: String, _ order: Double, level: Int = 1,
                         text: String = "Title") -> Block {
        Block(id: id, projectId: "p", sortOrder: order, blockType: .heading,
              textContent: text,
              markdownFragment: String(repeating: "#", count: level) + " " + text,
              headingLevel: level)
    }

    private func counts(_ pairs: [String: Int]) -> [String: ProjectDatabase.HeadingWordCounts] {
        pairs.mapValues { .init(sectionOnly: $0, aggregate: $0) }
    }

    @Test("A refresh overtaken by a newer apply must not merge its stale blocks back")
    func staleRefreshDoesNotOverwriteNewerApply() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Stale Heading\n\nBody text.")
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let state = EditorViewState()
        state.projectDatabase = db
        state.currentProjectId = pid

        let generationBeforeRefresh = state.outlineGeneration
        let refresh = Task { @MainActor in await state.refreshSectionsAwaiting() }
        await Task.yield()

        // MUST-FIX 2: prove the interleave actually happened -- if `sections` is already
        // non-empty here, the refresh finished and applied its (stale) result before the
        // newer apply below ever runs, so the race this test targets never occurred and it
        // must fail loudly rather than pass silently.
        #expect(state.sections.isEmpty, "setup didn't interleave -- refresh already landed before the newer apply")

        let newer = [heading("newer-1", 0, level: 1, text: "Newer Heading")]
        let newerCounts = counts(["newer-1": 42])
        state.applySectionsUpdate(from: newer, counts: newerCounts)

        await refresh.value

        #expect(state.sections.map(\.title) == ["Newer Heading"])
        #expect(state.isOutlineUnchanged(blocks: newer, counts: newerCounts) == true)
    }

    @Test("A later refresh's freshly-fetched data wins even when an earlier-started refresh resumes after it")
    func laterRefreshWinsOverEarlierLateLander() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Original Heading\n\nBody text.")
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let state = EditorViewState()
        state.projectDatabase = db
        state.currentProjectId = pid

        // First refresh: starts, captures its generation snapshot, and begins its DB fetch --
        // but hasn't landed yet.
        let first = Task { @MainActor in await state.refreshSectionsAwaiting() }
        await Task.yield()

        // Prove the interleave actually happened, same as the single-refresh test above: if
        // `sections` is already non-empty here, `first` already landed before the DB change
        // and the second refresh below, so the race this test targets never occurred.
        #expect(state.sections.isEmpty, "setup didn't interleave -- first refresh already landed")

        // Change the DB out from under the first refresh's still-pending fetch. `heading()`
        // hardcodes projectId "p" (fine for the in-memory-only `applySectionsUpdate` test
        // above), but `replaceBlocks` is a real DB write enforcing a FK against the actual
        // project row, so the block written here must carry the real `pid`.
        var newerBlock = heading("newer-1", 0, level: 1, text: "Newer Heading")
        newerBlock.projectId = pid
        let newer = [newerBlock]
        try db.replaceBlocks(newer, for: pid)

        // Second, later-started refresh. Because `refreshSectionsAwaiting()` serializes into a
        // chain, this call's own DB fetch cannot start until `first` has fully completed
        // (fetched AND applied) -- so it is guaranteed to observe whatever is freshest in the
        // DB at that point, and never races `first` for who lands first.
        let second = Task { @MainActor in await state.refreshSectionsAwaiting() }

        await first.value
        await second.value

        #expect(state.sections.map(\.title) == ["Newer Heading"])
        // Proves the drop path was never hit -- not just that the final state happens to look
        // right. Under the old (non-chained) implementation this could be nonzero: a
        // later-started-but-faster-landing refresh could win the generation check first,
        // causing the other (freshest-data) refresh to be wrongly discarded as "stale" once it
        // finally landed.
        #expect(state.staleRefreshDropCount == 0)
    }

    @Test("A refresh that bails early (no db/pid) does not wedge the chain for later refreshes")
    func bailingRefreshDoesNotWedgeChain() async throws {
        let state = EditorViewState()
        // No `projectDatabase`/`currentProjectId` set -- this call takes the early-bail path
        // inside `performSectionsRefresh`, before ever touching the chain's DB-fetch machinery.
        await state.refreshSectionsAwaiting()
        #expect(state.sections.isEmpty)
        #expect(state.staleRefreshDropCount == 0)

        // Wire up a real project and confirm a subsequent refresh still completes normally --
        // the bailed entry must not have left the chain-tail signal pointing at anything that
        // blocks forever.
        let db = try TestFixtureFactory.createTemporary(content: "# Real Heading\n\nBody.")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        state.projectDatabase = db
        state.currentProjectId = pid

        await state.refreshSectionsAwaiting()
        #expect(state.sections.map(\.title) == ["Real Heading"])
    }

    @Test("A queued refresh bails cleanly, without applying or hanging, if the project changes before its turn")
    func queuedRefreshBailsOnProjectChange() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Original Heading\n\nBody.")
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let state = EditorViewState()
        state.projectDatabase = db
        state.currentProjectId = pid

        // First refresh: starts on `pid`, begins its DB fetch, hasn't landed yet.
        let first = Task { @MainActor in await state.refreshSectionsAwaiting() }
        await Task.yield()
        #expect(state.sections.isEmpty, "setup didn't interleave -- first refresh already landed")

        // Second refresh: enqueued while the project is still `pid`, so it captures
        // `expectedProjectId == pid` at enqueue time (synchronously, before its chained-behind
        // fetch ever runs). The yield below lets that synchronous capture actually execute
        // before the project switch on the next line.
        let second = Task { @MainActor in await state.refreshSectionsAwaiting() }
        await Task.yield()

        // Known simplification: a real project switch goes through `startObserving`, which
        // sets `projectDatabase` and `currentProjectId` together. Here we only flip
        // `currentProjectId` (cheaper to set up, and it's the only one `performSectionsRefresh`'s
        // project guard actually reads), so this isn't a byte-for-byte replay of the real path --
        // just enough to exercise the guard.
        state.currentProjectId = "some-other-project-id"

        await first.value
        await second.value

        // `second` must have bailed cleanly on the project mismatch: it neither applied a
        // fetch for the wrong project nor hung waiting on its turn. Only `first`'s own
        // (correctly-scoped) fetch should be visible.
        #expect(state.sections.map(\.title) == ["Original Heading"])
        // The project-mismatch bail is a distinct guard from the generation-staleness drop
        // path -- it must not be counted as one.
        #expect(state.staleRefreshDropCount == 0)
    }

    @Test("A third caller arriving while an already-chained entry is still pending joins it instead of enqueueing a redundant one")
    func thirdCallerJoinsPendingChainedEntry() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Original Heading\n\nBody.")
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let state = EditorViewState()
        state.projectDatabase = db
        state.currentProjectId = pid

        // Entry 1: starts fetching immediately, stays suspended on its DB read.
        let first = Task { @MainActor in await state.refreshSectionsAwaiting() }
        await Task.yield()
        #expect(state.sections.isEmpty, "setup didn't interleave -- first refresh already landed")

        // Entry 2: arrives while entry 1 is still fetching. Entry 1 already cleared its own
        // `pendingRefreshSignal` (that clearing happens synchronously, before the DB read), so
        // entry 2 does NOT join it -- it creates its own new entry, chained behind entry 1.
        // Because entry 2 must await entry 1's completion before its OWN turn, entry 2's
        // `pendingRefreshSignal` stays set for entry 1's entire remaining runtime -- this is
        // the (non-zero-width, contrary to an earlier assumption) window in which the joiner
        // branch below is reachable.
        let second = Task { @MainActor in await state.refreshSectionsAwaiting() }
        await Task.yield()

        // Entry 3: arrives while entry 2 is still pending (chained behind entry 1, hasn't
        // started its own fetch yet, same project) -- this is the joiner branch itself.
        let third = Task { @MainActor in await state.refreshSectionsAwaiting() }

        await first.value
        await second.value
        await third.value

        // All three complete without hanging, and the refresh that actually landed is genuine
        // (not dropped), whichever of entry 2/3 ends up doing the real work.
        #expect(state.sections.map(\.title) == ["Original Heading"])
        #expect(state.staleRefreshDropCount == 0)
    }

    @Test("A caller whose project differs from a pending entry's does not join it, and still gets its own correctly-scoped refresh")
    func joinerRefusesMismatchedProjectAndGetsOwnEntry() async throws {
        let db1 = try TestFixtureFactory.createTemporary(content: "# Project One Heading\n\nBody.")
        let pid1 = try TestFixtureFactory.getProjectId(from: db1)
        let db2 = try TestFixtureFactory.createTemporary(content: "# Project Two Heading\n\nBody.")
        let pid2 = try TestFixtureFactory.getProjectId(from: db2)

        let state = EditorViewState()
        state.projectDatabase = db1
        state.currentProjectId = pid1

        // Entry 1: starts fetching project 1, stays suspended on its DB read.
        let first = Task { @MainActor in await state.refreshSectionsAwaiting() }
        await Task.yield()
        #expect(state.sections.isEmpty, "setup didn't interleave -- first refresh already landed")

        // Entry 2: chains behind entry 1, still scoped to project 1 (enqueued before the
        // switch below). Its `pendingRefreshSignal` stays set while it awaits entry 1.
        let second = Task { @MainActor in await state.refreshSectionsAwaiting() }
        await Task.yield()

        // Switch to project 2 (same simplification noted in `queuedRefreshBailsOnProjectChange`
        // -- only flipping the two properties `performSectionsRefresh`'s guards actually read).
        state.projectDatabase = db2
        state.currentProjectId = pid2

        // Entry 3 (caller C from the bug report): arrives on project 2 while entry 2 is still
        // pending, but entry 2 is scoped to project 1. Without the project check on the join,
        // entry 3 would join entry 2, entry 2 would bail on the (by-then) project mismatch, and
        // entry 3 would return having gotten NO refresh at all for project 2 -- silently. With
        // the check, entry 3 must instead get its own entry, chained behind entry 2, correctly
        // scoped to project 2.
        let third = Task { @MainActor in await state.refreshSectionsAwaiting() }

        await first.value
        await second.value
        await third.value

        // If entry 3 had silently joined entry 2 and returned with nothing done, `sections`
        // would still show project 1's content (from entry 1's apply) here. Seeing project 2's
        // content proves entry 3 actually performed its own fetch, scoped to its own project.
        #expect(state.sections.map(\.title) == ["Project Two Heading"])
        // Entry 2's bail is the project-mismatch guard, not the generation-staleness drop path.
        #expect(state.staleRefreshDropCount == 0)
    }
}
