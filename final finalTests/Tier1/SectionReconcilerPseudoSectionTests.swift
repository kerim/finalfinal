//
//  SectionReconcilerPseudoSectionTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Pseudo-section-specific matching tests for SectionReconciler, split out of
//  SectionReconcilerTests.swift to keep that file under SwiftLint's
//  file_length limit. Pseudo-sections (break markers, <!-- ::break:: -->)
//  have generic, content-derived titles that routinely collide with each
//  other, so they exercise a materially different code path than ordinary
//  headings: passesMatchGate's pseudo branch, strippingLeadingBreakMarker,
//  and the Tier 3 title tiebreak.
//

import Testing
import Foundation
@testable import final_final

@Suite("Section Reconciler — Pseudo-Section Matching (Tier 1: Silent Killers)")
// swiftlint:disable:next type_body_length
struct SectionReconcilerPseudoSectionTests {

    let reconciler = SectionReconciler()
    let projectId = "test-project-id"

    // MARK: - Helper Factories

    private func makeHeader(
        position: Int,
        title: String,
        level: Int = 2,
        isPseudoSection: Bool = false,
        startOffset: Int = 0,
        markdownContent: String = "",
        wordCount: Int = 10
    ) -> ParsedHeader {
        ParsedHeader(
            position: position,
            title: title,
            level: level,
            isPseudoSection: isPseudoSection,
            startOffset: startOffset,
            markdownContent: markdownContent,
            wordCount: wordCount
        )
    }

    private func makeSection(
        id: String = UUID().uuidString,
        sortOrder: Int,
        title: String,
        headerLevel: Int = 2,
        isPseudoSection: Bool = false,
        isBibliography: Bool = false,
        isNotes: Bool = false,
        markdownContent: String = "",
        status: SectionStatus = .writing,
        tags: [String] = ["important"],
        wordGoal: Int? = 500
    ) -> Section {
        Section(
            id: id,
            projectId: projectId,
            sortOrder: sortOrder,
            headerLevel: headerLevel,
            isPseudoSection: isPseudoSection,
            isBibliography: isBibliography,
            isNotes: isNotes,
            title: title,
            markdownContent: markdownContent,
            status: status,
            tags: tags,
            wordGoal: wordGoal
        )
    }

    // MARK: - Tier 2 Exclusion

