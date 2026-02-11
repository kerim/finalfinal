//
//  TestFixtureFactory.swift
//  final finalTests
//
//  Creates .ff test fixtures using ProjectDatabase APIs.
//  Ensures fixtures match the current database schema (all migrations applied).
//

import Foundation
@testable import final_final

enum TestFixtureFactory {
    /// The canonical test content used across all test fixtures
    static let testContent = """
    # Test Document

    This is a test paragraph for automated testing.

    ## Second Section

    More content here.
    """

    /// Creates a fresh .ff fixture at the given URL
    /// - Parameters:
    ///   - url: Directory URL where the .ff package will be created
    ///   - title: Project title (defaults to "Test Project")
    ///   - content: Markdown content (defaults to testContent)
    /// - Returns: The created ProjectDatabase
    @discardableResult
    static func createFixture(
        at url: URL,
        title: String = "Test Project",
        content: String? = nil
    ) throws -> ProjectDatabase {
        let package = try ProjectPackage.create(at: url, title: title)
        let db = try ProjectDatabase.create(
            package: package,
            title: title,
            initialContent: content ?? testContent
        )
        return db
    }
}
