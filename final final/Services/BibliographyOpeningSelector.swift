//
//  BibliographyOpeningSelector.swift
//  final final
//
//  Shared decision rule for "which unit opens the bibliography section", used by all three
//  markdown-scanning call sites that must answer this question independently:
//  `BlockParser.selectBibliographyOpeningIndex` (raw blocks), `SectionSyncService.
//  selectBibliographyOpeningOffset` (lines), and `SectionSyncService.injectBibliographyMarker`
//  (lines). Each site tokenizes its OWN input into a `[Unit]` sequence using its own existing
//  predicates (marker/terminator/candidate tests deliberately differ site to site — see each
//  call site's own doc comment for its exact predicates and why they diverge) and hands the
//  sequence to `select(_:)`, which applies ONE shared rule so all three can never structurally
//  disagree about the DECISION itself — only, deliberately, about what counts as a candidate.
//

import Foundation

/// Two-tier rule for selecting the bibliography-opening unit. Tier 3 ("last title match
/// anywhere, no evidence required") is PERMANENTLY DELETED here, not weakened — `Block.
/// isBibliography` must be set only on evidence the app itself wrote: an opening marker, or a
/// genuine terminator-bounded run with real content in it.
///
/// THE RULE:
///
/// 1. **The first SUPPORTED marker wins outright.** A marker unit is supported when it carries
///    its own evidence that a real bibliography section opens there — either it is not
///    standalone (glued to a heading or other text in the same unit, so the unit itself names
///    the section), or, being standalone, the next non-empty unit is a bibliography-title
///    candidate. This exists because CodeMirror's Source Mode hides the opening marker as an
///    invisible atomic decoration with no delete-protection, so deleting the visible
///    bibliography section around it can leave a BARE marker literal behind as an orphan — an
///    unsupported standalone marker with no valid pairing. Tier 1 scans PAST such an orphan for
///    a later, supported marker rather than stopping dead on the first (possibly orphaned)
///    marker it meets: an old orphan sitting mid-document must not disable tier 1 for a real,
///    supported marker further down, which is exactly the steady state this rule creates (the
///    user adds a citation; regeneration correctly writes a real marker + heading further down;
///    the next parse must find and select THAT marker, skipping past the earlier orphan). Tier 2
///    is reached only when NO marker anywhere in the sequence is supported. See
///    `markerIsSupported` for the full predicate, including its load-bearing blank-skip
///    behavior.
///
///    SCOPE: this narrows only the specific bare-marker-only orphan shape at tier 1 (and the
///    equivalent level 3 of `BibliographySyncService.updateBibliographyBlock`'s anchor
///    fallback chain — see that function). A marker glued onto a SURVIVING real heading still
///    passes unconditionally (not-standalone ⇒ supported); `updateBibliographyBlock`'s anchor
///    level 2 (first flagged heading, unconditional) is ALSO still unconditional and untouched
///    by this fix. This is not "all orphan shapes are now covered."
/// 2. **Terminator-bounded, non-empty run.** Otherwise, find the first unit with
///    `isTerminator`. If there is none, select nothing. Otherwise take the LAST `isCandidate`
///    unit strictly before it.
///    - No candidate before the terminator -> select nothing.
///    - The candidate's run is EMPTY if there is no non-empty, non-candidate, non-heading unit
///      strictly between it and the terminator — i.e. only headings and/or blank units sit in
///      between. `isHeading` units are excluded from this content check deliberately, to match
///      `Database+BlocksReplace.swift`'s `carryBibliographyFlagForward`, which already stops a
///      run dead at ANY heading (`if blocks[cursor].blockType == .heading { break }`). Without
///      this the selector and the carry-forward machinery could disagree about the exact
///      damaged shape this whole fix targets: `# Bibliography` / `## Notes` (a subsection
///      heading, no real content) / terminator — a bare subsection heading with nothing under
///      it must NOT count as evidence of a genuine run.
///    - If the run is empty -> select nothing. Do NOT fall through to an earlier candidate.
///    - Otherwise -> select the candidate.
///
/// WHY SUPPRESSION, NOT FALLBACK: `Database+BlocksReplace.swift`'s own KNOWN LIMITATION comment
/// (on `carryBibliographyFlagForward`) documents the empty-run shape as a REAL, app-produced
/// state: on a document already in the damaged state (heading flagged, entries not), the
/// assembler places the terminator directly after the heading — exactly "last candidate has an
/// empty run". Falling back to an earlier candidate in that state would hand the flag to the
/// bare-title user heading with real prose beneath it — the exact bug this task exists to
/// prevent, reintroduced through the fix's own code path. This matches the house rule already
/// documented at `BlockParser.swift`'s `selectBibliographyOpeningIndex`: "select NOTHING — do
/// not fall through."
///
/// NON-CIRCULARITY: the run-length signal can't be faked by the flag under repair. `select`
/// never reads any prior `isBibliography` state at all — it only reads the caller's per-unit
/// marker/terminator/candidate/heading/empty booleans, derived from the raw text. Nothing on a
/// live path can manufacture a fake non-empty run either: the insert path is marker-only
/// (`Database+BlocksInsert.swift`'s `buildInsertedBlock` uses `hasBibliographyMarker`, never a
/// bare-title match), and carry-forward can't extend a run past a terminator the stale flag
/// itself placed.
///
/// DISCLOSED CONSEQUENCES:
/// 1. Legacy documents depend on `BlockParser.parse`'s coupled
///    `strippingBibliographyMarkerFromBlocks` fix (see that parameter's doc comment) — not
///    optional. A legacy document arrives markerless AND terminator-less on first load under
///    the current (blocks-based) system; with tier 3 deleted, it has no other evidence to
///    select on, so skipping that coupled fix silently loses its bibliography flag entirely.
/// 2. A document already in the damaged state (heading flagged, entries not) BEFORE this fix
///    ever ran does NOT stay "exactly as damaged as before" — it changes shape. On its next
///    full reparse, `Database+BlocksReplace.swift`'s restore gate (`applyPreservedHeading`'s
///    `restoringBibliography` parameter, gated by `hasGenuineBibliographyRun`) requires the
///    SAME evidence this selector requires: a genuine, non-empty, terminator-bounded run. A
///    document in this damaged shape has none — `assembleMarkdownForEditor` never even emits a
///    terminator, since the unflagged entries give it nothing to bound a run on — so the
///    heading's own stale flag is now correctly DROPPED rather than resurrected by title-match
///    preservation. The document ends up uniformly unflagged (heading included), not left in
///    the old split state (heading flagged, entries not). This is still not a repair — the
///    real entries stay lost to every export until the user re-marks the section — but it is a
///    materially different, and more honest, outcome than "unchanged". See
///    `BibliographyCarryForwardTests.swift`'s `alreadyDamagedDocumentIsNotRepaired` for the
///    assertion this describes. Do not conflate this with consequence #3 below: this one is
///    about `applyPreservedHeading`'s restore gate acting on a PRE-EXISTING stale DB flag
///    during metadata preservation; #3 is about this selector's OWN empty-run rule refusing to
///    flag a REAL heading during a fresh parse. Different code paths, different triggers,
///    similar-sounding but distinct outcomes.
/// 3. When a terminator sits immediately after a real bibliography heading with ALL its entries
///    removed, that heading also goes unflagged (an empty run, by this same rule). Concretely:
///    `BibliographySyncService.updateBibliographyBlock` fetches `isBibliography == true` to
///    find its anchor — with nothing flagged, the next regeneration finds no anchor and
///    APPENDS A SECOND BIBLIOGRAPHY HEADING beside the user's existing (now-unflagged) one.
///    `removeBibliographyBlock` deletes on the same filter — a full citation removal in this
///    state LEAVES THE OLD HEADING ORPHANED IN THE DOCUMENT, unflagged, doing nothing. This is
///    still the correct trade — visible and fixable by the user beats silent permanent data
///    loss — but it is a real, user-visible consequence, not merely "reads as unmanaged."
enum BibliographyOpeningSelector {