    @Test("Pseudo-sections skip title matching — avoids false matches")
    func pseudoSectionsSkipTitleMatch() {
        // Two pseudo-sections with similar generated titles at different positions
        let headers = [
            makeHeader(position: 0, title: "Section Break", isPseudoSection: true),
            makeHeader(position: 1, title: "Section Break", isPseudoSection: true)
        ]
        let dbSections = [
            makeSection(id: "ps1", sortOrder: 0, title: "Section Break", isPseudoSection: true),
            makeSection(id: "ps2", sortOrder: 1, title: "Section Break", isPseudoSection: true)
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        // Should match by position (Tier 1), not create duplicates
        let inserts = changes.filter { if case .insert = $0 { return true }; return false }
        let deletes = changes.filter { if case .delete = $0 { return true }; return false }
        #expect(inserts.isEmpty)
        #expect(deletes.isEmpty)
    }

    // MARK: - Tier 3 Content-Relatedness Gate

    @Test("Tier 3 pseudo-section batch shift: reattaches by content, not raw proximity")
    func tier3PseudoSectionBatchShift() {
        // A pseudo-section is deleted, shifting a later pseudo-section's position,
        // and that surviving pseudo-section's own auto-derived title has also
        // drifted because a trailing sentence was appended to its body (pseudo
        // titles are derived from content, so an edited body plausibly changes the
        // title too). The header's title is therefore deliberately DIFFERENT from
        // sP2's stored title -- only `contentRelated`'s prefix check (the header's
        // body is sP2's stored body plus an appended sentence) can put sP2 into
        // Tier 3's `related` set. Pseudo-sections skip Tier 2 (Tier 2 explicitly
        // excludes them), so Tier 3 is their only fallback path. Must not
        // misattribute the surviving pseudo-section's identity to the deleted
        // one's now-closer old slot.
        let headers = [
            makeHeader(position: 0, title: "A"),
            makeHeader(
                position: 1,
                title: "§ Knights and castles guard the border, ever vigilant through the night",
                isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\nKnights and castles guard the border tirelessly. Ever vigilant through the night."
            )
        ]
        let dbSections = [
            makeSection(id: "sA", sortOrder: 0, title: "A"),
            makeSection(
                id: "sP1", sortOrder: 1, title: "§ Wizards and dragons roam this land",
                isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\nWizards and dragons roam this land in peace."
            ),
            makeSection(
                id: "sP2", sortOrder: 2, title: "§ Knights and castles guard the border",
                isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\nKnights and castles guard the border tirelessly."
            )
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let deletes = Set(changes.compactMap { change -> String? in if case .delete(let id) = change { return id }; return nil })
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }; return nil
        }

        #expect(deletes == ["sP1"], "The genuinely-deleted pseudo-section (sP1) should be deleted")
        let p2Update = updates.first { $0.0 == "sP2" }
        #expect(p2Update != nil, "sP2 should survive matched to its own content, not stolen by sP1's old slot")
        if let p2Update {
            #expect(p2Update.1.sortOrder == 1, "sP2 should move to its new position 1")
            #expect(
                p2Update.1.title == "§ Knights and castles guard the border, ever vigilant through the night",
                "sP2's title should update to the header's new (content-derived) title"
            )
        }
    }

    @Test("Tier 3 pseudo-sections with empty content still degrade to proximity fallback")
    func tier3PseudoSectionsEmptyContentFallsBackToProximity() {
        // Fresh skeleton pseudo-sections with empty markdownContent (no
        // distinguishing body at all) and titles that all genuinely differ from
        // one another and from the reparsed header. Neither title equality nor
        // `contentRelated` (which returns false whenever either side is empty) can
        // put ANY candidate into Tier 3's `related` set here, so this genuinely
        // exercises the `related.isEmpty` fallback branch -- proximity alone,
        // exactly as Tier 3 behaved before the content-relatedness gate was added.
        // The header also deliberately does NOT land on a same-titled row's exact
        // sortOrder, so Tier 1's gate doesn't resolve this directly either.
        //
        // Note: none of the DB row titles here actually collide with the header's
        // title ("§ Section Break" vs "§ Fragment One" / "§ Fragment Two"), so this
        // test never exercised passesMatchGate's title clause even before the
        // pseudo-section fix below -- it only ever covered this pure-proximity
        // fallback branch. After the fix, this is the ONLY path left available to
        // a pseudo header with no content evidence at all, since pseudo headers no
        // longer get a title clause to fall back on either.
        let headers = [
            makeHeader(position: 0, title: "A"),
            makeHeader(position: 1, title: "§ Section Break", isPseudoSection: true)
        ]
        let dbSections = [
            makeSection(id: "sA", sortOrder: 0, title: "A"),
            makeSection(id: "sP1", sortOrder: 1, title: "§ Fragment One", isPseudoSection: true),
            makeSection(id: "sP2", sortOrder: 2, title: "§ Fragment Two", isPseudoSection: true)
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let inserts = changes.filter { if case .insert = $0 { return true }; return false }
        #expect(inserts.isEmpty, "Should still match via proximity fallback, not insert a new section")

        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }; return nil
        }
        let deletes = Set(changes.compactMap { change -> String? in if case .delete(let id) = change { return id }; return nil })

        let p1Update = updates.first { $0.0 == "sP1" }
        #expect(
            p1Update != nil,
            "Closest candidate (sP1) should be matched via the pure-proximity fallback since neither title nor content offers any evidence"
        )
        #expect(deletes.contains("sP2"), "Farther candidate (sP2) should be left unmatched and deleted, not stolen")
    }

    @Test("Tier 3 pseudo generic-title fallback still keeps its own row when it's the only candidate")
    func tier3PseudoGenericTitleFallbackKeepsItsOwnRow() {
        // Side-effect guard: passes before AND after this fix. A single break
        // sits at its own exact slot with the same generic title as before, but
        // its body has been rewritten to something wholly unrelated. Before the
        // fix, Tier 1 would match sP1 immediately via title equality (both titles
        // are literally "§ Section Break"), ignoring content entirely. After the
        // fix, Tier 1's pseudo branch drops the title clause and the content
        // check fails, so Tier 1 refuses -- and Tier 3's proximity fallback (not
        // Tier 1) is what actually recovers sP1, since it's the only candidate
        // within range and `related.isEmpty` degrades to pure proximity (the
        // title tiebreak is moot with a single candidate). Either way sP1 ends up
        // matched; this test pins that the *outcome* is unchanged for the
        // single-candidate case, only the internal tier that resolves it moves
        // (hence the name change from this test's original tier1-prefixed name).
        let headers = [
            makeHeader(position: 0, title: "A", markdownContent: "## A\nAlpha body."),
            makeHeader(
                position: 1, title: "§ Section Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\n> new quoted material"
            )
        ]
        let dbSections = [
            makeSection(id: "sA", sortOrder: 0, title: "A", markdownContent: "## A\nAlpha body."),
            makeSection(
                id: "sP1", sortOrder: 1, title: "§ Section Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\n> old quoted material"
            )
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }; return nil
        }
        let deletes = changes.filter { if case .delete = $0 { return true }; return false }
        let inserts = changes.filter { if case .insert = $0 { return true }; return false }

        #expect(inserts.isEmpty)
        #expect(deletes.isEmpty)
        #expect(updates.count == 1, "sP1 should get exactly one update")
        #expect(updates.first?.0 == "sP1", "sP1 should keep its own row via proximity fallback")
    }

    @Test("Tier 3 pseudo-section with a shared generic title does not steal from a genuine content match")
    func tier3PseudoSharedGenericTitleDoesNotStealFromContentMatch() {
        // THE CORE BUG. Two pseudo-sections share the same auto-derived generic
        // title "§ Section Break" (no distinguishing paragraph followed either
        // break in the DB's stored content -- see extractPseudoSectionTitle).
        // Before this fix, Tier 3's `related` filter accepted title equality
        // alone for pseudo headers too, so the NEARER row (sP1, content-unrelated)
        // would beat the FARTHER row (sP2, content-related) purely because they
        // happen to share the same generic title. After the fix, pseudo headers
        // get no title clause at all in the gate -- only content evidence counts,
        // so sP2 wins over sP1 even though sP1 is closer. No DB row exists at
        // sortOrder 1 (the header's own position), which isolates this to Tier 3
        // -- Tier 1 has nothing to accept or reject there.
        let headers = [
            makeHeader(position: 0, title: "A", markdownContent: "## A\nAlpha body."),
            makeHeader(
                position: 1, title: "§ Section Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\n- item one\n- item two\n- item three"
            )
        ]
        let dbSections = [
            makeSection(id: "sA", sortOrder: 0, title: "A", markdownContent: "## A\nAlpha body."),
            makeSection(
                id: "sP1", sortOrder: 2, title: "§ Section Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\n> quoted material, wholly unrelated"
            ),
            makeSection(
                id: "sP2", sortOrder: 3, title: "§ Section Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\n- item one\n- item two"
            )
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let deletes = changes.compactMap { change -> String? in if case .delete(let id) = change { return id }; return nil }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }; return nil
        }
        let inserts = changes.filter { if case .insert = $0 { return true }; return false }

        #expect(inserts.isEmpty, "No new sections should be inserted")
        #expect(deletes == ["sP1"], "sP1 (content-unrelated, merely closer) should be deleted, not stolen")
        let p2Update = updates.first { $0.0 == "sP2" }
        #expect(p2Update != nil, "sP2 (content-related, farther) should be matched, not sP1")
        if let p2Update {
            #expect(p2Update.1.sortOrder == 1, "sP2 should move to the header's position")
        }
    }

    @Test("Tier 3 farther content match displaces the nearer, evidence-free row")
    func tier3PseudoFartherContentMatchDisplacesNearestRow() {
        // Same shape as the previous test, but the unrelated row now sits at the
        // header's EXACT sortOrder slot, so Tier 1 sees it first. Tier 1's gate
        // still refuses it (no content evidence for a pseudo header), so the
        // header falls through to Tier 3, which correctly prefers the farther,
        // content-related row instead.
        //
        // This is the honest, tested version of a claim about "bounded impact"
        // that was explicitly withdrawn during plan review: sNear's status, tags,
        // and word goal are genuinely LOST here, not preserved. The document has
        // one fewer pseudo-section than the DB has rows in this shape, so exactly
        // one row must be discarded either way -- this fix discards the
        // evidence-free row (sNear) instead of the evidence-bearing one (sFar).
        // That is the intended, disclosed trade-off, not a side effect to paper
        // over.
        let headers = [
            makeHeader(position: 0, title: "A", markdownContent: "## A\nAlpha body."),
            makeHeader(
                position: 1, title: "§ Section Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\n- alpha item\n- beta item\n- gamma item"
            )
        ]
        let dbSections = [
            makeSection(id: "sA", sortOrder: 0, title: "A", markdownContent: "## A\nAlpha body."),
            makeSection(
                id: "sNear", sortOrder: 1, title: "§ Section Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\n> quoted material, wholly unrelated",
                status: .review, tags: ["near-tag"], wordGoal: 250
            ),
            makeSection(
                id: "sFar", sortOrder: 3, title: "§ Section Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\n- alpha item\n- beta item"
            )
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let deletes = changes.compactMap { change -> String? in if case .delete(let id) = change { return id }; return nil }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }; return nil
        }
        let inserts = changes.filter { if case .insert = $0 { return true }; return false }

        #expect(inserts.isEmpty, "No new sections should be inserted")
        #expect(deletes.contains("sNear"), "sNear (nearest, but no content evidence) must be displaced")
        let farUpdate = updates.first { $0.0 == "sFar" }
        #expect(farUpdate != nil, "sFar (content-related, farther) should be matched instead")
        if let farUpdate {
            #expect(farUpdate.1.sortOrder == 1, "sFar should move to the header's position")
        }
        // Before this fix, these assertions would invert: sNear matched (by
        // shared generic title) and sFar deleted -- and sNear's status/tags/word
        // goal would have survived on the wrong section while sFar's real
        // content-match was thrown away instead.
    }

    @Test("Tier 3 resolves crossed pseudo-section identities by content, not position")
    func tier3PseudoCrossedIdentitiesResolveByContent() {
        // Two section breaks whose bodies were effectively swapped relative to
        // their old DB slots. Both headers land exactly on a DB row's sortOrder,
        // but on the WRONG one -- so Tier 1's exact-position check finds a
        // candidate each time, but the content gate correctly refuses it both
        // times, and Tier 3 re-crosses them by content instead.
        let headers = [
            makeHeader(position: 0, title: "A", markdownContent: "## A\nAlpha body."),
            makeHeader(
                position: 1, title: "§ Section Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\nThe quartz canyon glows amber at dusk."
            ),
            makeHeader(
                position: 2, title: "§ Section Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\nA lone violin echoes through the empty hall."
            )
        ]
        let dbSections = [
            makeSection(id: "sA", sortOrder: 0, title: "A", markdownContent: "## A\nAlpha body."),
            makeSection(
                id: "sY", sortOrder: 1, title: "§ Section Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\nA lone violin echoes through the empty hall."
            ),
            makeSection(
                id: "sX", sortOrder: 2, title: "§ Section Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\nThe quartz canyon glows amber at dusk."
            )
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let deletes = changes.filter { if case .delete = $0 { return true }; return false }
        let inserts = changes.filter { if case .insert = $0 { return true }; return false }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }; return nil
        }

        #expect(deletes.isEmpty, "Both pseudo-sections should be matched, not deleted")
        #expect(inserts.isEmpty, "Both pseudo-sections should be matched, not inserted as new")

        let xUpdate = updates.first { $0.0 == "sX" }
        let yUpdate = updates.first { $0.0 == "sY" }
        #expect(xUpdate != nil, "sX should be matched by content")
        #expect(yUpdate != nil, "sY should be matched by content")
        if let xUpdate {
            #expect(xUpdate.1.sortOrder == 1, "sX's content (quartz canyon) matches the header now at position 1")
        }
        if let yUpdate {
            #expect(yUpdate.1.sortOrder == 2, "sY's content (violin) matches the header now at position 2")
        }
    }

    @Test("A marker-only pseudo-section body is not content evidence for anything")
    func tier3PseudoMarkerOnlyRowIsNotContentEvidence() {
        // sBare's entire content is the break marker line with nothing after it
        // -- exactly what a real document produces when two breaks sit adjacent,
        // or a break precedes a heading with no intervening paragraph. Without
        // stripping the marker (Step 2), sBare's RAW content is a literal prefix
        // of every other pseudo-section's raw content (they all start with the
        // same marker line), so `contentRelated` would count it as "evidence"
        // against anything -- and since sBare also sits at the header's exact
        // sortOrder, it would win at Tier 1 before Tier 3 is ever consulted,
        // stealing the slot from sP1, the row that's actually related by its real
        // (post-marker) content.
        let headers = [
            makeHeader(position: 0, title: "A", markdownContent: "## A\nAlpha body."),
            makeHeader(
                position: 1, title: "§ Section Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\n> distinctive quoted content unique to this section"
            )
        ]
        let dbSections = [
            makeSection(id: "sA", sortOrder: 0, title: "A", markdownContent: "## A\nAlpha body."),
            makeSection(
                id: "sBare", sortOrder: 1, title: "§ Section Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\n"
            ),
            makeSection(
                id: "sP1", sortOrder: 2, title: "§ Section Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\n> distinctive quoted content unique to this section"
            )
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let deletes = changes.compactMap { change -> String? in if case .delete(let id) = change { return id }; return nil }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }; return nil
        }
        let inserts = changes.filter { if case .insert = $0 { return true }; return false }

        #expect(inserts.isEmpty)
        #expect(deletes == ["sBare"], "The marker-only row must be deleted, not the content-related one")
        let p1Update = updates.first { $0.0 == "sP1" }
        #expect(p1Update != nil, "sP1 (genuinely content-related) should be matched")
        if let p1Update {
            #expect(p1Update.1.sortOrder == 1, "sP1 should move to the header's position")
        }
    }

    @Test("A bare marker at the end of a document (no trailing newline) is never content evidence")
    func tier3PseudoBareMarkerAtDocumentEndIsNeverContentEvidence() {
        // "F10" gap flagged in review: a section break that is the very LAST line
        // of a document has no trailing newline, so its markdownContent is
        // LITERALLY "<!-- ::break:: -->" with no newline at all -- a different,
        // previously-untested branch of strippingLeadingBreakMarker than the
        // marker-plus-newline case covered by
        // tier3PseudoMarkerOnlyRowIsNotContentEvidence above. Both the header and
        // sBareFar strip to "", exercising contentRelated's isEmpty guard.
        //
        // The proof this guard matters: after fix #1, `related`'s composition is
        // asymmetric between kinds -- it can only ever contain OTHER
        // pseudo-sections (existing.isPseudoSection is gated before content is
        // even considered), while the `inRange` proximity fallback has no such
        // restriction and can contain non-pseudo rows too. If contentRelated's
        // empty guard were broken, the empty header's stripped content would
        // spuriously "relate" to sBareFar (also pseudo, also empty after
        // stripping), populating `related` and thereby EXCLUDING sNonPseudoNear
        // -- which is only reachable through the unrestricted `inRange` fallback
        // -- even though sNonPseudoNear is the header's true nearest candidate
        // and the only legitimate resolution once there is genuinely zero
        // content evidence anywhere. With the guard intact, `related` stays
        // empty and sNonPseudoNear correctly wins by proximity instead. Neither
        // decoy's title matches the header's, so the Tier 3 title tiebreak can't
        // confound this either -- only the content guard is under test.
        let headers = [
            makeHeader(position: 0, title: "A", markdownContent: "## A\nAlpha body."),
            makeHeader(position: 1, title: "§ Section Break", isPseudoSection: true, markdownContent: "<!-- ::break:: -->")
        ]
        let dbSections = [
            makeSection(id: "sA", sortOrder: 0, title: "A", markdownContent: "## A\nAlpha body."),
            makeSection(id: "sNonPseudoNear", sortOrder: 1, title: "Random Heading", markdownContent: "## Random Heading\nSome body."),
            makeSection(
                id: "sBareFar", sortOrder: 3, title: "§ Some Other Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->"
            )
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let deletes = changes.compactMap { change -> String? in if case .delete(let id) = change { return id }; return nil }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }; return nil
        }
        let inserts = changes.filter { if case .insert = $0 { return true }; return false }

        #expect(inserts.isEmpty, "No new sections should be inserted")
        #expect(deletes == ["sBareFar"], "The evidence-free bare marker must be deleted, not matched")
        #expect(updates.contains { $0.0 == "sNonPseudoNear" }, "The header should fall back to its true nearest candidate")
        // If contentRelated's empty guard were removed, sBareFar (wrongly
        // "evidenced" by two empty strings) would win Tier 3 instead, and
        // sNonPseudoNear -- reachable only through the kind-unrestricted
        // `inRange` fallback -- would be wrongly left deleted.
    }

    // MARK: - Cross-Kind Gate (Fix Round 2)

    @Test("A pseudo header's stripped body must never content-match a non-pseudo row's raw content")
    func tier3PseudoStrippedBodyNeverMatchesNonPseudoRawContent() {
        // Adversarial cross-kind case flagged in review: a pseudo header's
        // marker-stripped body can coincidentally be a SUFFIX of an unrelated
        // real heading's raw (unstripped) content -- "Some body text." is a
        // suffix of "## Heading\nSome body text.". Before fix #1 (gating
        // passesMatchGate's pseudo branch on `existing.isPseudoSection`), that
        // coincidence let `contentRelated` return true, and Tier 3's `related`
        // filter would wrongly include the real heading as "evidence" -- a
        // section break silently reinterpreted as a real heading's row. The
        // header's title matches neither decoy's title, so the Tier 3 title
        // tiebreak can't confound this: only the kind-gate is under test.
        let headers = [
            makeHeader(position: 0, title: "A", markdownContent: "## A\nAlpha body."),
            makeHeader(
                position: 1, title: "§ Section Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\nSome body text."
            )
        ]
        let dbSections = [
            makeSection(id: "sA", sortOrder: 0, title: "A", markdownContent: "## A\nAlpha body."),
            makeSection(id: "sHeadingDecoy", sortOrder: 1, title: "Heading", markdownContent: "## Heading\nSome body text."),
            makeSection(
                id: "sGenuine", sortOrder: 3, title: "§ Some Other Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\nSome body text. Continued with more detail."
            )
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let deletes = changes.compactMap { change -> String? in if case .delete(let id) = change { return id }; return nil }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }; return nil
        }
        let inserts = changes.filter { if case .insert = $0 { return true }; return false }

        #expect(inserts.isEmpty, "No new sections should be inserted")
        #expect(deletes == ["sHeadingDecoy"], "The real heading must be deleted, not stolen by the pseudo header")
        #expect(!updates.contains { $0.0 == "sHeadingDecoy" }, "A pseudo header must never claim a real heading's row")
        let genuineUpdate = updates.first { $0.0 == "sGenuine" }
        #expect(genuineUpdate != nil, "The farther, genuinely pseudo, content-related row should match instead")
        if let genuineUpdate {
            #expect(genuineUpdate.1.sortOrder == 1, "sGenuine should move to the header's position")
        }
        // Before fix #1: sHeadingDecoy (distance 0, cross-kind content
        // coincidence) would have won Tier 3's `.min`, sGenuine (distance 2,
        // genuinely related) would have been left deleted, and the real
        // "Heading" row would have been overwritten with pseudo-section
        // identity (title, isPseudoSection, content) -- a section break
        // silently reinterpreted as a real heading's row.
    }

    // MARK: - Title Tiebreak (Fix Round 2)

    @Test("Tier 3 title tiebreak: a farther title-matching row beats a nearer title-mismatched one")
    func tier3TitleTiebreakPrefersFartherTitleMatchOverCloserMismatch() {
        // A pseudo-section's auto-derived title only depends on the opening ~30
        // characters of the paragraph following the break marker (see
        // extractPseudoSectionTitle) -- so a heavily-edited body can keep a
        // STABLE, distinctive (non-generic-fallback) title even though the rest
        // of the paragraph changed enough to fail contentRelated's
        // prefix/suffix check entirely. Without the title tiebreak, Tier 3's
        // `related` set is empty here (neither candidate has content
        // evidence), so pure proximity would hand the match to whichever row
        // is merely closer -- sCloserDecoy, which shares nothing with the
        // header. The tiebreak instead correctly prefers sTitleMatch, which is
        // farther but title-identical.
        let distinctiveTitle = "§ A distinctive title from the paragraph"
        let headers = [
            makeHeader(position: 0, title: "A", markdownContent: "## A\nAlpha body."),
            makeHeader(
                position: 1, title: distinctiveTitle, isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\nA completely rewritten paragraph with all new wording throughout."
            )
        ]
        let dbSections = [
            makeSection(id: "sA", sortOrder: 0, title: "A", markdownContent: "## A\nAlpha body."),
            makeSection(
                id: "sCloserDecoy", sortOrder: 1, title: "§ Something else entirely different", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\nYet another unrelated paragraph of text."
            ),
            makeSection(
                id: "sTitleMatch", sortOrder: 3, title: distinctiveTitle, isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\nThe original paragraph before any edits happened here today."
            )
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let deletes = changes.compactMap { change -> String? in if case .delete(let id) = change { return id }; return nil }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }; return nil
        }
        let inserts = changes.filter { if case .insert = $0 { return true }; return false }

        #expect(inserts.isEmpty, "No new sections should be inserted")
        #expect(deletes.contains("sCloserDecoy"), "The closer but title-mismatched row must lose the tiebreak")
        let titleMatchUpdate = updates.first { $0.0 == "sTitleMatch" }
        #expect(titleMatchUpdate != nil, "The farther, title-matching row should win instead")
        if let titleMatchUpdate {
            #expect(titleMatchUpdate.1.sortOrder == 1, "sTitleMatch should move to the header's position")
        }
        // Before the title-tiebreak fix, `.min` compared purely by distance:
        // sCloserDecoy (distance 0) would have won, and sTitleMatch (distance
        // 2, but title-identical) would have been wrongly deleted.
    }

    // MARK: - Live-Editor Formatting Drift (Fix Round 3)

    @Test("Tier 3 content match survives the live editor's list-reformatting round-trip")
    func tier3PseudoContentMatchSurvivesEditorRoundTripFormattingDrift() {
        // Reproduces the EXACT gap a real end-to-end run (driving the actual
        // running app, not this unit test's synthetic reconcile() call) found
        // in fix round 2: three pseudo-sections sharing the generic title
        // "§ Section Break", each with its own status, then a one-shot edit
        // that removes two of them and extends the third's list. The e2e test
        // failed with the surviving row carrying break 1's identity/status,
        // not break 3's -- the pre-fix bug, reintroduced through a formatting
        // side-channel `strippingLeadingBreakMarker` alone didn't cover.
        //
        // Root cause, confirmed by directly reproducing the real Milkdown
        // pipeline (Editor.make() with sectionBreakPlugin + commonmark + gfm,
        // fed this app's own seed/replacement markdown -- not guessed): a
        // Source Mode paste's reparse goes through `api-content.ts`'s
        // `getContent()`, which calls Milkdown's own whole-document
        // `getMarkdown()` serializer. That serializer (a) always emits "*"
        // for bullet markers regardless of source, and (b) turns a multi-item
        // tight list into a "loose" one, giving each item its own
        // blank-line-separated line. Neither transformation touches this
        // app's canonical block-fragment builder
        // (`block-sync-plugin.ts`'s `nodeToMarkdownFragment`, which always
        // emits "- " and joins items with a single "\n") -- so a freshly
        // re-parsed header's markdownContent and the DB row's ORIGINAL
        // stored markdownContent (seeded/derived via the block-fragment
        // path) can describe byte-different text for what is, semantically,
        // the identical list.
        //
        // sBreak3's stored content ("- gamma one\n- gamma two", tight, dash)
        // deliberately does NOT match the header's post-edit content
        // ("* gamma one\n\n* gamma two\n\n* gamma three\n", loose, asterisk)
        // under a byte-exact comparison -- only the list-formatting
        // normalization added in fix round 3 bridges them.
        let headers = [
            makeHeader(position: 0, title: "A", markdownContent: "## A\nIntro paragraph for section A."),
            makeHeader(
                position: 1, title: "§ Section Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\n\n* gamma one\n\n* gamma two\n\n* gamma three\n"
            )
        ]
        let dbSections = [
            makeSection(id: "sA", sortOrder: 0, title: "A", markdownContent: "## A\nIntro paragraph for section A."),
            makeSection(
                id: "sBreak1", sortOrder: 1, title: "§ Section Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\n- alpha one", status: .writing
            ),
            makeSection(
                id: "sBreak2", sortOrder: 2, title: "§ Section Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\n- beta one", status: .review
            ),
            makeSection(
                id: "sBreak3", sortOrder: 3, title: "§ Section Break", isPseudoSection: true,
                markdownContent: "<!-- ::break:: -->\n- gamma one\n- gamma two", status: .final_
            )
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let deletes = Set(changes.compactMap { change -> String? in if case .delete(let id) = change { return id }; return nil })
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }; return nil
        }
        let inserts = changes.filter { if case .insert = $0 { return true }; return false }

        #expect(inserts.isEmpty, "No new sections should be inserted")
        #expect(deletes == ["sBreak1", "sBreak2"], "Only the genuinely-removed breaks should be deleted")

        let survivorUpdate = updates.first { $0.0 == "sBreak3" }
        #expect(survivorUpdate != nil, "sBreak3 (content-related once formatting drift is normalized) should be matched")
        if let survivorUpdate {
            #expect(survivorUpdate.1.sortOrder == 1, "sBreak3 should move to the header's position")
        }
        // Before this fix (formatting normalization absent, `strippingLeadingBreakMarker`
        // alone): contentRelated would fail for ALL THREE candidates (sBreak3
        // included, defeated by the "*"/loose-list drift), so `related` would be
        // empty and Tier 3 would fall back to `inRange` with the title tiebreak --
        // which cannot discriminate here, since all three DB rows share the exact
        // same generic title as the header. Pure proximity would then hand the
        // match to sBreak1 (distance 0), exactly the e2e failure: the surviving
        // row would carry break 1's id and "writing" status, not break 3's "final_".
        #expect(!updates.contains { $0.0 == "sBreak1" }, "sBreak1's row must not be repurposed for break 3's content")
        #expect(!updates.contains { $0.0 == "sBreak2" }, "sBreak2's row must not be repurposed for break 3's content")
    }

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
        // `tier3PseudoBareMarkerAtDocumentEndIsNeverContentEvidence` above), so
        // BOTH candidates fail the content gate and `related` is empty here too.
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
