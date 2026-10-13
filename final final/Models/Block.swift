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
    case mathDisplay = "math_display"

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
        case .mathDisplay: return "Math"
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

    /// Persisted section-hierarchy parent: the id of the nearest preceding outline block
    /// (heading or pseudo-section) with a strictly lower heading level, or `nil` for a
    /// level-1 heading -- the exact rule `SectionHierarchy.parentIds(for:)` implements and
    /// `EditorViewState.recalculateParentRelationships()` derives in memory every observation
    /// tick. Kept up to date by `ProjectDatabase.recomputeSectionParents(db:projectId:)`,
    /// called at the end of every DB write that can change section structure or ordering
    /// (reorder, replace, editor-diff apply, section delete/duplicate).
    ///
    /// NOT the same thing as `parentId` above: `parentId` is the structural (list-nesting)
    /// parent and is unrelated to section hierarchy. Also distinct from the LEGACY `section`
    /// table's own separately-maintained `parentId` column, which already has its own real DB
    /// reader (`ProjectIntegrityChecker.checkSectionIntegrity`'s orphan check). This column,
    /// `block.sectionParentId`, is the one that had NO reader at all until
    /// `ProjectIntegrityChecker.checkSectionParentDrift` was added alongside it.
    var sectionParentId: String?
    var textContent: String         // Plain text content (for search, word count)
    var markdownFragment: String    // Original markdown for this block
    var headingLevel: Int?          // 1-6 for headings, nil for other types

    // Section metadata (heading blocks and section breaks only)
    var status: SectionStatus?
    var tags: [String]?
    var wordGoal: Int?
    var goalType: GoalType
    var aggregateGoal: Int?
    var aggregateGoalType: GoalType
    var wordCount: Int

    // Image metadata (image blocks only)
    var imageSrc: String?           // Relative path: media/filename.png
    var imageAlt: String?           // Accessibility description
    var imageCaption: String?       // Visible caption text
    var imageWidth: Int?            // Display width as percentage of container

    // Special flags
    var isBibliography: Bool
    var isNotes: Bool               // Footnote notes section
    var isPseudoSection: Bool       // Section break markers

    /// TRANSIENT — parse-time only, never persisted. Set by `BlockParser.parse()` on the
    /// block immediately preceding a `bibliographyEndMarker` raw block: "the bibliography
    /// run ends here, at me, inclusive." `parse()` emits no Block for the marker itself, so
    /// without this the closing boundary is invisible to `replaceBlocks`, whose carry-forward
    /// needs it to bound how far a restored heading flag may travel.
    ///
    /// Deliberately absent from `Columns` and `CodingKeys` below, so it is neither written to
    /// nor read from the `block` table — a row fetched from the database always has it `false`.
    ///
    /// TRAP: this field is transient and excluded from persistence, but it DOES participate in
    /// `Block`'s synthesized `Equatable` conformance (declared on the struct above) — there is
    /// no custom `==`. A parser-fresh `Block` (which may have this `true`) must therefore never
    /// be compared with `==` against a persisted one (which always has it `false`) without
    /// accounting for that, or an otherwise-identical pair will compare unequal.
    var endsBibliographyRun: Bool = false

    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "block"

    init(
        id: String = UUID().uuidString,
        projectId: String,
        parentId: String? = nil,
        sortOrder: Double,
        blockType: BlockType,
        sectionParentId: String? = nil,
        textContent: String = "",
        markdownFragment: String = "",
        headingLevel: Int? = nil,
        status: SectionStatus? = nil,
        tags: [String]? = nil,
        wordGoal: Int? = nil,
        goalType: GoalType = .approx,
        aggregateGoal: Int? = nil,
        aggregateGoalType: GoalType = .approx,
        wordCount: Int = 0,
        imageSrc: String? = nil,
        imageAlt: String? = nil,
        imageCaption: String? = nil,
        imageWidth: Int? = nil,
        isBibliography: Bool = false,
        isNotes: Bool = false,
        isPseudoSection: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectId = projectId
        self.parentId = parentId
        self.sortOrder = sortOrder
        self.blockType = blockType
        self.sectionParentId = sectionParentId
        self.textContent = textContent
        self.markdownFragment = markdownFragment
        self.headingLevel = headingLevel
        self.status = status
        self.tags = tags
        self.wordGoal = wordGoal
        self.goalType = goalType
        self.aggregateGoal = aggregateGoal
        self.aggregateGoalType = aggregateGoalType
        self.wordCount = wordCount
        self.imageSrc = imageSrc
        self.imageAlt = imageAlt
        self.imageCaption = imageCaption
        self.imageWidth = imageWidth
        self.isBibliography = isBibliography
        self.isNotes = isNotes
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
        case sectionParentId
        case textContent
        case markdownFragment
        case headingLevel
        case status
        case tags
        case wordGoal
        case goalType
        case aggregateGoal
        case aggregateGoalType
        case wordCount
        case imageSrc
        case imageAlt
        case imageCaption
        case imageWidth
        case isBibliography
        case isNotes
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
        case sectionParentId
        case textContent
        case markdownFragment
        case headingLevel
        case status
        case tags
        case wordGoal
        case goalType
        case aggregateGoal
        case aggregateGoalType
        case wordCount
        case imageSrc
        case imageAlt
        case imageCaption
        case imageWidth
        case isBibliography
        case isNotes
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

        sectionParentId = try container.decodeIfPresent(String.self, forKey: .sectionParentId)
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
        aggregateGoal = try container.decodeIfPresent(Int.self, forKey: .aggregateGoal)
        if let aggGoalTypeString = try container.decodeIfPresent(String.self, forKey: .aggregateGoalType) {
            aggregateGoalType = GoalType(rawValue: aggGoalTypeString) ?? .approx
        } else {
            aggregateGoalType = .approx
        }
        wordCount = try container.decode(Int.self, forKey: .wordCount)
        imageSrc = try container.decodeIfPresent(String.self, forKey: .imageSrc)
        imageAlt = try container.decodeIfPresent(String.self, forKey: .imageAlt)
        imageCaption = try container.decodeIfPresent(String.self, forKey: .imageCaption)
        imageWidth = try container.decodeIfPresent(Int.self, forKey: .imageWidth)
        isBibliography = try container.decode(Bool.self, forKey: .isBibliography)
        isNotes = try container.decode(Bool.self, forKey: .isNotes)
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
        try container.encodeIfPresent(sectionParentId, forKey: .sectionParentId)
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
        try container.encodeIfPresent(aggregateGoal, forKey: .aggregateGoal)
        try container.encode(aggregateGoalType.rawValue, forKey: .aggregateGoalType)
        try container.encode(wordCount, forKey: .wordCount)
        try container.encodeIfPresent(imageSrc, forKey: .imageSrc)
        try container.encodeIfPresent(imageAlt, forKey: .imageAlt)
        try container.encodeIfPresent(imageCaption, forKey: .imageCaption)
        try container.encodeIfPresent(imageWidth, forKey: .imageWidth)
        try container.encode(isBibliography, forKey: .isBibliography)
        try container.encode(isNotes, forKey: .isNotes)
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

    /// Calculate word count from text content.
    /// Non-prose block types (code, image, horizontal rule, section break) always
    /// count as zero words — they have no user-visible prose by definition.
    /// Bibliography blocks DO count their prose; the user's `excludeBibliography`
    /// toggle (applied at `EditorViewState.filteredTotalWordCount`) is the single
    /// policy lever that drops the bibliography from the displayed total.
    mutating func recalculateWordCount() {
        switch blockType {
        case .codeBlock, .horizontalRule, .sectionBreak, .image, .mathDisplay:
            wordCount = 0
        default:
            wordCount = MarkdownUtils.wordCount(for: textContent)
        }
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

    /// Generate Pandoc-compatible markdown for export.
    /// Uses the `alt` attribute (Pandoc's `link_attributes` extension) to separate the visible
    /// caption from accessibility alt text. For non-image blocks, returns `markdownFragment`
    /// unchanged.
    func markdownForExport() -> String {
        guard blockType == .image, let src = imageSrc else {
            return markdownFragment
        }

        let alt = imageAlt ?? ""
        let caption = imageCaption ?? ""

        // Visible text in ![...] is the caption ONLY — an empty caption produces an empty
        // bracket, NOT a fallback to alt. Pandoc's implicit_figures extension only wraps an
        // image in a captioned <figure> when the bracket text is non-empty, so falling back to
        // alt here (the pre-fix behavior) is exactly what caused every image's auto-filled
        // filename (see MilkdownCoordinator+MessageHandlers.swift's insertion handlers) to show
        // up as a visible "Figure N: filename.jpg" caption in every export.
        //
        // Backslash MUST be escaped before the delimiter (`]`) — same order as the JS side's
        // escapeAltAttr (web/milkdown/src/image-plugin.ts) — because Pandoc's markdown reader
        // treats a trailing unescaped backslash as escaping the character that follows it. A
        // caption ending in an unescaped `\` would otherwise consume the closing `]` as an
        // escaped literal instead of the bracket's terminator, producing malformed markdown that
        // can make the whole image silently disappear from PDF/Word/ODT export.
        let displayText = caption
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "]", with: "\\]")

        var result = "![\(displayText)](\(src))"

        // Build {attributes} block: `alt=` carries the real accessibility text, completely
        // separate from the visible caption — confirmed via a real `pandoc --to latex`/`--to
        // docx`/`--to odt` run that `alt="..."` (not `fig-alt`, which Pandoc doesn't recognize
        // and silently drops) is the attribute Pandoc's link_attributes extension understands.
        var attrs: [String] = []
        if !alt.isEmpty {
            // Backslash escaped before the delimiter (`"`) for the same reason as displayText
            // above — matches escapeAltAttr's order exactly.
            let escapedAlt = alt
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            attrs.append("alt=\"\(escapedAlt)\"")
        }
        if let width = imageWidth {
            attrs.append("width=\(width)%")
        }
        if !attrs.isEmpty {
            result += "{\(attrs.joined(separator: " "))}"
        }

        return result
    }

    /// Generate standard markdown for export (no Pandoc-specific attributes).
    /// Caption appears as italic paragraph below the image.
    func markdownForStandardExport() -> String {
        guard blockType == .image, let src = imageSrc else {
            return markdownFragment
        }

        let alt = imageAlt ?? ""
        var result = "![\(alt)](\(src))"

        if let caption = imageCaption, !caption.isEmpty {
            result += "\n\n*\(caption)*"
        }

        return result
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
    let atDocumentStart: Bool?  // True when this block is literal doc position 0

    init(tempId: String, blockType: String, textContent: String, markdownFragment: String,
         headingLevel: Int?, afterBlockId: String?, atDocumentStart: Bool? = nil) {
        self.tempId = tempId
        self.blockType = blockType
        self.textContent = textContent
        self.markdownFragment = markdownFragment
        self.headingLevel = headingLevel
        self.afterBlockId = afterBlockId
        self.atDocumentStart = atDocumentStart
    }
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
