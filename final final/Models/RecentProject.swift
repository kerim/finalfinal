//
//  RecentProject.swift
//  final final
//

import Foundation
import GRDB

struct RecentProject: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var path: String
    var title: String
    var lastOpenedAt: Date

    init(id: String = UUID().uuidString, path: String, title: String, lastOpenedAt: Date = Date()) {
        self.id = id
        self.path = path
        self.title = title
        self.lastOpenedAt = lastOpenedAt
    }
}
