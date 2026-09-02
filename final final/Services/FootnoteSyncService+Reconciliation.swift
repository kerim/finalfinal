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

    /// Extract footnote definitions from the Notes section content.
    /// Returns a dictionary of label → definition text (including multi-paragraph).
    ///
    /// C4 CORRUPTION FIX: previously only skipped a line matching the literal `"# "` prefix
    /// (single-hash H1) as "the heading line" -- every OTHER heading (any `##`-`######` level,
    /// including a SECOND "## Notes"/"# Notes" heading) fell through to the continuation-line
    /// branch below and got APPENDED onto whatever definition was still open, silently
    /// corrupting that definition's text with heading content instead of being recognized as a
    /// boundary. This was reachable even before Stage C (any caller that concatenates more than
    /// one Notes run's content into a single `notesContent` string before calling this, or a
    /// hand-typed second "## Notes" heading inside the section, already exhibited it) but Stage
    /// C's widening makes it substantially MORE reachable: `pushDefinitionsToEditor`'s migrated
    /// scan (see that function) can now legitimately concatenate more than one confirmed Notes
    /// run into the `notesContent` it hands this function, since H2 headings are recognized
    /// openers too. Fixed by treating ANY heading line (`^#{1,6}\s+`, matching every other
    /// heading test in this codebase -- see `NotesOpeningSelector.Unit.isAnyHeading`) as a
    /// boundary: it saves whatever definition was open, resets tracking state, and is itself
    /// never appended to any definition's text.
    nonisolated static func extractFootnoteDefinitions(from notesContent: String) -> [String: String] {
        var definitions: [String: String] = [:]
        let lines = notesContent.components(separatedBy: "\n")

        var currentLabel: String?
        var currentText: [String] = []

        for line in lines {
            // Any heading line (not just the literal H1 "# " this used to special-case) is a
            // boundary: save whatever definition was open, then skip the heading itself --
            // never append its text to anything. See this function's own doc comment.
            if line.range(of: "^#{1,6}\\s+", options: .regularExpression) != nil {
                if let label = currentLabel {
                    definitions[label] = currentText.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                currentLabel = nil
                currentText = []
                continue
            }

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

    /// Strip the Notes section from markdown content (returns body only).
    ///
    /// C4: migrated onto the shared `NotesOpeningSelector` (H1-or-H2 title match +
    /// `[^N]:` evidence beneath -- see that type's doc comment) in place of the old
    /// exact-H1-literal-only `"# notes"` check, and the closing rule is widened from
    /// "next H1" to "next heading of ANY level" (matching `NotesOpeningSelector.Unit.
    /// isAnyHeading`'s rule, and `BlockParser.sectionFlagCarriedForward`'s "any other
    /// heading closes the run"). `notesHeaderName` defaults to the literal `"Notes"` --
    /// same override contract as `BlockParser.isNotesHeading` -- for every existing
    /// caller to stay bit-identical when a DB-resolved name isn't available.
    /// Stage A's open/close instrumentation below is preserved as-is; only the
    /// open/close CONDITIONS changed, per this function's own A3 comment.
    nonisolated static func stripNotesSection(from markdown: String, notesHeaderName: String = "Notes") -> String {
        let lines = markdown.components(separatedBy: "\n")
        DebugLog.log(.footnotes, "[FootnoteSyncService] stripNotesSection: entry lines=\(lines.count)")

        let trimmedLines = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        // C4 fence fix (found while cross-checking against SectionSyncService+Parsing.swift's
        // own `inCodeBlock`-gated heading detection, and against BlockParser -- a fenced code
        // block is one opaque raw block there, so a "## Notes"-shaped LINE inside it is never
        // separately tokenized as its own unit at all): a heading-shaped or evidence-shaped
        // line sitting INSIDE a ``` fence must never be treated as real -- someone's code
        // sample literally containing "## Notes" or "[^1]: text" must not be mistaken for a
        // real Notes heading/definition. This scan tracks fence state exactly like
        // `SectionSyncService+Parsing.swift`'s main loop does.
        var inCodeBlockForTokenizing = false
        let units = trimmedLines.map { trimmed -> NotesOpeningSelector.Unit in
            if trimmed.hasPrefix("```") {
                inCodeBlockForTokenizing.toggle()
                return NotesOpeningSelector.Unit(isCandidateHeading: false, isAnyHeading: false, isEvidence: false)
            }
            guard !inCodeBlockForTokenizing else {
                return NotesOpeningSelector.Unit(isCandidateHeading: false, isAnyHeading: false, isEvidence: false)
            }
            return NotesOpeningSelector.Unit(
                isCandidateHeading: BlockParser.isNotesHeading(trimmed, notesHeaderName: notesHeaderName),
                isAnyHeading: trimmed.range(of: "^#{1,6}\\s+", options: .regularExpression) != nil,
                isEvidence: parseNotesLabel(from: trimmed) != nil
            )
        }
        let openingIndices = Set(NotesOpeningSelector.select(units))

        var result: [String] = []
        var inNotes = false
        // A3 (opening-vs-extent): this is a Notes-region open/close computation like
        // `adoptUnflaggedNotesContinuations` above -- log the opening index separately
        // from the closing index/reason, so a later stage can tell "wrong opening
        // selected" apart from "run cut off in the wrong place" for THIS scanner too
        // (Stage D's regression gate needs to diff both axes against this exact
        // function -- attempt 1 changed both the open rule and the close rule here).
        var openIndex: Int?
        var everOpened = false

        for (index, line) in lines.enumerated() {
            if openingIndices.contains(index) {
                inNotes = true
                openIndex = index
                everOpened = true
                DebugLog.log(.footnotes, "[FootnoteSyncService] stripNotesSection: opened " +
                    "index=\(index) line=\"\(line.prefix(60))\"")
                continue
            }
            // Any other heading of any level closes the run -- widened from the old
            // H1-only check; see this function's own doc comment.
            if inNotes && units[index].isAnyHeading {
                DebugLog.log(.footnotes, "[FootnoteSyncService] stripNotesSection: closed " +
                    "closedAtIndex=\(index) openIndex=\(openIndex ?? -1) reason=next-heading " +
                    "line=\"\(line.prefix(60))\"")
                inNotes = false
                openIndex = nil
            }
            if !inNotes {
                result.append(line)
            }
        }
        if inNotes {
            DebugLog.log(.footnotes, "[FootnoteSyncService] stripNotesSection: closed " +
                "closedAtIndex=\(lines.count) openIndex=\(openIndex ?? -1) reason=end-of-document")
        } else if !everOpened {
            DebugLog.log(.footnotes, "[FootnoteSyncService] stripNotesSection: no-notes-heading-found")
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
    /// C1 -- EVIDENCE BAR (supersedes Stage B's B8 comment, which deferred this to Stage C
    /// because `NotesOpeningSelector` didn't exist yet). Adoption now opens a run two ways,
    /// per C1(1):
    /// 1. The heading's own `isNotes` flag (set by `BlockParser.sectionFlagCarriedForward`
    ///    on a full reparse, or by `handleFootnoteInsertedImmediate` on live insertion) --
    ///    the pre-Stage-C path, unchanged.
    /// 2. `NotesOpeningSelector`-confirmed evidence: an UNFLAGGED H1-or-H2 heading whose
    ///    title matches the document's currently-recognized Notes header name (see
    ///    `fetchNotesHeadingTitle`'s doc comment; falls back to `"Notes"`) AND whose span
    ///    contains a real `[^N]:` definition. This is the actual widening this whole task
    ///    exists to land: a doc's `## Notes` (or any other unflagged, evidenced Notes
    ///    heading) is now recognized by this backstop even when nothing upstream ever
    ///    flagged it.
    ///
    /// C1(2): when path 2 is what opened the run, this function now WRITES `isNotes = true`
    /// onto the heading row itself (a flag-only write, no `updatedAt` restamp -- same B2(i)
    /// discipline as the continuation-adoption write below) -- previously this function only
    /// ever READ a heading's flag, never wrote one, which is exactly why step 5's later
    /// flag-keyed heading lookup (see `reconcileNotesBlocks`) used to duplicate the heading
    /// instead of finding this one: from that lookup's point of view, an evidenced-but-
    /// unflagged "## Notes" heading simply didn't exist yet.
    ///
    /// C1(3) -- THE ACTUAL B3 FIX: adoption claims ONLY footnote definitions
    /// (`FootnoteSyncService.parseNotesLabel` matches) and their CONTINUATIONS (any
    /// non-definition, non-heading row positioned after a definition and before the next
    /// heading -- the same positional-ownership model `notesOwnershipMap` already uses for
    /// already-flagged rows, applied here to decide adoption itself). Arbitrary user prose
    /// sitting inside an open run BEFORE its first definition is NEVER claimed -- it stays
    /// unflagged exactly where it is. This is the fix Stage B's own B3 needed but couldn't
    /// safely make at the `Database+BlocksReplace+RowOps.swift` layer: B3's first attempt
    /// narrowed `protectingNotes` to machine-owned rows only and broke a proven invariant,
    /// because at THAT layer there was no way to tell "a later run's genuinely-untouched
    /// user prose" apart from "the user deleted it" -- both looked identical once arbitrary
    /// prose could already carry `isNotes = true`. Fixing it HERE instead, by simply never
    /// granting that flag to prose in the first place, means every `isNotes` non-heading row
    /// this function is responsible for adopting really is machine-owned footnote content --
    /// `protectingNotes` at the RowOps layer stays exactly as Stage B left it (unconditional
    /// protect-all), which remains correct and needs no further narrowing. Deletion of
    /// anything this function adopts additionally requires B5's body evidence (see
    /// `deleteOrphanedFootnoteDefinitions` below) before a row already carrying real text can
    /// be treated as redundant.
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
        DebugLog.log(.footnotes, "[FootnoteSyncService] adoptUnflaggedNotesContinuations: entry " +
            "projectId=\(projectId) blocks=\(docOrder.count)")

        // C1(1)/C2: the currently-recognized Notes header name -- whatever heading is
        // ALREADY flagged `isNotes`, if any, else the literal default. Mirrors
        // `Database+Blocks.swift`'s `fetchNotesHeadingTitle` exactly (same query, same
        // `ORDER BY sortOrder` first-in-document-order tie rule) but inlined against this
        // function's own `db: Database` rather than going through `ProjectDatabase.read`,
        // since this call is already inside an open write transaction.
        let existingNotesHeaderName = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.blockType == BlockType.heading.rawValue)
            .filter(Block.Columns.isNotes == true)
            .order(Block.Columns.sortOrder)
            .fetchOne(db)?.textContent
        let notesHeaderName = existingNotesHeaderName ?? "Notes"

        // C1(1)/C3: every doc-order index whose heading the shared `NotesOpeningSelector`
        // confirms opens a Notes run by evidence alone (title match + a real `[^N]:`
        // beneath it), independent of whatever flag it currently carries.
        let notesOpeningIndices = Set(NotesOpeningSelector.select(docOrder.map { block in
            // `block.textContent` is already the heading text with its leading "#"s and
            // whitespace stripped (see `BlockParser.extractTextContent`), so the candidate
            // test here is a direct case-insensitive title comparison rather than a
            // round-trip through `isNotesHeading`'s own "# "/"## " literal reconstruction --
            // level 1-or-2 is read straight off `block.headingLevel` instead.
            let isCandidateHeading = block.blockType == .heading
                && [1, 2].contains(block.headingLevel)
                && block.textContent.caseInsensitiveCompare(notesHeaderName) == .orderedSame
            return NotesOpeningSelector.Unit(
                isCandidateHeading: isCandidateHeading,
                isAnyHeading: block.blockType == .heading,
                isEvidence: FootnoteSyncService.parseNotesLabel(from: block.markdownFragment) != nil
            )
        }))

        var inNotesRun = false
        // C1(3): the label most recently seen as a definition in the CURRENT run, reset at
        // every run boundary (heading, isBibliography row, or run close) -- exactly
        // `notesOwnershipMap`'s own `currentOwnerLabel` reset discipline, applied here to
        // decide ADOPTION rather than to classify already-adopted rows.
        var currentOwnerLabel: String?
        // A3 (opening-vs-extent): the opening heading's index/id for whichever run is
        // currently open, and how many rows it has adopted so far. Logged whenever the
        // run closes -- separately from the opening log line -- so a later stage can tell
        // "the wrong heading was selected" apart from "the run was cut off in the wrong
        // place" (see this file's DebugLog.log call sites in reconcileNotesBlocks for the
        // same discipline applied to the other Notes-region computations).
        var runOpenIndex: Int?
        var runOpenHeadingId: String?
        var runAdoptedCount = 0

        func closeRun(reason: String, closedAtIndex: Int, closedByBlockId: String?) {
            guard let openIndex = runOpenIndex else { return }
            DebugLog.log(.footnotes, "[FootnoteSyncService] adoptUnflaggedNotesContinuations: run closed " +
                "openIndex=\(openIndex) openHeadingId=\(runOpenHeadingId ?? "?") closedAtIndex=\(closedAtIndex) " +
                "closedByBlockId=\(closedByBlockId ?? "end-of-document") reason=\(reason) adopted=\(runAdoptedCount)")
            runOpenIndex = nil
            runOpenHeadingId = nil
            runAdoptedCount = 0
        }

        for (index, var block) in docOrder.enumerated() {
            // A dual-flagged (isBibliography) row is never Notes-reconciliation's to own --
            // same exclusion `existingDefBlocks`/`existingNotesBlocksForOwnership` below apply
            // -- and it also ends whatever Notes run preceded it positionally.
            if block.isBibliography {
                if inNotesRun {
                    closeRun(reason: "isBibliography row", closedAtIndex: index, closedByBlockId: block.id)
                }
                inNotesRun = false
                currentOwnerLabel = nil
                continue
            }
            if block.blockType == .heading {
                // C1(1): a heading (re-)opens a run when it's ALREADY flagged (the
                // pre-Stage-C path, trusted exactly as before -- a flagged heading is never
                // left ambiguous at insert/parse time) OR the selector confirms it by
                // evidence alone.
                let selectorConfirmed = notesOpeningIndices.contains(index)
                DebugLog.log(.footnotes, "[FootnoteSyncService] adoptUnflaggedNotesContinuations: heading seen " +
                    "index=\(index) id=\(block.id) isNotes=\(block.isNotes) " +
                    "selectorConfirmed=\(selectorConfirmed) " +
                    "fragment=\"\(block.markdownFragment.prefix(60))\"")
                if inNotesRun {
                    closeRun(reason: "next heading", closedAtIndex: index, closedByBlockId: block.id)
                }
                inNotesRun = block.isNotes || selectorConfirmed
                currentOwnerLabel = nil
                if inNotesRun {
                    runOpenIndex = index
                    runOpenHeadingId = block.id
                    runAdoptedCount = 0
                    // C1(2): persist the flag onto the heading itself when the SELECTOR is
                    // what opened this run -- see this function's doc comment for why this
                    // write (previously this function never wrote a heading row at all) is
                    // what makes step 5's flag-keyed heading lookup stop duplicating.
                    if selectorConfirmed && !block.isNotes {
                        DebugLog.log(.footnotes, "[FootnoteSyncService] adoptUnflaggedNotesContinuations: " +
                            "flagging heading index=\(index) id=\(block.id) reason=selector-confirmed-evidence")
                        // B2(i): flag-only write -- no `updatedAt` restamp, same reasoning as
                        // the continuation-adoption write below.
                        block.isNotes = true
                        try block.update(db)
                    }
                }
                continue
            }
            guard inNotesRun else { continue }
            // C1(3): claim ONLY definitions and their continuations, never arbitrary prose --
            // see this function's doc comment ("THE ACTUAL B3 FIX") for why this is the
            // correct layer for that fix, not `Database+BlocksReplace+RowOps.swift`.
            if let parsed = FootnoteSyncService.parseNotesLabel(from: block.markdownFragment) {
                currentOwnerLabel = parsed.label
                if !block.isNotes {
                    DebugLog.log(.footnotes, "[FootnoteSyncService] adoptUnflaggedNotesContinuations: adopting " +
                        "index=\(index) id=\(block.id) kind=definition label=\(parsed.label) " +
                        "fragment=\"\(block.markdownFragment.prefix(60))\"")
                    // B2(i): this is a FLAG-ONLY write -- do not restamp updatedAt. Dedup
                    // (see the `reconcileNotesBlocks` step-1 rewrite below) used to trust
                    // updatedAt as a recency signal to pick a winner between two same-labeled
                    // rows; restamping it here on every adoption made that signal meaningless
                    // (an adopted row would always look "more recent" than a genuinely-edited
                    // one). Leaving `block.updatedAt` untouched means `.update(db)` writes the
                    // same value back for that column -- a true no-op for it.
                    block.isNotes = true
                    try block.update(db)
                    runAdoptedCount += 1
                }
                continue
            }
            if currentOwnerLabel != nil {
                if !block.isNotes {
                    DebugLog.log(.footnotes, "[FootnoteSyncService] adoptUnflaggedNotesContinuations: adopting " +
                        "index=\(index) id=\(block.id) kind=continuation owner=\(currentOwnerLabel ?? "?") " +
                        "fragment=\"\(block.markdownFragment.prefix(60))\"")
                    block.isNotes = true
                    try block.update(db)
                    runAdoptedCount += 1
                }
                continue
            }
            // Arbitrary prose positioned before this run's first definition -- never
            // claimed. See this function's doc comment ("C1(3) -- THE ACTUAL B3 FIX").
            DebugLog.log(.footnotes, "[FootnoteSyncService] adoptUnflaggedNotesContinuations: skipping " +
                "index=\(index) id=\(block.id) reason=user-prose-no-owning-definition-yet " +
                "fragment=\"\(block.markdownFragment.prefix(60))\"")
        }
        if inNotesRun {
            closeRun(reason: "end of document", closedAtIndex: docOrder.count, closedByBlockId: nil)
        }
    }

    /// E1: returns label -> newly-inserted-block-id for every label step 6 actually creates a
    /// fresh row for in THIS call (an untouched/renamed label is never in this map). Lets
    /// `handleImmediateInsertion` thread the real DB id of the label the user just inserted
    /// through to the `.scrollToFootnoteDefinition` notification's `userInfo["blockId"]`,
    /// instead of that id being discarded here as it previously was. `@discardableResult`
    /// because the debounced path (`updateNotesBlock`) has no single "the one label the user
    /// just inserted" to report and legitimately ignores the return value.
    @discardableResult
    static func reconcileNotesBlocks(
        db: Database,
        projectId: String,
        targetRefs: [String],
        renameMap: [String: String] = [:],
        definitionOverrides: [String: String] = [:]
    ) throws -> [String: String] {
        DebugLog.log(.footnotes, "[FootnoteSyncService] reconcileNotesBlocks: entry projectId=\(projectId) " +
            "targetRefs=\(targetRefs) renameMap=\(renameMap) definitionOverrides=\(Array(definitionOverrides.keys))")

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

        // B2(ii): dedup no longer picks a winner by `updatedAt` recency -- B2(i) stopped
        // adoption from restamping it on a flag-only write, so it is no longer a
        // trustworthy signal that one row is "more recent" than the other. Instead this
        // applies B5's body rule directly: never delete a non-blank body in favor of a
        // blank one, and never delete when two non-blank bodies genuinely differ (that
        // case is PARKED -- surfaced, per B8 -- rather than either row being destroyed).
        // A row that fails `parseNotesLabel` — a multi-paragraph footnote's continuation
        // paragraph, or the user's own hand-typed Notes prose before any definition — is
        // NEVER a dedup candidate and is NEVER deleted here: it has no label to be a
        // "duplicate" of. (Previously this loop deleted every unparseable isNotes
        // paragraph outright, which silently destroyed continuation paragraphs on every
        // reconciliation call — see MultiParagraphFootnoteExportTests.)
        var snapshot: [String: Block] = [:]
        var dedupDeletedCount = 0
        let byLabel = Dictionary(grouping: existingDefBlocks.compactMap { block -> (String, Block)? in
            guard let parsed = parseNotesLabel(from: block.markdownFragment) else { return nil }
            return (parsed.label, block)
        }, by: \.0).mapValues { $0.map(\.1) }

        for (label, group) in byLabel {
            guard group.count > 1 else {
                snapshot[label] = group[0]
                continue
            }
            let bodies = group.map { block in
                (block: block, body: (parseNotesLabel(from: block.markdownFragment)?.text ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let distinctNonBlank = Set(bodies.map(\.body).filter { !$0.isEmpty })
            if distinctNonBlank.count > 1 {
                // Two rows genuinely disagree on this label's text -- never delete either.
                // Keep the first as the canonical row so the rest of reconciliation has
                // exactly one block per label to work with; every other row is left in
                // place, untouched, and logged (B8's repair-path surfacing).
                let winner = bodies[0].block
                snapshot[label] = winner
                DebugLog.log(.footnotes, "[FootnoteSyncService] reconcileNotesBlocks:dedup PARKED " +
                    "label=\(label) reason=bodies-differ-non-blank canonicalId=\(winner.id) " +
                    "blockIds=\(group.map(\.id)) bodies=\(bodies.map(\.body))")
                continue
            }
            // All bodies blank, or every non-blank body among the group is identical text
            // -- a genuine duplicate. Keep a non-blank one if present (else any), delete
            // the rest.
            let winner = bodies.first(where: { !$0.body.isEmpty })?.block ?? group[0]
            snapshot[label] = winner
            for block in group where block.id != winner.id {
                // B9: log the full fragment before deleting.
                DebugLog.log(.footnotes, "[FootnoteSyncService] reconcileNotesBlocks:dedup DELETING loser " +
                    "label=\(label) loserId=\(block.id) winnerId=\(winner.id) reason=blank-or-identical-body " +
                    "loserFragment=\"\(block.markdownFragment)\"")
                try Block.deleteOne(db, key: block.id)
                dedupDeletedCount += 1
            }
        }
        DebugLog.log(.footnotes, "[FootnoteSyncService] reconcileNotesBlocks:dedup done deleted=\(dedupDeletedCount)")

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
        let preWriteOwnership = notesOwnershipMap(for: existingNotesBlocksForOwnership).ownership

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
        // B4: `.fetchOne` with no `.order` picked whichever row SQLite happened to return
        // first -- non-deterministic once two flagged Notes headings exist. Tie-break,
        // stated: the EARLIEST heading in document order (lowest sortOrder) is "the" Notes
        // heading this reconciliation reuses/updates; any other flagged heading is left
        // alone here (it is a second run, handled by the per-run sort key below).
        let existingHeading = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.isNotes == true)
            .filter(Block.Columns.blockType == BlockType.heading.rawValue)
            .order(Block.Columns.sortOrder)
            .fetchOne(db)
        DebugLog.log(.footnotes, "[FootnoteSyncService] reconcileNotesBlocks:step5 heading lookup " +
            (existingHeading.map {
                "found id=\($0.id) headingLevel=\($0.headingLevel ?? -1) fragment=\"\($0.markdownFragment.prefix(60))\""
            } ?? "none-found willCreate=\(!targetRefs.isEmpty)"))

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
            // C1(2)-adjacent fix: before materializing a brand-new machine "# Notes" heading,
            // re-check for an UNFLAGGED heading matching the Notes title at level 1 or 2 and
            // adopt it in place instead. This closes a gap step 0's `adoptUnflaggedNotesContinuations`
            // can't: that step ran BEFORE step 6 below inserts this call's own new definition
            // row, so a live-typed "## Notes" heading with no OTHER evidence yet (e.g. the very
            // first footnote the user is inserting) looks evidence-free to step 0 and is left
            // unflagged — leaving `existingHeading` (which only looks for an ALREADY-flagged
            // heading) nil here too, and this branch would otherwise silently insert a second,
            // machine-owned "# Notes" heading right alongside the user's own, unflagged "##
            // Notes". Adopting the existing row in place preserves its `headingLevel` and
            // `markdownFragment` exactly as the user typed them, matching Stage C's settled
            // decision that heading level is kept as typed, never normalized. Mirrors
            // `adoptUnflaggedNotesContinuations`'s own title/level match and its `isBibliography`
            // dual-flag exclusion (a legacy heading flagged both is never this reconciliation's
            // to adopt — see that exclusion's doc comment a few hundred lines up in this file).
            let unflaggedNotesHeading = try Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.blockType == BlockType.heading.rawValue)
                .filter(Block.Columns.isNotes == false)
                .filter(Block.Columns.isBibliography == false)
                .order(Block.Columns.sortOrder)
                .fetchAll(db)
                .first { candidate in
                    [1, 2].contains(candidate.headingLevel)
                        && candidate.textContent.caseInsensitiveCompare("Notes") == .orderedSame
                }
            if var adopted = unflaggedNotesHeading {
                DebugLog.log(.footnotes, "[FootnoteSyncService] reconcileNotesBlocks:step5 adopting " +
                    "unflagged heading id=\(adopted.id) headingLevel=\(adopted.headingLevel ?? -1) " +
                    "fragment=\"\(adopted.markdownFragment.prefix(60))\" instead of materializing a new one")
                adopted.isNotes = true
                try adopted.update(db)
            } else {
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
        }

        // 6. Insert brand-new labels.
        DebugLog.log(.footnotes, "[FootnoteSyncService] reconcileNotesBlocks:step6 toInsert=\(toInsert)")
        var insertedIds: [String: String] = [:]
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
            insertedIds[label] = defBlock.id
            DebugLog.log(.footnotes, "[FootnoteSyncService] reconcileNotesBlocks:step6 inserted blank " +
                "id=\(defBlock.id) label=\(label) textIsBlank=\(text.isEmpty) sortOrder=\(defBlock.sortOrder)")
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
        let postWrite = notesOwnershipMap(for: allBlocks.filter { $0.isNotes && !$0.isBibliography })

        let sorted = allBlocks.sorted { a, b in
            let aGroup = a.isBibliography ? 2 : (a.isNotes ? 1 : 0)
            let bGroup = b.isBibliography ? 2 : (b.isNotes ? 1 : 0)
            if aGroup != bGroup { return aGroup < bGroup }
            if aGroup == 1 {
                return notesSortKey(postWrite.ownership[a.id], run: postWrite.run[a.id] ?? 0) <
                    notesSortKey(postWrite.ownership[b.id], run: postWrite.run[b.id] ?? 0)
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

        return insertedIds
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
    /// B4: also returns a per-block RUN ordinal, zero-based from this same walk's own
    /// heading-reset boundary (the identical boundary `currentOwnerLabel` resets on,
    /// below) — a row with no owning heading yet (stray content before any heading in
    /// `blocks`, which should not normally occur but is handled rather than crashing)
    /// takes run 0. This is what `notesSortKey` uses as its MOST significant sort
    /// component: before this, every heading collapsed to the identical key `(-1, 0, 0)`
    /// regardless of which run it opened, so two separate Notes runs' content could
    /// interleave/fuse under sort. `run` must never be recomputed positionally inside a
    /// sort comparator (same reasoning as `NotesBlockOwnership` itself) — it is captured
    /// here, once, per block.
    nonisolated static func notesOwnershipMap(for blocks: [Block]) -> (ownership: [String: NotesBlockOwnership], run: [String: Int]) {
        let sorted = blocks.sorted { a, b in
            if a.sortOrder != b.sortOrder {
                return a.sortOrder < b.sortOrder
            }
            return (a.blockType == .heading ? 0 : 1) < (b.blockType == .heading ? 0 : 1)
        }

        var map: [String: NotesBlockOwnership] = [:]
        var runIndex: [String: Int] = [:]
        var currentOwnerLabel: String?
        var continuationIndex = 0
        var userProseIndex = 0
        var currentRun = -1

        for block in sorted {
            if block.blockType == .heading {
                currentRun += 1
                map[block.id] = .heading
                runIndex[block.id] = currentRun
                // A new "# Notes" run begins here -- any owner tracked from a PRIOR run
                // must not leak into this one. See this function's RUN-BOUNDARY RESET doc
                // above (kept in sync with BlockParser+Assembly.swift's classifyNotesRuns
                // and Database+BlocksReplace.swift's buildNotesRowIndex).
                currentOwnerLabel = nil
                continuationIndex = 0
                continue
            }
            // Stray non-heading content ahead of any heading in `blocks` (shouldn't
            // normally happen -- a "# Notes" run always opens with its heading) takes
            // run 0 rather than -1, so it still sorts as a real, first-position run.
            let run = max(currentRun, 0)
            runIndex[block.id] = run
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
        return (map, runIndex)
    }

    /// Strict-weak-ordering sort key for a block within the Notes group, derived entirely
    /// from its precomputed `NotesBlockOwnership` and run ordinal — never recomputed
    /// positionally inside the comparator itself (which is what makes this a strict weak
    /// ordering, safe for `Array.sorted`). Replaces the old per-block `notesGroupSortKey`,
    /// which had no notion of continuations and would have scattered them via its
    /// `Int.max` fallback, letting a continuation drift away from its definition on
    /// renormalization.
    /// Four-way strict-weak-ordering key: RUN (most significant -- B4; keeps two separate
    /// Notes runs contiguous instead of fusing), then group (heading < definitions/
    /// continuations < user prose), then label, then within-label index. A struct rather
    /// than a bare tuple so `<` compares component-wise via synthesized `Comparable`.
    private struct NotesSortKey: Comparable {
        let run: Int
        let group: Int
        let label: Int
        let index: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.run, lhs.group, lhs.label, lhs.index) < (rhs.run, rhs.group, rhs.label, rhs.index)
        }
    }

    private static func notesSortKey(_ ownership: NotesBlockOwnership?, run: Int) -> NotesSortKey {
        switch ownership {
        case .heading: return NotesSortKey(run: run, group: -1, label: 0, index: 0)
        case .definition(let label): return NotesSortKey(run: run, group: 0, label: Int(label) ?? Int.max, index: 0)
        case .continuation(let ownerLabel, let index):
            return NotesSortKey(run: run, group: 0, label: Int(ownerLabel) ?? Int.max, index: index)
        // B4 stated behavior change: `.userProse` sorted last within the WHOLE Notes
        // group before this. With `run` now the most significant component, it sorts
        // last WITHIN ITS OWN RUN instead -- prose belonging to run 2 stays inside run
        // 2 rather than being pulled to the tail of run N. Intentional; see T6.
        case .userProse(let index): return NotesSortKey(run: run, group: 1, label: Int.max, index: index)
        case nil: return NotesSortKey(run: run, group: 1, label: Int.max, index: Int.max)
        }
    }

    /// B7: independent guard for the destructive `refs.isEmpty` branch in
    /// `performFootnoteUpdate` (`FootnoteSyncService.swift`), which calls the
    /// mass-deleting `removeNotesBlock`. `refs` there is computed via `extractFootnoteRefs`,
    /// which itself calls `stripNotesSection` first -- so if `stripNotesSection` ever
    /// mis-scopes a Notes run (wrong opening OR wrong extent), `refs` could read empty
    /// while the document still genuinely contains a footnote reference. This function
    /// answers a DIFFERENT, narrower question against the RAW, unstripped document, using
    /// only the plain reference regex `\[\^\d+\](?!:)` -- it must never be implemented in
    /// terms of `stripNotesSection`/`extractFootnoteRefs`, or it stops being independent of
    /// the exact scanner it exists to catch a mistake in.
    nonisolated static func documentContainsFootnoteReference(_ markdown: String) -> Bool {
        let range = NSRange(markdown.startIndex..., in: markdown)
        return footnoteRefPattern.firstMatch(in: markdown, range: range) != nil
    }

    /// B5: an ALLOWLIST, not a denylist. The old version deleted every `isNotes == false`
    /// paragraph that merely LOOKED LIKE a footnote definition -- with no check that a
    /// twin claiming the same label even existed, this is exactly the mechanism that
    /// deleted the user's real, hand-typed footnote text once a `## Notes` heading went
    /// unrecognized and step 6 above inserted a blank twin in its place. Now a candidate
    /// is deleted ONLY on positive evidence of redundancy against a same-labeled
    /// `isNotes == true` twin -- never on the shape of its own text alone.
    ///
    /// - Parameter knownPriorTwins: rows that WERE a candidate's twin a moment ago but no
    ///   longer exist in the DB to be found by this function's own fresh query -- e.g.
    ///   B1's `removeNotesBlock`, which deletes the machine-owned definition rows in the
    ///   SAME write transaction, before calling this sweep (B6). Without this, "no twin by
    ///   construction" would defeat B5's whole body comparison right when it matters most.
    ///   A current (still-in-DB) twin always wins over a `knownPriorTwins` entry for the
    ///   same label, since the live DB state is the more authoritative source when both
    ///   exist.
    ///
    /// R10 (accepted trade-off, stated explicitly): only a blank candidate or an
    /// exact-duplicate-bodied candidate remains deletable here. A true orphan carrying
    /// real, now-unreferenced text is PERMANENTLY left in the document as literal
    /// `[^N]: some text` -- nothing auto-deletes it, ever. Occasional manual tidying
    /// replaces silent data loss.
    static func deleteOrphanedFootnoteDefinitions(
        db: Database, projectId: String, knownPriorTwins: [Block] = []
    ) throws {
        let candidates = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.isNotes == false)
            .filter(Block.Columns.blockType == BlockType.paragraph.rawValue)
            .fetchAll(db)
        DebugLog.log(.footnotes, "[FootnoteSyncService] deleteOrphanedFootnoteDefinitions: entry " +
            "projectId=\(projectId) candidates=\(candidates.count) knownPriorTwins=\(knownPriorTwins.count)")

        // Twin lookup: label -> the isNotes==true row that justifies (or refuses) deleting
        // a same-labeled candidate. Current DB state first (most authoritative), then
        // `knownPriorTwins` fills in any label a caller already deleted in this same
        // transaction (B6) and that a fresh query can therefore never find.
        var twinsByLabel: [String: Block] = [:]
        let currentNotesDefs = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.isNotes == true)
            .filter(Block.Columns.isBibliography == false)
            .filter(Block.Columns.blockType == BlockType.paragraph.rawValue)
            .fetchAll(db)
        for block in currentNotesDefs {
            guard let parsed = parseNotesLabel(from: block.markdownFragment) else { continue }
            twinsByLabel[parsed.label] = block
        }
        for block in knownPriorTwins {
            guard let parsed = parseNotesLabel(from: block.markdownFragment) else { continue }
            if twinsByLabel[parsed.label] == nil {
                twinsByLabel[parsed.label] = block
            }
        }

        var deletedCount = 0
        for block in candidates {
            let frag = block.markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines)
            // 1. Label unparseable -- never delete.
            guard let parsedCandidate = parseNotesLabel(from: frag) else {
                DebugLog.log(.footnotes, "[FootnoteSyncService] deleteOrphanedFootnoteDefinitions: skip " +
                    "id=\(block.id) reason=unparseable-label fragment=\"\(frag.prefix(60))\"")
                continue
            }
            // 2. No same-label twin -- never delete.
            guard let twin = twinsByLabel[parsedCandidate.label] else {
                DebugLog.log(.footnotes, "[FootnoteSyncService] deleteOrphanedFootnoteDefinitions: skip " +
                    "id=\(block.id) label=\(parsedCandidate.label) reason=no-twin-found " +
                    "fragment=\"\(frag.prefix(60))\"")
                continue
            }
            // 3. Body comparison -- the exhaustive four-way rule.
            let candidateBody = parsedCandidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let twinBody = (parseNotesLabel(from: twin.markdownFragment)?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let shouldDelete: Bool
            let reason: String
            if candidateBody.isEmpty {
                shouldDelete = true
                reason = "candidate-body-empty"
            } else if twinBody.isEmpty {
                // The exact case step 6 manufactures: a real-texted candidate must never
                // lose to a blank twin the reconciliation pass just inserted.
                shouldDelete = false
                reason = "twin-body-empty-candidate-has-real-text"
            } else if candidateBody == twinBody {
                shouldDelete = true
                reason = "bodies-identical"
            } else {
                shouldDelete = false
                reason = "bodies-differ-non-blank"
            }

            if shouldDelete {
                // 4. B9: log the full fragment, and the justifying twin, before deleting.
                DebugLog.log(.footnotes, "[FootnoteSyncService] deleteOrphanedFootnoteDefinitions: DELETING " +
                    "id=\(block.id) label=\(parsedCandidate.label) reason=\(reason) fragment=\"\(frag)\" " +
                    "twinId=\(twin.id) twinFragment=\"\(twin.markdownFragment)\"")
                try Block.deleteOne(db, key: block.id)
                deletedCount += 1
            } else {
                DebugLog.log(.footnotes, "[FootnoteSyncService] deleteOrphanedFootnoteDefinitions: skip " +
                    "id=\(block.id) label=\(parsedCandidate.label) reason=\(reason) " +
                    "fragment=\"\(frag.prefix(60))\" twinId=\(twin.id)")
            }
        }
        DebugLog.log(.footnotes, "[FootnoteSyncService] deleteOrphanedFootnoteDefinitions: done " +
            "deleted=\(deletedCount) of candidates=\(candidates.count)")
    }
}
