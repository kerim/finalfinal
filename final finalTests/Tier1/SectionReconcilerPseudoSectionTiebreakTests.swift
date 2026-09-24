//
//  SectionReconcilerPseudoSectionTiebreakTests.swift
//  final finalTests
//
//  Split out of SectionReconcilerPseudoSectionTests.swift to keep that file under SwiftLint's
//  file_length limit -- see the header comment there for the full pseudo-section matching
//  background (break markers, passesMatchGate's pseudo branch, the Tier 3 title tiebreak).
//  This file covers the "Mixed Document (No Spillover)" and "Full Collisions: Deterministic
//  Proximity Tiebreak" scenarios, using the shared `makeHeader`/`makeSection` factories defined
//  in SectionReconcilerPseudoSectionTests.swift.
//

import Testing
import Foundation
@testable import final_final

extension SectionReconcilerPseudoSectionTests {

    // MARK: - Mixed Document (No Spillover)

    @Test("Mixed document: a pseudo-section content match doesn't disturb a neighboring real heading")
    func mixedDocumentPseudoContentMatchDoesNotAffectRealHeadingNeighbor() {
        // A real heading before and a real heading after the affected
        // pseudo-sections, to confirm this fix has no spillover effect on
        // ordinary (non-pseudo) heading matching within the same reconcile()
        // call. The pseudo header's stripped body ("Conclusion body.") is
        // DELIBERATELY a suffix of the real "Conclusion" heading's raw content
        // ("## Conclusion\nConclusion body.") -- before fix #1, that
        // coincidence would have made Tier 3's `related` filter wrongly
        // include sConclusion (distance 1) alongside sFar (distance 2,
        // genuinely related), and since sConclusion is closer, it would have
        // won: the section break would have stolen the real heading's row,
        // and the "Conclusion" header would then have needed a second (also
        // wrong) fallback match of its own.
        let headers = [
            makeHeader(position: 0, title: "Intro", markdownContent: "## Intro\nIntro body."),
            makeHeader(
                position: 1, title: "§ Section Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\nConclusion body."
            ),
            makeHeader(position: 2, title: "Conclusion", markdownContent: "## Conclusion\nConclusion body.")
        ]
        let dbSections = [
            makeSection(id: "sIntro", sortOrder: 0, title: "Intro", markdownContent: "## Intro\nIntro body."),
            makeSection(
                id: "sNear", sortOrder: 1, title: "§ Section Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\n> unrelated quoted content"
            ),
            makeSection(id: "sConclusion", sortOrder: 2, title: "Conclusion", markdownContent: "## Conclusion\nConclusion body."),
            makeSection(
                id: "sFar", sortOrder: 3, title: "§ Section Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\nConclusion body. And then some extra sentence follows this one."
            )
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let deletes = changes.compactMap { change -> String? in if case .delete(let id) = change { return id }; return nil }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }; return nil
        }
        let inserts = changes.filter { if case .insert = $0 { return true }; return false }

        #expect(inserts.isEmpty, "No new sections should be inserted")
        #expect(deletes == ["sNear"], "Only the evidence-free pseudo row should be deleted")

        let farUpdate = updates.first { $0.0 == "sFar" }
        #expect(farUpdate != nil, "sFar should be matched by content")
        if let farUpdate {
            #expect(farUpdate.1.sortOrder == 1, "sFar should move to the pseudo header's position")
        }

