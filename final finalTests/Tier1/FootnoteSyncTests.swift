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
}
