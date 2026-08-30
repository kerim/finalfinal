//
//  BibliographyGluedHeadingReconcileTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers -- end-to-end proof that the `parseHeaders` fix (commits 24cb79c7 /
//  5d3d6163: the marker branch's `inAutoBibliography` latch is now selector-gated AND closes
//  again at the terminator, instead of latching unconditionally and never resetting) actually
//  stops a real, user-reported data-loss cascade through `SectionReconciler.reconcile` -- not
//  just that `parseHeaders` alone now returns the right `[ParsedHeader]` in isolation (that's
//  already covered by `BibliographyOutlineSpanTests.swift` and
//  `BibliographyOpeningSelectorCrossCheckTests.swift` from the prior round).
//
//  CONFIRMED ROOT CAUSE (traced from a real user diagnostic log): when the bibliography
//  regenerates with its opening marker glued directly onto the heading text on the SAME line
//  (`<!-- ::auto-bibliography:: --># Bibliography` -- no newline between them, exactly the shape
//  `BibliographySyncService`'s regeneration writes), the very next reparse called `parseHeaders`
//  to rebuild `[ParsedHeader]` for `SectionReconciler.reconcile`. The OLD `parseHeaders` bug (the
//  marker branch set `inAutoBibliography = true` unconditionally on ANY marker-prefixed line, and
//  NEVER reset it -- there was no terminator-close branch at all) meant every REAL heading
//  physically located after that marker's line was silently absent from `parseHeaders`'s output.
//  `SectionReconciler.reconcile` then treated every DB `Section` row that didn't match anything
//  in that corrupted, incomplete header list as "deleted from markdown" and issued real
//  `.delete` changes for them -- genuinely destroying real user sections and their content. This
//  file proves that cascade is now closed: feeding the FIXED `parseHeaders`'s real output for
//  this exact glued-marker fixture through the FULL reconcile pipeline no longer deletes the
//  real sections physically located after the bibliography.
//
//  IMPORTANT, CONFIRMED-BY-TRACING WRINKLE (not a defect in the fix -- a documented, pre-existing
//  property of `parseHeaders` itself, already pinned by
//  `BibliographyOpeningSelectorCrossCheckTests.standaloneMarkerInvariantHoldsAtAllThreeSites`):
//  when the marker is glued directly onto the heading on the SAME line, that whole line fails
//  `trimmed.hasPrefix("#")` (it starts with "<"), so the marker branch's own `continue` consumes
//  it before `parseHeaderLine` is ever reached -- NO `ParsedHeader` with `isBibliography == true`
//  is ever emitted for a glued heading, in EITHER the old or the fixed code (both take the exact
//  same marker branch up to that point; they only diverge on what happens to headers AFTER it).
//  Consequently `SectionReconciler.reconcile` never reaches its dedicated
//  `if header.isBibliography` match path for this fixture -- the bibliography DB row is left
//  entirely unmatched by any header, same as before the fix. It is NOT deleted (the delete-sweep
//  loop's `if section.isBibliography && !bibliographyGone { continue }` immortal-row guard --
//  `bibliographyGone` is unconditionally `false` here because this test calls the 3-arg
//  `reconcile(headers:dbSections:projectId:)` overload, whose `bibliographyExistsInBlocks`
//  parameter defaults to `true`) and NOT duplicate-inserted, but it also does NOT receive an
//  `.update` -- it receives NO change at all in this pass, protected exactly like an unmatched
//  row that genuinely still exists elsewhere. `bibliographySectionReceivesNoSpuriousChange` below
//  pins this precisely instead of asserting the update the surface-level bug description might
//  suggest -- see that test's inline comment for the full trace.
//

import Testing
import Foundation
@testable import final_final

@Suite("parseHeaders -> SectionReconciler.reconcile -- glued bibliography marker no longer deletes real sections after it")
struct BibliographyGluedHeadingReconcileTests {

    let projectId = "test-project-id"

    /// The exact failure shape from the user's diagnostic log: a few real headings, then a
    /// bibliography whose opening marker is glued directly onto "# Bibliography" on the same
    /// line, with real entries, then the terminator, then AT LEAST ONE MORE real heading with
    /// real content after the terminator (mirroring the user's actual document -- the deleted
    /// sections in their log sat structurally after/around the bibliography's position).
    private var markdown: String {
        """
        # Introduction

        Real introduction text discussing what this document is about and why it matters to readers.

        # Methods

        Real methods text describing the procedure used in this study, written out in full detail.

        \(BlockParser.bibliographyStartMarker)# Bibliography

        Smith, J. (2020). A Book About Testing Practices.

        Jones, K. (2021). Another Reference Work Worth Citing Here.

        \(BlockParser.bibliographyEndMarker)

        # Discussion

        Real discussion text that comes after the bibliography section entirely, analyzing results in depth.

        # Conclusion

        Real concluding text wrapping up the whole document with final thoughts and next steps.
        """
    }

