//
//  TestFixtureCleanupTests.swift
//  final finalTests
//
//  Proves TestFixtureCleanup's ownership-manifest mechanism: a fresh
//  registration is deleted by cleanupOwn(), a live owner's manifest is
//  never touched by the reaper, a genuinely dead owner's manifest IS
//  reaped, and the path-prefix guard rejects anything outside
//  /tmp/claude (or its /private/tmp/claude symlink target) while still
//  accepting both spellings of paths that ARE inside it.
//

import XCTest
@testable import final_final

final class TestFixtureCleanupTests: XCTestCase {

    /// register() + cleanupOwn() deletes what was registered, AND
    /// cleanupOwn() leaves the mechanism in a working state afterward: a
    /// fresh register() + cleanupOwn() cycle right after must still
    /// actually delete its own fixture, not silently no-op because the
    /// manifest file is gone and/or the in-memory registration list was
    /// never cleared. This is exactly the failure mode this whole feature
    /// exists to prevent, and it was previously caused by this very test.
    func testRegisterAndCleanupOwnDeletesFixture() throws {
        let dir = TestFixtureCleanup.root.appendingPathComponent("cleanup-own-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))

        TestFixtureCleanup.register(dir)
        TestFixtureCleanup.cleanupOwn()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.path),
            "cleanupOwn() should delete every URL registered in this process"
        )

        // Prove the mechanism still works after that cleanupOwn() call —
        // not just that the FIRST cleanupOwn() deleted something.
        let secondDir = TestFixtureCleanup.root.appendingPathComponent("cleanup-own-test-second-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: secondDir)
        }

