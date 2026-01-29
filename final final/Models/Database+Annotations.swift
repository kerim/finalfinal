//
//  Database+Annotations.swift
//  final final
//

import Foundation
import GRDB

// MARK: - Annotation Change Types

/// Represents a surgical change to apply to the annotations table
enum AnnotationChange {
    case insert(Annotation)
    case update(id: String, updates: AnnotationUpdates)
    case delete(id: String)
}

/// Updates to apply to an existing annotation (all fields optional)
struct AnnotationUpdates {
    var text: String?
    var isCompleted: Bool?
    var charOffset: Int?
    var highlightStart: Int??  // Double-optional: nil = don't change, .some(nil) = set to nil
    var highlightEnd: Int??
    var sectionId: String??

    init(
        text: String? = nil,
        isCompleted: Bool? = nil,
        charOffset: Int? = nil,
        highlightStart: Int?? = nil,
        highlightEnd: Int?? = nil,
        sectionId: String?? = nil
    ) {
        self.text = text
        self.isCompleted = isCompleted
        self.charOffset = charOffset
        self.highlightStart = highlightStart
        self.highlightEnd = highlightEnd
        self.sectionId = sectionId
    }
}

// MARK: - ProjectDatabase Annotation CRUD

extension ProjectDatabase {

    // MARK: - Fetch Operations

    /// Fetch all annotations for a content, sorted by charOffset
    func fetchAnnotations(contentId: String) throws -> [Annotation] {
        try read { db in
            try Annotation
                .filter(Annotation.Columns.contentId == contentId)
                .order(Annotation.Columns.charOffset)
                .fetchAll(db)
        }
    }

    /// Fetch annotations filtered by type
    func fetchAnnotations(contentId: String, type: AnnotationType) throws -> [Annotation] {
        try read { db in
            try Annotation
                .filter(Annotation.Columns.contentId == contentId)
                .filter(Annotation.Columns.type == type.rawValue)
                .order(Annotation.Columns.charOffset)
                .fetchAll(db)
        }
    }

    /// Fetch annotations for a specific section
    func fetchAnnotations(sectionId: String) throws -> [Annotation] {
        try read { db in
            try Annotation
                .filter(Annotation.Columns.sectionId == sectionId)
                .order(Annotation.Columns.charOffset)
                .fetchAll(db)
        }
    }

    /// Fetch a single annotation by ID
    func fetchAnnotation(id: String) throws -> Annotation? {
        try read { db in
            try Annotation.fetchOne(db, key: id)
        }
    }

    /// Fetch incomplete tasks for a content
    func fetchIncompleteTasks(contentId: String) throws -> [Annotation] {
        try read { db in
            try Annotation
                .filter(Annotation.Columns.contentId == contentId)
                .filter(Annotation.Columns.type == AnnotationType.task.rawValue)
                .filter(Annotation.Columns.isCompleted == false)
                .order(Annotation.Columns.charOffset)
                .fetchAll(db)
        }
    }

    // MARK: - Insert/Update Operations

    /// Insert a new annotation
    func insertAnnotation(_ annotation: Annotation) throws {
        var annotation = annotation
        try write { db in
            try annotation.insert(db)
        }
    }

    /// Update an existing annotation
    func updateAnnotation(_ annotation: Annotation) throws {
        var updated = annotation
        updated.updatedAt = Date()
        try write { db in
            try updated.update(db)
        }
    }

    /// Toggle annotation completion status (for tasks)
    func toggleAnnotationCompletion(id: String) throws -> Bool {
        try write { db in
            guard var annotation = try Annotation.fetchOne(db, key: id) else {
                return false
            }

            annotation.isCompleted.toggle()
            annotation.updatedAt = Date()
            try annotation.update(db)
            return annotation.isCompleted
        }
    }

