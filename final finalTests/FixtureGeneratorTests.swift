//
//  FixtureGeneratorTests.swift
//  final finalTests
//
//  Generates and validates the committed test fixture.
//  Run this test to (re)generate the fixture after schema changes.
//

import XCTest
@testable import final_final

final class FixtureGeneratorTests: XCTestCase {

    /// Generates the committed test fixture.
    /// Run this test to create or refresh the fixture after schema migrations change.
    func testGenerateCommittedFixture() throws {
        // Determine fixture destination: final finalTests/Fixtures/test-fixture.ff
        let testBundle = Bundle(for: type(of: self))
        // The test bundle is inside the app bundle for hosted tests.
        // Navigate up to find the source directory.
        // For CI/manual use: FIXTURE_OUTPUT_PATH env var overrides.
        let outputPath: String
        if let envPath = ProcessInfo.processInfo.environment["FIXTURE_OUTPUT_PATH"] {
            outputPath = envPath
        } else {
            // Use /tmp/claude for sandbox-safe generation
            outputPath = "/tmp/claude/test-fixture.ff"
        }

        let fixtureURL = URL(fileURLWithPath: outputPath)

        // Remove existing fixture
        try? FileManager.default.removeItem(at: fixtureURL)

        // Create fixture using ProjectDatabase APIs (runs all migrations)
        try TestFixtureFactory.createFixture(at: fixtureURL)

        // Verify it was created
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixtureURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixtureURL.appendingPathComponent("content.sqlite").path))

        print("[FixtureGenerator] Fixture created at: \(fixtureURL.path)")
        print("[FixtureGenerator] Copy to final finalTests/Fixtures/test-fixture.ff to commit")
    }

    /// Generates the rich test fixture with annotations, citations, footnotes, images.
    /// Run this test to create or refresh the rich fixture after schema changes.
    func testGenerateRichFixture() throws {
        let outputPath: String
        if let envPath = ProcessInfo.processInfo.environment["FIXTURE_OUTPUT_PATH"] {
            outputPath = envPath.replacingOccurrences(of: ".ff", with: "-rich.ff")
        } else {
            outputPath = "/tmp/claude/test-fixture-rich.ff"
        }

        let fixtureURL = URL(fileURLWithPath: outputPath)
        try? FileManager.default.removeItem(at: fixtureURL)

        let db = try TestFixtureFactory.createRichFixture(at: fixtureURL)

        // Verify fixture was created
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixtureURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixtureURL.appendingPathComponent("content.sqlite").path))

        // Verify rich content characteristics
        let blocks = try db.dbWriter.read { database in
            try Block.fetchAll(database)
        }

        // Should have multiple headings at different levels
        let headings = blocks.filter { $0.blockType == .heading }
        XCTAssertGreaterThanOrEqual(headings.count, 5, "Rich fixture should have 5+ headings")

        let h1s = headings.filter { $0.headingLevel == 1 }
        let h2s = headings.filter { $0.headingLevel == 2 }
        let h3s = headings.filter { $0.headingLevel == 3 }
        XCTAssertGreaterThanOrEqual(h1s.count, 1, "Should have H1 headings")
        XCTAssertGreaterThanOrEqual(h2s.count, 2, "Should have H2 headings")
        XCTAssertGreaterThanOrEqual(h3s.count, 1, "Should have H3 headings")

        // Should have image block
        let images = blocks.filter { $0.blockType == .image }
        XCTAssertGreaterThanOrEqual(images.count, 1, "Rich fixture should have at least 1 image")

        // Verify content has citations, footnotes, and annotations
        let content = try db.dbWriter.read { database in
            try String.fetchOne(database, sql: "SELECT markdown FROM content LIMIT 1")
        }
        XCTAssertNotNil(content)
        XCTAssertTrue(content?.contains("[@") ?? false, "Rich fixture should contain citations")
        XCTAssertTrue(content?.contains("[^") ?? false, "Rich fixture should contain footnote refs")
        XCTAssertTrue(content?.contains("<!-- ::task::") ?? false, "Rich fixture should contain task annotations")
        XCTAssertTrue(content?.contains("<!-- ::comment::") ?? false, "Rich fixture should contain comment annotations")
        XCTAssertTrue(content?.contains("<!-- ::reference::") ?? false, "Rich fixture should contain reference annotations")
        XCTAssertTrue(content?.contains("==") ?? false, "Rich fixture should contain highlights")

        print("[FixtureGenerator] Rich fixture created at: \(fixtureURL.path)")
        print("[FixtureGenerator] \(blocks.count) blocks, \(headings.count) headings")
    }

    /// Validates the committed fixture can be opened and has expected content.
    /// This catches schema drift — if migrations change, the fixture needs regeneration.
    func testCommittedFixtureIsValid() throws {
        // Look for fixture in test bundle resources
        let testBundle = Bundle(for: type(of: self))

        // For hosted tests, the fixture is in the app bundle's resources
        // Try multiple locations
        var fixtureURL: URL?

        // Check if fixture exists in the source tree (for local dev)
        let sourceFixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/test-fixture.ff")
        if FileManager.default.fileExists(atPath: sourceFixture.path) {
            fixtureURL = sourceFixture
        }

        guard let url = fixtureURL else {
            // Fixture not yet committed — skip validation
            print("[FixtureValidator] No committed fixture found, skipping validation")
            return
        }

        // Copy to temp to avoid modifying the committed fixture (WAL mode, migrations)
        let tempFixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-validation-\(UUID().uuidString).ff")
        try FileManager.default.copyItem(at: url, to: tempFixture)
        defer { try? FileManager.default.removeItem(at: tempFixture) }

        // Open the copy — this will run migrations and validate schema
        let package = try ProjectPackage.open(at: tempFixture)
        let db = try ProjectDatabase(package: package)

        // Verify content exists
        let content = try db.dbWriter.read { database in
            try String.fetchOne(database, sql: "SELECT markdown FROM content LIMIT 1")
        }

        XCTAssertNotNil(content)
        XCTAssertTrue(content?.contains("Test Document") ?? false, "Fixture should contain test content")
    }
}