        // Both real headings are already at their correct position with unchanged
        // content, so a correctly-unaffected match produces NO change entry for
        // either -- the same "no news is good news" signal `noChangesWhenPerfectMatch`
        // relies on in SectionReconcilerTests.swift. If the pseudo-section
        // content-matching fix had any spillover onto ordinary heading matching,
        // one of these would show up as an unexpected update, delete, or insert.
        #expect(!updates.contains { $0.0 == "sIntro" }, "Intro is a perfect match — no update needed")
        #expect(!updates.contains { $0.0 == "sConclusion" }, "Conclusion is a perfect match — no update needed")
        #expect(!deletes.contains("sConclusion"), "Conclusion's row must not be swept up by the pseudo-section reshuffle")
    }

    // MARK: - Full Collisions: Deterministic Proximity Tiebreak (2026-07-28)

    // Every test above disambiguates its two pseudo-section candidates by SOME
    // signal -- different content, different distance, or a title that only one
    // of them shares. The two tests below remove every signal at once: two DB
    // rows with byte-identical content to each other AND to the header (or both
    // fully empty), the same generic title, and EQUAL distance from the header's
    // position. Tier 3's `.min` tiebreak (title match, then distance) is
    // completely exhausted and falls through to whichever candidate `min(by:)`
    // encountered first -- the lower-sortOrder row, since `available`/`inRange`/
    // `related` all preserve `sortedDB`'s ascending sortOrder order and
    // `min(by:)` only replaces its running result on a STRICT improvement. This
    // is the "probably correct but untested" fallback the pseudo-section
    // content-matching fix (2026-07-27) relies on for genuinely tied candidates:
    // a future refactor that reorders the filtering, switches `min` for `max`,
    // or changes iteration order would silently start attaching edits to the
    // wrong section, with nothing here to catch it before now.

    @Test("Tier 3 identical non-empty content on both candidates: earlier row wins the tie")
    func tier3IdenticalContentCandidatesTiedByProximityKeepsEarlierRow() {
        // sBefore and sAfter are byte-identical to each other AND to the header
        // (post marker-stripping), so BOTH pass `contentRelated` and BOTH land in
        // Tier 3's `related` set -- there is no "the content-related one" here,
        // unlike every earlier test in this file. Both also share the header's
        // exact generic title, and both sit exactly 2 slots away (3 and 7, vs the
        // header's position 5), so the title tiebreak and the distance tiebreak
        // are each fully tied too. The only thing left to decide the match is
        // `min(by:)`'s first-encountered-wins behavior on an exact tie.
        let sharedContent = "<!-- ::break:: -->\nIdentical text shared by both."
        let headers = [
            makeHeader(position: 0, title: "A", markdownContent: "## A\nAlpha body."),
            makeHeader(position: 5, title: "§ Section Break", isPseudoSection: true, markdownContent: sharedContent)
        ]
        let dbSections = [
            makeSection(id: "sA", sortOrder: 0, title: "A", markdownContent: "## A\nAlpha body."),
            makeSection(
                id: "sBefore", sortOrder: 3, title: "§ Section Break", isPseudoSection: true, markdownContent: sharedContent
            ),
            makeSection(
                id: "sAfter", sortOrder: 7, title: "§ Section Break", isPseudoSection: true, markdownContent: sharedContent
            )
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let deletes = Set(changes.compactMap { change -> String? in if case .delete(let id) = change { return id }; return nil })
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }; return nil
        }
        let inserts = changes.filter { if case .insert = $0 { return true }; return false }

        #expect(inserts.isEmpty, "No new sections should be inserted")
        #expect(deletes == ["sAfter"], "sAfter loses the tie purely by iteration order and must be deleted")

        let beforeUpdate = updates.first { $0.0 == "sBefore" }
        #expect(beforeUpdate != nil, "sBefore (the earlier-sortOrder, otherwise-indistinguishable row) must win the tie")
        if let beforeUpdate {
            #expect(beforeUpdate.1.sortOrder == 1, "sBefore should move to the header's array index (1)")
        }
        #expect(!updates.contains { $0.0 == "sAfter" }, "sAfter must not receive the header's identity")
        // If a future refactor changed the tiebreak's iteration order (or swapped
        // `min` for `max`), this would silently start matching sAfter instead --
        // attaching the edit to a different, equally-plausible row with no other
        // test here to notice.
    }

    @Test("Tier 3 both candidates fully empty: earlier row wins the tie, never via content evidence")
    func tier3BothCandidatesEmptyTiedByProximityKeepsEarlierRow() {
        // Same shape as above, but both candidates strip down to a fully EMPTY
        // body (a bare break marker with nothing after it), and so does the
        // header. Unlike the identical-non-empty-content case, this path never
        // reaches Tier 3's `related` set at all: `contentRelated` unconditionally
        // returns false whenever either side is empty (see its doc comment and
        // `tier3PseudoBareMarkerAtDocumentEndIsNeverContentEvidence` in
        // SectionReconcilerPseudoSectionTests.swift), so BOTH candidates fail
        // the content gate and `related` is empty here too.
        // This exercises the OTHER branch of the same fallback --
        // `candidates = related.isEmpty ? inRange : related` picking `inRange`
        // instead of `related` -- while landing on the identical tie-break
        // outcome (earlier sortOrder wins) for the same underlying reason.
        let bareMarker = "<!-- ::break:: -->"
        let headers = [
            makeHeader(position: 0, title: "A", markdownContent: "## A\nAlpha body."),
            makeHeader(position: 5, title: "§ Section Break", isPseudoSection: true, markdownContent: bareMarker)
        ]
        let dbSections = [
            makeSection(id: "sA", sortOrder: 0, title: "A", markdownContent: "## A\nAlpha body."),
            makeSection(id: "sBefore", sortOrder: 3, title: "§ Section Break", isPseudoSection: true, markdownContent: bareMarker),
            makeSection(id: "sAfter", sortOrder: 7, title: "§ Section Break", isPseudoSection: true, markdownContent: bareMarker)
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let deletes = Set(changes.compactMap { change -> String? in if case .delete(let id) = change { return id }; return nil })
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }; return nil
        }
        let inserts = changes.filter { if case .insert = $0 { return true }; return false }

        #expect(inserts.isEmpty, "No new sections should be inserted")
        #expect(deletes == ["sAfter"], "sAfter loses the tie purely by iteration order and must be deleted")

        let beforeUpdate = updates.first { $0.0 == "sBefore" }
        #expect(beforeUpdate != nil, "sBefore (the earlier-sortOrder, otherwise-indistinguishable row) must win the tie")
        if let beforeUpdate {
            #expect(beforeUpdate.1.sortOrder == 1, "sBefore should move to the header's array index (1)")
        }
        #expect(!updates.contains { $0.0 == "sAfter" }, "sAfter must not receive the header's identity")
    }
}
