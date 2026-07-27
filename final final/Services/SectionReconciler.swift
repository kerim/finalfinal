//
//  SectionReconciler.swift
//  final final
//
//  Position-based section reconciliation for editor ↔ database sync.
//  Matches parsed headers to database sections using a three-tier strategy:
//  1. Exact position match (most common - edits within a section)
//  2. Same title anywhere (handles drag-drop reordering)
//  3. Closest position within ±3 (handles batch deletes/inserts)
//

import Foundation

/// Parsed header information from markdown content
struct ParsedHeader: Sendable {
    let position: Int           // 0-indexed position among headers
    let title: String
    let level: Int              // Header level (1-6, pseudo-sections inherit from preceding)
    let isPseudoSection: Bool   // True for break markers (<!-- ::break:: -->)
    let startOffset: Int        // Character offset where section starts
    let markdownContent: String // Full markdown content of this section
    let wordCount: Int
}

/// Core reconciliation engine for section sync
/// Compares parsed headers with database sections to produce surgical changes
struct SectionReconciler: Sendable {

    /// Reconcile parsed headers with existing database sections
    /// Returns the minimal set of changes needed to update the database
    /// - Parameters:
    ///   - headers: Headers parsed from the current markdown content
    ///   - dbSections: Existing sections from the database
    ///   - projectId: Project ID for new sections
    /// - Returns: Array of changes to apply (insert/update/delete)
    func reconcile(
        headers: [ParsedHeader],
        dbSections: [Section],
        projectId: String
    ) -> [SectionChange] {
        var changes: [SectionChange] = []
        var matchedDBIds: Set<String> = []

        // Sort DB sections by position for matching
        let sortedDB = dbSections.sorted { $0.sortOrder < $1.sortOrder }

        // Match each parsed header to a database section
        for (index, header) in headers.enumerated() {
            if let match = findMatch(header, in: sortedDB, excluding: matchedDBIds) {
                matchedDBIds.insert(match.id)

                // Check if section needs updating
                let updates = buildUpdates(header: header, existing: match, newPosition: index)
                if updates != nil {
                    changes.append(.update(id: match.id, updates: updates!))
                }
            } else {
                // New section - create with new UUID
                let newSection = Section(
                    projectId: projectId,
                    sortOrder: index,
                    headerLevel: header.level,
                    isPseudoSection: header.isPseudoSection,
                    title: header.title,
                    markdownContent: header.markdownContent,
                    wordCount: header.wordCount,
                    startOffset: header.startOffset
                )
                changes.append(.insert(newSection))
            }
        }

        // Unmatched DB sections were deleted from markdown
        // EXCEPT bibliography/notes sections which are managed separately by their sync services
        for section in sortedDB where !matchedDBIds.contains(section.id) && !section.isBibliography && !section.isNotes {
            changes.append(.delete(id: section.id))
            // Deliberately excludes title: it's a literal excerpt of the user's
            // manuscript, and this line reaches the persistent DiagnosticLogFile
            // sink (Release builds included) whenever the user's Diagnostics
            // toggle is on. id+sortOrder+pseudo+status is enough to correlate
            // against a read-only DB inspection (see CLAUDE.md) if a mis-steal
            // needs investigating; it can't distinguish that from an ordinary
            // user-initiated deletion on its own, but this is a correlation key,
            // not a verdict.
            DebugLog.log(.sync, "[SectionReconciler] Deleted id=\(section.id.prefix(8)) " +
                "order=\(section.sortOrder) pseudo=\(section.isPseudoSection) status=\(section.status)")
        }

        return changes
    }

    // MARK: - Private Matching Logic

