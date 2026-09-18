//
//  RecentProjectsTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//  Regression tests for DocumentManager's recent-projects persistence:
//  dedup-by-path (no duplicates on reopen), save/load round-trip, max-count
//  trimming, and resilience when bookmark resolution fails but the plain
//  path still exists on disk.
//  Uses .serialized trait since DocumentManager.shared is a singleton.
//

import Testing
import Foundation
@testable import final_final

@Suite("Recent Projects — Tier 2: Visible Breakage", .serialized)
struct RecentProjectsTests {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp/claude/RecentProjectsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeDummyProject(named name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("\(name).ff")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @MainActor
    private func resetRecentProjects() {
        TestMode.clearTestState()
        DocumentManager.shared.recentProjects = []
    }

    // MARK: - Dedup

    @Test("Reopening the same project bumps it to the top instead of duplicating")
    @MainActor
    func reopeningSameProjectBumpsToTop() throws {
        resetRecentProjects()
        // These fixtures live under /tmp/claude, which falls under the default
        // `excludedRecentProjectRoots` (system temp) — disable the scratch-path filter for
        // this test's duration so these still-valid regression tests keep exercising real
        // add/save/load behavior instead of being silently filtered. Restored via defer.
        let originalExcludedRoots = DocumentManager.shared.excludedRecentProjectRoots
        // Register the restoring `defer` before the throwing `makeTempDir()` call below —
        // if that call threw before the `defer` was registered, `excludedRecentProjectRoots`
        // would stay disabled (`[]`) on the shared singleton for the rest of the test process.
        defer { DocumentManager.shared.excludedRecentProjectRoots = originalExcludedRoots }
        DocumentManager.shared.excludedRecentProjectRoots = []
        let dir = try makeTempDir()
        defer {
            cleanup(dir)
            resetRecentProjects()
        }

        let urlA = try makeDummyProject(named: "A", in: dir)
        let urlB = try makeDummyProject(named: "B", in: dir)

        DocumentManager.shared.addToRecentProjects(url: urlA, title: "A")
        DocumentManager.shared.addToRecentProjects(url: urlB, title: "B")
        DocumentManager.shared.addToRecentProjects(url: urlA, title: "A")

        let recents = DocumentManager.shared.recentProjects
        #expect(recents.count == 2)
        #expect(recents.first?.title == "A")
        #expect(recents.filter { $0.path == urlA.standardizedFileURL.path }.count == 1)
    }

    // MARK: - Symlink Normalization
    //
    // Regression coverage for the `standardizedFileURL` (here) vs.
    // `resolvingSymlinksInPath()` (DocumentManager's "already open" check) mismatch:
    // the two used different normalization, so a project reachable via a symlinked
    // path compared unequal to itself reached via its real path. Both now go through
    // the shared `URL.normalizedProjectPath` helper.

    @Test("URL.normalizedProjectPath treats a symlinked path and its real path as equal")
    func normalizedProjectPathResolvesSymlinks() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let realURL = try makeDummyProject(named: "Real", in: dir)
        let linkURL = dir.appendingPathComponent("Link.ff")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: realURL)

        // Sanity check that this fixture actually exercises symlink resolution —
        // if these already matched, the test below wouldn't prove anything.
        #expect(realURL.standardizedFileURL.path != linkURL.standardizedFileURL.path)

