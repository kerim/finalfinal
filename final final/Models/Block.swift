//
//  Block.swift
//  final final
//
//  Block-based content model for stable annotation anchoring.
//  Each block represents a structural element (paragraph, heading, list item, etc.)
//  with a unique ID that survives edits elsewhere in the document.
//

import Foundation
import GRDB

/// Block types that can exist in a document
enum BlockType: String, Codable, CaseIterable, Sendable {
    case paragraph
    case heading
    case bulletList = "bullet_list"
    case orderedList = "ordered_list"
    case listItem = "list_item"
    case blockquote
    case codeBlock = "code_block"
    case horizontalRule = "horizontal_rule"
    case sectionBreak = "section_break"
    case bibliography
    case table
    case image

    var displayName: String {
        switch self {
        case .paragraph: return "Paragraph"
        case .heading: return "Heading"
        case .bulletList: return "Bullet List"
        case .orderedList: return "Ordered List"
        case .listItem: return "List Item"
        case .blockquote: return "Blockquote"
        case .codeBlock: return "Code Block"
        case .horizontalRule: return "Horizontal Rule"
        case .sectionBreak: return "Section Break"
        case .bibliography: return "Bibliography"
        case .table: return "Table"
        case .image: return "Image"
        }
    }

    /// Whether this block type can have section metadata (status, tags, goals)
    var canHaveSectionMetadata: Bool {
        switch self {
        case .heading, .sectionBreak:
            return true
        default:
            return false
        }
    }
}

