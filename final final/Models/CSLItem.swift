//
//  CSLItem.swift
//  final final
//
//  CSL-JSON item model for Zotero/Better BibTeX integration.
//  Uses lenient decoding due to complex CSL-JSON format variations.
//

import Foundation

/// A single author/contributor in CSL-JSON format
struct CSLName: Codable, Sendable, Equatable {
    var family: String?
    var given: String?
    var literal: String?  // For institutional authors

    /// Display name for UI
    var displayName: String {
        if let literal = literal, !literal.isEmpty {
            return literal
        }
        let parts = [given, family].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    /// Short name for citations (family name only)
    var shortName: String {
        if let literal = literal, !literal.isEmpty {
            return literal
        }
        return family ?? given ?? ""
    }
}

/// Date in CSL-JSON format (array of date parts)
/// Handles various BBT/Zotero date formats with lenient decoding
struct CSLDate: Sendable, Equatable {
    var dateParts: [[Int]]?
    var raw: String?
    var literal: String?

    enum CodingKeys: String, CodingKey {
        case dateParts = "date-parts"
        case raw
        case literal
    }

    /// Extract year from date
    var year: Int? {
        if let parts = dateParts, let first = parts.first, !first.isEmpty {
            return first[0]
        }
        // Try parsing raw date
        if let raw = raw {
            let digits = raw.filter { $0.isNumber }
            if digits.count >= 4 {
                return Int(String(digits.prefix(4)))
            }
        }
        // Try parsing literal
        if let literal = literal {
            let digits = literal.filter { $0.isNumber }
            if digits.count >= 4 {
                return Int(String(digits.prefix(4)))
            }
        }
        return nil
    }

    /// Display string for date
    var displayString: String {
        if let year = year {
            return String(year)
        }
        return literal ?? raw ?? ""
    }

    /// Extract [[Int]] from various formats (handles Int, String, Double)
    /// BBT sends integers [[2015, 9, 15]], some versions send strings [["2015", "9", "15"]]
    private static func extractDateParts(from value: Any) -> [[Int]]? {
        // Handle [[Any]] - standard date-parts format
        if let outerArray = value as? [[Any]] {
            return outerArray.map { innerArray in
                innerArray.compactMap { element -> Int? in
                    if let intVal = element as? Int { return intVal }
                    if let doubleVal = element as? Double { return Int(doubleVal) }
                    if let strVal = element as? String { return Int(strVal) }
                    return nil
                }
            }
        }
        // Handle [Any] - flat array format
        if let flatArray = value as? [Any] {
            let ints = flatArray.compactMap { element -> Int? in
                if let intVal = element as? Int { return intVal }
                if let doubleVal = element as? Double { return Int(doubleVal) }
                if let strVal = element as? String { return Int(strVal) }
                return nil
            }
            return ints.isEmpty ? nil : [ints]
        }
        return nil
    }
}

extension CSLDate: Codable {
    init(from decoder: Decoder) throws {
        // Try decoding as a container first
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            // Use AnyCodable to decode date-parts flexibly without corrupting decoder state
            // This avoids the "key visited" problem where Swift's KeyedDecodingContainer
            // considers a key consumed after the first decode attempt fails on type mismatch
            if let anyValue = try? container.decodeIfPresent(AnyCodable.self, forKey: .dateParts) {
                self.dateParts = Self.extractDateParts(from: anyValue.value)
            } else {
                self.dateParts = nil
            }

            self.raw = try? container.decodeIfPresent(String.self, forKey: .raw)
            self.literal = try? container.decodeIfPresent(String.self, forKey: .literal)
        }
        // Try decoding as a simple string (e.g., "2019-03-15" or "2019")
        else if let singleValue = try? decoder.singleValueContainer(),
                let dateString = try? singleValue.decode(String.self) {
            self.raw = dateString
            self.literal = nil
            // Try to extract year from ISO date or plain year
            if let year = Int(dateString.prefix(4)) {
                self.dateParts = [[year]]
            } else {
                self.dateParts = nil
            }
        }
        // Try decoding as a simple number (year only)
        else if let singleValue = try? decoder.singleValueContainer(),
                let year = try? singleValue.decode(Int.self) {
            self.dateParts = [[year]]
            self.raw = nil
            self.literal = nil
        } else {
            // Fallback: empty date
            self.dateParts = nil
            self.raw = nil
            self.literal = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(dateParts, forKey: .dateParts)
        try container.encodeIfPresent(raw, forKey: .raw)
        try container.encodeIfPresent(literal, forKey: .literal)
    }
}

/// Helper type for decoding any JSON value without type constraints
/// Used to decode date-parts which can be [[Int]], [[String]], [[Double]], etc.
/// Uses singleValueContainer() to read values atomically, avoiding decoder state corruption.
struct AnyCodable: Decodable, @unchecked Sendable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode value")
        }
    }
}

