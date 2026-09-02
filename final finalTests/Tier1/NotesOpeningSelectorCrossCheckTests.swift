//
//  NotesOpeningSelectorCrossCheckTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers -- Stage C (t-7f7e6ed2 / t-mtianjujt9ub, "notes-heading-scanner-unify").
//  Mirrors `BibliographyOpeningSelectorCrossCheckTests.swift`'s structure exactly: feeds the
//  SAME fixture to every migrated Notes-opening call site's own tokenizer --
//  `BlockParser.parse` (site A, raw blocks), `FootnoteSyncService.stripNotesSection` (site B,
//  lines), `FootnoteSyncService.pushDefinitionsToEditor` (site C, lines, side-effecting via
//  `.footnoteDefinitionsReady`), and `SectionSyncService.parseHeaders` (site D, lines, its own
//  `confirmNotesCandidates`) -- and asserts they agree: either all four select the "Notes"
//  heading, or none of them do.
//
//  This property is FALSE for an unscoped fixture set, exactly as the Bibliography suite's own
//  doc comment explains for its three sites. The one KNOWN, deliberate divergence between the
//  four Notes sites (mirroring Bibliography's own "site B allows 1-6, A/C only 1-2"): site D's
//  OUTER title-match loop in `SectionSyncService+Parsing.swift` accepts a Notes-titled heading
//  at ANY level (1-6) as a CANDIDATE (only evidence gates it, not level), while sites A/B/C all
//  restrict candidacy to H1-or-H2 (`BlockParser.isNotesHeading`). Every fixture below is scoped
//  to H1/H2 only, so this divergence never actually fires here -- it is a real, accepted
//  difference, not a bug, and is exercised deliberately in `NotesOpeningSelectorTests.swift`'s
//  own DB-derived-title test instead of here.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("NotesOpeningSelector -- cross-check: sites A/B/C/D agree")
struct NotesOpeningSelectorCrossCheckTests {

    /// Fails the calling test if `markdown` violates this suite's own scoping preconditions --
    /// mirrors `BibliographyOpeningSelectorCrossCheckTests.assertFixtureIsInScope` exactly.
    private func assertFixtureIsInScope(_ markdown: String) {
        #expect(
            markdown.range(of: #"(^|\n)#{3,6}\s"#, options: .regularExpression) == nil,
            "Cross-check fixtures must only use heading levels 1-2 (site D's outer loop allows 1-6, A/B/C only 1-2)"
        )
    }

    /// Site C's result: whether `pushDefinitionsToEditor` actually posted `.footnoteDefinitionsReady`
    /// with non-empty definitions -- it has no return value, so "selected" is observed via the
    /// side effect it's documented to produce. `pushDefinitionsToEditor` is synchronous and
    /// `NotificationCenter.post` delivers to `queue: nil` observers synchronously on the posting
    /// thread, so the observer fires (or doesn't) before this function returns.
    @MainActor
    private func pushDefinitionsSelected(_ markdown: String) -> Bool {
        var didFire = false
        let observer = NotificationCenter.default.addObserver(
            forName: .footnoteDefinitionsReady, object: nil, queue: nil
        ) { _ in didFire = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        FootnoteSyncService().pushDefinitionsToEditor(fullContent: markdown)
        return didFire
    }

    // MARK: - Fixture: H1 with real evidence -- all four sites select "Notes"

    @Test("Cross-check: '# Notes' with real evidence -- all four sites select it")
    @MainActor
    func h1WithEvidenceAllSitesAgree() throws {
        let markdown = """
        # Chapter

        A reference[^1].

        # Notes

        [^1]: Real definition text.
        """
        assertFixtureIsInScope(markdown)

        // Site A: BlockParser.parse
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")
        #expect(blocks.first { $0.blockType == .heading && $0.textContent == "Notes" }?.isNotes == true, "Site A must select")

        // Site B: stripNotesSection
        let stripped = FootnoteSyncService.stripNotesSection(from: markdown)
        #expect(!stripped.contains("# Notes"), "Site B must recognize and strip the heading")
        #expect(!stripped.contains("Real definition text"), "Site B must strip the definition too")

        // Site C: pushDefinitionsToEditor
        #expect(pushDefinitionsSelected(markdown), "Site C must post definitions -- the section was recognized")

        // Site D: SectionSyncService.parseHeaders
        let headers = SectionSyncService.parseHeaders(from: markdown)
        #expect(headers.first { $0.title == "Notes" }?.isNotes == true, "Site D must select")
    }

    // MARK: - Fixture: H2 with real evidence -- the primary Stage C widening, all four sites select

    @Test("Cross-check: '## Notes' with real evidence -- all four sites select it (Stage C's core widening)")
    @MainActor
    func h2WithEvidenceAllSitesAgree() throws {
        let markdown = """
        # Chapter

        A reference[^1].

        ## Notes

        [^1]: Real definition text.
        """
        assertFixtureIsInScope(markdown)

        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")
        #expect(blocks.first { $0.blockType == .heading && $0.textContent == "Notes" }?.isNotes == true, "Site A must select")

        let stripped = FootnoteSyncService.stripNotesSection(from: markdown)
        #expect(!stripped.contains("## Notes"), "Site B must recognize and strip the heading")
        #expect(!stripped.contains("Real definition text"), "Site B must strip the definition too")

        #expect(pushDefinitionsSelected(markdown), "Site C must post definitions")

        let headers = SectionSyncService.parseHeaders(from: markdown)
        #expect(headers.first { $0.title == "Notes" }?.isNotes == true, "Site D must select")
    }

    // MARK: - Fixture: evidence-free "Notes" heading -- none of the four sites select

    @Test("Cross-check: an evidence-free 'Notes' heading -- none of the four sites select it")
    @MainActor
    func evidenceFreeHeadingNoSiteAgrees() throws {
        let markdown = """
        # Chapter

        Body prose with no footnote references.

        ## Notes

        Just closing remarks -- no footnote definitions at all.
        """
        assertFixtureIsInScope(markdown)

        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")
        #expect(blocks.first { $0.blockType == .heading && $0.textContent == "Notes" }?.isNotes == false, "Site A must not select")

        let stripped = FootnoteSyncService.stripNotesSection(from: markdown)
        #expect(stripped == markdown, "Site B must leave the document untouched")

        #expect(!pushDefinitionsSelected(markdown), "Site C must not post any definitions")

        let headers = SectionSyncService.parseHeaders(from: markdown)
        #expect(headers.first { $0.title == "Notes" }?.isNotes == false, "Site D must not select")
    }

    // MARK: - Fixture: '## Notes' inside a fenced code block -- none of the four sites select

    @Test("Cross-check: a '## Notes'-shaped line inside a fenced code block -- none of the four sites select it")
    @MainActor
    func fencedCodeBlockDecoyNoSiteAgrees() throws {
        let markdown = """
        # Chapter

        Example:

        ```markdown
        ## Notes

        [^1]: like this.
        ```
        """
        assertFixtureIsInScope(markdown)

        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")
        #expect(!blocks.contains { $0.isNotes }, "Site A must not select anything -- it's all one code-fence block")

        let stripped = FootnoteSyncService.stripNotesSection(from: markdown)
        #expect(stripped == markdown, "Site B must leave the fenced content untouched")

        #expect(!pushDefinitionsSelected(markdown), "Site C must not post any definitions from inside a fence")

        let headers = SectionSyncService.parseHeaders(from: markdown)
        #expect(!headers.contains { $0.title == "Notes" && $0.isNotes }, "Site D must not select the fenced decoy")
    }
}
