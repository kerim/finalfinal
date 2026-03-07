//
//  Snapshot.swift
//  final final
//
//  Version history models for saving and restoring project states.
//

import Foundation
import GRDB

/// A snapshot represents a saved version of the project at a point in time.
/// Can be created automatically (auto-backup) or manually (named save).
struct Snapshot: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var projectId: String
    var name: String?           // nil for auto-backups, user-provided for manual saves
    var createdAt: Date
    var isAutomatic: Bool       // true for auto-backups, false for manual saves
    var previewMarkdown: String // Full content.markdown at time of snapshot

    static let databaseTableName = "snapshot"

    init(
        id: String = UUID().uuidString,
        projectId: String,
        name: String? = nil,
        createdAt: Date = Date(),
        isAutomatic: Bool = true,
        previewMarkdown: String
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.createdAt = createdAt
        self.isAutomatic = isAutomatic
        self.previewMarkdown = previewMarkdown
    }

    // MARK: - Database Columns

    enum Columns: String, ColumnExpression {
        case id
        case projectId
        case name
        case createdAt
        case isAutomatic
        case previewMarkdown
    }

    // MARK: - Computed Properties

    /// Display name for the snapshot (name if available, otherwise formatted date)
    var displayName: String {
        if let name = name, !name.isEmpty {
            return name
        }
        return Self.dateFormatter.string(from: createdAt)
    }

    /// Whether this is a named (manual) save
    var isNamed: Bool {
        name != nil && !name!.isEmpty
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// A section within a snapshot, storing the state of a section at the time of the snapshot.
/// Uses originalSectionId to track which section it came from (for restore matching).
struct SnapshotSection: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var snapshotId: String
    var originalSectionId: String?  // Plain TEXT, not FK (sections can be deleted)
    var title: String
    var markdownContent: String
    var headerLevel: Int
    var sortOrder: Int
    var status: SectionStatus?
    var tags: [String]
    var wordGoal: Int?

    static let databaseTableName = "snapshotSection"

    init(
        id: String = UUID().uuidString,
        snapshotId: String,
        originalSectionId: String?,
        title: String,
        markdownContent: String,
        headerLevel: Int,
        sortOrder: Int,
        status: SectionStatus? = nil,
        tags: [String] = [],
        wordGoal: Int? = nil
    ) {
        self.id = id
        self.snapshotId = snapshotId
        self.originalSectionId = originalSectionId
        self.title = title
        self.markdownContent = markdownContent
        self.headerLevel = headerLevel
        self.sortOrder = sortOrder
        self.status = status
        self.tags = tags
        self.wordGoal = wordGoal
    }

    /// Create a SnapshotSection from an existing Section
    init(from section: Section, snapshotId: String) {
        self.id = UUID().uuidString
        self.snapshotId = snapshotId
        self.originalSectionId = section.id
        self.title = section.title
        self.markdownContent = section.markdownContent
        self.headerLevel = section.headerLevel
        self.sortOrder = section.sortOrder
        self.status = section.status
        self.tags = section.tags
        self.wordGoal = section.wordGoal
    }

    // MARK: - Database Columns

    enum Columns: String, ColumnExpression {
        case id
        case snapshotId
        case originalSectionId
        case title
        case markdownContent
        case headerLevel
        case sortOrder
        case status
        case tags
        case wordGoal
    }

    // MARK: - Custom Encoding for Tags (JSON array)

    private enum CodingKeys: String, CodingKey {
        case id
        case snapshotId
        case originalSectionId
        case title
        case markdownContent
        case headerLevel
        case sortOrder
        case status
        case tags
        case wordGoal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        snapshotId = try container.decode(String.self, forKey: .snapshotId)
        originalSectionId = try container.decodeIfPresent(String.self, forKey: .originalSectionId)
        title = try container.decode(String.self, forKey: .title)
        markdownContent = try container.decode(String.self, forKey: .markdownContent)
        headerLevel = try container.decode(Int.self, forKey: .headerLevel)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        status = try container.decodeIfPresent(SectionStatus.self, forKey: .status)
        wordGoal = try container.decodeIfPresent(Int.self, forKey: .wordGoal)

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
        try container.encode(snapshotId, forKey: .snapshotId)
        try container.encodeIfPresent(originalSectionId, forKey: .originalSectionId)
        try container.encode(title, forKey: .title)
        try container.encode(markdownContent, forKey: .markdownContent)
        try container.encode(headerLevel, forKey: .headerLevel)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(wordGoal, forKey: .wordGoal)

        // Tags encoded as JSON string
        let tagsData = try JSONEncoder().encode(tags)
        let tagsString = String(data: tagsData, encoding: .utf8) ?? "[]"
        try container.encode(tagsString, forKey: .tags)
    }
}