    /// The PRIOR reconciled DB state: rows for every real section in the document, including
    /// the ones that sit structurally after the bibliography, each already correctly matched/
    /// created from an earlier reconcile pass. The bibliography row occupies its own sortOrder
    /// slot between Methods and Discussion (as it would from any prior pass where the
    /// bibliography boundary WAS visible to parseHeaders), which is exactly why Discussion and
    /// Conclusion's DB sortOrder now sits one slot ahead of their freshly re-parsed header
    /// position -- Tier 2 (same-title-anywhere) has to do the reattaching, exactly like a real
    /// drag-drop/renumbering case.
    private func priorReconciledSections(headers: [ParsedHeader]) -> (
        intro: Section, methods: Section, bib: Section, discussion: Section, conclusion: Section
    ) {
        let intro = Section(
            id: "s-intro", projectId: projectId, sortOrder: 0, headerLevel: 1,
            title: "Introduction", markdownContent: headers[0].markdownContent
        )
        let methods = Section(
            id: "s-methods", projectId: projectId, sortOrder: 1, headerLevel: 1,
            title: "Methods", markdownContent: headers[1].markdownContent
        )
        let bib = Section(
            id: "s-bib", projectId: projectId, sortOrder: 2, headerLevel: 1,
            isBibliography: true, title: "Bibliography",
            markdownContent: "# Bibliography\n\nSmith, J. (2020). A Book About Testing Practices."
        )
        let discussion = Section(
            id: "s-discussion", projectId: projectId, sortOrder: 3, headerLevel: 1,
            title: "Discussion", markdownContent: headers[2].markdownContent
        )
        let conclusion = Section(
            id: "s-conclusion", projectId: projectId, sortOrder: 4, headerLevel: 1,
            title: "Conclusion", markdownContent: headers[3].markdownContent
        )
        return (intro, methods, bib, discussion, conclusion)
    }

    // MARK: - The fix, proven end-to-end

    @Test("FIXED parseHeaders output through the full reconcile pipeline: real sections after the glued bibliography survive")
    func realSectionsAfterGluedBibliographySurviveReconcile() throws {
        let headers = SectionSyncService.parseHeaders(from: markdown, existingBibTitle: "Bibliography")

        // Sanity check on the fixture itself, pinning the documented wrinkle from this file's
        // header comment: the glued line never becomes a boundary, so exactly the 4 real
        // (non-bibliography) headings surface, and NONE is flagged isBibliography.
        #expect(
            headers.map(\.title) == ["Introduction", "Methods", "Discussion", "Conclusion"],
            """
            The fix must surface Discussion and Conclusion (after the terminator) alongside \
            Introduction and Methods (before the marker) -- this is the terminator-reset fix \
            actually firing, not the glued line itself becoming a header
            """
        )
        #expect(headers.allSatisfy { !$0.isBibliography }, "the glued line is consumed whole by the marker branch -- see this file's header comment")

        let sections = priorReconciledSections(headers: headers)
        let dbSections = [sections.intro, sections.methods, sections.bib, sections.discussion, sections.conclusion]

        let changes = SectionReconciler().reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let deletes = Set(changes.compactMap { change -> String? in
            if case .delete(let id) = change { return id }
            return nil
        })
        let updates = changes.compactMap { change -> (String, SectionUpdates)? in
            if case .update(let id, let updates) = change { return (id, updates) }
            return nil
        }
        let inserts = changes.compactMap { change -> Section? in
            if case .insert(let section) = change { return section }
            return nil
        }

        // THE CORE CLAIM: no real section anywhere -- especially Discussion and Conclusion,
        // which sit AFTER the bibliography's position -- is deleted.
        #expect(deletes.isEmpty, "No real section should be deleted: got deletes for \(deletes)")
        #expect(!deletes.contains(sections.discussion.id), "Discussion (after the bibliography) must not be deleted")
        #expect(!deletes.contains(sections.conclusion.id), "Conclusion (after the bibliography) must not be deleted")

        // Discussion and Conclusion must be POSITIVELY reattached (not merely "absent from
        // deletes" by accident) -- each gets an update repositioning it to its new header index.
        let discussionUpdate = updates.first { $0.0 == sections.discussion.id }
        let conclusionUpdate = updates.first { $0.0 == sections.conclusion.id }
        #expect(discussionUpdate != nil, "Discussion must be matched and updated, not silently dropped")
        #expect(conclusionUpdate != nil, "Conclusion must be matched and updated, not silently dropped")
        #expect(discussionUpdate?.1.sortOrder == 2, "Discussion moves to its new header position")
        #expect(conclusionUpdate?.1.sortOrder == 3, "Conclusion moves to its new header position")

