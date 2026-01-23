//
//  OutlineNode.swift
//  final final
//

import Foundation
import GRDB

struct OutlineNode: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var projectId: String
    var headerLevel: Int
    var title: String
    var startOffset: Int
    var endOffset: Int
    var parentId: String?
    var sortOrder: Int
    var isPseudoSection: Bool

    init(
        id: String = UUID().uuidString,
        projectId: String,
        headerLevel: Int,
        title: String,
        startOffset: Int,
        endOffset: Int,
        parentId: String? = nil,
        sortOrder: Int,
        isPseudoSection: Bool = false
    ) {
        self.id = id
        self.projectId = projectId
        self.headerLevel = headerLevel
        self.title = title
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.parentId = parentId
        self.sortOrder = sortOrder
        self.isPseudoSection = isPseudoSection
    }
}
