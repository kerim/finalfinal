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

    /// ONE-TIME UTILITY — not part of the regular suite's job.
    ///
    /// Repairs the shipped `getting-started.ff` fixture, which has a corrupted
    /// block split: a fenced code block demonstrating raw table syntax got cut
    /// into a `code_block` row (just the opening ``` fence) followed by a
    /// separate `table` row (the table body + closing ``` fence). This is the
    /// exact bug fixed in BlockParser.splitIntoRawBlocks (missing `!inCodeBlock`
    /// guards on the table-start and `$$`-math-fence checks).
    ///
    /// This test does NOT touch the committed
    /// `final final/Resources/getting-started.ff` — it copies it to a sandbox-
    /// writable temp location, re-derives the block table from the fixture's own
    /// `content.markdown` (the source of truth, which was never corrupted) using
    /// the now-fixed `BlockParser`, and writes the repaired copy to a
    /// UUID-suffixed path under `/tmp/claude/` (printed at runtime). A
    /// human/reviewer must inspect that output and copy it over the committed
    /// fixture if it looks correct — this test intentionally does not do that
    /// itself.
    ///
    /// Run manually once (e.g. after verifying the BlockParser fix):
    ///   xcodebuild test -scheme "final final" -destination 'platform=macOS' \
    ///     -only-testing 'final finalTests/FixtureGeneratorTests/testRegenerateGettingStartedFixture_ONETIME'
    func testRegenerateGettingStartedFixture_ONETIME() throws {
        let fm = FileManager.default

        // Locate the committed fixture relative to this source file.
        let committedFixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // final finalTests/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("final final/Resources/getting-started.ff")
        guard fm.fileExists(atPath: committedFixture.path) else {
            throw XCTSkip("Committed getting-started.ff not found at \(committedFixture.path) — skipping one-time repair utility")
        }

        // Work on a sandbox-writable copy; never mutate the committed fixture.
        let tmpClaudeDir = URL(fileURLWithPath: "/tmp/claude")
        try fm.createDirectory(at: tmpClaudeDir, withIntermediateDirectories: true)
        let repairedURL = tmpClaudeDir.appendingPathComponent("getting-started-repaired-\(UUID().uuidString).ff")
        try? fm.removeItem(at: repairedURL)
        try fm.copyItem(at: committedFixture, to: repairedURL)

        // Open, re-parse, and replace blocks in a scoped helper so the
        // ProjectDatabase (and its pooled SQLite connections) is deallocated
        // before we touch the -wal/-shm sidecar files below — deleting them
        // while GRDB still holds open handles trips libsqlite3's
        // "vnode unlinked while in use" API-violation guard.
        try Self.repairGettingStartedFixture(at: repairedURL)

        // Now that the connections are closed, the WAL was already checkpointed
        // to TRUNCATE (0 bytes) inside the helper — remove the empty sidecars so
        // the shipped copy is a single clean file (matches the "Guard: no SQLite
        // sidecars" build-phase requirement).
        for sidecar in ["content.sqlite-wal", "content.sqlite-shm"] {
            let sidecarURL = repairedURL.appendingPathComponent(sidecar)
            if fm.fileExists(atPath: sidecarURL.path) {
                try fm.removeItem(at: sidecarURL)
            }
        }

        print("[FixtureRepair] Repaired fixture written to: \(repairedURL.path)")
        print("[FixtureRepair] Inspect it, then if correct, copy it over: \(committedFixture.path)")
    }

    /// Opens the fixture copy, re-derives blocks from `content.markdown` via the
    /// fixed `BlockParser`, replaces them, and checkpoints the WAL to TRUNCATE.
    /// Scoped to a static function so `db`/`package` go out of scope (and GRDB's
    /// DatabasePool deallocates its connections) before the caller deletes the
    /// now-empty -wal/-shm sidecar files.
    private static func repairGettingStartedFixture(at url: URL) throws {
        let package = try ProjectPackage.open(at: url)
        let db = try ProjectDatabase(package: package)

        // content.markdown is intact and is the source of truth for repair.
        let (markdown, projectId): (String, String) = try db.dbWriter.read { database in
            let markdown = try String.fetchOne(database, sql: "SELECT markdown FROM content LIMIT 1")!
            let projectId = try String.fetchOne(database, sql: "SELECT id FROM project LIMIT 1")!
            return (markdown, projectId)
        }

        // Re-parse with the fixed BlockParser and replace via the same production
        // path TestFixtureFactory.createFixture uses.
        let blocks = BlockParser.parse(markdown: markdown, projectId: projectId)
        try db.replaceBlocks(blocks, for: projectId)

        // Checkpoint WAL to TRUNCATE so the shipped copy is a single clean file.
        try db.dbWriter.writeWithoutTransaction { database in
            try database.checkpoint(.truncate)
        }
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