        #expect(inserts.isEmpty, "Nothing here is genuinely new -- no insert, and in particular no duplicate Bibliography insert")
    }

    @Test("The bibliography row itself: no delete, no duplicate insert, and (see file header comment) no spurious update either")
    func bibliographySectionReceivesNoSpuriousChange() throws {
        // Documented wrinkle, confirmed by direct code trace against the shipped parseHeaders
        // (and already pinned independently by
        // BibliographyOpeningSelectorCrossCheckTests.standaloneMarkerInvariantHoldsAtAllThreeSites'
        // `headers.isEmpty` assertion on the same glued-line shape): a marker glued to its
        // heading on the SAME line never produces a `ParsedHeader` with `isBibliography == true`
        // -- the whole line fails `trimmed.hasPrefix("#")` and is consumed by the marker
        // branch's own `continue` before `parseHeaderLine` ever runs. So `reconcile` never
        // reaches its dedicated `if header.isBibliography` match path for this fixture; the
        // bibliography DB row is left unmatched by any header, exactly as it was before this
        // round's fix. It survives ONLY via the immortal-row guard in the unmatched-sections
        // sweep (`if section.isBibliography && !bibliographyGone { continue }`) -- which,
        // calling the 3-arg `reconcile(headers:dbSections:projectId:)` overload as instructed
        // (so `bibliographyExistsInBlocks` defaults to `true`, making `bibliographyGone`
        // unconditionally `false`), means the row is skipped in the sweep and receives NO
        // change at all: not deleted, not duplicate-inserted, but also not updated. That NO-op
        // outcome -- not an `.update` -- is what this test pins.
        let headers = SectionSyncService.parseHeaders(from: markdown, existingBibTitle: "Bibliography")
        let sections = priorReconciledSections(headers: headers)
        let dbSections = [sections.intro, sections.methods, sections.bib, sections.discussion, sections.conclusion]

        let changes = SectionReconciler().reconcile(headers: headers, dbSections: dbSections, projectId: projectId)

        let bibChange = changes.first { change in
            switch change {
            case .delete(let id): return id == sections.bib.id
            case .update(let id, _): return id == sections.bib.id
            case .deleteDuplicate(let loserId, let survivorId, _): return loserId == sections.bib.id || survivorId == sections.bib.id
            case .insert: return false
            }
        }
        #expect(bibChange == nil, "The bibliography row must produce no change at all in this pass -- got \(String(describing: bibChange))")
        let inserts = changes.compactMap { change -> Section? in
            if case .insert(let section) = change { return section }
            return nil
        }
        #expect(!inserts.contains { $0.isBibliography }, "No duplicate Bibliography section should ever be inserted")
    }

    // MARK: - Proof this test construction would have caught the ORIGINAL bug

    @Test("ANTI-REGRESSION: the OLD parseHeaders shape for this exact fixture WOULD have deleted the real sections after the bibliography")
    func oldParseHeadersShapeWouldHaveDeletedRealSectionsAfterBibliography() throws {
        // The OLD (pre-24cb79c7) marker branch was:
        //
        //     if trimmed.hasPrefix("<!-- ::auto-bibliography:: -->") {
        //         inAutoBibliography = true
        //         bibliographyStartOffset = currentOffset
        //         currentOffset += lineStr.count + 1
        //         continue
        //     }
        //
        // -- unconditional (no selector gate) and, critically, THERE WAS NO TERMINATOR-CLOSE
        // BRANCH AT ALL: nothing ever reset `inAutoBibliography` back to false. Everything
        // before the glued marker line is untouched by this round's fix (the selector-gated
        // `if currentOffset == selectedBibliographyOffset` check the fixed code adds is always
        // true for the FIRST/only marker in this fixture, so old and fixed code set
        // `inAutoBibliography = true` / `bibliographyStartOffset` at the exact same offset
        // either way) -- so old code's first two boundaries ("Introduction", "Methods") are
        // BYTE-IDENTICAL to the fixed function's own first two entries. The divergence is
        // ENTIRELY about what happens afterward: with no reset, old code's `!inAutoBibliography`
        // heading-gate (used at both the pseudo-section and header branches) stayed false for
        // the rest of the document, so "Discussion" and "Conclusion" -- and their terminator's
        // reset, which didn't exist yet -- were never reached at all. Reusing the FIXED
        // function's own first two entries is therefore not a guess standing in for old
        // behavior; it IS what the old function would have produced for this exact input.
        let headers = SectionSyncService.parseHeaders(from: markdown, existingBibTitle: "Bibliography")
        let oldShapedHeaders = Array(headers.prefix(2))
        #expect(
            oldShapedHeaders.map(\.title) == ["Introduction", "Methods"],
            "sanity check: this is the OLD function's reconstructed output for this exact fixture"
        )

        let sections = priorReconciledSections(headers: headers)
        let dbSections = [sections.intro, sections.methods, sections.bib, sections.discussion, sections.conclusion]

        let changes = SectionReconciler().reconcile(headers: oldShapedHeaders, dbSections: dbSections, projectId: projectId)

        let deletes = Set(changes.compactMap { change -> String? in
            if case .delete(let id) = change { return id }
            return nil
        })

        #expect(
            deletes.contains(sections.discussion.id),
            """
            Under the OLD parseHeaders shape, Discussion (silently missing from its output) is wrongly deleted -- \
            this is the exact cascade from the user's diagnostic log, and proves this test construction would \
            have failed against the pre-fix code
            """
        )
        #expect(
            deletes.contains(sections.conclusion.id),
            "Under the OLD parseHeaders shape, Conclusion (silently missing from its output) is wrongly deleted"
        )
        #expect(!deletes.contains(sections.bib.id), "The bibliography row itself is still immortal-protected even under the old shape")
    }
}
