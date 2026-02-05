//
//  Document.swift
//  final final
//

import Foundation
import GRDB

/// Schema version for project data model
/// - 1: Section-based (legacy) - uses section table
/// - 2: Block-based (new) - uses block table with stable IDs
enum ProjectSchemaVersion: Int, Codable, Sendable {
    case sectionBased = 1
    case blockBased = 2
}

struct Project: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var title: String
    var schemaVersion: ProjectSchemaVersion
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        title: String,
        schemaVersion: ProjectSchemaVersion = .blockBased,  // Default to new block-based for new projects
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Whether this project uses the new block-based architecture
    var usesBlocks: Bool {
        schemaVersion == .blockBased
    }
}

struct Content: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var projectId: String
    var markdown: String
    var updatedAt: Date

    init(id: String = UUID().uuidString, projectId: String, markdown: String = "", updatedAt: Date = Date()) {
        self.id = id
        self.projectId = projectId
        self.markdown = markdown
        self.updatedAt = updatedAt
    }
}
