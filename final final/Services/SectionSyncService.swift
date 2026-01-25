//
//  SectionSyncService.swift
//  final final
//

import Foundation
import Combine

/// Service to sync editor content with sections database
/// Uses Option B: Re-parse on save with debouncing
@MainActor
@Observable
class SectionSyncService {
    private var cancellables = Set<AnyCancellable>()
    private var debounceTask: Task<Void, Never>?
    private let debounceInterval: Duration = .milliseconds(500)

    private var projectDatabase: ProjectDatabase?
    private var projectId: String?

    // MARK: - Public API

    /// Configure the service for a specific project
    func configure(database: ProjectDatabase, projectId: String) {
        self.projectDatabase = database
        self.projectId = projectId
    }

    /// Called when editor content changes
    /// Debounces and triggers sync after delay
    func contentChanged(_ markdown: String) {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }
            await syncSections(from: markdown)
        }
    }

    /// Force immediate sync (e.g., before app quit)
    func syncNow(_ markdown: String) async {
        debounceTask?.cancel()
        await syncSections(from: markdown)
    }

    /// Load sections from database
    func loadSections() async -> [Section] {
        guard let db = projectDatabase, let pid = projectId else { return [] }

        do {
            return try db.fetchSections(projectId: pid)
        } catch {
            print("[SectionSyncService] Failed to load sections: \(error)")
            return []
        }
    }

    // MARK: - Private Methods

    private func syncSections(from markdown: String) async {
        guard let db = projectDatabase, let pid = projectId else {
            print("[SectionSyncService] Not configured")
            return
        }

        // Parse markdown into section structure
        let parsedSections = parseMarkdownToSections(markdown, projectId: pid)

        // Load existing sections for matching
        let existingSections: [Section]
        do {
            existingSections = try db.fetchSections(projectId: pid)
        } catch {
            print("[SectionSyncService] Failed to fetch existing sections: \(error)")
            return
        }

        // Match and merge sections
        let mergedSections = mergeSections(parsed: parsedSections, existing: existingSections)

        // Save to database
        do {
            try db.replaceSections(mergedSections, for: pid)
            print("[SectionSyncService] Synced \(mergedSections.count) sections")
        } catch {
            print("[SectionSyncService] Failed to save sections: \(error)")
        }
    }

    /// Parse markdown content into sections
    private func parseMarkdownToSections(_ markdown: String, projectId: String) -> [Section] {
        var sections: [Section] = []
        var currentOffset = 0
        var inCodeBlock = false

        // Track section boundaries
        struct SectionBoundary {
            let startOffset: Int
            let level: Int
            let title: String
            let isPseudo: Bool
        }

        var boundaries: [SectionBoundary] = []

        // First pass: find all headers and pseudo-sections
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let lineStr = String(line)
            let trimmed = lineStr.trimmingCharacters(in: .whitespaces)

            // Track code blocks
            if trimmed.hasPrefix("```") {
                inCodeBlock = !inCodeBlock
            }

            if !inCodeBlock {
                // Check for pseudo-section marker
                if trimmed == "<!-- ::break:: -->" {
                    // Next non-empty line is the pseudo-section title
                    boundaries.append(SectionBoundary(
                        startOffset: currentOffset,
                        level: 0,
                        title: "§ Section Break",
                        isPseudo: true
                    ))
                }
                // Check for header
                else if let header = parseHeader(trimmed) {
                    boundaries.append(SectionBoundary(
                        startOffset: currentOffset,
                        level: header.level,
                        title: header.title,
                        isPseudo: false
                    ))
                }
            }

            currentOffset += lineStr.count + 1 // +1 for newline
        }

        guard !boundaries.isEmpty else { return [] }

        // Second pass: calculate content for each section
        let contentLength = markdown.count

        for (index, boundary) in boundaries.enumerated() {
            let endOffset: Int
            if index < boundaries.count - 1 {
                endOffset = boundaries[index + 1].startOffset
            } else {
                endOffset = contentLength
            }

            // Extract markdown content for this section
            let startIdx = markdown.index(markdown.startIndex, offsetBy: min(boundary.startOffset, markdown.count))
            let endIdx = markdown.index(markdown.startIndex, offsetBy: min(endOffset, markdown.count))
            let sectionMarkdown = String(markdown[startIdx..<endIdx])

            let wordCount = countWords(in: sectionMarkdown)

            sections.append(Section(
                projectId: projectId,
                parentId: nil, // Will be assigned below
                sortOrder: index,
                headerLevel: boundary.level,
                title: boundary.title,
                markdownContent: sectionMarkdown,
                wordCount: wordCount
            ))
        }

        // Assign parent IDs based on header levels
        assignParents(&sections)

        return sections
    }

    private struct ParsedHeader {
        let level: Int
        let title: String
    }

    private func parseHeader(_ line: String) -> ParsedHeader? {
        guard line.hasPrefix("#") else { return nil }

        var level = 0
        var idx = line.startIndex

        while idx < line.endIndex && line[idx] == "#" && level < 6 {
            level += 1
            idx = line.index(after: idx)
        }

        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }

        let titleStart = line.index(after: idx)
        let title = String(line[titleStart...]).trimmingCharacters(in: .whitespaces)

        guard !title.isEmpty else { return nil }

        return ParsedHeader(level: level, title: title)
    }

    private func countWords(in text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    private func assignParents(_ sections: inout [Section]) {
        var parentStack: [(level: Int, id: String?)] = [(0, nil)]

        for i in sections.indices {
            let currentLevel = sections[i].headerLevel == 0 ? 1 : sections[i].headerLevel

            // Pop until we find a parent with lower level
            while parentStack.count > 1 && parentStack.last!.level >= currentLevel {
                parentStack.removeLast()
            }

            sections[i].parentId = parentStack.last?.id
            parentStack.append((currentLevel, sections[i].id))
        }
    }

    /// Merge parsed sections with existing sections to preserve metadata
    private func mergeSections(parsed: [Section], existing: [Section]) -> [Section] {
        // Create lookup by title+level for matching
        var existingLookup: [String: Section] = [:]
        for section in existing {
            let key = "\(section.headerLevel):\(section.title)"
            existingLookup[key] = section
        }

        return parsed.map { parsedSection in
            let key = "\(parsedSection.headerLevel):\(parsedSection.title)"

            if let existingSection = existingLookup[key] {
                // Preserve metadata from existing section
                var merged = parsedSection
                merged.id = existingSection.id
                merged.status = existingSection.status
                merged.tags = existingSection.tags
                merged.wordGoal = existingSection.wordGoal
                merged.createdAt = existingSection.createdAt
                return merged
            }

            return parsedSection
        }
    }
}