        #expect(realURL.normalizedProjectPath == linkURL.normalizedProjectPath)
    }

    @Test("Adding a project via its real path and via a symlinked path doesn't duplicate it")
    @MainActor
    func addingViaSymlinkDoesNotDuplicateEntry() throws {
        resetRecentProjects()
        // These fixtures live under /tmp/claude, which falls under the default
        // `excludedRecentProjectRoots` (system temp) — disable the scratch-path filter for
        // this test's duration so these still-valid regression tests keep exercising real
        // add/save/load behavior instead of being silently filtered. Restored via defer.
        let originalExcludedRoots = DocumentManager.shared.excludedRecentProjectRoots
        // Register the restoring `defer` before the throwing `makeTempDir()` call below —
        // if that call threw before the `defer` was registered, `excludedRecentProjectRoots`
        // would stay disabled (`[]`) on the shared singleton for the rest of the test process.
        defer { DocumentManager.shared.excludedRecentProjectRoots = originalExcludedRoots }
        DocumentManager.shared.excludedRecentProjectRoots = []
        let dir = try makeTempDir()
        defer {
            cleanup(dir)
            resetRecentProjects()
        }

        let realURL = try makeDummyProject(named: "Real", in: dir)
        let linkURL = dir.appendingPathComponent("Link.ff")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: realURL)

        DocumentManager.shared.addToRecentProjects(url: realURL, title: "Real")
        DocumentManager.shared.addToRecentProjects(url: linkURL, title: "Real")

        #expect(DocumentManager.shared.recentProjects.count == 1)
    }

    // MARK: - Save/Load Round Trip

    @Test("saveRecentProjects/loadRecentProjects round-trips ordering and content")
    @MainActor
    func saveLoadRoundTrip() throws {
        resetRecentProjects()
        // These fixtures live under /tmp/claude, which falls under the default
        // `excludedRecentProjectRoots` (system temp) — disable the scratch-path filter for
        // this test's duration so these still-valid regression tests keep exercising real
        // add/save/load behavior instead of being silently filtered. Restored via defer.
        let originalExcludedRoots = DocumentManager.shared.excludedRecentProjectRoots
        // Register the restoring `defer` before the throwing `makeTempDir()` call below —
        // if that call threw before the `defer` was registered, `excludedRecentProjectRoots`
        // would stay disabled (`[]`) on the shared singleton for the rest of the test process.
        defer { DocumentManager.shared.excludedRecentProjectRoots = originalExcludedRoots }
        DocumentManager.shared.excludedRecentProjectRoots = []
        let dir = try makeTempDir()
        defer {
            cleanup(dir)
            resetRecentProjects()
        }

        let urlA = try makeDummyProject(named: "A", in: dir)
        let urlB = try makeDummyProject(named: "B", in: dir)
        let urlC = try makeDummyProject(named: "C", in: dir)

        DocumentManager.shared.addToRecentProjects(url: urlA, title: "A")
        DocumentManager.shared.addToRecentProjects(url: urlB, title: "B")
        DocumentManager.shared.addToRecentProjects(url: urlC, title: "C")

        let expectedIds = DocumentManager.shared.recentProjects.map { $0.id }

        DocumentManager.shared.recentProjects = []
        DocumentManager.shared.loadRecentProjects()

        #expect(DocumentManager.shared.recentProjects.map { $0.id } == expectedIds)
        #expect(DocumentManager.shared.recentProjects.map { $0.title } == ["C", "B", "A"])
    }

    // MARK: - Trimming

    @Test("List is trimmed to maxRecentProjects")
    @MainActor
    func trimsToMaxCount() throws {
        resetRecentProjects()
        // These fixtures live under /tmp/claude, which falls under the default
        // `excludedRecentProjectRoots` (system temp) — disable the scratch-path filter for
        // this test's duration so these still-valid regression tests keep exercising real
        // add/save/load behavior instead of being silently filtered. Restored via defer.
        let originalExcludedRoots = DocumentManager.shared.excludedRecentProjectRoots
        // Register the restoring `defer` before the throwing `makeTempDir()` call below —
        // if that call threw before the `defer` was registered, `excludedRecentProjectRoots`
        // would stay disabled (`[]`) on the shared singleton for the rest of the test process.
        defer { DocumentManager.shared.excludedRecentProjectRoots = originalExcludedRoots }
        DocumentManager.shared.excludedRecentProjectRoots = []
        let dir = try makeTempDir()
        defer {
            cleanup(dir)
            resetRecentProjects()
        }

        let max = DocumentManager.shared.maxRecentProjects
        let urls = try (0..<(max + 3)).map { try makeDummyProject(named: "Project\($0)", in: dir) }

        for (index, url) in urls.enumerated() {
            DocumentManager.shared.addToRecentProjects(url: url, title: "Project\(index)")
        }

        #expect(DocumentManager.shared.recentProjects.count == max)
        #expect(DocumentManager.shared.recentProjects.first?.title == "Project\(max + 2)")
    }

    // MARK: - Resilience to Bookmark Failures

    @Test("loadRecentProjects keeps an entry whose bookmark fails but whose path still exists")
    @MainActor
    func keepsEntryWithValidPathButBadBookmark() throws {
        resetRecentProjects()
        // These fixtures live under /tmp/claude, which falls under the default
        // `excludedRecentProjectRoots` (system temp) — disable the scratch-path filter for
        // this test's duration so these still-valid regression tests keep exercising real
        // add/save/load behavior instead of being silently filtered. Restored via defer.
        let originalExcludedRoots = DocumentManager.shared.excludedRecentProjectRoots
        // Register the restoring `defer` before the throwing `makeTempDir()` call below —
        // if that call threw before the `defer` was registered, `excludedRecentProjectRoots`
        // would stay disabled (`[]`) on the shared singleton for the rest of the test process.
        defer { DocumentManager.shared.excludedRecentProjectRoots = originalExcludedRoots }
        DocumentManager.shared.excludedRecentProjectRoots = []
        let dir = try makeTempDir()
        defer {
            cleanup(dir)
            resetRecentProjects()
        }

        let url = try makeDummyProject(named: "StillHere", in: dir)
        let badEntry = DocumentManager.RecentProjectEntry(
            title: "StillHere",
            bookmarkData: Data([0xFF, 0xFF, 0xFF]),
            path: url.standardizedFileURL.path
        )

        DocumentManager.shared.recentProjects = [badEntry]
        DocumentManager.shared.saveRecentProjects()
        DocumentManager.shared.recentProjects = []

        DocumentManager.shared.loadRecentProjects()

        #expect(DocumentManager.shared.recentProjects.count == 1)
        #expect(DocumentManager.shared.recentProjects.first?.title == "StillHere")
    }

    @Test("loadRecentProjects updates a stale path when the project moved but the bookmark still resolves")
    @MainActor
    func updatesStalePathWhenBookmarkResolvesToNewLocation() throws {
        resetRecentProjects()
        // These fixtures live under /tmp/claude, which falls under the default
        // `excludedRecentProjectRoots` (system temp) — disable the scratch-path filter for
        // this test's duration so these still-valid regression tests keep exercising real
        // add/save/load behavior instead of being silently filtered. Restored via defer.
        let originalExcludedRoots = DocumentManager.shared.excludedRecentProjectRoots
        // Register the restoring `defer` before the throwing `makeTempDir()` call below —
        // if that call threw before the `defer` was registered, `excludedRecentProjectRoots`
        // would stay disabled (`[]`) on the shared singleton for the rest of the test process.
        defer { DocumentManager.shared.excludedRecentProjectRoots = originalExcludedRoots }
        DocumentManager.shared.excludedRecentProjectRoots = []
        let dir = try makeTempDir()
        defer {
            cleanup(dir)
            resetRecentProjects()
        }

        let originalURL = try makeDummyProject(named: "Original", in: dir)
        let bookmarkData = try originalURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        // Simulate the project being moved/renamed after the bookmark was saved —
        // the stale `path` no longer points at a real file, but the bookmark
        // itself should still resolve to the new location.
        let movedURL = dir.appendingPathComponent("Renamed.ff")
        try FileManager.default.moveItem(at: originalURL, to: movedURL)

        let staleEntry = DocumentManager.RecentProjectEntry(
            title: "Original",
            bookmarkData: bookmarkData,
            path: originalURL.standardizedFileURL.path
        )

        DocumentManager.shared.recentProjects = [staleEntry]
        DocumentManager.shared.saveRecentProjects()
        DocumentManager.shared.recentProjects = []

        DocumentManager.shared.loadRecentProjects()

        #expect(DocumentManager.shared.recentProjects.count == 1)
        #expect(DocumentManager.shared.recentProjects.first?.path == movedURL.standardizedFileURL.path)
        #expect(DocumentManager.shared.recentProjects.first?.path != originalURL.standardizedFileURL.path)
    }

    // MARK: - Scratch-Path Exclusion
    //
    // Regression coverage for internal dev/scratch `.ff` packages (created by unit/UI tests
    // and other tooling under system temp directories) leaking into the user's real Recent
    // Projects list. These tests deliberately use the DEFAULT `excludedRecentProjectRoots`
    // (unlike the tests above, which override it to `[]`) since they exercise the exclusion
    // itself.

    @Test("addToRecentProjects skips a project under the default excluded (system temp) root")
    @MainActor
    func addToRecentProjectsSkipsScratchRoot() throws {
        resetRecentProjects()
        defer { resetRecentProjects() }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentProjectsScratchTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let scratchURL = try makeDummyProject(named: "Scratch", in: dir)
        DocumentManager.shared.addToRecentProjects(url: scratchURL, title: "Scratch")

        #expect(DocumentManager.shared.recentProjects.isEmpty)
    }

    @Test("loadRecentProjects prunes a previously-persisted entry under an excluded root, and the prune persists")
    @MainActor
    func loadRecentProjectsPrunesScratchEntry() throws {
        resetRecentProjects()
        defer { resetRecentProjects() }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentProjectsScratchLoadTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let scratchURL = try makeDummyProject(named: "Scratch", in: dir)
        let bookmarkData = try scratchURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        // Simulate an entry already persisted (e.g. by a pre-fix build) that bypassed
        // addToRecentProjects's own — also fixed — filter.
        let leakedEntry = DocumentManager.RecentProjectEntry(
            title: "Scratch",
            bookmarkData: bookmarkData,
            path: scratchURL.normalizedProjectPath
        )

        DocumentManager.shared.recentProjects = [leakedEntry]
        DocumentManager.shared.saveRecentProjects()
        DocumentManager.shared.recentProjects = []

        DocumentManager.shared.loadRecentProjects()
        #expect(DocumentManager.shared.recentProjects.isEmpty)

        // Confirm the prune actually persisted (needsResave fired) rather than only
        // filtering in-memory for this one load — the list should self-heal permanently.
        DocumentManager.shared.recentProjects = []
        DocumentManager.shared.loadRecentProjects()
        #expect(DocumentManager.shared.recentProjects.isEmpty)
    }

    @Test("isExcludedFromRecentProjects matches by path component, not raw string prefix")
    @MainActor
    func excludedRootsMatchByComponentNotRawPrefix() throws {
        let originalRoots = DocumentManager.shared.excludedRecentProjectRoots
        defer { DocumentManager.shared.excludedRecentProjectRoots = originalRoots }

        // Real, existing directories — not fabricated non-existent path strings.
        // `resolvingSymlinksInPath()` special-cases well-known system directories (/tmp,
        // /var, /etc) and folds their `/private/...` form back to the convenience form only
        // when the full path actually resolves on disk, so a non-existent leaf under
        // `/private/tmp` behaves inconsistently with a real one. Using real directories here
        // keeps this test about the component-boundary logic under test, not that quirk.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComponentBoundaryTest-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let insideRoot = root.appendingPathComponent("foo.ff", isDirectory: true)
        // Shares the string prefix "root" but is a sibling directory, not a child of `root`
        // — a raw `hasPrefix` string check would wrongly treat it as excluded.
        let siblingWithSharedPrefix = base.appendingPathComponent("rootfoo", isDirectory: true)
        let insideSibling = siblingWithSharedPrefix.appendingPathComponent("bar.ff", isDirectory: true)

        try FileManager.default.createDirectory(at: insideRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: insideSibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        DocumentManager.shared.excludedRecentProjectRoots = [root.path]

        #expect(DocumentManager.shared.isExcludedFromRecentProjects(path: insideRoot.normalizedProjectPath))
        #expect(!DocumentManager.shared.isExcludedFromRecentProjects(path: insideSibling.normalizedProjectPath))
    }

    @Test("isExcludedFromRecentProjects resolves symlinks on both sides before comparing")
    @MainActor
    func excludedRootsResolveSymlinksBeforeComparing() throws {
        let originalRoots = DocumentManager.shared.excludedRecentProjectRoots
        defer { DocumentManager.shared.excludedRecentProjectRoots = originalRoots }

        // `FileManager.default.temporaryDirectory` returns the unresolved `/var/folders/...`
        // form; `normalizedProjectPath` (and hence any real stored Recent Projects path)
        // resolves symlinks, landing on `/private/var/folders/...` instead. An unresolved
        // root must still match a resolved candidate.
        DocumentManager.shared.excludedRecentProjectRoots = [FileManager.default.temporaryDirectory.path]

        let resolvedCandidate = FileManager.default.temporaryDirectory
            .appendingPathComponent("some-project.ff")
            .resolvingSymlinksInPath()
            .path

        #expect(DocumentManager.shared.isExcludedFromRecentProjects(path: resolvedCandidate))
    }
}