        TestFixtureCleanup.register(secondDir)
        TestFixtureCleanup.cleanupOwn()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: secondDir.path),
            "cleanupOwn() must still actually delete registered fixtures after a prior cleanupOwn() call in the same process"
        )
    }

    /// A manifest belonging to a still-live process must never be reaped,
    /// even though its pid was not this process's own. pid 1 (launchd) is
    /// always running on macOS, so kill(1, 0) is a reliable "alive" probe
    /// (it may return 0, or -1/EPERM since launchd runs as a different
    /// uid — either way the reaper must skip it).
    func testLiveOwnerIsNeverReaped() throws {
        let victimDir = TestFixtureCleanup.root.appendingPathComponent("cleanup-live-owner-victim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: victimDir, withIntermediateDirectories: true)

        let manifestURL = TestFixtureCleanup.root.appendingPathComponent(".ff-test-owner-1")
        defer {
            // Clean up manually: reapDeadOwners() must leave both of these
            // untouched, so nothing else will remove them for us.
            try? FileManager.default.removeItem(at: victimDir)
            try? FileManager.default.removeItem(at: manifestURL)
        }
        try (victimDir.path + "\n").write(to: manifestURL, atomically: true, encoding: .utf8)

        TestFixtureCleanup.reapDeadOwners()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: victimDir.path),
            "A live owner's (pid 1) fixtures must never be reaped"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: manifestURL.path),
            "A live owner's (pid 1) own manifest file must never be reaped either"
        )
    }

    /// A manifest belonging to a confirmed-dead process IS reaped: both
    /// the fixture it listed and the manifest file itself are removed.
    func testDeadOwnerIsReaped() throws {
        let deadPid = try Self.spawnAndWaitForConfirmedDeadPid()

        let victimDir = TestFixtureCleanup.root.appendingPathComponent("cleanup-dead-owner-victim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: victimDir, withIntermediateDirectories: true)
        addTeardownBlock {
            // Reaping is expected to remove this itself; this is only a
            // backstop so a failing assertion above doesn't leak it.
            try? FileManager.default.removeItem(at: victimDir)
        }

        let manifestURL = TestFixtureCleanup.root.appendingPathComponent(".ff-test-owner-\(deadPid)")
        try (victimDir.path + "\n").write(to: manifestURL, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: manifestURL)
        }

        TestFixtureCleanup.reapDeadOwners()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: victimDir.path),
            "A genuinely dead owner's fixtures should be reaped"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: manifestURL.path),
            "A genuinely dead owner's manifest file should be removed"
        )
    }

    /// The path-prefix guard rejects anything outside /tmp/claude (or its
    /// /private/tmp/claude symlink target). The outside path is listed
    /// FIRST in the manifest, deliberately: a guard that bails on the
    /// first bad-ish line instead of skipping and continuing would fail
    /// this test by leaving the later, legitimate victims un-removed.
    func testPathPrefixGuardRejectsOutOfBoundsAndAcceptsBothSpellings() throws {
        let deadPid = try Self.spawnAndWaitForConfirmedDeadPid()

        // (c) A file outside /tmp/claude entirely — must survive untouched.
        let outsideContents = "do-not-touch-\(UUID().uuidString)"
        let outsideURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ff-guard-outside-\(UUID().uuidString).txt")
        try outsideContents.write(to: outsideURL, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: outsideURL)
        }

        // (a) A "victim" spelled via /private/tmp/claude. NOTE: this does
        // NOT actually exercise a distinct code path from (b) below —
        // because this directory is created (i.e. exists on disk) before
        // reapDeadOwners() ever reads the manifest line naming it,
        // resolvingSymlinksInPath() normalizes it back to the plain
        // /tmp/claude spelling before the guard ever sees it (see
        // sanitizedFixtureURL's doc comment), so both (a) and (b) take the
        // identical already-/tmp/claude branch. The /private spelling only
        // ever actually reaches the guard, un-normalized, for a path that
        // does NOT yet exist on disk — and there is nothing to observe by
        // "deleting" a path with nothing behind it, so that case isn't
        // separately asserted here; this victim is kept only as an
        // (untested) extra real fixture under that spelling.
        let privateVictim = URL(fileURLWithPath: "/private/tmp/claude/ff-guard-private-victim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: privateVictim, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: privateVictim)
        }

        // (b) A second real victim spelled via the plain /tmp/claude form.
        let plainVictim = TestFixtureCleanup.root.appendingPathComponent("ff-guard-plain-victim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plainVictim, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: plainVictim)
        }

        // (d) A REAL file physically outside /tmp/claude, referenced only
        // via a `..`-traversal string from within /tmp/claude. This is the
        // actual "out-of-bounds deletion" proof: reapDeadOwners() only
        // ever deletes, never creates, so asserting nothing was CREATED at
        // a traversal target proves nothing about whether the guard's
        // rejection logic engaged — a target that never existed would
        // "survive" identically whether the guard worked or not. This
        // target exists beforehand, so its survival (with unchanged
        // contents) after reaping actually demonstrates the guard rejected
        // the traversal line rather than letting it resolve past
        // /tmp/claude's boundary.
        let traversalContents = "do-not-touch-traversal-\(UUID().uuidString)"
        let traversalTargetURL = TestFixtureCleanup.root
            .deletingLastPathComponent()
            .appendingPathComponent("ff-guard-real-traversal-target-\(UUID().uuidString).txt")
        try traversalContents.write(to: traversalTargetURL, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: traversalTargetURL)
        }
        let traversalLine = "/tmp/claude/../\(traversalTargetURL.lastPathComponent)"

        let manifestContents = [
            outsideURL.path,
            privateVictim.path,
            plainVictim.path,
            traversalLine
        ].joined(separator: "\n") + "\n"

        let manifestURL = TestFixtureCleanup.root.appendingPathComponent(".ff-test-owner-\(deadPid)")
        try manifestContents.write(to: manifestURL, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: manifestURL)
        }

        TestFixtureCleanup.reapDeadOwners()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: privateVictim.path),
            "The /private/tmp/claude-spelled victim should be reaped"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: plainVictim.path),
            "The /tmp/claude-spelled victim should be reaped"
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outsideURL.path),
            "A path outside /tmp/claude must never be touched"
        )
        let survivingContents = try String(contentsOf: outsideURL, encoding: .utf8)
        XCTAssertEqual(survivingContents, outsideContents, "The outside file's contents must be unchanged")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: traversalTargetURL.path),
            "A real file reached only via a `..`-traversal line must never be deleted"
        )
        let survivingTraversalContents = try String(contentsOf: traversalTargetURL, encoding: .utf8)
        XCTAssertEqual(
            survivingTraversalContents,
            traversalContents,
            "The traversal target's contents must be unchanged"
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: manifestURL.path),
            "The manifest should be removed after reaping, even though one of its lines was rejected"
        )
    }

    // MARK: - Helpers

    /// Spawns `/bin/sleep 0` and waits for it to exit, so the returned pid
    /// is confirmed dead (not merely "probably exited").
    private static func spawnAndWaitForConfirmedDeadPid() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0"]
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }
}
