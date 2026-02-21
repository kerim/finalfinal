//
//  FootnoteSyncService.swift
//  final final
//
//  Service for managing the # Notes section based on footnote references in the document.
//  Creates/removes the section and pushes definition texts to the editor for popup display.
//  Modeled on BibliographySyncService.swift.
//

import Foundation
import GRDB

/// State machine for footnote sync to prevent race conditions
enum FootnoteSyncState: Sendable {
    case idle
    case syncing
    case userEditPending
}

@MainActor
@Observable
final class FootnoteSyncService {
    // MARK: - State

    /// Current sync state
    private(set) var state: FootnoteSyncState = .idle

    /// Last known footnote ref labels (to prevent unnecessary updates)
    private var lastKnownRefs: [String] = []

    /// Hash of last renumbered content (feedback loop breaker)
    private var lastRenumberedHash: Int = 0

    /// Debounce timer for footnote updates
    private var debounceTask: Task<Void, Never>?

    /// Debounce interval (3 seconds — longer than bibliography to let Notes edits settle)
    private let debounceInterval: TimeInterval = 3.0

    // MARK: - Dependencies

    weak var database: ProjectDatabase?

    // MARK: - Static Helpers

    /// Pre-compiled regex for footnote reference extraction
    /// Matches [^N] where N is one or more digits, with negative lookahead for definition [^N]:
    private static let footnoteRefPattern: NSRegularExpression = {
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
    private static let footnoteDefPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(
                pattern: #"^\[\^(\d+)\]:\s*(.*)"#,
                options: [.anchorsMatchLines]
            )
        } catch {
            fatalError("Invalid footnote def regex pattern: \(error)")
        }
    }()

    /// Extract ordered unique footnote reference labels from markdown content
    /// Excludes the #Notes section content (definitions should not be counted as references)
    static func extractFootnoteRefs(from markdown: String) -> [String] {
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
    static func extractFootnoteDefinitions(from notesContent: String) -> [String: String] {
        var definitions: [String: String] = [:]
        let lines = notesContent.components(separatedBy: "\n")

        var currentLabel: String?
        var currentText: [String] = []

        for line in lines {
            // Skip the heading line
            if line.hasPrefix("# ") { continue }

            let range = NSRange(line.startIndex..., in: line)
            if let match = footnoteDefPattern.firstMatch(in: line, range: range),
               let labelRange = Range(match.range(at: 1), in: line),
               let textRange = Range(match.range(at: 2), in: line) {
                // Save previous definition if any
                if let label = currentLabel {
                    definitions[label] = currentText.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                currentLabel = String(line[labelRange])
                currentText = [String(line[textRange])]
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
    private static func stripNotesSection(from markdown: String) -> String {
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

    // MARK: - Public Methods

    /// Configure the service with a database
    func configure(database: ProjectDatabase, projectId: String) {
        self.database = database
    }

    /// Called from onChange(of: editorState.content) — checks if footnotes need updating
    func checkAndUpdateFootnotes(
        footnoteRefs: [String],
        projectId: String,
        fullContent: String
    ) {
        guard state == .idle else { return }

        // Check if refs have changed
        guard footnoteRefs != lastKnownRefs else {
            // Even if refs haven't changed, we should still push definitions
            // for tooltip display (definitions may have been edited in #Notes)
            pushDefinitionsToEditor(fullContent: fullContent)
            return
        }

        // Debounce the update
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard !Task.isCancelled else { return }

            try? await Task.sleep(nanoseconds: UInt64(3_000_000_000))

            guard !Task.isCancelled else { return }
            await self?.performFootnoteUpdate(refs: footnoteRefs, projectId: projectId, fullContent: fullContent)
        }
    }

    /// Push footnote definitions to the editor for tooltip display
    func pushDefinitionsToEditor(fullContent: String) {
        // Find the #Notes section content
        let lines = fullContent.components(separatedBy: "\n")
        var notesContent = ""
        var inNotes = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased() == "# notes" {
                inNotes = true
                notesContent += line + "\n"
                continue
            }
            if inNotes && trimmed.hasPrefix("# ") && trimmed.lowercased() != "# notes" {
                break // Hit the next H1 heading
            }
            if inNotes {
                notesContent += line + "\n"
            }
        }

        guard !notesContent.isEmpty else { return }

        let definitions = Self.extractFootnoteDefinitions(from: notesContent)
        guard !definitions.isEmpty else { return }

        // Push to editor via notification (editor will call setFootnoteDefinitions)
        NotificationCenter.default.post(
            name: .footnoteDefinitionsReady,
            object: nil,
            userInfo: ["definitions": definitions]
        )
    }

    /// Reset service state (call when switching projects)
    func reset() {
        debounceTask?.cancel()
        debounceTask = nil
        lastKnownRefs = []
        lastRenumberedHash = 0
        state = .idle
    }

    // MARK: - Private Methods

    private func performFootnoteUpdate(refs: [String], projectId: String, fullContent: String) async {
        guard let database else { return }

        state = .syncing
        defer { state = .idle }

        // Remove #Notes section when no footnotes
        guard !refs.isEmpty else {
            lastKnownRefs = []
            await removeNotesBlock(projectId: projectId)
            return
        }

        // Check if renumbering is needed: labels should be sequential 1..N
        let renumberMapping = computeRenumberMapping(refs: refs)

        // Determine the effective refs (post-renumbering)
        let effectiveRefs: [String]
        if !renumberMapping.isEmpty {
            // Apply mapping to get new labels in document order
            effectiveRefs = refs.map { renumberMapping[$0] ?? $0 }
        } else {
            effectiveRefs = refs
        }

        // Update lastKnownRefs to post-renumbered values to prevent re-trigger
        lastKnownRefs = effectiveRefs

        // Check if refs actually changed (definitions are read from DB, not content)
        let contentHash = effectiveRefs.joined(separator: ",").hashValue
        guard contentHash != lastRenumberedHash else { return }
        lastRenumberedHash = contentHash

        // Post renumbering to web editor BEFORE updating DB
        // (editor content change will trigger another checkAndUpdate which lastKnownRefs catches)
        if !renumberMapping.isEmpty {
            NotificationCenter.default.post(
                name: .renumberFootnotes,
                object: nil,
                userInfo: ["mapping": renumberMapping]
            )
        }

        // Create individual notes blocks (1 heading + N definition paragraphs)
        do {
            try updateNotesBlock(
                effectiveRefs: effectiveRefs,
                originalRefs: refs,
                projectId: projectId,
                database: database
            )
            NotificationCenter.default.post(name: .notesSectionChanged, object: nil)
        } catch {
            print("[FootnoteSyncService] Failed to update notes section: \(error)")
        }

        // Push definitions to editor for tooltip display
        pushDefinitionsToEditor(fullContent: fullContent)
    }

    private func updateNotesBlock(
        effectiveRefs: [String],
        originalRefs: [String],
        projectId: String,
        database: ProjectDatabase
    ) throws {
        try database.write { db in
            // Read existing definition text from DB blocks BEFORE deleting
            let existingDefBlocks = try Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.isNotes == true)
                .filter(Block.Columns.blockType == BlockType.paragraph.rawValue)
                .fetchAll(db)

            var dbDefs: [String: String] = [:]
            for block in existingDefBlocks {
                let frag = block.markdownFragment
                let range = NSRange(frag.startIndex..., in: frag)
                if let match = Self.footnoteDefPattern.firstMatch(in: frag, range: range),
                   let labelRange = Range(match.range(at: 1), in: frag),
                   let textRange = Range(match.range(at: 2), in: frag) {
                    dbDefs[String(frag[labelRange])] = String(frag[textRange])
                }
            }

            // Delete ALL existing notes blocks (handles duplicates)
            try Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.isNotes == true)
                .deleteAll(db)

            // Clean up orphaned footnote definitions from before isNotes propagation fix
            try Self.deleteOrphanedFootnoteDefinitions(db: db, projectId: projectId)

            #if DEBUG
            let deletedCount = db.changesCount
            let orphanCount = try Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.isNotes == false)
                .fetchAll(db)
                .filter { $0.markdownFragment.range(of: #"\[\^\d+\]:"#, options: .regularExpression) != nil }
                .count
            print("[DIAG-FN] updateNotesBlock: deleted \(deletedCount) isNotes blocks, \(orphanCount) orphaned def blocks remain")
            print("[DIAG-FN] updateNotesBlock: creating \(effectiveRefs.count + 1) individual blocks (1 heading + \(effectiveRefs.count) defs)")
            #endif

            // Get max sort order from non-bibliography blocks
            // Notes should appear after user content but before bibliography
            let maxNonBibSortOrder = try Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.isBibliography == false)
                .order(Block.Columns.sortOrder.desc)
                .fetchOne(db)?.sortOrder ?? 0

            let baseSortOrder = maxNonBibSortOrder + 0.5

            // 1. Insert heading block
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
            try headingBlock.insert(db)

            // 2. Insert one block per definition (1 DB block = 1 editor node)
            for (index, ref) in effectiveRefs.enumerated() {
                // Look up definition by the original (pre-renumber) label
                let defText = dbDefs[originalRefs[index]] ?? ""
                var defBlock = Block(
                    projectId: projectId,
                    sortOrder: baseSortOrder + Double(index + 1),
                    blockType: .paragraph,
                    textContent: defText,
                    markdownFragment: "[^\(ref)]: \(defText)",
                    isNotes: true
                )
                defBlock.recalculateWordCount()
                try defBlock.insert(db)
            }

            // Ensure bibliography stays after notes by normalizing sort orders
            let allBlocks = try Block
                .filter(Block.Columns.projectId == projectId)
                .order(Block.Columns.sortOrder)
                .fetchAll(db)

            // Re-sort: normal content first, then notes, then bibliography
            let sorted = allBlocks.sorted { a, b in
                let aGroup = a.isBibliography ? 2 : (a.isNotes ? 1 : 0)
                let bGroup = b.isBibliography ? 2 : (b.isNotes ? 1 : 0)
                if aGroup != bGroup { return aGroup < bGroup }
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
    }

    /// Delete orphaned footnote definition blocks (isNotes=false but contain [^N]: text)
    /// Cleans up corruption from before Fix 1 marked all Notes children with isNotes=true
    static func deleteOrphanedFootnoteDefinitions(db: Database, projectId: String) throws {
        let orphanedDefPattern = try! NSRegularExpression(pattern: #"^\[\^\d+\]:\s*"#)
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

    /// Compute renumbering mapping if labels are not sequential 1..N
    /// Returns empty dictionary if no renumbering needed
    private func computeRenumberMapping(refs: [String]) -> [String: String] {
        // Check if already sequential 1..N
        let isSequential = refs.enumerated().allSatisfy { index, label in
            label == String(index + 1)
        }
        guard !isSequential else { return [:] }

        // Build old→new mapping based on document order (first appearance)
        var mapping: [String: String] = [:]
        for (index, oldLabel) in refs.enumerated() {
            let newLabel = String(index + 1)
            if oldLabel != newLabel {
                mapping[oldLabel] = newLabel
            }
        }
        return mapping
    }

    /// Remove notes blocks when all footnotes are deleted
    private func removeNotesBlock(projectId: String) async {
        guard let database else { return }

        do {
            try database.write { db in
                try Block
                    .filter(Block.Columns.projectId == projectId)
                    .filter(Block.Columns.isNotes == true)
                    .deleteAll(db)

                // Clean up orphaned footnote definitions from before isNotes propagation fix
                try Self.deleteOrphanedFootnoteDefinitions(db: db, projectId: projectId)
            }
            NotificationCenter.default.post(name: .notesSectionChanged, object: nil)
            lastRenumberedHash = 0
            lastKnownRefs = []
        } catch {
            print("[FootnoteSyncService] Error removing notes section: \(error)")
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when footnote definitions are ready to be pushed to the editor
    static let footnoteDefinitionsReady = Notification.Name("footnoteDefinitionsReady")
}