    /// Three-tier matching strategy for robust section identification
    /// - Parameters:
    ///   - header: The parsed header to match
    ///   - sections: Available database sections (sorted by sortOrder)
    ///   - excluding: IDs already matched (to prevent double-matching)
    /// - Returns: Matching section, or nil if no match found
    private func findMatch(
        _ header: ParsedHeader,
        in sections: [Section],
        excluding: Set<String>
    ) -> Section? {
        // Filter out already-matched IDs and bibliography sections.
        // Bibliography exclusion is needed because:
        // 1. OutlineParser markers prevent parsed headers FROM the bibliography
        // 2. But we also need to prevent parsed headers from matching TO the bibliography
        //    section via Tier 3 proximity matching. BibliographySyncService owns this section.
        let available = sections.filter { !excluding.contains($0.id) && !$0.isBibliography && !$0.isNotes }

        // Tier 1: Exact position match (most common - edits within a section)
        // Only honored when there's actual evidence the parsed header and the DB
        // row are the SAME logical section — not just co-located by sortOrder.
        // Without this gate, deleting a section's header+body causes whatever
        // follows to slide into the deleted section's old sortOrder slot and
        // silently inherit its identity (see meaningfulTextOverlap() in
        // web/milkdown/src/block-id-plugin.ts for the analogous fix on the
        // ProseMirror side of this exact bug).
        if let match = available.first(where: { $0.sortOrder == header.position }),
           passesMatchGate(header, match) {
            return match
        }

        // Tier 2: Same title anywhere (handles drag-drop reordering)
        // Skip for pseudo-sections which all have similar generated titles
        if !header.isPseudoSection,
           let match = available.first(where: { $0.title == header.title && $0.headerLevel == header.level }) {
            return match
        }

        // Tier 3: Closest position within ±3 (handles batch deletes/inserts)
        // Prefer a candidate with title/content evidence (the same identity gate
        // used by Tier 1) over a merely-closer unrelated one. Without this, a header
        // that lands within ±3 of an unrelated row (e.g. two sections deleted and a
        // third renamed in the same edit) can steal that row's identity while the
        // row that actually matches, now slightly farther away but still in range,
        // is left to be hard-deleted. Pseudo-sections rely on this exclusively,
        // since Tier 2 explicitly skips them (their titles are too generic to
        // trust). For pseudo headers, `passesMatchGate` drops the title clause
        // entirely, requires the candidate to ALSO be a pseudo-section, and compares
        // content with the leading break-marker line stripped from both sides —
        // pseudo titles collapse to the same generic "§ Section Break" whenever no
        // distinguishing paragraph follows the marker, so two unrelated breaks can
        // and do share a title; trusting it here (or comparing a pseudo header's
        // stripped body against a real heading's raw, unstripped content) is exactly
        // the bug this gate exists to close. If NO candidate in range has any
        // evidence at all, fall back to the original pure-proximity behavior — Tier
        // 3 exists specifically as a last resort when a section's title AND content
        // have both changed and only position continuity remains as a signal (see
        // closestPositionMatch).
        //
        // Within whichever candidate set wins (`related` or the `inRange` fallback),
        // title equality is used as a TIEBREAK preference, never as an admission
        // gate: a row that failed the filtering above never reaches this `.min` call
        // at all, but among rows that did, one whose title also matches the header
        // is preferred over a merely-closer one. This recovers the common case where
        // a pseudo-section's auto-derived title is stable (it only depends on a
        // paragraph's opening ~30 characters) but the rest of the paragraph was
        // heavily edited, breaking `contentRelated`'s prefix/suffix check — without
        // the tiebreak, that legitimate match could lose the `related.isEmpty`
        // proximity fallback to a coincidentally closer, title-mismatched row.
        let inRange = available.filter { abs($0.sortOrder - header.position) <= 3 }
        let related = inRange.filter { passesMatchGate(header, $0) }
        let candidates = related.isEmpty ? inRange : related
        return candidates.min { lhs, rhs in
            let lhsTitleMatches = lhs.title == header.title
            let rhsTitleMatches = rhs.title == header.title
            if lhsTitleMatches != rhsTitleMatches { return lhsTitleMatches }
            return abs(lhs.sortOrder - header.position) < abs(rhs.sortOrder - header.position)
        }
    }

