//
//  TestFixtureCleanup.swift
//  final finalTests
//
//  Per-process ownership manifests for throwaway .ff test fixtures created
//  under /tmp/claude/. Unit tests create UUID-suffixed .ff packages and
//  historically never deleted them — 31,464 leftovers (7.3 GB) were found
//  and deleted by hand on 2026-08-26.
//
//  Mechanism: every test process claims a manifest file
//  (/tmp/claude/.ff-test-owner-<pid>) listing every fixture path it
//  registers. On normal exit it deletes everything it registered and
//  leaves behind an empty manifest file, swept by the next process's
//  dead-owner reap. On startup, before claiming its own manifest, it reaps
//  manifests left behind by processes that are no longer running (crash,
//  force-kill, timeout) — deleting the fixtures they list and the manifest
//  itself. A manifest belonging to a still-live process (or one owned by a
//  different uid) is never touched.
//
//  Normal-exit cleanup is triggered by `testBundleDidFinish(_:)`
//  (XCTestObservation), NOT `atexit`. `atexit` fires at raw process
//  shutdown, by which point a batch delete of potentially hundreds of
//  fixture directories can race a `ProjectDatabase`/GRDB connection that
//  hasn't been released yet (Swift gives no ordering guarantee for
//  synchronous deinit at process exit) — deleting a package whose SQLite
//  WAL/SHM files are still memory-mapped by a live connection is exactly
//  what trips SQLite's "vnode unlinked while in use" API-violation warning
//  (see FixtureGeneratorTests.swift for the same hazard on a single
//  fixture). `testBundleDidFinish` fires once per test bundle run, inside
//  the test process, after XCTest has already torn down every test case —
//  later than `atexit`, giving per-test references more of a chance to
//  have been released first. It is still process-scoped (this project's
//  test targets run `parallelizable: false`, i.e. one process per bundle
//  run), so this is a strict improvement in timing, not a change in when
//  cleanup normally happens relative to the process lifecycle. A process
//  that crashes or is force-killed still never runs `testBundleDidFinish`
//  — exactly as it never ran `atexit` in that case either — so
//  `reapDeadOwners()` below remains the sole recovery path for that case.
//
//  `test-fixture.ff` and `test-fixture-rich.ff` (the committed, reused
//  fixtures under final finalTests/Fixtures/) are never registered — see
//  the `register: false` call sites in FixtureGeneratorTests.swift.
//

import Foundation
import Darwin
import XCTest

/// Registered with `XCTestObservationCenter` from `TestFixtureCleanup.bootstrap`
/// so that `TestFixtureCleanup.cleanupOwn()` runs once, at the end of the test
/// bundle's run — see the header comment above for why this replaced `atexit`.
final class TestFixtureCleanupObserver: NSObject, XCTestObservation {
    func testBundleDidFinish(_ testBundle: Bundle) {
        TestFixtureCleanup.cleanupOwn()
    }
}

enum TestFixtureCleanup {

    /// Root directory all managed fixtures and manifest files live under.
    static let root = URL(fileURLWithPath: "/tmp/claude")

    private static let lock = NSLock()
    private static var registeredPaths: [URL] = []

    private static let manifestFilenamePrefix = ".ff-test-owner-"

    /// One-shot per-process bootstrap. Reaps dead owners' leftovers FIRST,
    /// then claims (creates/truncates) this process's own manifest, then
    /// registers the `testBundleDidFinish` observer that triggers normal-exit
    /// cleanup (see the header comment for why this isn't `atexit`).
    ///
    /// Ordering matters: if pid recycling handed this process a manifest
    /// filename left behind by a dead process with the same pid, and we
    /// truncated it before reaping, that dead process's fixtures would be
    /// unlinked from every record and leak permanently — exactly the
    /// failure this feature exists to prevent. Reap first, always.
    private static let bootstrap: Void = {
        // On a freshly-swept machine /tmp/claude may not exist yet — create
        // it before claiming a manifest inside it. This is one-shot, so if
        // it's skipped here it never runs again for this process.
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        reapDeadOwners()

        claimOwnManifest()

        XCTestObservationCenter.shared.addTestObserver(TestFixtureCleanupObserver())
    }()

    /// Registers a fixture URL for cleanup — either by this process at
    /// normal exit, or by a future process's reaper if this process dies
    /// first without running its own cleanup.
    static func register(_ url: URL) {
        _ = bootstrap

        // Same guard reapDeadOwners() applies on the way out: never accept
        // a URL that doesn't resolve under /tmp/claude (or its
        // /private/tmp/claude symlink target) into the manifest. Every real
        // call site today is already inside /tmp/claude, so this is not
        // expected to change any existing behavior.
        guard sanitizedFixtureURL(forRawPath: url.path) != nil else { return }

        lock.lock()
        defer { lock.unlock() }

        registeredPaths.append(url)

        guard let handle = try? FileHandle(forWritingTo: ownManifestURL) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        if let data = (url.path + "\n").data(using: .utf8) {
            try? handle.write(contentsOf: data)
            try? handle.synchronize()
        }
    }

