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
}
