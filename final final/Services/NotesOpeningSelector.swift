//
//  NotesOpeningSelector.swift
//  final final
//
//  Shared decision rule for "which heading(s) open a Notes section", used by every
//  markdown-scanning call site that must answer this question independently:
//  `BlockParser.parse` (raw blocks), `FootnoteSyncService+Reconciliation.swift`'s
//  `stripNotesSection` and `adoptUnflaggedNotesContinuations` (lines / DB rows),
//  `FootnoteSyncService.pushDefinitionsToEditor` (lines), and
//  `SectionSyncService+Parsing.swift`'s `confirmNotesCandidates` (lines). Each site
//  tokenizes its OWN input into a `[Unit]` sequence using its own existing predicates
//  (heading/evidence tests deliberately stay site-local — see each call site's own
//  doc comment) and hands the sequence to `select(_:)`, which applies ONE shared rule
//  so every site can never structurally disagree about the DECISION itself.
//
//  Mirrors `BibliographyOpeningSelector`'s multi-tokenizer shape (`Unit` struct + one
//  static `select` entry point per caller), but the actual RULE is different, not a
//  copy: Notes has no persisted opening marker and no closing terminator, so there is
//  no two-tier marker-then-run logic here, and — unlike Bibliography, which picks
//  exactly ONE opening for the whole document — a document can legitimately contain
//  MORE THAN ONE independent Notes run (see `FootnoteSyncService+Reconciliation.swift`'s
//  `notesOwnershipMap`, "RUN-BOUNDARY RESET"). `select` therefore returns every
//  confirmed opening, not a single winner.
//

import Foundation

/// THE RULE: a heading unit opens a Notes run when it is a TITLE CANDIDATE (its text
/// matches the configured Notes header name — "Notes" by default, or whatever
/// `Database+Blocks.swift`'s `fetchNotesHeadingTitle` resolves once a section is
/// already recognized — at heading level 1 OR 2, mirroring `BlockParser.
/// isBibliographyHeading`'s own H1-or-H2 acceptance) AND its span carries EVIDENCE: at
/// least one genuine footnote-DEFINITION line (`[^N]:` at line/unit start) strictly
/// between it and the next heading of ANY kind (or end of input). A title match with
/// no evidence beneath it — an ordinary user heading that merely happens to be titled
/// "Notes", with no footnotes underneath — is NEVER selected. This mirrors
/// `SectionSyncService+Parsing.swift`'s pre-existing `confirmNotesCandidates` evidence
/// check, which this file generalizes into one shared rule every scanner can share
/// instead of re-deriving.
///
/// MULTIPLE RUNS: `select` returns every confirmed opening index, in document order.
/// Two Notes-titled headings that BOTH carry evidence are NOT a conflict to resolve —
/// both are genuinely independent, confirmed Notes runs, and both are returned. A tie
/// only exists for a caller that needs to reduce multiple confirmed openings to ONE
/// answer (e.g. resolving a single canonical title) — see `primaryOpening` below for
/// that named, deterministic reduction.
///
/// WHY NO LEVEL HEURISTIC FOR THE TIE: preferring, say, the H1 opening over an H2
/// opening (or vice versa) would make the "first" answer depend on document structure
/// that has nothing to do with which section the user actually means — a heading's
/// level is an authoring choice (Stage C's own settled decision #2: "heading level is
/// kept as typed on adoption, never normalized"), not a signal of which Notes section
/// is primary. FIRST-IN-DOCUMENT-ORDER is the only rule that is stable under reading
/// order, matches how a person skimming the document would answer the same question,
/// and needs no secondary tie-break of its own (`sortOrder`/index order is already a
/// strict total order, so "first" is always well-defined).
enum NotesOpeningSelector {

    /// One tokenized unit of a call site's own content sequence (raw blocks for
    /// `BlockParser`, lines for `FootnoteSyncService`/`SectionSyncService`). Every
    /// boolean is the CALLER's own existing predicate for that concept — `select`
    /// never re-derives any of them from text itself.
    struct Unit {
        /// The site's own test for "this unit IS a heading whose title matches the
        /// configured Notes header name, at heading level 1 or 2" — e.g.
        /// `BlockParser.isNotesHeading`. Narrower than `isAnyHeading`: a heading that
        /// isn't title-matched is `isAnyHeading` but not `isCandidateHeading`.
        let isCandidateHeading: Bool
        /// Whether this unit is ANY heading — broader than `isCandidateHeading`. Ends
        /// whatever run is currently open, exactly like `sectionFlagCarriedForward`'s
        /// "any other heading closes the run" rule and `BibliographyOpeningSelector.
        /// Unit.isHeading`.
        let isAnyHeading: Bool
        /// Whether this unit itself IS (or, for a multi-line raw-block unit, contains)
        /// a genuine footnote-definition line: `[^N]:` anchored at line start. This is
        /// the evidence a title-candidate heading's run must contain to be confirmed —
        /// mirrors `confirmNotesCandidates`'s `^\[\^\d+\]:` check exactly.
        let isEvidence: Bool

        init(isCandidateHeading: Bool, isAnyHeading: Bool, isEvidence: Bool) {
            self.isCandidateHeading = isCandidateHeading
            self.isAnyHeading = isAnyHeading
            self.isEvidence = isEvidence
        }
    }

    /// Every confirmed Notes-opening index in `units`, in document order. A
    /// title-candidate heading is confirmed when at least one `isEvidence` unit sits
    /// strictly between it and the next `isAnyHeading` unit (or the end of `units`,
    /// when no later heading exists). No candidate before it, and no evidence-free
    /// title match, is ever included — this is the DELETED "last title match anywhere,
    /// no evidence required" tier that `BibliographyOpeningSelector` also refuses to
    /// resurrect for its own section.
    static func select(_ units: [Unit]) -> [Int] {
        var openings: [Int] = []
        for index in units.indices where units[index].isCandidateHeading {
            if hasEvidence(in: units, after: index + 1) {
                openings.append(index)
            }
        }
        return openings
    }

    /// Whether a genuine footnote-definition evidence unit exists in `units`, scanning forward
    /// from `startIndex` up to (not including) the next `isAnyHeading` unit or the end of
    /// `units`. Factored out of `select`'s own per-candidate scan so a caller that already has
    /// its OWN candidate span in hand -- rather than a full document-wide `[Unit]` array to run
    /// `select` over -- can share the identical evidence rule instead of re-deriving it.
    /// `SectionSyncService+Parsing.swift`'s `confirmNotesCandidates` (C4: refactored onto this
    /// shared selector as the source-of-truth evidence rule) is the other caller: it identifies
    /// each candidate heading via its own title-match branches in a larger parse loop, then
    /// tokenizes just that candidate's own content span and calls this directly.
    static func hasEvidence(in units: [Unit], after startIndex: Int) -> Bool {
        var scan = startIndex
        while scan < units.count, !units[scan].isAnyHeading {
            if units[scan].isEvidence {
                return true
            }
            scan += 1
        }
        return false
    }

    /// The single, deterministic answer for a caller that must reduce potentially
    /// multiple confirmed openings (see `select`) to exactly ONE index — e.g.
    /// resolving one canonical Notes-section title when more than one confirmed
    /// heading exists. FIRST-IN-DOCUMENT-ORDER, never a level heuristic — see this
    /// type's own doc comment ("WHY NO LEVEL HEURISTIC FOR THE TIE") for why.
    static func primaryOpening(_ units: [Unit]) -> Int? {
        select(units).first
    }
}
