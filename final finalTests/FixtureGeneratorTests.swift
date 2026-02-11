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

        // Open it — this will run migrations and validate schema
        let package = try ProjectPackage.open(at: url)
        let db = try ProjectDatabase(package: package)

        // Verify content exists
        let content = try db.dbWriter.read { database in
            try String.fetchOne(database, sql: "SELECT markdown FROM content LIMIT 1")
        }

        XCTAssertNotNil(content)
        XCTAssertTrue(content?.contains("Test Document") ?? false, "Fixture should contain test content")
    }
}