/// CSL-JSON item type (article, book, etc.)
/// Only includes common types - others are stored as rawValue
struct CSLItemType: RawRepresentable, Codable, Sendable, Equatable {
    var rawValue: String

    static let article = CSLItemType(rawValue: "article")
    static let articleJournal = CSLItemType(rawValue: "article-journal")
    static let articleMagazine = CSLItemType(rawValue: "article-magazine")
    static let articleNewspaper = CSLItemType(rawValue: "article-newspaper")
    static let book = CSLItemType(rawValue: "book")
    static let chapter = CSLItemType(rawValue: "chapter")
    static let thesis = CSLItemType(rawValue: "thesis")
    static let report = CSLItemType(rawValue: "report")
    static let webpage = CSLItemType(rawValue: "webpage")
    static let paperConference = CSLItemType(rawValue: "paper-conference")
}

/// A CSL-JSON bibliographic item
/// Supports the core fields needed for citation display and bibliography generation.
struct CSLItem: Codable, Identifiable, Sendable, Equatable {
    // MARK: - Required Fields

    /// CSL item ID (matches citekey in Better BibTeX)
    var id: String

    /// Item type (article-journal, book, chapter, etc.)
    var type: CSLItemType

    // MARK: - Common Fields

    var title: String?
    var author: [CSLName]?
    var editor: [CSLName]?
    var issued: CSLDate?
    var accessed: CSLDate?

    // Publication info
    var containerTitle: String?  // Journal/book title
    var publisher: String?
    var publisherPlace: String?

    // Identifiers
    var DOI: String?
    var ISBN: String?
    var ISSN: String?
    var URL: String?

    // Pagination/volume
    var volume: String?
    var issue: String?
    var page: String?

    // Abstract and notes
    var abstract: String?
    var note: String?

    // Better BibTeX citekey
    var citationKey: String?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case author
        case editor
        case issued
        case accessed
        case containerTitle = "container-title"
        case publisher
        case publisherPlace = "publisher-place"
        case DOI
        case ISBN
        case ISSN
        case URL
        case volume
        case issue
        case page
        case abstract
        case note
        case citationKey = "citation-key"  // BBT uses hyphen in JSON-RPC response
    }

    // MARK: - Lenient Decoding

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Required fields
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(CSLItemType.self, forKey: .type)

        // Optional fields with lenient decoding
        title = try container.decodeIfPresent(String.self, forKey: .title)
        author = try? container.decodeIfPresent([CSLName].self, forKey: .author)
        editor = try? container.decodeIfPresent([CSLName].self, forKey: .editor)

        // Decode issued date with lenient fallback
        issued = try? container.decodeIfPresent(CSLDate.self, forKey: .issued)

        accessed = try? container.decodeIfPresent(CSLDate.self, forKey: .accessed)
        containerTitle = try container.decodeIfPresent(String.self, forKey: .containerTitle)
        publisher = try container.decodeIfPresent(String.self, forKey: .publisher)
        publisherPlace = try container.decodeIfPresent(String.self, forKey: .publisherPlace)
        DOI = try container.decodeIfPresent(String.self, forKey: .DOI)
        ISBN = try container.decodeIfPresent(String.self, forKey: .ISBN)
        ISSN = try container.decodeIfPresent(String.self, forKey: .ISSN)
        URL = try container.decodeIfPresent(String.self, forKey: .URL)

        // Volume/issue can be string or number in CSL-JSON
        if let volumeStr = try? container.decodeIfPresent(String.self, forKey: .volume) {
            volume = volumeStr
        } else if let volumeInt = try? container.decodeIfPresent(Int.self, forKey: .volume) {
            volume = String(volumeInt)
        }

        if let issueStr = try? container.decodeIfPresent(String.self, forKey: .issue) {
            issue = issueStr
        } else if let issueInt = try? container.decodeIfPresent(Int.self, forKey: .issue) {
            issue = String(issueInt)
        }

        page = try container.decodeIfPresent(String.self, forKey: .page)
        abstract = try container.decodeIfPresent(String.self, forKey: .abstract)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        citationKey = try container.decodeIfPresent(String.self, forKey: .citationKey)
    }

    // MARK: - Computed Properties

    /// The citekey to use (BBT citationKey or fallback to id)
    var citekey: String {
        citationKey ?? id
    }

    /// Display year (from issued date)
    var year: String {
        if let y = issued?.year {
            return String(y)
        }
        return "n.d."
    }

    /// First author's family name for display
    var firstAuthorName: String {
        author?.first?.shortName ?? editor?.first?.shortName ?? ""
    }

    /// Short citation format: "Author (Year)"
    var shortCitation: String {
        let name = firstAuthorName
        if name.isEmpty {
            return "(\(year))"
        }
        return "\(name) (\(year))"
    }

    /// Search text for fuzzy matching
    var searchText: String {
        let parts = [
            title,
            author?.map { $0.displayName }.joined(separator: " "),
            citekey,
            year,
            containerTitle
        ].compactMap { $0 }
        return parts.joined(separator: " ")
    }
}