    /// One tokenized unit of a call site's own content sequence (raw blocks for
    /// `BlockParser`, lines for `SectionSyncService`'s two call sites). Every boolean is the
    /// CALLER's own existing predicate for that concept — `select` never re-derives any of
    /// them from text itself.
    struct Unit {
        /// The site's own marker test (e.g. `hasBibliographyMarker`, `.contains(...)`).
        let isMarker: Bool
        /// The site's own exact-equality terminator test.
        let isTerminator: Bool
        /// The site's own title/level candidate predicate, already gated by that site's own
        /// candidacy rule (settings-value match, existing-title match, code-fence/notes
        /// guards, etc).
        let isCandidate: Bool
        /// Whether this unit is ANY heading — broader than `isCandidate` (a heading that
        /// ISN'T the bibliography title still counts as a heading for run-emptiness
        /// purposes). Matches `carryBibliographyFlagForward`'s heading-stops-a-run rule.
        let isHeading: Bool
        /// Whether this unit is blank/whitespace-only — excluded from the run-content check
        /// alongside `isHeading`.
        let isEmpty: Bool
        /// Whether this unit's own content IS the bare opening-marker literal and nothing else —
        /// the ORPHAN shape. A REFINEMENT of `isMarker`, never an independent test.
        ///
        /// INVARIANT: `isStandaloneMarker` must always imply `isMarker`. If a unit is
        /// standalone-marker-shaped, that same site's `isMarker` predicate must also be true —
        /// the standalone check narrows the marker check, it does not run beside it. `select`
        /// asserts this per unit in debug builds; a site whose standalone test ever becomes laxer
        /// than its own marker test would otherwise silently start dropping real candidates from
        /// tier 2's scan with no warning.
        let isStandaloneMarker: Bool