    /// Whether a parsed header clears the identity gate for a DB row — whether there
    /// is evidence they are the same logical section rather than two things that merely
    /// occupy nearby sortOrder slots. Shared by Tier 1 and Tier 3, which until now held
    /// two copy-pasted copies of this expression; the pseudo-section exclusion below was
    /// added to Tier 2 and never propagated to either copy.
    ///
    /// Named for what it does, not for what it proves: `false` means "no evidence
    /// found", NOT "definitely a different section" — Tier 3's `related.isEmpty`
    /// fallback exists for exactly that difference.
    ///
    /// Pseudo-sections get no title clause, AND may only match a DB row that is
    /// ALSO a pseudo-section. Their titles are derived from the first paragraph
    /// after the break marker and collapse to the generic "§ Section Break"
    /// whenever no paragraph follows (a list, quote, table, code block or another
    /// marker instead) — see extractPseudoSectionTitle. Two unrelated section breaks
    /// therefore routinely share a title. This mirrors Tier 2's `!header.isPseudoSection`
    /// guard, for the same reason. Their content comparison additionally drops the
    /// leading break-marker line — see strippingLeadingBreakMarker.
    ///
    /// The `existing.isPseudoSection` requirement is a separate, equally necessary
    /// guard: without it, a pseudo header's marker-stripped body is compared against
    /// a non-pseudo row's RAW (unstripped) content, and a short stripped body can
    /// spuriously satisfy `contentRelated`'s suffix check purely by coincidence —
    /// e.g. header body "Some body text." against an unrelated real heading whose
    /// raw stored content is "## Heading\nSome body text.". That's the same shape of
    /// bug this whole gate exists to close, reintroduced on the pseudo/real axis
    /// instead of the pseudo/pseudo axis. A pseudo header therefore simply never
    /// matches a non-pseudo row through this gate — not by title, not by content —
    /// the same way a section break should never be silently reinterpreted as a real
    /// heading's row, or vice versa, on a content coincidence. (A non-pseudo header
    /// CAN still match a pseudo row by title in the branch below, unchanged from
    /// before this whole feature — that asymmetry is intentional, not a bug to fix
    /// here: a real heading's title is trustworthy evidence regardless of what kind
    /// of row currently holds it.)
    private func passesMatchGate(_ header: ParsedHeader, _ existing: Section) -> Bool {
        if header.isPseudoSection {
            guard existing.isPseudoSection else { return false }
            return contentRelated(
                normalizingListFormatting(strippingLeadingBreakMarker(header.markdownContent)),
                normalizingListFormatting(strippingLeadingBreakMarker(existing.markdownContent))
            )
        }
        return header.title == existing.title
            || contentRelated(header.markdownContent, existing.markdownContent)
    }

    /// Whether a parsed header's content looks like the same logical section as an
    /// existing DB row, rather than unrelated content that happens to occupy the
    /// same sortOrder slot. Byte-identical content (including both empty) always
    /// counts as related. Otherwise, a prefix/suffix relationship in either
    /// direction counts — this covers body-only edits, header-level conversions,
    /// and partial rewrites that preserve a leading or trailing run of text. One
    /// side empty and the other not does NOT count: every string is trivially a
    /// "prefix" of any string, so an empty section could otherwise claim any
    /// unrelated non-empty row (or vice versa) just by chance.
    private func contentRelated(_ headerContent: String, _ existingContent: String) -> Bool {
        if headerContent.isEmpty || existingContent.isEmpty { return false }
        if headerContent == existingContent { return true }
        return headerContent.hasPrefix(existingContent) || existingContent.hasPrefix(headerContent)
            || headerContent.hasSuffix(existingContent) || existingContent.hasSuffix(headerContent)
    }

    /// The canonical section-break marker line, matched exactly as
    /// SectionSyncService+Parsing.swift matches it when creating a pseudo-section's
    /// boundary — so this is never stricter or looser than the parser that produced
    /// the content.
    private static let breakMarker = "<!-- ::break:: -->"

