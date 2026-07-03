//
//  FootnoteSyncTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for footnote sync: reference extraction, definition parsing,
//  and Notes section stripping. Lost footnote definitions corrupt documents.
//

import Testing
import Foundation
@testable import final_final

@Suite("Footnote Sync — Tier 1: Silent Killers")
struct FootnoteSyncTests {

    // MARK: - extractFootnoteRefs

    @Test("extractFootnoteRefs finds single ref")
    func extractFootnoteRefsSingleRef() {
        let refs = FootnoteSyncService.extractFootnoteRefs(from: "Text[^1] more")
        #expect(refs == ["1"])
    }

    @Test("extractFootnoteRefs finds multiple refs in order")
    func extractFootnoteRefsMultipleRefs() {
        let refs = FootnoteSyncService.extractFootnoteRefs(from: "A[^1] B[^2] C[^3]")
        #expect(refs == ["1", "2", "3"])
    }

    @Test("extractFootnoteRefs deduplicates repeated refs")
    func extractFootnoteRefsDeduplicates() {
        let refs = FootnoteSyncService.extractFootnoteRefs(from: "A[^1] B[^1]")
        #expect(refs == ["1"])
    }

    @Test("extractFootnoteRefs excludes definitions")
    func extractFootnoteRefsExcludesDefinitions() {
        let markdown = """
        Text[^1] here.

        # Notes

        [^1]: This is a definition
        """
        let refs = FootnoteSyncService.extractFootnoteRefs(from: markdown)
        #expect(refs == ["1"], "Should find the ref but not count the definition as a ref")
    }

    @Test("extractFootnoteRefs excludes refs in Notes section")
    func extractFootnoteRefsExcludesNotesSection() {
        let markdown = """
        Body text[^1] here.

        # Notes

        [^1]: Definition that mentions[^2] another ref
        """
        let refs = FootnoteSyncService.extractFootnoteRefs(from: markdown)
        #expect(refs == ["1"], "Refs inside Notes section should be excluded")
    }

    // MARK: - extractFootnoteDefinitions

    @Test("extractFootnoteDefinitions parses single and multi-paragraph definitions")
    func extractFootnoteDefinitions() {
        let notesContent = """
        # Notes

        [^1]: Simple definition.

        [^2]: First paragraph.
            Second paragraph with 4-space indent.
        """
        let defs = FootnoteSyncService.extractFootnoteDefinitions(from: notesContent)
        #expect(defs["1"] == "Simple definition.")
        #expect(defs["2"]?.contains("First paragraph.") == true)
        #expect(defs["2"]?.contains("Second paragraph with 4-space indent.") == true)
    }

    // MARK: - stripNotesSection

    @Test("stripNotesSection removes Notes but preserves other headings")
    func stripNotesSectionRemovesNotesOnly() {
        let markdown = """
        # Intro

        Introduction text.

        # Notes

        [^1]: A definition.

        # References

        Some references.
        """
        let stripped = FootnoteSyncService.stripNotesSection(from: markdown)
        #expect(stripped.contains("# Intro"), "Should preserve Intro heading")
        #expect(stripped.contains("Introduction text"), "Should preserve Intro content")
        #expect(!stripped.contains("# Notes"), "Should remove Notes heading")
        #expect(!stripped.contains("[^1]:"), "Should remove Notes content")
        #expect(stripped.contains("# References"), "Should preserve References heading")
        #expect(stripped.contains("Some references"), "Should preserve References content")
    }

    // MARK: - Immediate/debounced race (duplicate definition guard)

    @Test("Stale debounced rebuild after an immediate insertion is superseded (no lost/duplicate definition)")
    @MainActor
    func immediateInsertionSupersedesStaleDebounce() async throws {
        // Seed a document whose Notes section already has one real definition ([^1]).
        let seed = """
        Body text[^1] here.

        # Notes

        [^1]: Real definition one.
        """
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)

        // A debounced rebuild was scheduled with the pre-insertion snapshot (generation 0, refs=["1"]).

        // 1. Immediate insertion of [^2] (as if the user ran /footnote). Rebuilds Notes to
        //    [^1] real + [^2] empty, and bumps syncGeneration 0 -> 1.
        service.handleImmediateInsertion(label: "2", projectId: projectId)

        // 2. The stale debounced rebuild now fires. It must bail because the immediate
        //    insertion superseded it. Without the fix it deletes/empties the fresh [^2].
        await service.performFootnoteUpdate(
            refs: ["1"], projectId: projectId, fullContent: seed, scheduledGeneration: 0
        )

        // 3. DB must hold exactly two definition blocks: [^1] (real) and [^2] (empty placeholder),
        //    with no duplicate and no data loss.
        let defs = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        let frags = defs.map(\.markdownFragment)

        #expect(defs.count == 2, "Expected exactly [^1] and [^2]; got \(frags)")
        #expect(frags.filter { $0.hasPrefix("[^1]:") }.count == 1, "Exactly one [^1] block")
        #expect(frags.filter { $0.hasPrefix("[^2]:") }.count == 1, "Exactly one [^2] block (not destroyed)")
        #expect(frags.contains { $0.contains("Real definition one.") }, "[^1] real text preserved")
    }

    @Test("A current-generation debounced rebuild still runs (guard does not over-block)")
    @MainActor
    func currentGenerationDebounceStillRuns() async throws {
        let seed = """
        A[^1] B[^2].

        # Notes

        [^1]: First.

        [^2]: Second.
        """
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)

        // No immediate insertion happened, so the debounce's captured generation (0) still matches.
        await service.performFootnoteUpdate(
            refs: ["1", "2"], projectId: projectId, fullContent: seed, scheduledGeneration: 0
        )

        let defs = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        #expect(defs.count == 2, "Legitimate debounced rebuild must still produce both definitions")
    }
}
