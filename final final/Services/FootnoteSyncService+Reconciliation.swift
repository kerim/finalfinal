//
//  FootnoteSyncService+Reconciliation.swift
//  final final
//

import Foundation
import GRDB

extension FootnoteSyncService {
    // MARK: - Static Helpers

    /// Pre-compiled regex for footnote reference extraction
    /// Matches [^N] where N is one or more digits, with negative lookahead for definition [^N]:
    nonisolated(unsafe) private static let footnoteRefPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(
                pattern: #"\[\^(\d+)\](?!:)"#,
                options: []
            )
        } catch {
            fatalError("Invalid footnote regex pattern: \(error)")
        }
    }()

    /// Pre-compiled regex for footnote definition extraction
    /// Matches [^N]: at line start, capturing label and rest of line
    nonisolated(unsafe) private static let footnoteDefPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(
                pattern: #"^\[\^(\d+)\]:\s*(.*)"#,
                options: [.anchorsMatchLines]
            )
        } catch {
            fatalError("Invalid footnote def regex pattern: \(error)")
        }
    }()

    /// Parse a single "[^N]: text" line/fragment into its label and definition text using
    /// `footnoteDefPattern`. Shared by `extractFootnoteDefinitions` (per line) and
    /// `reconcileNotesBlocks` (per Notes-block `markdownFragment`) — both previously carried
    /// their own copy of this same regex-match-and-extract logic. Note the underlying regex's
    /// `.` does not match newlines, so if `text` contains embedded "\n" (a multi-paragraph
    /// definition stored in one block), only the first line is captured — unchanged from the
    /// prior duplicated call sites.
    nonisolated static func parseNotesLabel(from text: String) -> (label: String, text: String)? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = footnoteDefPattern.firstMatch(in: text, range: range),
              let labelRange = Range(match.range(at: 1), in: text),
              let textRange = Range(match.range(at: 2), in: text) else {
            return nil
        }
        return (String(text[labelRange]), String(text[textRange]))
    }

    /// Extract ordered unique footnote reference labels from markdown content
    /// Excludes the #Notes section content (definitions should not be counted as references)
    nonisolated static func extractFootnoteRefs(from markdown: String) -> [String] {
        // Strip the #Notes section before scanning
        let bodyContent = stripNotesSection(from: markdown)
        let range = NSRange(bodyContent.startIndex..., in: bodyContent)
        let matches = footnoteRefPattern.matches(in: bodyContent, range: range)

        var seen = Set<String>()
        var ordered: [String] = []
        for match in matches {
            guard let labelRange = Range(match.range(at: 1), in: bodyContent) else { continue }
            let label = String(bodyContent[labelRange])
            if seen.insert(label).inserted {
                ordered.append(label)
            }
        }
        return ordered
    }

    /// Extract footnote definitions from the #Notes section content
    /// Returns a dictionary of label → definition text (including multi-paragraph)
    nonisolated static func extractFootnoteDefinitions(from notesContent: String) -> [String: String] {
        var definitions: [String: String] = [:]
        let lines = notesContent.components(separatedBy: "\n")

        var currentLabel: String?
        var currentText: [String] = []

        for line in lines {
            // Skip the heading line
            if line.hasPrefix("# ") { continue }

            if let parsed = parseNotesLabel(from: line) {
                // Save previous definition if any
                if let label = currentLabel {
                    definitions[label] = currentText.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                currentLabel = parsed.label
                currentText = [parsed.text]
            } else if currentLabel != nil {
                // Continuation line (4-space indented for multi-paragraph, or empty line)
                if line.hasPrefix("    ") {
                    currentText.append(String(line.dropFirst(4)))
                } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    currentText.append("")
                } else {
                    // Non-indented, non-empty line ends the current definition
                    // (unless it's another definition, handled above)
                    currentText.append(line)
                }
            }
        }

        // Save last definition
        if let label = currentLabel {
            definitions[label] = currentText.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return definitions
    }

    /// Strip the #Notes section from markdown content (returns body only)
    nonisolated static func stripNotesSection(from markdown: String) -> String {
        // Find "# Notes" heading (case-insensitive)
        let lines = markdown.components(separatedBy: "\n")
        var result: [String] = []
        var inNotes = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased() == "# notes" {
                inNotes = true
                continue
            }
            // If we hit another H1 heading, we're out of the notes section
            if inNotes && trimmed.hasPrefix("# ") && trimmed.lowercased() != "# notes" {
                inNotes = false
            }
            if !inNotes {
                result.append(line)
            }
        }

        return result.joined(separator: "\n")
    }

    // MARK: - Reconciliation

    /// Reconcile the Notes section's definition blocks toward `targetRefs`: renames,
    /// inserts, and deletes only the specific labels the delta requires — no
    /// delete-all-and-recreate. A block whose label is in neither `renameMap.keys` nor
    /// the insert set nor the delete set is never fetched-for-write and never has
    /// `.update(db)` called, so an unrelated footnote's block keeps the exact same `id`
    /// and `updatedAt` across a call that doesn't touch it. This is what makes a
    /// stale/overlapping rebuild safe: it can only destroy data for labels it explicitly
    /// says should change.
    ///
    /// Must be called from inside an existing `database.write { db in ... }` closure —
    /// this function does not open its own transaction, so the fetch-then-mutate sequence
    /// below is atomic with every other MainActor caller of `database.write`.
    ///
    /// - Parameters:
    ///   - targetRefs: the final set of definition labels that must exist once this call
    ///     returns (order doesn't matter — final display order is always numeric).
    ///   - renameMap: old label -> new label, applied in place (same block id, text
    ///     carried forward unless overridden) against a snapshot taken once at the top of
    ///     this call — safe for overlapping shifts (e.g. "2"->"3" and "3"->"4" in the same
    ///     call) because renames resolve against original identity, not by re-querying by
    ///     label mid-loop.
    ///   - definitionOverrides: new-label -> definition text, for a caller that already
    ///     knows the text a renamed-into or newly-inserted label should carry. Neither
    ///     current caller uses this (renames carry forward existing text; inserts default
    ///     to blank).
    /// Adopt rows that sit positionally inside a "# Notes" run but aren't flagged yet.
    /// `Database+BlocksInsert.swift`'s `resolveInsertPlacement`/`buildInsertedBlock`
    /// already flag a live-typed footnote continuation `isNotes = true` at insert time
    /// (anchored on an existing, non-heading Notes block is sufficient evidence on its
    /// own -- see that function's doc comment), so in the normal live-typing case this
    /// step has nothing to do. It exists as a BACKSTOP for paths that create or move
    /// Notes-area content WITHOUT going through `resolveInsertPlacement`'s containment
    /// check at all -- e.g. paste, bulk-insert, or any other write path that lands rows
    /// in the database directly. For those, the whole document IS available here, in its
    /// real physical order, so the same "carry the flag forward from the opening heading
    /// until the next heading" rule `BlockParser.sectionFlagCarriedForward` applies on a
    /// full reparse can be applied directly against the CURRENT `sortOrder` -- before
    /// anything else has a chance to disturb it.
    ///
    /// Must run before `reconcileNotesBlocks`'s step 7 whole-project sortOrder
    /// renormalization: that step's group sort (`isBibliography ? 2 : (isNotes ? 1 : 0)`)
    /// files any still-unflagged row into group 0 (ordinary body content) and PHYSICALLY
    /// MOVES it -- writing a new, permanent `sortOrder` -- above the "# Notes" heading.
    /// Once that write lands, the row genuinely precedes "# Notes", and every later
    /// reparse correctly (and now permanently) leaves it unflagged, because
    /// `sectionFlagCarriedForward` only ever carries the flag FORWARD from the heading,
    /// never backward to something already positioned above it. This is the only point
    /// in the whole reconciliation call where such a row's real, pre-relocation position
    /// is still visible.
    private static func adoptUnflaggedNotesContinuations(db: Database, projectId: String) throws {
        let docOrder = try Block
            .filter(Block.Columns.projectId == projectId)
            .order(Block.Columns.sortOrder)
            .fetchAll(db)
            .sorted { a, b in
                if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
                return (a.blockType == .heading ? 0 : 1) < (b.blockType == .heading ? 0 : 1)
            }
        var inNotesRun = false
        for var block in docOrder {
            // A dual-flagged (isBibliography) row is never Notes-reconciliation's to own --
            // same exclusion `existingDefBlocks`/`existingNotesBlocksForOwnership` below apply
            // -- and it also ends whatever Notes run preceded it positionally.
            if block.isBibliography {
                inNotesRun = false
                continue
            }
            if block.blockType == .heading {
                // Mirrors `sectionFlagCarriedForward`: this heading's OWN `isNotes` flag tells
                // us whether it's the "# Notes" heading (re-)opening a run, or any OTHER
                // heading closing one. Trusting the flag already on the row is safe here --
                // unlike a continuation, a heading is never left ambiguous at insert/parse
                // time (a "# Notes" heading is always created already flagged, either by a
                // full reparse via `sectionFlagCarriedForward` itself, or immediately by
                // `handleFootnoteInsertedImmediate` on live insertion).
                inNotesRun = block.isNotes
                continue
            }
            if inNotesRun && !block.isNotes {
                block.isNotes = true
                block.updatedAt = Date()
                try block.update(db)
            }
        }
    }

    static func reconcileNotesBlocks(
        db: Database,
        projectId: String,
        targetRefs: [String],
        renameMap: [String: String] = [:],
        definitionOverrides: [String: String] = [:]
    ) throws {
        // 0. Adopt rows that sit positionally inside a "# Notes" run but aren't flagged yet.
        //    MUST run before step 7's whole-project sortOrder renormalization below -- see
        //    `adoptUnflaggedNotesContinuations`'s own doc comment for why.
        try adoptUnflaggedNotesContinuations(db: db, projectId: projectId)

        // 1. Fetch current Notes paragraph blocks fresh (definitions, their continuations,
        //    and any pre-definition user prose); snapshot label -> Block ONCE before any
        //    writes. Defensively de-duplicate PARSEABLE definition rows only (keep
        //    most-recently-updated) in case pre-fix corruption left two rows claiming one
        //    label.
        //
        //    EXCLUDES isBibliography == true: a legacy heading whose configured
        //    bibliography-opening title collides with "Notes" produces rows flagged BOTH
        //    isNotes and isBibliography (see docs/deferred/bibliography-heading-collision-
        //    ambiguity.md and BlockParser.swift's independent inBibliographySection /
        //    inNotesSection tracking). Those rows belong to BibliographySyncService, never
        //    to this reconciliation -- without this exclusion a dual-flagged bibliography
        //    entry could be swept into the ownership walk below and become
        //    cascade-delete-eligible when an unrelated footnote label is removed. Mirrors
        //    the precedence the final sort comparator already applies (bibliography sorts
        //    ahead of, and separately from, the Notes group).
        let existingDefBlocks = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.isNotes == true)
            .filter(Block.Columns.isBibliography == false)
            .filter(Block.Columns.blockType == BlockType.paragraph.rawValue)
            .fetchAll(db)

        var snapshot: [String: Block] = [:]
        for block in existingDefBlocks {
            guard let parsed = parseNotesLabel(from: block.markdownFragment) else { continue }
            if let existing = snapshot[parsed.label], existing.updatedAt > block.updatedAt {
                continue
            }
            snapshot[parsed.label] = block
        }
        // Rows that DID parse a label but weren't kept as the canonical block for that label
        // are extra corruption from before this fix (two rows claiming one label) — delete
        // them outright. A row that fails `parseNotesLabel` — a multi-paragraph footnote's
        // continuation paragraph, or the user's own hand-typed Notes prose before any
        // definition — is NEVER a dedup candidate and is NEVER deleted here: it has no label
        // to be a "duplicate" of. (Previously this loop deleted every unparseable isNotes
        // paragraph outright, which silently destroyed continuation paragraphs on every
        // reconciliation call — see MultiParagraphFootnoteExportTests.)
        let keptIds = Set(snapshot.values.map(\.id))
        for block in existingDefBlocks
        where parseNotesLabel(from: block.markdownFragment) != nil && !keptIds.contains(block.id) {
            try Block.deleteOne(db, key: block.id)
        }

        // Positional ownership of every Notes row, computed ONCE before any writes. Used
        // below to cascade-delete a deleted label's continuations (step 4). MUST include
        // headings, unlike `existingDefBlocks` above: `notesOwnershipMap` resets ownership
        // at every heading it sees (a new "# Notes" run), and a document can legitimately
        // have more than one such run (`sectionFlagCarriedForward` can re-open the flag
        // more than once). Without headings in this input, that boundary is invisible and a
        // second run's leading content can be wrongly attributed to the first run's last
        // footnote -- see `notesOwnershipMap`'s doc comment. Same isBibliography exclusion
        // as `existingDefBlocks` above.
        let existingNotesBlocksForOwnership = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.isNotes == true)
            .filter(Block.Columns.isBibliography == false)
            .fetchAll(db)
        let preWriteOwnership = notesOwnershipMap(for: existingNotesBlocksForOwnership)

        // 2. Apply renames FIRST, against the snapshot above — never re-queried mid-loop
        //    — so overlapping shifts can't cross-contaminate each other.
        var renamedNewLabels: Set<String> = []
        for (oldLabel, newLabel) in renameMap {
            guard oldLabel != newLabel, var block = snapshot[oldLabel] else { continue }
            let existingText = parseNotesLabel(from: block.markdownFragment)?.text ?? ""
            let text = definitionOverrides[newLabel] ?? existingText
            block.markdownFragment = "[^\(newLabel)]: \(text)"
            block.textContent = text
            block.recalculateWordCount()
            try block.update(db)
            renamedNewLabels.insert(newLabel)
        }

        // 3. Insert-set and delete-set, computed AFTER the rename pass from the
        //    post-rename label set.
        let untouchedLabels = Set(snapshot.keys).subtracting(renameMap.keys)
        let presentLabels = untouchedLabels.union(renamedNewLabels)
        let targetSet = Set(targetRefs)
        let toInsert = targetRefs.filter { !presentLabels.contains($0) }
        let toDelete = untouchedLabels.subtracting(targetSet)

        // 4. Delete labels no longer wanted -- and cascade-delete any continuation rows owned
        //    by that label (per `preWriteOwnership`, computed before this loop). A
        //    continuation has no label of its own; once its owning definition is gone it is
        //    orphaned text with nothing left to attach to on export or re-render.
        for label in toDelete {
            if let block = snapshot[label] {
                try Block.deleteOne(db, key: block.id)
            }
            for candidate in existingDefBlocks {
                if case .continuation(let ownerLabel, _) = preWriteOwnership[candidate.id], ownerLabel == label {
                    try Block.deleteOne(db, key: candidate.id)
                }
            }
        }

        // 5. Heading block: reuse existing id, leave completely untouched if already
        //    present (no more churn-on-every-insert).
        let existingHeading = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.isNotes == true)
            .filter(Block.Columns.blockType == BlockType.heading.rawValue)
            .fetchOne(db)

        // Get max sort order from non-bibliography blocks. Notes should appear after
        // user content but before bibliography. This is only a placeholder for any
        // newly-inserted rows below — the renormalization pass in step 7 assigns real,
        // final sortOrder values.
        let maxNonBibSortOrder = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.isBibliography == false)
            .order(Block.Columns.sortOrder.desc)
            .fetchOne(db)?.sortOrder ?? 0
        let baseSortOrder = maxNonBibSortOrder + 0.5

        if existingHeading == nil, !targetRefs.isEmpty {
            var headingBlock = Block(
                projectId: projectId,
                sortOrder: baseSortOrder,
                blockType: .heading,
                textContent: "Notes",
                markdownFragment: "# Notes",
                headingLevel: 1,
                status: .final_,
                isNotes: true
            )
            headingBlock.recalculateWordCount()
            try headingBlock.insert(db)
        }

        // 6. Insert brand-new labels.
        for (index, label) in toInsert.enumerated() {
            let text = definitionOverrides[label] ?? ""
            var defBlock = Block(
                projectId: projectId,
                sortOrder: baseSortOrder + Double(index + 1),
                blockType: .paragraph,
                textContent: text,
                markdownFragment: "[^\(label)]: \(text)",
                isNotes: true
            )
            defBlock.recalculateWordCount()
            try defBlock.insert(db)
        }

        // Clean up orphaned footnote definitions from before isNotes propagation fix
        try deleteOrphanedFootnoteDefinitions(db: db, projectId: projectId)

        // 7. Whole-project sortOrder renormalization. Within the Notes group
        //    specifically, order by PARSED NUMERIC LABEL rather than sortOrder — an
        //    untouched block's stale sortOrder can no longer be trusted for relative
        //    order once only some blocks in the group got fresh values from steps 2/6
        //    above. Content and bibliography groups are unaffected by this call, so they
        //    keep ordering by sortOrder exactly as before. Only writes (and only bumps
        //    updatedAt for) a block whose sortOrder actually changes — this is what
        //    keeps an untouched block's row byte-identical (same id, same updatedAt).
        let allBlocks = try Block
            .filter(Block.Columns.projectId == projectId)
            .order(Block.Columns.sortOrder)
            .fetchAll(db)

        // Re-derive ownership from this fresh fetch (not `preWriteOwnership` above) so
        // renames already `.update(db)`'d by step 2 are reflected under their NEW label —
        // `preWriteOwnership` above is only used for cascade-delete, which only ever
        // concerns untouched (never-renamed) labels. Excludes isBibliography for the same
        // reason as `existingDefBlocks`/`existingNotesBlocksForOwnership` above: a
        // dual-flagged row must never be walked into this map at all -- even though the
        // sort comparator below only ever consults this map for `aGroup == 1` (isNotes,
        // non-bibliography) blocks, letting a dual-flagged row through would still pollute
        // `currentOwnerLabel` for whatever genuinely-Notes-only block follows it.
        let postWriteOwnership = notesOwnershipMap(for: allBlocks.filter { $0.isNotes && !$0.isBibliography })

        let sorted = allBlocks.sorted { a, b in
            let aGroup = a.isBibliography ? 2 : (a.isNotes ? 1 : 0)
            let bGroup = b.isBibliography ? 2 : (b.isNotes ? 1 : 0)
            if aGroup != bGroup { return aGroup < bGroup }
            if aGroup == 1 {
                return notesSortKey(postWriteOwnership[a.id]) < notesSortKey(postWriteOwnership[b.id])
            }
            return a.sortOrder < b.sortOrder
        }

        let now = Date()
        for (index, var block) in sorted.enumerated() {
            let newSortOrder = Double(index + 1)
            if block.sortOrder != newSortOrder {
                block.sortOrder = newSortOrder
                block.updatedAt = now
                try block.update(db)
            }
        }
    }

    /// Positional ownership of a block within the Notes group. A continuation paragraph has
    /// no label of its own -- unlike a definition, which owns exactly its parsed `[^N]:`
    /// label -- so which definition owns it can only be recovered positionally, by walking
    /// the group in `sortOrder` order and tracking the most recently seen definition.
    enum NotesBlockOwnership: Equatable {
        case heading
        case definition(label: String)
        /// `index` is 1-based, restarting at each new owning definition.
        case continuation(ownerLabel: String, index: Int)
        /// isNotes but neither a heading nor parseable as `[^N]:`, and preceding the FIRST
        /// definition in its run — e.g. the user's own hand-typed prose above their
        /// footnotes. `index` preserves original scan order. Deliberately its own
        /// out-of-scope bucket (sorts last within the Notes group, via `notesSortKey`) —
        /// this task does not change that behavior, only gives continuations a real home.
        case userProse(index: Int)
    }

    /// Walks `blocks` (expected to already be the Notes-flagged, i.e. `isNotes == true`,
    /// subset) in `sortOrder` order — headings before non-headings at a tied `sortOrder`,
    /// matching `BlockParser`'s own `assemblySorted` — and classifies each block's position
    /// within the Notes run.
    ///
    /// RUN-BOUNDARY RESET: `currentOwnerLabel` is reset to `nil` every time a heading is
    /// encountered. Because the input here is already filtered to `isNotes == true` blocks
    /// only, ANY heading appearing in it is, by construction, a "# Notes"-opening heading —
    /// `sectionFlagCarriedForward` can re-open the isNotes flag more than once per document
    /// (two separate Notes runs separated by ordinary body text), and the ownership walk
    /// must never let the second run's leading content inherit an owner from the FIRST
    /// run's last footnote just because they happen to sit next to each other once
    /// non-Notes content is filtered out of view. This mirrors `BlockParser+Assembly.swift`'s
    /// `classifyNotesRuns`, which resets per-run for the identical reason over the
    /// unfiltered array (there, any OTHER heading of any kind ends a run; here, since
    /// non-Notes content is already absent, every heading seen already IS that boundary) —
    /// keep both in sync if this rule ever changes. Caller MUST exclude isBibliography rows
    /// from `blocks` before calling this (see `reconcileNotesBlocks`'s call sites) — a
    /// dual-flagged legacy row is never Notes-reconciliation's to own.
    ///
    /// LOAD-BEARING ASSUMPTION: this walk trusts `sortOrder` to still reflect each
    /// continuation's original position relative to its owning definition after a rename.
    /// This holds because `reconcileNotesBlocks`'s rename step (step 2, above) only ever
    /// rewrites a renamed block's `markdownFragment`/`textContent` — it NEVER touches
    /// `sortOrder` — so a continuation's positional adjacency to its (possibly renamed)
    /// owner survives every rename this function performs. If a future change to the rename
    /// step ever starts reassigning `sortOrder`, this assumption breaks and ownership can
    /// silently drift onto the wrong definition. `NotesLabelRenameOwnershipTests` (in
    /// FootnoteSyncTests) enforces this directly: it renames two labels that each have a
    /// continuation underneath and asserts ownership is unchanged after the rename, rather
    /// than resting on this comment alone.
    static func notesOwnershipMap(for blocks: [Block]) -> [String: NotesBlockOwnership] {
        let sorted = blocks.sorted { a, b in
            if a.sortOrder != b.sortOrder {
                return a.sortOrder < b.sortOrder
            }
            return (a.blockType == .heading ? 0 : 1) < (b.blockType == .heading ? 0 : 1)
        }

        var map: [String: NotesBlockOwnership] = [:]
        var currentOwnerLabel: String?
        var continuationIndex = 0
        var userProseIndex = 0

        for block in sorted {
            if block.blockType == .heading {
                map[block.id] = .heading
                // A new "# Notes" run begins here -- any owner tracked from a PRIOR run
                // must not leak into this one. See this function's RUN-BOUNDARY RESET doc
                // above (kept in sync with BlockParser+Assembly.swift's classifyNotesRuns
                // and Database+BlocksReplace.swift's buildNotesRowIndex).
                currentOwnerLabel = nil
                continuationIndex = 0
                continue
            }
            if let parsed = parseNotesLabel(from: block.markdownFragment) {
                map[block.id] = .definition(label: parsed.label)
                currentOwnerLabel = parsed.label
                continuationIndex = 0
                continue
            }
            if let owner = currentOwnerLabel {
                continuationIndex += 1
                map[block.id] = .continuation(ownerLabel: owner, index: continuationIndex)
            } else {
                map[block.id] = .userProse(index: userProseIndex)
                userProseIndex += 1
            }
        }
        return map
    }

    /// Strict-weak-ordering sort key for a block within the Notes group, derived entirely
    /// from its precomputed `NotesBlockOwnership` — never recomputed positionally inside the
    /// comparator itself (which is what makes this a strict weak ordering, safe for
    /// `Array.sorted`). Replaces the old per-block `notesGroupSortKey`, which had no notion
    /// of continuations and would have scattered them via its `Int.max` fallback, letting a
    /// continuation drift away from its definition on renormalization.
    /// Three-way strict-weak-ordering key: group (heading < definitions/continuations <
    /// user prose), then label, then within-label index. A struct rather than a bare tuple
    /// so `<` compares component-wise via synthesized `Comparable`.
    private struct NotesSortKey: Comparable {
        let group: Int
        let label: Int
        let index: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.group, lhs.label, lhs.index) < (rhs.group, rhs.label, rhs.index)
        }
    }

    private static func notesSortKey(_ ownership: NotesBlockOwnership?) -> NotesSortKey {
        switch ownership {
        case .heading: return NotesSortKey(group: -1, label: 0, index: 0)
        case .definition(let label): return NotesSortKey(group: 0, label: Int(label) ?? Int.max, index: 0)
        case .continuation(let ownerLabel, let index):
            return NotesSortKey(group: 0, label: Int(ownerLabel) ?? Int.max, index: index)
        case .userProse(let index): return NotesSortKey(group: 1, label: Int.max, index: index)
        case nil: return NotesSortKey(group: 1, label: Int.max, index: Int.max)
        }
    }

    /// Pre-compiled regex for orphaned footnote definition detection
    private static let orphanedDefPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"^\[\^\d+\]:\s*"#)
        } catch {
            fatalError("Invalid orphaned def regex pattern: \(error)")
        }
    }()

    /// Delete orphaned footnote definition blocks (isNotes=false but contain [^N]: text)
    /// Cleans up corruption from before Fix 1 marked all Notes children with isNotes=true
    static func deleteOrphanedFootnoteDefinitions(db: Database, projectId: String) throws {
        let candidates = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.isNotes == false)
            .filter(Block.Columns.blockType == BlockType.paragraph.rawValue)
            .fetchAll(db)
        for block in candidates {
            let frag = block.markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(frag.startIndex..., in: frag)
            if orphanedDefPattern.firstMatch(in: frag, range: range) != nil {
                try Block.deleteOne(db, key: block.id)
            }
        }
    }
}