    /// Update annotation completion status
    func updateAnnotationCompletion(id: String, isCompleted: Bool) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE annotation SET isCompleted = ?, updatedAt = ? WHERE id = ?",
                arguments: [isCompleted, Date(), id]
            )
        }
    }

    /// Update annotation text
    func updateAnnotationText(id: String, text: String) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE annotation SET text = ?, updatedAt = ? WHERE id = ?",
                arguments: [text, Date(), id]
            )
        }
    }

    /// Update annotation text and charOffset atomically (for sidebar editing)
    func updateAnnotation(id: String, text: String, charOffset: Int) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE annotation SET text = ?, charOffset = ?, updatedAt = ? WHERE id = ?",
                arguments: [text, charOffset, Date(), id]
            )
        }
    }

    // MARK: - Delete Operations

    /// Delete an annotation by ID
    func deleteAnnotation(id: String) throws {
        try write { db in
            try Annotation.deleteOne(db, key: id)
        }
    }

    /// Delete all annotations for a content
    func deleteAllAnnotations(contentId: String) throws {
        try write { db in
            try Annotation
                .filter(Annotation.Columns.contentId == contentId)
                .deleteAll(db)
        }
    }

    /// Delete annotations by type
    func deleteAnnotations(contentId: String, type: AnnotationType) throws {
        try write { db in
            try Annotation
                .filter(Annotation.Columns.contentId == contentId)
                .filter(Annotation.Columns.type == type.rawValue)
                .deleteAll(db)
        }
    }

    // MARK: - Bulk Operations

    /// Apply surgical annotation changes (insert/update/delete) within a single transaction
    func applyAnnotationChanges(_ changes: [AnnotationChange], for contentId: String) throws {
        try write { db in
            for change in changes {
                switch change {
                case .insert(var annotation):
                    try annotation.insert(db)

                case .update(let id, let updates):
                    guard var annotation = try Annotation.fetchOne(db, key: id) else { continue }

                    // Apply only the fields that are set
                    if let text = updates.text {
                        annotation.text = text
                    }
                    if let isCompleted = updates.isCompleted {
                        annotation.isCompleted = isCompleted
                    }
                    if let charOffset = updates.charOffset {
                        annotation.charOffset = charOffset
                    }
                    // Double-optional handling
                    if let highlightStartUpdate = updates.highlightStart {
                        annotation.highlightStart = highlightStartUpdate
                    }
                    if let highlightEndUpdate = updates.highlightEnd {
                        annotation.highlightEnd = highlightEndUpdate
                    }
                    if let sectionIdUpdate = updates.sectionId {
                        annotation.sectionId = sectionIdUpdate
                    }

                    annotation.updatedAt = Date()
                    try annotation.update(db)

                case .delete(let id):
                    try Annotation
                        .filter(Annotation.Columns.id == id)
                        .deleteAll(db)
                }
            }
        }
    }

    /// Replace all annotations for a content (used for initial sync)
    func replaceAnnotations(_ annotations: [Annotation], for contentId: String) throws {
        try write { db in
            // Delete existing annotations
            try Annotation
                .filter(Annotation.Columns.contentId == contentId)
                .deleteAll(db)

            // Insert new ones
            for var annotation in annotations {
                try annotation.insert(db)
            }
        }
    }

    // MARK: - Statistics

    /// Get annotation counts by type for a content (single GROUP BY query)
    func annotationCounts(contentId: String) throws -> [AnnotationType: Int] {
        try read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT type, COUNT(*) as count FROM annotation
                WHERE contentId = ? GROUP BY type
                """, arguments: [contentId])

            var counts: [AnnotationType: Int] = [:]
            for row in rows {
                if let typeString: String = row["type"],
                   let type = AnnotationType(rawValue: typeString) {
                    counts[type] = row["count"]
                }
            }
            return counts
        }
    }

    /// Get incomplete task count for a content
    func incompleteTaskCount(contentId: String) throws -> Int {
        try read { db in
            try Annotation
                .filter(Annotation.Columns.contentId == contentId)
                .filter(Annotation.Columns.type == AnnotationType.task.rawValue)
                .filter(Annotation.Columns.isCompleted == false)
                .fetchCount(db)
        }
    }
}
