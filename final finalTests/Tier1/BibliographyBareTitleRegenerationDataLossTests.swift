//
//  BibliographyBareTitleRegenerationDataLossTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers -- live-sequence regression for t-341706cb's bare-title heading
//  false positive, round 3, updated for the round-8 fix that DELETES tier 3 entirely (see
//  `BibliographyOpeningSelector.swift`).
//
//  THE ORIGINAL BUG this file reproduced (rounds 1-3, before tier 3 was deleted): a document
//  containing an early heading whose title exactly matched the configured bibliography header
//  name (e.g. "# Bibliography"), with ordinary prose underneath it, BEFORE any citation had
//  ever been inserted -- `BlockParser.parse()`'s then-existing tier 3 ("no marker, no
//  terminator -> last/only title match wins") transiently flagged that heading AND its prose
//  `isBibliography = true`. `BibliographySyncService.updateBibliographyBlock`'s anchor
//  selection then queried the BLOCK table for `isBibliography == true` to find "the existing
//  bibliography to regenerate", found the user's own heading+prose, and silently DELETED them
//  when generating the user's first-ever real bibliography -- worse than a cosmetic duplicate,
//  since real user content was destroyed.
//
//  THE FIX (round 8, this file's current form): tier 3 is deleted outright, not narrowed.
//  `BlockParser.parse()` now flags NOTHING for this shape of document -- no marker, no
//  terminator, so `BibliographyOpeningSelector.select` returns `.none`. The early heading and
//  its prose are never transiently flagged in the first place, which prevents the data-loss
//  mechanism at its source rather than papering over its symptom. The test below now pins
//  down that prevention directly: the early heading stays unflagged both BEFORE and AFTER the
//  first real citation is generated, and the user's prose survives untouched.
//
//  The SectionReconciler-level test further below is unaffected by the tier-3 deletion -- it
//  exercises `SectionReconciler.reconcile()` directly against hand-built `Section`/
//  `ParsedHeader` values, never through `BlockParser.parse`'s selection logic -- and is kept
//  unchanged as a still-valid pin on that mechanism.
//

import Testing
import Foundation
@testable import final_final

@Suite("Bibliography bare-title heading -- live regeneration data loss")
struct BibliographyBareTitleRegenerationDataLossTests {

    // MARK: - Confirms the FIX: with tier 3 deleted, the early bare-title heading is never
    // transiently flagged, so updateBibliographyBlock's anchor query never finds it in the
    // first place -- the data-loss mechanism can't occur at its source.