    /// Removes every URL this process registered, then removes this
    /// process's own manifest file. Already-gone paths are the normal
    /// case (many call sites already remove their own directory via their
    /// own `defer` before `testBundleDidFinish` ever runs) — `try?` treats
    /// that as success, not an error. Called automatically at the end of
    /// the test bundle's run (see `TestFixtureCleanupObserver` above); safe
    /// to call directly as well.
    ///
    /// Leaves the mechanism in a working state afterward: the in-memory
    /// list is cleared and a fresh manifest is re-claimed, so a `register()`
    /// call right after this one still has somewhere to write. Without
    /// this, calling `cleanupOwn()` mid-process (as a test does) would
    /// silently disable crash protection for the rest of the process —
    /// every later `register()` would find the manifest gone and no-op.
    static func cleanupOwn() {
        lock.lock()
        let paths = registeredPaths
        registeredPaths = []
        lock.unlock()

        for url in paths {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: ownManifestURL)

        claimOwnManifest()
    }

    /// Scans `/tmp/claude/.ff-test-owner-*` for manifests belonging to
    /// processes that are no longer running, removes every fixture path
    /// they list (subject to the path-prefix guard), then removes the
    /// manifest file itself.
    ///
    /// A manifest whose pid is still alive (`kill(pid, 0) == 0`) or alive
    /// under a different uid (`errno == EPERM`) is left completely
    /// untouched. Only `errno == ESRCH` (no such process) triggers reaping.
    static func reapDeadOwners() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        let ownPid = getpid()

        for manifestURL in entries {
            let filename = manifestURL.lastPathComponent
            guard filename.hasPrefix(manifestFilenamePrefix) else { continue }

            let pidString = filename.dropFirst(manifestFilenamePrefix.count)
            guard let pid = Int32(pidString), pid > 0, pid != ownPid else { continue }
            // pid > 0 above matters: kill(0, _) targets the whole process
            // group and kill(-1, _) targets every process this uid can
            // signal — harmless with signal 0, but an unintended path to
            // reach for while scanning a world-writable directory whose
            // filenames aren't otherwise validated.

            let killResult = kill(pid, 0)
            if killResult == 0 {
                // Alive — never touch.
                continue
            }
            guard errno == ESRCH else {
                // EPERM (alive, different uid) or any other unexpected
                // errno: skip, don't touch.
                continue
            }

            // Confirmed dead. Read its manifest and remove what it listed.
            // The manifest could vanish mid-read if another process is
            // concurrently reaping the same dead owner — tolerate that and
            // move on rather than treating it as an error.
            guard let contents = try? String(contentsOf: manifestURL, encoding: .utf8) else {
                continue
            }

            for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
                if let safeURL = sanitizedFixtureURL(forRawPath: String(line)) {
                    try? fm.removeItem(at: safeURL)
                }
            }

            try? fm.removeItem(at: manifestURL)
        }
    }

    // MARK: - Private helpers

    private static var ownManifestURL: URL {
        root.appendingPathComponent("\(manifestFilenamePrefix)\(getpid())")
    }

    /// Creates (or truncates) this process's own manifest file. Shared by
    /// `bootstrap` and `cleanupOwn()` — cleanupOwn() re-runs this so a
    /// `register()` call right after it still has a manifest to write to.
    ///
    /// Truncate-on-claim is deliberate, not append: pid recycling can hand
    /// a fresh process a manifest filename left behind by a dead process
    /// with the same pid, and truncating starts clean rather than
    /// inheriting ambiguous stale entries. The Bool return is discarded
    /// deliberately — a failure here just means the next `register()` call
    /// will also fail its own `FileHandle(forWritingTo:)` open and no-op,
    /// which is the existing degraded-but-safe behavior.
    private static func claimOwnManifest() {
        FileManager.default.createFile(atPath: ownManifestURL.path, contents: nil)
    }

    /// Path-prefix guard used on every manifest line before removal, and on
    /// every URL passed to `register()`.
    ///
    /// Resolves the line's path and only returns it if the result begins
    /// with `/tmp/claude/` or `/private/tmp/claude/` — macOS symlinks
    /// `/tmp` to `/private/tmp`, and `resolvingSymlinksInPath()` strips a
    /// leading `/private` back down to the plain `/tmp` spelling, but ONLY
    /// for a path that already exists on disk; for a path that does not
    /// exist, the string is returned exactly as spelled, `/private` prefix
    /// and all. So the `/private/tmp/claude/...` spelling is only ever
    /// actually reachable here for a path that doesn't exist yet (e.g. one
    /// already deleted, or a bogus/traversal line) — both spellings must
    /// still be accepted, or this guard would reject those. Anything that
    /// doesn't satisfy this (including a `..`-traversal line) is rejected
    /// silently: never acted on, never crashes.
    private static func sanitizedFixtureURL(forRawPath rawPath: String) -> URL? {
        guard !rawPath.isEmpty else { return nil }

        let resolved = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath()
        let path = resolved.path

        for allowedPrefix in ["/tmp/claude/", "/private/tmp/claude/"] {
            if path.hasPrefix(allowedPrefix) {
                return resolved
            }
        }
        return nil
    }
}