/// A block represents a structural element in the document.
/// Blocks have stable IDs that annotations can reference.
struct Block: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var projectId: String
    var parentId: String?           // For nested blocks (list items in lists)
    var sortOrder: Double           // Fractional for easy insertion between blocks
    var blockType: BlockType
    var textContent: String         // Plain text content (for search, word count)
    var markdownFragment: String    // Original markdown for this block
    var headingLevel: Int?          // 1-6 for headings, nil for other types

    // Section metadata (heading blocks and section breaks only)
    var status: SectionStatus?
    var tags: [String]?
    var wordGoal: Int?
    var goalType: GoalType
    var wordCount: Int

    // Special flags
    var isBibliography: Bool
    var isPseudoSection: Bool       // Section break markers

    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "block"

    init(
        id: String = UUID().uuidString,
        projectId: String,
        parentId: String? = nil,
        sortOrder: Double,
        blockType: BlockType,
        textContent: String = "",
        markdownFragment: String = "",
        headingLevel: Int? = nil,
        status: SectionStatus? = nil,
        tags: [String]? = nil,
        wordGoal: Int? = nil,
        goalType: GoalType = .approx,
        wordCount: Int = 0,
        isBibliography: Bool = false,
        isPseudoSection: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectId = projectId
        self.parentId = parentId
        self.sortOrder = sortOrder
        self.blockType = blockType
        self.textContent = textContent
        self.markdownFragment = markdownFragment
        self.headingLevel = headingLevel
        self.status = status
        self.tags = tags
        self.wordGoal = wordGoal
        self.goalType = goalType
        self.wordCount = wordCount
        self.isBibliography = isBibliography
        self.isPseudoSection = isPseudoSection
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Database Columns

    enum Columns: String, ColumnExpression {
        case id
        case projectId
        case parentId
        case sortOrder
        case blockType
        case textContent
        case markdownFragment
        case headingLevel
        case status
        case tags
        case wordGoal
        case goalType
        case wordCount
        case isBibliography
        case isPseudoSection
        case createdAt
        case updatedAt
    }

    // MARK: - Custom Encoding for Tags (JSON array)

    private enum CodingKeys: String, CodingKey {
        case id
        case projectId
        case parentId
        case sortOrder
        case blockType
        case textContent
        case markdownFragment
        case headingLevel
        case status
        case tags
        case wordGoal
        case goalType
        case wordCount
        case isBibliography
        case isPseudoSection
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectId = try container.decode(String.self, forKey: .projectId)
        parentId = try container.decodeIfPresent(String.self, forKey: .parentId)
        sortOrder = try container.decode(Double.self, forKey: .sortOrder)

        // blockType stored as raw string
        let blockTypeString = try container.decode(String.self, forKey: .blockType)
        blockType = BlockType(rawValue: blockTypeString) ?? .paragraph

        textContent = try container.decode(String.self, forKey: .textContent)
        markdownFragment = try container.decode(String.self, forKey: .markdownFragment)
        headingLevel = try container.decodeIfPresent(Int.self, forKey: .headingLevel)

        // status stored as raw string
        if let statusString = try container.decodeIfPresent(String.self, forKey: .status) {
            // Handle "final" as reserved word
            if statusString == "final" {
                status = .final_
            } else {
                status = SectionStatus(rawValue: statusString)
            }
        } else {
            status = nil
        }

        wordGoal = try container.decodeIfPresent(Int.self, forKey: .wordGoal)
        if let goalTypeString = try container.decodeIfPresent(String.self, forKey: .goalType) {
            goalType = GoalType(rawValue: goalTypeString) ?? .approx
        } else {
            goalType = .approx
        }
        wordCount = try container.decode(Int.self, forKey: .wordCount)
        isBibliography = try container.decode(Bool.self, forKey: .isBibliography)
        isPseudoSection = try container.decode(Bool.self, forKey: .isPseudoSection)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        // Tags are stored as JSON string
        if let tagsString = try container.decodeIfPresent(String.self, forKey: .tags),
           let data = tagsString.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            tags = decoded
        } else {
            tags = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(projectId, forKey: .projectId)
        try container.encodeIfPresent(parentId, forKey: .parentId)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encode(blockType.rawValue, forKey: .blockType)
        try container.encode(textContent, forKey: .textContent)
        try container.encode(markdownFragment, forKey: .markdownFragment)
        try container.encodeIfPresent(headingLevel, forKey: .headingLevel)

        // Encode status, handling "final" reserved word
        if let status = status {
            let statusString = status == .final_ ? "final" : status.rawValue
            try container.encode(statusString, forKey: .status)
        } else {
            try container.encodeNil(forKey: .status)
        }

        try container.encodeIfPresent(wordGoal, forKey: .wordGoal)
        try container.encode(goalType.rawValue, forKey: .goalType)
        try container.encode(wordCount, forKey: .wordCount)
        try container.encode(isBibliography, forKey: .isBibliography)
        try container.encode(isPseudoSection, forKey: .isPseudoSection)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)

        // Tags encoded as JSON string
        if let tags = tags {
            let tagsData = try JSONEncoder().encode(tags)
            let tagsString = String(data: tagsData, encoding: .utf8) ?? "[]"
            try container.encode(tagsString, forKey: .tags)
        } else {
            try container.encodeNil(forKey: .tags)
        }
    }

    // MARK: - Computed Properties

    /// Calculate word count from text content
    mutating func recalculateWordCount() {
        wordCount = MarkdownUtils.wordCount(for: textContent)
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

    /// Whether this block is a heading that can appear in the outline sidebar
    var isOutlineHeading: Bool {
        blockType == .heading && headingLevel != nil
    }

    /// Title for display in outline (heading text or section break marker)
    var outlineTitle: String {
        if blockType == .heading {
            return textContent.isEmpty ? "(Untitled)" : textContent
        } else if isPseudoSection {
            return "§"  // Section break marker
        }
        return textContent
    }
}

// MARK: - Block Insert/Update Helpers

/// Represents a block insert from the editor
struct BlockInsert: Codable, Sendable {
    let tempId: String          // Temporary ID assigned by editor
    let blockType: String
    let textContent: String
    let markdownFragment: String
    let headingLevel: Int?
    let afterBlockId: String?   // Insert after this block
}

/// Represents a block update from the editor
struct BlockUpdate: Codable, Sendable {
    let id: String
    let textContent: String?
    let markdownFragment: String?
    let headingLevel: Int?
}

/// Represents block changes from the editor for sync
struct BlockChanges: Codable, Sendable {
    var updates: [BlockUpdate]
    var inserts: [BlockInsert]
    var deletes: [String]       // Block IDs to delete

    init(updates: [BlockUpdate] = [], inserts: [BlockInsert] = [], deletes: [String] = []) {
        self.updates = updates
        self.inserts = inserts
        self.deletes = deletes
    }

    var isEmpty: Bool {
        updates.isEmpty && inserts.isEmpty && deletes.isEmpty
    }
}