    @Test("Live sequence: an early Bibliography-titled heading with prose is never flagged, and survives untouched when the first real citation is generated")
    @MainActor
    func earlyBareTitleHeadingAndProseSurviveFirstBibliographyGeneration() async throws {
        // Step 1: a brand-new document. The early heading exactly matches the default
        // configured bibliography header name ("Bibliography"), with ordinary prose beneath
        // it, followed by a later real heading + content.
        let markdown = """
        # Bibliography

        Some placeholder prose about future references.

        # Conclusion

        Final thoughts here.
        """

        let db = try TestFixtureFactory.createTemporary(content: markdown)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        // THE FIX: no marker, no terminator anywhere in this document -- tier 3 is deleted, so
        // BlockParser.parse's pre-scan selects nothing. The early heading and its prose must
        // NOT be flagged, unlike the pre-fix behavior this file used to pin down.
        let blocksBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let earlyHeadingBefore = try #require(
            blocksBefore.first { $0.blockType == .heading && $0.textContent == "Bibliography" }
        )
        #expect(!earlyHeadingBefore.isBibliography, "Tier 3 is deleted -- the early bare-title heading must never be flagged")
        let proseBefore = try #require(
            blocksBefore.first { $0.textContent == "Some placeholder prose about future references." }
        )
        #expect(!proseBefore.isBibliography, "The user's prose beneath the early heading must never be flagged either")
        let conclusionBefore = try #require(blocksBefore.first { $0.textContent == "Conclusion" })
        #expect(!conclusionBefore.isBibliography)

        // Step 2: the user's first-ever real citation. Mirrors
        // BibliographySyncTests.flushPendingSyncForcesScheduledBibliographyUpdate's pattern --
        // a real Zotero item loaded into ZoteroService.shared, then the real production entry
        // point (checkAndUpdateBibliography -> debounced performBibliographyUpdate ->
        // updateBibliographyBlock), forced through immediately via flushPendingSync() instead
        // of waiting out the real 1s debounce.
        let itemJSON = """
        {"id":"bareheadingtestkey2026","type":"book","title":"Real Citation Title","author":[{"family":"Smith","given":"Alice"}],"issued":{"date-parts":[[2022]]}}
        """
        let item = try JSONDecoder().decode(CSLItem.self, from: Data(itemJSON.utf8))

        ZoteroService.shared.isConnected = true
        ZoteroService.shared.loadItem(item)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        let service = BibliographySyncService()
        service.configure(database: db, projectId: projectId)
        service.checkAndUpdateBibliography(currentCitekeys: ["bareheadingtestkey2026"], projectId: projectId)
        await service.flushPendingSync()

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)

        // THE FIX, confirmed: the user's own placeholder prose survives untouched -- it was
        // never flagged, so updateBibliographyBlock's `isBibliography == true` anchor query
        // never saw it and had nothing to delete.
        #expect(
            blocksAfter.contains { $0.textContent == "Some placeholder prose about future references." },
            "The user's own prose beneath their early bare-title heading must survive -- it was never mistaken for an existing bibliography"
        )

        // The user's own heading text must still exist as ordinary (unflagged) content.
        let survivingEarlyHeading = blocksAfter.first {
            $0.blockType == .heading && $0.textContent == "Bibliography" && !$0.isBibliography
        }
        #expect(
            survivingEarlyHeading != nil,
            "The user's own early heading must survive as an ordinary, unflagged heading"
        )

        // The real bibliography must still be generated correctly.
        let bibEntryAfter = blocksAfter.first { $0.markdownFragment.contains("Smith") }
        #expect(bibEntryAfter != nil, "The real bibliography entry must still be generated")

        // Positional check: for a FIRST-EVER generation (no real prior bibliography existed),
        // the documented behavior is "append at the end" -- the real bibliography must sort
        // AFTER "Conclusion"/"Final thoughts here.", not before them.
        let conclusionAfter = try #require(blocksAfter.first { $0.textContent == "Conclusion" })
        if let bibEntryAfter {
            #expect(
                bibEntryAfter.sortOrder > conclusionAfter.sortOrder,
                "A first-ever bibliography generation must append at the end of the document, not splice in at the early heading's position"
            )
        }
    }

    // MARK: - Directly pins the SectionReconciler-level claim from the working hypothesis:
    // does a Section row that WAS isBibliography == true ever get correctly demoted once the
    // early heading is no longer the sole bibliography candidate? This isolates the
    // reconciler mechanism from BibliographySyncService's separate (and, per the test above,
    // actually broken) block-level anchor selection.

    @Test("SectionReconciler: an early heading's stale-flagged Section row is not left as a permanent duplicate once a later header claims the bibliography flag")
    func sectionReconcilerSettlesCleanlyWhenAnEarlyHeadingIsTransientlyFlaggedThenDemoted() {
        let reconciler = SectionReconciler()
        let projectId = "test-project-id"

        // The Section row as it exists after tier 3 transiently flagged the early heading
        // (round 1/2's established, correct behavior) -- BEFORE the real bibliography exists.
        let earlyHeadingRowId = UUID().uuidString
        let staleRow = Section(
            id: earlyHeadingRowId, projectId: projectId, sortOrder: 0, headerLevel: 1,
            isBibliography: true, title: "Bibliography",
            markdownContent: "# Bibliography\n\nSome placeholder prose.",
            wordCount: 4, startOffset: 0
        )

        // The next full reparse, AFTER a real bibliography has been generated elsewhere in the
        // document: the early heading now correctly parses as isBibliography == false (this
        // fix's own block-level curative demotion, mirrored up into the ParsedHeader), and a
        // separate, later heading is the real, machine-managed bibliography.
        let earlyHeader = ParsedHeader(
            position: 0, title: "Bibliography", level: 1, isPseudoSection: false,
            startOffset: 0, markdownContent: "# Bibliography\n\nSome placeholder prose.",
            wordCount: 4, isBibliography: false
        )
        let realBibHeader = ParsedHeader(
            position: 1, title: "Bibliography", level: 1, isPseudoSection: false,
            startOffset: 200, markdownContent: "# Bibliography\n\nSmith, A. (2022). Real Citation Title.",
            wordCount: 6, isBibliography: true
        )

        let changes = reconciler.reconcile(
            headers: [earlyHeader, realBibHeader], dbSections: [staleRow], projectId: projectId
        )

        // The stale row must be claimed by the REAL bibliography header (findBibliographyMatch's
        // "already flagged -> match directly" tier), refreshed to the real content.
        let realBibUpdate = changes.first {
            if case .update(let id, let updates) = $0 { return id == earlyHeadingRowId && updates.markdownContent?.contains("Smith") == true }
            return false
        }
        #expect(realBibUpdate != nil, "The stale flagged row must be refreshed in place to hold the real bibliography's content")

        // A fresh row must be inserted for the early heading, correctly unflagged -- not left
        // unrepresented, and not left flagged.
        let earlyHeadingInsert = changes.first {
            if case .insert(let section) = $0 { return section.title == "Bibliography" && !section.isBibliography }
            return false
        }
        #expect(earlyHeadingInsert != nil, "A fresh, unflagged Section row must be created for the early heading")

        // No delete: the only pre-existing row is claimed by the real bibliography header
        // above, so nothing is left unmatched to sweep.
        let deletes = changes.filter { if case .delete = $0 { return true }; return false }
        #expect(deletes.isEmpty, "The single pre-existing row is claimed by the real bibliography match -- nothing should be deleted")

        // End state: exactly one row flagged isBibliography, exactly one not -- never two rows
        // both flagged (which would be the literal "duplicate ghost" the hypothesis predicted).
        let flaggedCount = changes.filter {
            switch $0 {
            case .insert(let s): return s.isBibliography
            case .update(_, let u): return u.isBibliography == true
            default: return false
            }
        }.count
        #expect(flaggedCount <= 1, "At most one row may end up flagged isBibliography after this reconcile pass")
    }
}
