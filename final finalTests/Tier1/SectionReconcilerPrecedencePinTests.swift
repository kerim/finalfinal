//
//  SectionReconcilerPrecedencePinTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tier-major precedence pins for SectionReconciler's five-pass matching. These exist
//  because the old single header-major loop let an earlier header's weaker evidence (a
//  pure-proximity grab) claim a row a later header would have matched more strongly by
//  title, silently relabeling rows. Each pin discriminates pre-fix from post-fix unless
//  its own comment says otherwise.
//
//  Split rationale — two different reasons, not one:
//  (a) G, G′ and I were split out of SectionReconcilerTests.swift to keep that file
//      under SwiftLint's file_length warning (mirrors SectionReconcilerPseudoSectionTests.swift).
//  (b) E, E″ and E′ were never in SectionReconcilerTests.swift: they are housed here
//      because adding them to the pseudo-section file would have pushed that 878-line
//      file over the file_length ERROR (1000 lines), not the warning.
//

import Testing
import Foundation
@testable import final_final

@Suite("Section Reconciler — Tier-Major Precedence Pins")
// swiftlint:disable:next type_body_length
struct SectionReconcilerPrecedencePinTests {

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
        wordCount: Int = 10,
        isBibliography: Bool = false,
        isNotes: Bool = false
    ) -> ParsedHeader {
        ParsedHeader(
            position: position,
            title: title,
            level: level,
            isPseudoSection: isPseudoSection,
            startOffset: startOffset,
            markdownContent: markdownContent,
            wordCount: wordCount,
            isBibliography: isBibliography,
            isNotes: isNotes
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

    // MARK: - Tier 3 Residual (accepted trade-off)

    @Test("Earlier header with weak evidence still beats a later header with identical evidence")
    func earlierHeaderWithWeakEvidenceStillBeatsLaterIdenticalEvidence() throws {
        // ACCEPTED TRADE-OFF (tier-major reconciliation, tracked like t-8f7644f5):
        // Within Pass 3a headers are still visited in document order, so an earlier header
        // with prefix-only evidence can beat a later header with byte-identical evidence.
        // Closing that would need either a fifth evidence-strength pass or a full global
        // assignment, both rejected as disproportionate to the reported bug; this test pins
        // the current behaviour so a future attempt registers as a deliberate change.
        //
        // NON-DISCRIMINATING on purpose: pre-fix and post-fix produce the same changes.
        let headers = [
            makeHeader(position: 0, title: "Different A",
                       markdownContent: "## Row Title\nAlpha beta gamma. plus extra tail"),
            makeHeader(position: 1, title: "Row Title", level: 3,
                       markdownContent: "## Row Title\nAlpha beta gamma.")
        ]
        let dbSections = [
            makeSection(id: "r", sortOrder: 2, title: "Row Title", headerLevel: 2,
                        markdownContent: "## Row Title\nAlpha beta gamma.")
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let inserts = changes.compactMap { change -> Section? in
            if case .insert(let section) = change { return section }
            return nil
        }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }
            return nil
        }
        // Delete binding, matching the sibling pins: without it, an implementation that
        // emitted the expected update + insert AND a spurious extra delete would pass here.
        let deletedIds = changes.compactMap { change -> String? in
            switch change {
            case .delete(let id): return id
            case .deleteDuplicate(let loserId, _, _): return loserId
            default: return nil
            }
        }

        let rUpdate = try #require(updates.first { $0.0 == "r" },
                                   "The earlier header's prefix-only evidence admits r in Pass 3a")
        #expect(rUpdate.1.title == "Different A", "r is relabeled by the earlier header — the pinned residual")
        #expect(rUpdate.1.sortOrder == 0, "r moves to the earlier header's index")
        #expect(inserts.map(\.title) == ["Row Title"], "The later header inserts instead")
        #expect(inserts.map(\.sortOrder) == [1], "Its insert lands at its own index")
        #expect(deletedIds.isEmpty, "No row should be deleted")
    }

    // MARK: - Pass 2 Outranks Earlier 3a Content Evidence

    @Test("Earlier byte-identical content header yields to a later Pass 2 title+level match")
    func earlierIdenticalContentHeaderYieldsToLaterTitleLevelMatch() throws {
        // Deliberate and accepted: title+level is stronger evidence than byte-identical
        // content, consistent with the ranking the pseudo-row pins disclose below.
        let rowContent = "## Row Title\nAlpha beta gamma."
        let headers = [
            makeHeader(position: 0, title: "Different A", markdownContent: rowContent),
            makeHeader(position: 1, title: "Row Title",
                       markdownContent: "## Row Title\nSomething else entirely.")
        ]
        let dbSections = [
            makeSection(id: "r", sortOrder: 2, title: "Row Title", headerLevel: 2,
                        markdownContent: rowContent)
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let inserts = changes.compactMap { change -> Section? in
            if case .insert(let section) = change { return section }
            return nil
        }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }
            return nil
        }
        let deletedIds = changes.compactMap { change -> String? in
            switch change {
            case .delete(let id): return id
            case .deleteDuplicate(let loserId, _, _): return loserId
            default: return nil
            }
        }

        let rUpdate = try #require(updates.first { $0.0 == "r" },
                                   "The later header must claim r in Pass 2")
        #expect(rUpdate.1.title == nil, "r must never be relabeled to the earlier header's title")
        #expect(rUpdate.1.sortOrder == 1, "r moves to the later header's index")
        #expect(inserts.map(\.title) == ["Different A"],
                "The earlier header, whose only evidence was content, now inserts")
        #expect(inserts.map(\.sortOrder) == [0], "Its insert lands at its own index")
        #expect(deletedIds.isEmpty, "No row should be deleted")
    }

    // MARK: - Pass 1 Outranks Earlier Pass 2 Title Match

    @Test("Later header's exact-position match beats an earlier header's title match anywhere")
    func laterHeaderExactPositionBeatsEarlierHeaderTitleMatchAnywhere() {
        // Discloses the deliberate Pass-1-beats-earlier-Pass-2 change: the row's
        // status/tags/wordGoal stay with the card sitting at the row's own slot.
        let rowContent = "## Alpha\nOriginal body."
        let headers = [
            makeHeader(position: 0, title: "Alpha", markdownContent: rowContent),
            makeHeader(position: 1, title: "Alpha", markdownContent: rowContent)
        ]
        let dbSections = [
            makeSection(id: "X", sortOrder: 1, title: "Alpha", headerLevel: 2,
                        markdownContent: rowContent)
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let inserts = changes.compactMap { change -> Section? in
            if case .insert(let section) = change { return section }
            return nil
        }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }
            return nil
        }
        let deletedIds = changes.compactMap { change -> String? in
            switch change {
            case .delete(let id): return id
            case .deleteDuplicate(let loserId, _, _): return loserId
            default: return nil
            }
        }

        #expect(inserts.map(\.title) == ["Alpha"], "Only the earlier header inserts")
        #expect(inserts.map(\.sortOrder) == [0], "Its insert lands at its own index")
        #expect(updates.isEmpty, "X is untouched — no metadata moves")
        #expect(deletedIds.isEmpty, "No row should be deleted")
    }

    // MARK: - Gate 5: Real Heading Claims a Pseudo Row

    @Test("Real heading's Pass 2 title match claims a pseudo row before the earlier pseudo header")
    func realHeadingTitleMatchClaimsPseudoRowBeforeEarlierPseudoHeaderContentMatch() throws {
        // Gate 5, the Pass 2 form. The pseudo header sits at position 0 — deliberately NOT
        // at pRow's slot (1), which is exactly what makes this the Pass 2 form rather than
        // the Pass-1 form pinned in realHeadingAtPseudoRowSlotClaimsItInPassOne. The real
        // heading is also deliberately away from pRow's slot.
        //
        // What this test actually pins (B1): that the real heading ends up owning pRow —
        // asserted only through the observable update payload, which flips
        // `isPseudoSection` to false — and that the displaced pseudo header inserts a fresh
        // section at Section's DEFAULTS (status == .next, tags empty, wordGoal nil).
        //
        // It does NOT pin the row-side half of the Gate-5 metadata disclosure: `buildUpdates`
        // never writes status/tags/wordGoal, so the update payload is structurally incapable
        // of showing whether pRow's `.review`/["bib-tag"]/500 survived, and no assertion here
        // could observe them. The three insert-default assertions are also NOT discriminating:
        // pre-fix the pseudo header inserted through the same `insertChange` with the same
        // defaults. What IS discriminating is who owns pRow.
        let pRowContent = "<!-- ::break:: -->\nBridge Notes and the prose continues here."
        let headers = [
            makeHeader(position: 0, title: "§ Section Break", isPseudoSection: true,
                       markdownContent: pRowContent),
            makeHeader(position: 2, title: "Bridge Notes",
                       markdownContent: "## Bridge Notes\nSome body.")
        ]
        let dbSections = [
            makeSection(id: "pRow", sortOrder: 1, title: "Bridge Notes", isPseudoSection: true,
                        markdownContent: pRowContent, status: .review, tags: ["bib-tag"],
                        wordGoal: 500)
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let inserts = changes.compactMap { change -> Section? in
            if case .insert(let section) = change { return section }
            return nil
        }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }
            return nil
        }
        let deletedIds = changes.compactMap { change -> String? in
            switch change {
            case .delete(let id): return id
            case .deleteDuplicate(let loserId, _, _): return loserId
            default: return nil
            }
        }

        let pRowUpdate = try #require(updates.first { $0.0 == "pRow" },
                                      "The real heading must claim pRow")
        #expect(inserts.count == 1, "The pseudo header inserts; the real heading claims pRow")
        #expect(inserts.first?.isPseudoSection == true, "The inserted section is the pseudo one")
        #expect(inserts.first?.sortOrder == 0, "It lands at the pseudo header's index")
        #expect(inserts.first?.title == "§ Section Break", "It carries the pseudo header's title")
        #expect(inserts.first?.status == .next, "A fresh insert starts at the default status")
        #expect(inserts.first?.tags.isEmpty == true, "A fresh insert starts with no tags")
        #expect(inserts.first?.wordGoal == nil, "A fresh insert starts with no word goal")
        #expect(pRowUpdate.1.isPseudoSection == false, "pRow flips to a real section")
        #expect(pRowUpdate.1.title == nil, "pRow's title already matches — no relabel")
        #expect(pRowUpdate.1.sortOrder == nil, "pRow already sits at the winner's index")
        #expect(deletedIds.isEmpty, "No row should be deleted")
    }

    @Test("Real heading at the pseudo row's own slot claims it in Pass 1")
    func realHeadingAtPseudoRowSlotClaimsItInPassOne() throws {
        // Gate 5, the Pass-1 form — the true second instance. The real heading sits exactly
        // at pRow.sortOrder and is ordered AFTER the pseudo header, so Pass 1's non-pseudo
        // branch of passesMatchGate (which accepts title equality without consulting
        // existing.isPseudoSection) claims it; pre-fix the earlier pseudo header claimed
        // pRow in Tier 3 by content, so the winner inverts on header order alone.
        //
        // What this test actually pins (B1, mirrored from the Pass 2 form above): that the
        // real heading owns pRow — via the observable `isPseudoSection == false` flip — and
        // that the displaced pseudo header inserts at Section's defaults. It does NOT pin the
        // row-side half of the metadata disclosure: `buildUpdates` never writes
        // status/tags/wordGoal, so no assertion here could observe pRow's
        // `.review`/["bib-tag"]/500 surviving, and the three insert-default assertions are
        // not discriminating (the pre-fix insert used the same `insertChange` defaults).
        let pRowContent = "<!-- ::break:: -->\nBridge Notes and the prose continues here."
        let headers = [
            makeHeader(position: 0, title: "§ Section Break", isPseudoSection: true,
                       markdownContent: pRowContent),
            makeHeader(position: 1, title: "Bridge Notes",
                       markdownContent: "## Bridge Notes\nSome body.")
        ]
        let dbSections = [
            makeSection(id: "pRow", sortOrder: 1, title: "Bridge Notes", isPseudoSection: true,
                        markdownContent: pRowContent, status: .review, tags: ["bib-tag"],
                        wordGoal: 500)
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let inserts = changes.compactMap { change -> Section? in
            if case .insert(let section) = change { return section }
            return nil
        }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }
            return nil
        }
        let deletedIds = changes.compactMap { change -> String? in
            switch change {
            case .delete(let id): return id
            case .deleteDuplicate(let loserId, _, _): return loserId
            default: return nil
            }
        }

        let pRowUpdate = try #require(updates.first { $0.0 == "pRow" },
                                      "The real heading must claim pRow in Pass 1")
        #expect(inserts.map(\.title) == ["§ Section Break"],
                "The pseudo header inserts once the real heading has taken its row")
        #expect(inserts.first?.isPseudoSection == true, "The inserted section is the pseudo one")
        #expect(inserts.map(\.sortOrder) == [0], "It lands at the pseudo header's index")
        #expect(inserts.first?.status == .next, "A fresh insert starts at the default status")
        #expect(inserts.first?.tags.isEmpty == true, "A fresh insert starts with no tags")
        #expect(inserts.first?.wordGoal == nil, "A fresh insert starts with no word goal")
        #expect(pRowUpdate.1.isPseudoSection == false, "pRow flips to a real section")
        #expect(pRowUpdate.1.title == nil, "pRow's title already matches — no relabel")
        #expect(pRowUpdate.1.sortOrder == nil, "pRow already sits at the winner's index")
        #expect(deletedIds.isEmpty, "No row should be deleted")
    }

    @Test("Pseudo header keeps its own row against a later real heading — the mirror")
    func pseudoHeaderKeepsItsOwnRowAgainstLaterRealHeading() {
        // The mirror of the two Gate 5 instances above, not a third instance: pre-fix the
        // real heading ordered BEFORE the pseudo header stole pRow via Tier 2; post-fix the
        // pseudo header keeps it via Pass 1.
        //
        // Deliberate fixture decoupling (C7): the real heading's position (3) is NOT its array
        // index (0) — production always has `position == index`. The decoupling is what makes
        // this the mirror rather than a third Pass-1 instance: with contiguous positions the
        // real heading at index 0 would sit at pRow's own slot (1) only by coincidence, and
        // the point here is precisely that it does NOT, so the pseudo header's exact-position
        // claim on pRow is the only Pass-1 candidate and survives. Changing position 3 → 0
        // would collapse this into the Pass-1 form already pinned above.
        let pRowContent = "<!-- ::break:: -->\nBridge Notes and the prose continues here."
        let headers = [
            makeHeader(position: 3, title: "Bridge Notes",
                       markdownContent: "## Bridge Notes\nSome body."),
            makeHeader(position: 1, title: "Bridge Notes", isPseudoSection: true,
                       markdownContent: pRowContent)
        ]
        let dbSections = [
            makeSection(id: "pRow", sortOrder: 1, title: "Bridge Notes", isPseudoSection: true,
                        markdownContent: pRowContent, status: .review, tags: ["bib-tag"],
                        wordGoal: 500)
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let inserts = changes.compactMap { change -> Section? in
            if case .insert(let section) = change { return section }
            return nil
        }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }
            return nil
        }
        let deletedIds = changes.compactMap { change -> String? in
            switch change {
            case .delete(let id): return id
            case .deleteDuplicate(let loserId, _, _): return loserId
            default: return nil
            }
        }

        #expect(inserts.map(\.title) == ["Bridge Notes"], "The real heading inserts instead")
        #expect(inserts.first?.isPseudoSection == false, "The insert is a real section")
        #expect(inserts.map(\.sortOrder) == [0], "Its insert lands at its own index")
        #expect(updates.isEmpty, "The pseudo header's exact-position match changes nothing")
        #expect(deletedIds.isEmpty, "No row should be deleted")
    }

    // MARK: - Swept-Row Set Is Not Invariant (C1/A4)

    @Test("Spillover row: a proximity-grabbed row lost to a later exact-position match is hard-deleted")
    func spilloverRowLostToLaterExactPositionMatchIsHardDeleted() throws {
        // C1/A4 — the change's most consequential and least-obvious consequence: the tier-major
        // reorder does not merely reassign which row a header keeps, it changes WHICH ROWS THE
        // SWEEP HARD-DELETES. Production-realistic shape (positions contiguous with their
        // indices, as production guarantees): H1@0, H2@1; rows A@1 and B@4; H2's title equals
        // A's, H1's stored content relates to A, and B is unrelated to both.
        //
        // Pre-fix: H1's Tier-3 content pass claimed A (both `inRange` and `related`), and H2 —
        // left only with B, which no title/proximity evidence reaches but which sits inside
        // ±3 of H2's position — took B via the gate-free fallback. BOTH rows matched, ZERO
        // deletes, two relabels.
        // Post-fix: Pass 1 gives A to H2. H1's 3a/3b windows are empty (|4 − 0| = 4 > ±3), so
        // H1 inserts, and B is unmatched and plain-`.delete`d. A plain delete migrates nothing:
        // B's id, status, tags, wordGoal and annotation links all go, where pre-fix the row
        // survived (under a wrong title, which is the bug this task fixed). Accepted by
        // orphan-delete-decision.md; this test is the disclosure's executable half.
        let aContent = "## Alpha\nShared body text for the relationship check."
        let bContent = "## Beta\nAn unrelated section the user removed."
        let headers = [
            makeHeader(position: 0, title: "Heading One", markdownContent: aContent),
            makeHeader(position: 1, title: "Alpha", markdownContent: "## Alpha\nSome different body.")
        ]
        let dbSections = [
            makeSection(id: "rowA", sortOrder: 1, title: "Alpha", headerLevel: 2,
                        markdownContent: aContent, status: .final_, tags: ["kept-tag"],
                        wordGoal: 1200),
            makeSection(id: "rowB", sortOrder: 4, title: "Beta", headerLevel: 2,
                        markdownContent: bContent, status: .review, tags: ["orphan-tag"],
                        wordGoal: 700)
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let inserts = changes.compactMap { change -> Section? in
            if case .insert(let section) = change { return section }
            return nil
        }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }
            return nil
        }
        let deletes = changes.compactMap { change -> String? in
            if case .delete(let id) = change { return id }
            return nil
        }
        let deleteDuplicates = changes.compactMap { change -> String? in
            if case .deleteDuplicate(let loserId, _, _) = change { return loserId }
            return nil
        }

        // The full change list, in header order: H1 inserts, H2 updates rowA, rowB is swept.
        let order = changes.compactMap { change -> String? in
            switch change {
            case .insert(let section):       return "insert:\(section.title)"
            case .update(let id, _):         return "update:\(id)"
            case .delete(let id):            return "delete:\(id)"
            case .deleteDuplicate(let loserId, _, _): return "deleteDuplicate:\(loserId)"
            }
        }
        #expect(order == ["insert:Heading One", "update:rowA", "delete:rowB"],
                "The full change list in header order: H1 inserts, H2 relabels rowA, rowB is swept")

        #expect(inserts.map(\.sortOrder) == [0], "Its insert lands at H1's own index")

        let rowAUpdate = try #require(updates.first { $0.0 == "rowA" },
                                      "H2 must claim rowA by exact position + title")
        #expect(rowAUpdate.1.title == nil,
                "rowA already reads Alpha — the title equality that admitted the claim is the same fact, so nothing is relabeled")
        #expect(rowAUpdate.1.sortOrder == nil,
                "rowA already sits at H2's index, so no position moves either — only its body changes")

        #expect(deletes == ["rowB"],
                "EXACT swept set: the one row no header can now reach is hard-deleted")
        #expect(deleteDuplicates.isEmpty,
                "rowB is unflagged, so it takes the plain .delete path with no data migration")
        #expect(!deletes.contains("rowA"), "The row H2 claimed must never be swept")
    }

    @Test("Three-heading fixture: the old order kept every row, the new order sweeps the second spillover row")
    func threeHeadingFixtureSweepsTheSecondSpilloverRow() throws {
        // C1's three-heading/three-row fixture, the shape the reviewer traced: headers
        // h0(0,"D") · h1(1,"C") · h2(2,"A") against rows R0(title "A") · R1(title "C") ·
        // R2(title "C"). Note R2 is a second same-titled spillover row and carries real user
        // metadata, so this is not merely a stale duplicate — the sweep destroys live data
        // either way. Positions are contiguous with their indices; the rows' sortOrders are
        // deliberately non-contiguous (0/1/4), which matters because `findTitleMatch` picks the
        // FIRST title+level row in sorted order, not the closest (C5), and because
        // `buildUpdates` renumbers by index.
        //
        // Pre-fix (header-major): h0 has no title match and no related content, so its Tier-3
        // `related` set is empty and the pure-proximity `.min` picks the NEAREST in-range row,
        // R0 at distance 0 — relabeling R0 to "D" and moving it to index 0. h1 then claims R1
        // by exact position + title, and h2, finding R0 already claimed and no title match for
        // R2, takes R2 through the gate-free in-range fallback at distance 2. ALL THREE rows
        // matched, ZERO deletes.
        // Post-fix: Pass 1 gives R1 to h1 (exact slot + title), Pass 2 gives R0 to h2 (title),
        // and h0 inserts: R1 is already claimed, R0 and R2 are both reachable by h0's ±3 window
        // (|0 − 0| and |4 − 0| ≤ 3) but neither clears the identity gate, so Pass 3a's
        // candidate set is empty and Pass 3b has nothing left. R2 is then unmatched and
        // hard-deleted with its tags/word-goal.
        let row0Content = "## A\nAlpha body."
        let row1Content = "## C\nCharlie body."
        let row2Content = "## C\nCharlie body, second copy."
        let headers = [
            makeHeader(position: 0, title: "D", markdownContent: "## D\nDelta body."),
            makeHeader(position: 1, title: "C", markdownContent: "## C\nCharlie body."),
            makeHeader(position: 2, title: "A", markdownContent: row0Content)
        ]
        let dbSections = [
            makeSection(id: "R0", sortOrder: 0, title: "A", headerLevel: 2,
                        markdownContent: row0Content, status: .review, tags: ["a-tag"]),
            makeSection(id: "R1", sortOrder: 1, title: "C", headerLevel: 2,
                        markdownContent: row1Content, status: .final_, tags: ["c-tag"]),
            makeSection(id: "R2", sortOrder: 4, title: "C", headerLevel: 2,
                        markdownContent: row2Content, status: .writing, tags: ["live-tag"],
                        wordGoal: 900)
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let inserts = changes.compactMap { change -> Section? in
            if case .insert(let section) = change { return section }
            return nil
        }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }
            return nil
        }
        let deletes = changes.compactMap { change -> String? in
            if case .delete(let id) = change { return id }
            return nil
        }
        let deleteDuplicates = changes.compactMap { change -> String? in
            if case .deleteDuplicate(let loserId, _, _) = change { return loserId }
            return nil
        }

        #expect(inserts.map(\.title) == ["D"], "h0 is the one header with no row left")
        #expect(inserts.map(\.sortOrder) == [0], "Its insert lands at h0's own index")

        // R1 already reads C at its own slot, so h1's exact-position + title claim changes
        // nothing at all: `buildUpdates` returns nil for it and NO update is emitted. The
        // absence is the assertion — a per-row `#require` here would demand an entry that
        // must not exist. Pinning the whole update list is what makes the absence explicit,
        // and it keeps this site discriminating: pre-fix the list carries a second entry.
        #expect(updates.map { $0.0 } == ["R0"],
                "R1 receives no update at all — it already reads C; only h2's renumbering of R0 emits one")

        let r0Update = try #require(updates.first { $0.0 == "R0" },
                                    "h2 claims R0 by title in Pass 2")
        #expect(r0Update.1.title == nil, "R0 already reads A — no relabel")
        #expect(r0Update.1.sortOrder == 2, "R0 moves to h2's index")

        #expect(deletes == ["R2"], "EXACT swept set: only the second same-titled spillover row")
        #expect(deleteDuplicates.isEmpty, "R2 is unflagged — plain .delete, no migration")
    }

    // MARK: - 3a/3b Asymmetry (C3)

    @Test("A gated 3a candidate claimed elsewhere sends the header to the gate-free 3b fallback")
    func gatedCandidateClaimedElsewhereSendsHeaderToGateFreeFallback() throws {
        // C3 — the last real fix-prover available, and the sharpest statement of the 3a/3b
        // asymmetry: 3a only considers rows that CLEAR the identity gate, while 3b considers
        // every in-range row with no gate at all. So when a header's only gated candidate is
        // taken by another header, it does not merely fail — it falls to 3b and can claim an
        // UNRELATED row it could never have claimed through 3a, relabeling it and moving its
        // metadata.
        //
        // Pre-fix: the earlier header ran first and claimed the content-related gate row in its
        // own Tier-3 pass; the later header, left with no title match and no gated candidate,
        // then took `rowBad` through the gate-free in-range fallback — it did not insert.
        // Post-fix: Pass 1 gives the gate row to the later header (title + exact slot) before
        // any proximity pass runs, so the earlier header's 3a candidate set is gone, 3a returns
        // nil, and 3b hands it `rowBad` — inside ±3 but with no title or content evidence
        // whatsoever. The inversion is the point: the gate row's metadata now stays put, and
        // the unrelated row is the one that moves.
        let gateContent = "## Gate Row\nThe prior body, still short."
        let headers = [
            makeHeader(position: 0, title: "Something Else", markdownContent: gateContent),
            makeHeader(position: 1, title: "Gate Row",
                       markdownContent: "## Gate Row\nA different body now.")
        ]
        let dbSections = [
            makeSection(id: "rowGate", sortOrder: 1, title: "Gate Row", headerLevel: 2,
                        markdownContent: gateContent, status: .review, tags: ["gate-tag"],
                        wordGoal: 800),
            makeSection(id: "rowBad", sortOrder: 2, title: "Unrelated", headerLevel: 2,
                        markdownContent: "## Unrelated\nNothing in common, but nearby.",
                        status: .writing, tags: ["bad-tag"], wordGoal: 300),
            makeSection(id: "rowEmpty", sortOrder: 3, title: "Empty",
                        markdownContent: "", status: .writing, tags: [], wordGoal: nil)
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let inserts = changes.compactMap { change -> Section? in
            if case .insert(let section) = change { return section }
            return nil
        }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }
            return nil
        }
        let deletes = changes.compactMap { change -> String? in
            if case .delete(let id) = change { return id }
            return nil
        }

        #expect(inserts.isEmpty, "Both headers claim a row — the earlier one via the 3b re-grab")

        let gateUpdate = try #require(updates.first { $0.0 == "rowGate" },
                                      "The later header claims the gate row in Pass 1")
        #expect(gateUpdate.1.title == nil,
                "rowGate already reads Gate Row — a claim admitted by the title gate relabels nothing")
        #expect(gateUpdate.1.sortOrder == nil, "rowGate already sits at the later header's index")

        let badUpdate = try #require(updates.first { $0.0 == "rowBad" },
                                     "The earlier header's 3b fallback claims the unrelated row")
        #expect(badUpdate.1.title == "Something Else",
                "The unrelated row is relabeled by the gate-free fallback")
        #expect(badUpdate.1.sortOrder == 0, "and it moves to the earlier header's index")

        #expect(!deletes.contains("rowBad"),
                "rowBad is claimed, not swept — it survives as the wrong section")
        #expect(!deletes.contains("rowGate"), "The gate row must never be swept here")
        #expect(deletes == ["rowEmpty"],
                "Only the evidence-free empty row is swept, having been skipped by both passes")
    }

    // MARK: - Pure-Proximity Guard (non-discriminating)

    @Test("Fully rewritten section is still kept by the pure-proximity pass")
    func fullyRewrittenSectionIsStillKeptByPureProximity() throws {
        // NON-DISCRIMINATING on purpose, like the accepted-trade-off pin above and the
        // flagged-row sweep guard: this behaviour is IDENTICAL pre-fix and post-fix and must
        // not be counted among the tests that demonstrate the fix. Both match paths reach the
        // same gate-free fallback for the later header (pre-fix Tier 3 only after the earlier
        // header's failed tiers; post-fix Pass 3b after the earlier header failed Passes 1–3a),
        // and emit the same update.
        //
        // What it guards is the delete sweep's worst case: the section whose title AND body
        // were both rewritten, which the gate cannot see at all because `passesMatchGate`
        // compares title equality and content prefix/suffix and finds neither. The pure-
        // proximity last resort exists precisely for that case, and this fixture pins that the
        // row is KEPT — updated in place — rather than inserted-and-deleted, which is what
        // would silently destroy its status/tags/wordGoal and detach its annotations.
        // (Rewritten-at-the-same-index is the shape: the earlier header's unrelated row is one
        // slot away by design, so it is a 3b candidate and must lose the position tiebreak.)
        let oldContent = "## Old Title\nOld body with nothing in common."
        let headers = [
            makeHeader(position: 0, title: "Brand New", markdownContent: "## Brand New\nRewritten body entirely."),
            makeHeader(position: 1, title: "Rewritten Title", markdownContent: "## Rewritten Title\nCompletely new prose.")
        ]
        let dbSections = [
            makeSection(id: "rowUnrelated", sortOrder: 0, title: "Something Else",
                        markdownContent: "## Something Else\nAnother body entirely.",
                        status: .writing, tags: ["other-tag"], wordGoal: 100),
            makeSection(id: "rowRewritten", sortOrder: 1, title: "Old Title",
                        markdownContent: oldContent, status: .final_, tags: ["kept-tag"],
                        wordGoal: 1500)
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let inserts = changes.compactMap { change -> Section? in
            if case .insert(let section) = change { return section }
            return nil
        }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }
            return nil
        }
        let deletes = changes.compactMap { change -> String? in
            if case .delete(let id) = change { return id }
            return nil
        }

        #expect(inserts.isEmpty, "The rewritten section keeps its row — nothing is inserted")
        #expect(deletes.isEmpty, "and nothing is swept, so its metadata and annotations survive")

        let rewrittenUpdate = try #require(updates.first { $0.0 == "rowRewritten" },
                                           "The rewritten row is updated in place, not orphaned")
        #expect(rewrittenUpdate.1.title == "Rewritten Title",
                "It takes the rewritten heading's title")
        #expect(rewrittenUpdate.1.markdownContent == "## Rewritten Title\nCompletely new prose.",
                "and the rewritten body")
    }

    // MARK: - Multi-Row Steady State Guard (non-discriminating)

    @Test("Three headings matching three rows exactly produce an empty change list")
    func threeMatchedHeadingsProduceAnEmptyChangeList() {
        // NON-DISCRIMINATING on purpose, like the accepted-trade-off pin and the pure-proximity
        // guard above: old and new code both emit nothing here, so this is a guard, not
        // fix-proof. What it guards is the multi-row steady state the single-row
        // `noChangesWhenPerfectMatch` cannot reach: an over-eager sweep (or any stray update/
        // insert) on a document whose headings did not change at all. `reconcile` runs behind
        // the editors' 3-second poll, so a sweep that deletes a matched row here would destroy
        // that row's real status/tags/wordGoal in the background, on every single poll. Each
        // row carries distinct metadata so a spurious metadata move cannot hide behind
        // identical defaults.
        let alphaContent = "## Alpha\nAlpha body."
        let betaContent = "## Beta\nBeta body."
        let gammaContent = "## Gamma\nGamma body."
        let headers = [
            makeHeader(position: 0, title: "Alpha", markdownContent: alphaContent),
            makeHeader(position: 1, title: "Beta", markdownContent: betaContent),
            makeHeader(position: 2, title: "Gamma", markdownContent: gammaContent)
        ]
        let dbSections = [
            makeSection(id: "rowAlpha", sortOrder: 0, title: "Alpha", markdownContent: alphaContent,
                        status: .writing, tags: ["alpha-tag"], wordGoal: 300),
            makeSection(id: "rowBeta", sortOrder: 1, title: "Beta", markdownContent: betaContent,
                        status: .review, tags: ["beta-tag"], wordGoal: 600),
            makeSection(id: "rowGamma", sortOrder: 2, title: "Gamma", markdownContent: gammaContent,
                        status: .final_, tags: ["gamma-tag"], wordGoal: 900)
        ]

        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let inserts = changes.compactMap { change -> Section? in
            if case .insert(let section) = change { return section }
            return nil
        }
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let update) = change { return (id, update) }
            return nil
        }
        let sweptIds = changes.compactMap { change -> String? in
            switch change {
            case .delete(let id): return id
            case .deleteDuplicate(let loserId, _, _): return loserId
            default: return nil
            }
        }

        #expect(changes.isEmpty, "An unchanged three-section document reconciles to zero changes")
        #expect(inserts.isEmpty, "No heading inserts — every row is claimed in place")
        #expect(updates.isEmpty, "Nothing moves: no relabel, no renumber, no metadata move")
        #expect(sweptIds.isEmpty,
                "No delete or deleteDuplicate — a sweep here is background data loss behind the 3s poll")
    }
}
