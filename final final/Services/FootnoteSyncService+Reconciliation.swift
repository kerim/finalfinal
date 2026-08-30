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
    static func reconcileNotesBlocks(
        db: Database,
        projectId: String,
        targetRefs: [String],
        renameMap: [String: String] = [:],
        definitionOverrides: [String: String] = [:]
    ) throws {
        // 1. Fetch current Notes paragraph blocks fresh; snapshot label -> Block ONCE
        //    before any writes. Defensively de-duplicate (keep most-recently-updated) in
        //    case pre-fix corruption left two rows claiming one label.
        let existingDefBlocks = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.isNotes == true)
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
        // Rows not kept as the canonical block for their label are extra corruption from
        // before this fix (two rows claiming one label) — delete them outright.
        let keptIds = Set(snapshot.values.map(\.id))
        for block in existingDefBlocks where !keptIds.contains(block.id) {
            try Block.deleteOne(db, key: block.id)
        }

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

        // 4. Delete labels no longer wanted.
        for label in toDelete {
            if let block = snapshot[label] {
                try Block.deleteOne(db, key: block.id)
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

        let sorted = allBlocks.sorted { a, b in
            let aGroup = a.isBibliography ? 2 : (a.isNotes ? 1 : 0)
            let bGroup = b.isBibliography ? 2 : (b.isNotes ? 1 : 0)
            if aGroup != bGroup { return aGroup < bGroup }
            if aGroup == 1 {
                return notesGroupSortKey(a) < notesGroupSortKey(b)
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

    /// Sort key for a block within the Notes group: heading always first, then
    /// definition paragraphs ordered by their parsed numeric label (not sortOrder — see
    /// `reconcileNotesBlocks`).
    private static func notesGroupSortKey(_ block: Block) -> Int {
        guard block.blockType != .heading else { return -1 }
        guard let parsed = parseNotesLabel(from: block.markdownFragment),
              let labelInt = Int(parsed.label) else {
            return Int.max
        }
        return labelInt
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