    /// Pseudo-section content with its leading break-marker line removed, AND
    /// trailing whitespace/newlines trimmed. Every pseudo-section's content starts
    /// with that line (its boundary begins at the marker's offset), so the marker is
    /// shared boilerplate: without removing it, a marker-only body is a prefix of
    /// every other section break's body and would count as content "evidence"
    /// against all of them. The trailing trim matters for the identical reason: a
    /// marker-plus-newline-only body would otherwise strip down to just "\n" instead
    /// of "", which slips past `contentRelated`'s `isEmpty` guard and (via
    /// `hasSuffix`) would falsely relate to any body that happens to end in a
    /// newline.
    ///
    /// Only ever reached from the pseudo branch of `passesMatchGate`, and only AFTER
    /// that branch's `existing.isPseudoSection` guard — so both arguments passed
    /// here are always known to be pseudo-section content. That matters: this
    /// function is a no-op on content that doesn't start with the marker line, so if
    /// a non-pseudo row's raw content were ever passed through here unguarded, it
    /// would flow into `contentRelated` completely unstripped — exactly the
    /// coincidental-suffix/prefix bug that guard exists to prevent. `contentRelated`
    /// itself, and non-pseudo matching, are untouched by this helper.
    private func strippingLeadingBreakMarker(_ content: String) -> String {
        guard let newline = content.firstIndex(of: "\n") else {
            return content.trimmingCharacters(in: .whitespaces) == Self.breakMarker ? "" : content
        }
        guard content[content.startIndex..<newline]
                .trimmingCharacters(in: .whitespaces) == Self.breakMarker else { return content }
        return String(content[content.index(after: newline)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Matches a blank-line run (2+ consecutive newlines) that sits immediately
    /// before a line already starting with a bullet ("-"/"*"/"+") or ordered
    /// ("1."/"1)") list marker, optionally indented.
    private static let looseListGap: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"\n{2,}(?=[ \t]*(?:[-*+]|\d+[.)]) )"#, options: [])
        } catch {
            fatalError("Invalid loose-list-gap regex pattern: \(error)")
        }
    }()

    /// Matches a bullet marker specifically ("*" or "+", not "-") at the start of a
    /// line, capturing any leading indent so it can be preserved.
    private static let nonDashBulletMarker: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"^([ \t]*)[*+] "#, options: .anchorsMatchLines)
        } catch {
            fatalError("Invalid non-dash bullet marker regex pattern: \(error)")
        }
    }()

    /// Normalizes two SPECIFIC list-formatting differences confirmed by directly
    /// reproducing the real Milkdown pipeline (Editor.make() with
    /// sectionBreakPlugin + commonmark + gfm, feeding it this app's own seed
    /// markdown — not guessed) to come out of `api-content.ts`'s `getContent()`
    /// (Milkdown's own whole-document `getMarkdown()` serializer — the path a
    /// Source Mode paste's reparse goes through) but NOT out of this app's
    /// canonical block-fragment builder (`block-sync-plugin.ts`'s
    /// `nodeToMarkdownFragment`, which always emits "- " and joins sibling
    /// items with a single "\n"):
    ///
    /// 1. Bullet markers come back as "*" regardless of whether the source used
    ///    "-" (or "+") — reproduced with `<!-- ::break:: -->\n- alpha one` going
    ///    in and `<!-- ::break:: -->\n\n* alpha one\n` coming out.
    /// 2. A multi-item bullet list comes back "loose" — every item gets its own
    ///    blank-line-separated line instead of one item per line — reproduced
    ///    with `- gamma one\n- gamma two\n- gamma three` going in and
    ///    `* gamma one\n\n* gamma two\n\n* gamma three\n` coming out.
    ///
    /// Neither is a content change a person would recognize as one, but both
    /// defeat `contentRelated`'s exact-string prefix/suffix comparison: a
    /// pseudo-section's stored `markdownContent` (written directly, or produced
    /// by the block-fragment path) can carry "-" and tight spacing while a
    /// freshly re-parsed header carries "*" and loose spacing for the identical
    /// list, silently reintroducing the pre-fix bug through a formatting
    /// side-channel `strippingLeadingBreakMarker` doesn't touch. Scoped
    /// narrowly on purpose: `looseListGap` only collapses a blank-line run that
    /// sits immediately before a line that already looks like a list marker —
    /// blank lines anywhere else (genuinely separating distinct blocks) are
    /// untouched — and `nonDashBulletMarker` only retargets the marker
    /// character itself, never list-item TEXT. Both apply uniformly to
    /// whichever operand they're called on, so a side that was already tight/
    /// dash-formatted is unaffected (no-op). Only reached from the pseudo
    /// branch of `passesMatchGate`, after `strippingLeadingBreakMarker` —
    /// `contentRelated` itself, and non-pseudo matching, are untouched by this
    /// helper.
    private func normalizingListFormatting(_ content: String) -> String {
        let gapRange = NSRange(content.startIndex..., in: content)
        let tightened = Self.looseListGap.stringByReplacingMatches(in: content, options: [], range: gapRange, withTemplate: "\n")
        let markerRange = NSRange(tightened.startIndex..., in: tightened)
        return Self.nonDashBulletMarker.stringByReplacingMatches(in: tightened, options: [], range: markerRange, withTemplate: "$1- ")
    }

    /// Build updates struct if any field changed
    /// Returns nil if no changes needed
    private func buildUpdates(
        header: ParsedHeader,
        existing: Section,
        newPosition: Int
    ) -> SectionUpdates? {
        var hasChanges = false
        var updates = SectionUpdates()

        // Title changed (rename)
        if header.title != existing.title {
            updates.title = header.title
            hasChanges = true
        }

        // Level changed
        if header.level != existing.headerLevel {
            updates.headerLevel = header.level
            hasChanges = true
        }

        // isPseudoSection changed
        if header.isPseudoSection != existing.isPseudoSection {
            updates.isPseudoSection = header.isPseudoSection
            hasChanges = true
        }

        // Position changed
        if newPosition != existing.sortOrder {
            updates.sortOrder = newPosition
            hasChanges = true
        }

        // Content changed
        if header.markdownContent != existing.markdownContent {
            updates.markdownContent = header.markdownContent
            updates.wordCount = header.wordCount
            hasChanges = true
        }

        // Offset changed
        if header.startOffset != existing.startOffset {
            updates.startOffset = header.startOffset
            hasChanges = true
        }

        return hasChanges ? updates : nil
    }
}
