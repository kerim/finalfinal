//
//  SQLiteReader.swift
//  QuickLook Extension
//
//  Read-only SQLite3 C API wrapper.
//  Reads project title and markdown content from .ff package databases.
//

import Foundation
import SQLite3

enum SQLiteReader {
    struct ProjectData {
        let title: String
        let markdown: String
    }

    enum ReadError: Error {
        case cannotOpenDatabase(String)
        case queryFailed(String)
        case noContent
    }

    static func read(from packageURL: URL) throws -> ProjectData {
        let dbPath = packageURL.appendingPathComponent("content.sqlite").path
        var db: OpaquePointer?

        let rc = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil)

        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw ReadError.cannotOpenDatabase(message)
        }

        defer { sqlite3_close(db) }

        let title = try queryString(db: db, sql: "SELECT title FROM project LIMIT 1") ?? "Untitled"

        // Primary: block-based schema (current) -- concatenate markdown fragments
        // Subquery ensures ORDER BY is respected by group_concat;
        // double newline separator so markdown parser sees block boundaries
        let blockMarkdown = try queryString(
            db: db,
            sql: """
                SELECT group_concat(markdownFragment, char(10) || char(10))
                FROM (SELECT markdownFragment FROM block WHERE isNotes = 0 AND isBibliography = 0 ORDER BY sortOrder)
                """
        )

        // Fallback: legacy content table
        let markdown: String
        if let blockMarkdown, !blockMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            markdown = blockMarkdown
        } else if let contentMarkdown = try queryString(db: db, sql: "SELECT markdown FROM content LIMIT 1") {
            markdown = contentMarkdown
        } else {
            throw ReadError.noContent
        }

        return ProjectData(title: title, markdown: markdown)
    }

    private static func queryString(db: OpaquePointer, sql: String) throws -> String? {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            // Table may not exist (e.g. "block" table in older databases) -- return nil
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cString = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cString)
    }
}
