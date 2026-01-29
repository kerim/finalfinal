//
//  Section.swift
//  final final
//

import Foundation
import GRDB

/// Section status for workflow tracking
enum SectionStatus: String, Codable, CaseIterable, Sendable {
    case next       // Default status - first in cycle
    case writing
    case waiting
    case review
    case final_

    var displayName: String {
        switch self {
        case .next: return "Next"
        case .writing: return "Writing"
        case .waiting: return "Waiting"
        case .review: return "Review"
        case .final_: return "Final"
        }
    }

    /// Returns the next status in the cycle: next → writing → waiting → review → final → next
    var nextStatus: SectionStatus {
        switch self {
        case .next: return .writing
        case .writing: return .waiting
        case .waiting: return .review
        case .review: return .final_
        case .final_: return .next
        }
    }

    // Custom coding to handle "final" as reserved word
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case "final": self = .final_
        default: self = SectionStatus(rawValue: rawValue) ?? .next
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .final_: try container.encode("final")
        default: try container.encode(rawValue)
        }
    }
}

/// A section represents a block of content with its own metadata.
/// Sections can be hierarchical (parent/child relationships based on header levels).
struct Section: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var projectId: String
    var parentId: String?
    var sortOrder: Int
    var headerLevel: Int  // 1-6 for headers (pseudo-sections inherit level from preceding section)
    var isPseudoSection: Bool  // True for break markers (<!-- ::break:: -->)
    var isBibliography: Bool  // True for auto-generated bibliography section
    var title: String
    var markdownContent: String
    var status: SectionStatus
    var tags: [String]
    var wordGoal: Int?
    var wordCount: Int
    var startOffset: Int  // Character offset where section begins in document
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "section"

    init(
        id: String = UUID().uuidString,
        projectId: String,
        parentId: String? = nil,
        sortOrder: Int,
        headerLevel: Int,
        isPseudoSection: Bool = false,
        isBibliography: Bool = false,
        title: String,
        markdownContent: String = "",
        status: SectionStatus = .next,
        tags: [String] = [],
        wordGoal: Int? = nil,
        wordCount: Int = 0,
        startOffset: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectId = projectId
        self.parentId = parentId
        self.sortOrder = sortOrder
        self.headerLevel = headerLevel
        self.isPseudoSection = isPseudoSection
        self.isBibliography = isBibliography
        self.title = title
        self.markdownContent = markdownContent
        self.status = status
        self.tags = tags
        self.wordGoal = wordGoal
        self.wordCount = wordCount
        self.startOffset = startOffset
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Database Columns

    enum Columns: String, ColumnExpression {
        case id
        case projectId
        case parentId
        case sortOrder
        case headerLevel
        case isPseudoSection
        case isBibliography
        case title
        case markdownContent
        case status
        case tags
        case wordGoal
        case wordCount
        case startOffset
        case createdAt
        case updatedAt
    }

    // MARK: - Custom Encoding for Tags (JSON array)

    private enum CodingKeys: String, CodingKey {
        case id
        case projectId
        case parentId
        case sortOrder
        case headerLevel
        case isPseudoSection
        case isBibliography
        case title
        case markdownContent
        case status
        case tags
        case wordGoal
        case wordCount
        case startOffset
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectId = try container.decode(String.self, forKey: .projectId)
        parentId = try container.decodeIfPresent(String.self, forKey: .parentId)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        headerLevel = try container.decode(Int.self, forKey: .headerLevel)
        isPseudoSection = try container.decode(Bool.self, forKey: .isPseudoSection)
        isBibliography = try container.decode(Bool.self, forKey: .isBibliography)
        title = try container.decode(String.self, forKey: .title)
        markdownContent = try container.decode(String.self, forKey: .markdownContent)
        status = try container.decode(SectionStatus.self, forKey: .status)
        wordGoal = try container.decodeIfPresent(Int.self, forKey: .wordGoal)
        wordCount = try container.decode(Int.self, forKey: .wordCount)
        startOffset = try container.decode(Int.self, forKey: .startOffset)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        // Tags are stored as JSON string
        let tagsString = try container.decode(String.self, forKey: .tags)
        if let data = tagsString.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            tags = decoded
        } else {
            tags = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(projectId, forKey: .projectId)
        try container.encodeIfPresent(parentId, forKey: .parentId)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encode(headerLevel, forKey: .headerLevel)
        try container.encode(isPseudoSection, forKey: .isPseudoSection)
        try container.encode(isBibliography, forKey: .isBibliography)
        try container.encode(title, forKey: .title)
        try container.encode(markdownContent, forKey: .markdownContent)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(wordGoal, forKey: .wordGoal)
        try container.encode(wordCount, forKey: .wordCount)
        try container.encode(startOffset, forKey: .startOffset)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)

        // Tags encoded as JSON string
        let tagsData = try JSONEncoder().encode(tags)
        let tagsString = String(data: tagsData, encoding: .utf8) ?? "[]"
        try container.encode(tagsString, forKey: .tags)
    }

    // MARK: - Computed Properties

    /// Calculate word count from markdown content (excludes markdown syntax)
    mutating func recalculateWordCount() {
        wordCount = MarkdownUtils.wordCount(for: markdownContent)
    }

    /// Progress toward word goal (0.0 to 1.0+)
    var goalProgress: Double? {
        guard let goal = wordGoal, goal > 0 else { return nil }
        return Double(wordCount) / Double(goal)
    }

    /// Display string for word count (e.g., "450" or "450/500")
    var wordCountDisplay: String {
        if let goal = wordGoal {
            return "\(wordCount)/\(goal)"
        }
        return "\(wordCount)"
    }
}