        init(
            isMarker: Bool,
            isTerminator: Bool,
            isCandidate: Bool,
            isHeading: Bool,
            isEmpty: Bool,
            isStandaloneMarker: Bool
        ) {
            self.isMarker = isMarker
            self.isTerminator = isTerminator
            self.isCandidate = isCandidate
            self.isHeading = isHeading
            self.isEmpty = isEmpty
            self.isStandaloneMarker = isStandaloneMarker
        }
    }

    /// The selector's verdict — an enum, not `Int?`, so a call site that must react differently
    /// to "there's a marker already, leave it alone" (site C's tier-1 bail: return the original
    /// markdown unchanged) vs. "nothing qualifies, leave it alone" (site C's tier-2 miss: same
    /// unchanged-return action, different reason) can pattern-match instead of losing that
    /// distinction to a single `nil` case. In particular this is what lets site C's `.marker`
    /// branch return the input unchanged unconditionally — no shared code path can ever make it
    /// write a second marker.
    enum Selection: Equatable {
        case marker(Int)
        case candidate(Int)
        case none
    }

    static func select(_ units: [Unit]) -> Selection {
        assert(
            units.allSatisfy { !$0.isStandaloneMarker || $0.isMarker },
            "isStandaloneMarker must imply isMarker — see Unit.isStandaloneMarker's invariant"
        )
        // A standalone-marker unit must never also be a title candidate — being the bare
        // marker literal and nothing else is orthogonal to being a genuine bibliography-title
        // match, and tier 1's `markerIsSupported` / tier 2's candidate scan both trust
        // `isCandidate` to mean "a real title was found here". A site whose `isCandidate`
        // predicate ever regresses to matching the bare marker literal again (the exact bug
        // this assert guards against — see `BlockParser.selectBibliographyOpeningIndex`'s
        // `isCandidate` construction) would let an orphan marker re-select itself via either
        // tier, silently. Every real call site's own tokenizer is exercised by this assert
        // whenever its output reaches `select`, in any debug/test build.
        assert(
            units.allSatisfy { !$0.isStandaloneMarker || !$0.isCandidate },
            "isStandaloneMarker must imply !isCandidate — a bare marker unit is never itself a title candidate"
        )

        if let markerIndex = units.indices.first(where: {
            units[$0].isMarker && markerIsSupported(units, at: $0)
        }) {
            return .marker(markerIndex)
        }

        guard let terminatorIndex = units.firstIndex(where: { $0.isTerminator }) else {
            return .none
        }

        guard let candidateIndex = units[..<terminatorIndex].lastIndex(where: { $0.isCandidate }) else {
            return .none
        }

        let contentRange = (candidateIndex + 1)..<terminatorIndex
        let runHasContent = units[contentRange].contains { unit in
            !unit.isEmpty && !unit.isCandidate && !unit.isHeading && !unit.isTerminator
        }

        return runHasContent ? .candidate(candidateIndex) : .none
    }

    /// A marker unit is SUPPORTED when it carries its own evidence that a real bibliography
    /// section opens there: either it is not standalone (the marker is glued to a heading or
    /// other text in the same unit, so the unit itself names the section), or, being standalone,
    /// the next NON-EMPTY unit is a bibliography-title candidate — the persisted
    /// `<!-- ::auto-bibliography:: -->` / blank / `# Bibliography` shape.
    ///
    /// LOAD-BEARING: blank units are skipped deliberately. At sites B and C (line tokenizers)
    /// the blank line between marker and heading is the NORMAL, real persisted shape — the
    /// marker sits on its own line, then a blank line, then the heading on its own line. A
    /// STRICT "next unit" test (no blank-skip) would mark every genuine standalone marker at
    /// those two sites unsupported and silently disable tier 1 there for the common case, not
    /// just the orphan case. At site A (raw blocks, blank-line-delimited) blank units cannot
    /// occur between the two, so the skip is a no-op there — but it must still be present for
    /// sites B and C to work at all.
    private static func markerIsSupported(_ units: [Unit], at index: Int) -> Bool {
        guard units[index].isStandaloneMarker else { return true }
        guard let next = units[(index + 1)...].firstIndex(where: { !$0.isEmpty }) else { return false }
        return units[next].isCandidate
    }
}
