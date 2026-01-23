//
//  Document.swift
//  final final
//

import Foundation
import GRDB

struct Project: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString, title: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct Content: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
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
