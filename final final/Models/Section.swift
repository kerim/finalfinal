//
//  Section.swift
//  final final
//

import Foundation
import GRDB

/// Goal type for word count targets
enum GoalType: String, Codable, CaseIterable, Sendable {
    case min     // Red below, green at/above (minimum requirement)
    case max     // Green at/below, red above (maximum limit)
    case approx  // Red outside ±5%, green within (approximate target)

    var displaySymbol: String {
        switch self {
        case .min: return "≥"
        case .max: return "≤"
        case .approx: return "~"
        }
    }

    var displayName: String {
        switch self {
        case .min: return "Minimum"
        case .max: return "Maximum"
        case .approx: return "Approx"
        }
    }
}

/// Goal status indicating whether the current word count meets the goal
enum GoalStatus {
    case met      // Goal criteria satisfied (green)
    case warning  // Close to goal but not met (orange)
    case notMet   // Goal criteria not satisfied (red)
    case noGoal   // No goal set (neutral)

    /// Calculate goal status based on word count, goal, goal type, and thresholds
    static func calculate(wordCount: Int, goal: Int?, goalType: GoalType,
                          thresholds: GoalThresholds = .defaults) -> GoalStatus {
        guard let goal = goal, goal > 0 else { return .noGoal }
        let ratio = Double(wordCount) / Double(goal) * 100

        switch goalType {
        case .min:
            if ratio >= 100 { return .met }
            if ratio >= thresholds.minWarningPercent { return .warning }
            return .notMet
        case .max:
            if ratio <= 100 { return .met }
            if ratio <= thresholds.maxWarningPercent { return .warning }
            return .notMet
        case .approx:
            let deviation = abs(ratio - 100)
            if deviation <= thresholds.approxGreenPercent { return .met }
            if deviation <= thresholds.approxOrangePercent { return .warning }
            return .notMet
        }
    }
}

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
    var goalType: GoalType
    var aggregateGoal: Int?
    var aggregateGoalType: GoalType
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
        goalType: GoalType = .approx,
        aggregateGoal: Int? = nil,
        aggregateGoalType: GoalType = .approx,
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
        self.goalType = goalType
        self.aggregateGoal = aggregateGoal
        self.aggregateGoalType = aggregateGoalType
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
        case goalType
        case aggregateGoal
        case aggregateGoalType
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
        case goalType
        case aggregateGoal
        case aggregateGoalType
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
        goalType = try container.decode(GoalType.self, forKey: .goalType)
        aggregateGoal = try container.decodeIfPresent(Int.self, forKey: .aggregateGoal)
        aggregateGoalType = try container.decode(GoalType.self, forKey: .aggregateGoalType)
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
        try container.encode(goalType, forKey: .goalType)
        try container.encodeIfPresent(aggregateGoal, forKey: .aggregateGoal)
        try container.encode(aggregateGoalType, forKey: .aggregateGoalType)
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

    /// Calculate word count from markdown content (excludes markdown syntax and annotations)
    mutating func recalculateWordCount() {
        wordCount = MarkdownUtils.wordCount(for: markdownContent)
    }

    /// Progress toward word goal (0.0 to 1.0+)
    var goalProgress: Double? {
        guard let goal = wordGoal, goal > 0 else { return nil }
        return Double(wordCount) / Double(goal)
    }

    /// Goal status based on current word count, goal, and goal type
    var goalStatus: GoalStatus {
        GoalStatus.calculate(wordCount: wordCount, goal: wordGoal, goalType: goalType)
    }

    /// Display string for word count (number only, no goal)
    var wordCountDisplay: String {
        "\(wordCount)"
    }
}
