//
//  Annotation.swift
//  final final
//

import Foundation
import GRDB

/// Annotation types: task, comment, or reference
enum AnnotationType: String, Codable, CaseIterable, Sendable, Hashable {
    case task
    case comment
    case reference

    var displayName: String {
        switch self {
        case .task: return "Task"
        case .comment: return "Comment"
        case .reference: return "Reference"
        }
    }

    /// Collapsed marker symbol for inline display
    var collapsedMarker: String {
        switch self {
        case .task: return "☐"  // Will show ☑ when completed
        case .comment: return "◇"
        case .reference: return "▤"
        }
    }

    /// Completed marker (only applicable to tasks)
    var completedMarker: String {
        return "☑"
    }
}

/// Display mode for annotations in the editor (per-type setting)
/// Note: Global "panel only" mode is separate - see EditorViewState.isPanelOnlyMode
enum AnnotationDisplayMode: String, Codable, CaseIterable, Sendable, Hashable {
    case inline    // Full annotation visible in editor
    case collapsed // Shows only marker symbol

    var displayName: String {
        switch self {
        case .inline: return "Inline"
        case .collapsed: return "Collapsed"
        }
    }
}

/// An annotation embedded in markdown content.
/// Annotations are stored as HTML comments: <!-- ::type:: text -->
/// Tasks can have completion state: <!-- ::task:: [ ] text --> or <!-- ::task:: [x] text -->
struct Annotation: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var contentId: String
    var sectionId: String?
    var type: AnnotationType
    var text: String
    var isCompleted: Bool
    var charOffset: Int           // Position in markdown where annotation appears
    var highlightStart: Int?      // Start of ==highlight== if present
    var highlightEnd: Int?        // End of ==highlight== if present
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "annotation"

    init(
        id: String = UUID().uuidString,
        contentId: String,
        sectionId: String? = nil,
        type: AnnotationType,
        text: String,
        isCompleted: Bool = false,
        charOffset: Int,
        highlightStart: Int? = nil,
        highlightEnd: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.contentId = contentId
        self.sectionId = sectionId
        self.type = type
        self.text = text
        self.isCompleted = isCompleted
        self.charOffset = charOffset
        self.highlightStart = highlightStart
        self.highlightEnd = highlightEnd
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Database Columns

    enum Columns: String, ColumnExpression {
        case id
        case contentId
        case sectionId
        case type
        case text
        case isCompleted
        case charOffset
        case highlightStart
        case highlightEnd
        case createdAt
        case updatedAt
    }

    // MARK: - Computed Properties

    /// Check if this annotation has a highlight span
    var hasHighlight: Bool {
        highlightStart != nil && highlightEnd != nil
    }

    /// The markdown syntax for this annotation
    var markdownSyntax: String {
        switch type {
        case .task:
            let checkbox = isCompleted ? "[x]" : "[ ]"
            return "<!-- ::task:: \(checkbox) \(text) -->"
        case .comment:
            return "<!-- ::comment:: \(text) -->"
        case .reference:
            return "<!-- ::reference:: \(text) -->"
        }
    }
}

/// Parsed annotation from markdown (before database reconciliation)
struct ParsedAnnotation: Equatable {
    let type: AnnotationType
    let text: String
    let isCompleted: Bool
    let charOffset: Int
    let highlightStart: Int?
    let highlightEnd: Int?

    /// Create an Annotation model from parsed data
    func toAnnotation(contentId: String, sectionId: String? = nil, existingId: String? = nil) -> Annotation {
        Annotation(
            id: existingId ?? UUID().uuidString,
            contentId: contentId,
            sectionId: sectionId,
            type: type,
            text: text,
            isCompleted: isCompleted,
            charOffset: charOffset,
            highlightStart: highlightStart,
            highlightEnd: highlightEnd
        )
    }
}
