//
//  ProjectLifecycleTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//  Tests for DocumentManager: new, open, close, and basic project lifecycle.
//  Uses .serialized trait since DocumentManager.shared is a singleton.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Project Lifecycle — Tier 2: Visible Breakage", .serialized)
struct ProjectLifecycleTests {

    // MARK: - Helpers

    @MainActor
    private func cleanUp() {
        DocumentManager.shared.closeProject()
    }

    private func tempProjectURL() -> URL {
        let url = URL(fileURLWithPath: "/tmp/claude/project-lifecycle-\(UUID().uuidString).ff")
        TestFixtureCleanup.register(url)
        return url
    }

    // MARK: - New Project

    @Test("newProject creates valid .ff package with expected structure")
    @MainActor
    func newProjectCreatesPackage() throws {
        TestMode.clearTestState()

        let url = tempProjectURL()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(url) }
        let projectId = try DocumentManager.shared.newProject(at: url, title: "Test Project")

        #expect(!projectId.isEmpty)
        #expect(DocumentManager.shared.hasOpenProject)
        #expect(DocumentManager.shared.projectTitle == "Test Project")

        // Verify file structure
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: url.path), ".ff package should exist")
        #expect(fm.fileExists(atPath: url.appendingPathComponent("content.sqlite").path),
                "content.sqlite should exist inside package")
    }

    // MARK: - Open Project

    @Test("openProject loads fixture, hasOpenProject is true")
    @MainActor
    func openProjectLoadsFixture() throws {
        TestMode.clearTestState()

        // Create a fixture first
        let url = tempProjectURL()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(url) }
        _ = try TestFixtureFactory.createFixture(at: url, title: "Open Test")

        let projectId = try DocumentManager.shared.openProject(at: url)

        #expect(!projectId.isEmpty)
        #expect(DocumentManager.shared.hasOpenProject)
        #expect(DocumentManager.shared.projectURL?.lastPathComponent == url.lastPathComponent)
    }

    // MARK: - Close Project

    @Test("closeProject clears state, hasOpenProject is false")
    @MainActor
    func closeProjectClearsState() throws {
        TestMode.clearTestState()

        let url = tempProjectURL()
        _ = try DocumentManager.shared.newProject(at: url, title: "Close Test")
        #expect(DocumentManager.shared.hasOpenProject)
        // Captured before closeProject() below drops DocumentManager's own reference,
        // so the connection can still be closed explicitly (deterministically) rather
        // than left to whenever ARC happens to deinit it.
        let db = try #require(DocumentManager.shared.projectDatabase)
        defer { TestDatabaseTeardown.closeThenCleanUp(url, db) }

        DocumentManager.shared.closeProject()

        #expect(!DocumentManager.shared.hasOpenProject)
        #expect(DocumentManager.shared.projectDatabase == nil)
        #expect(DocumentManager.shared.projectId == nil)
        #expect(DocumentManager.shared.projectTitle == nil)
        #expect(DocumentManager.shared.projectURL == nil)
    }

    // MARK: - Error Handling

    @Test("Opening nonexistent path throws error gracefully")
    @MainActor
    func openNonexistentPathThrows() throws {
        TestMode.clearTestState()
        defer { cleanUp() }

        let badURL = URL(fileURLWithPath: "/tmp/claude/does-not-exist-\(UUID().uuidString).ff")

        #expect(throws: Error.self) {
            try DocumentManager.shared.openProject(at: badURL)
        }
    }

    // MARK: - Save As (Manual Checkpoint + Copy)

    @Test("Copy project package creates independently openable copy")
    @MainActor
    func copyProjectPackage() throws {
        TestMode.clearTestState()

        // Create original project
        let originalURL = tempProjectURL()
        defer { try? FileManager.default.removeItem(at: originalURL) }
        _ = try DocumentManager.shared.newProject(at: originalURL, title: "Original")

        // Capture the original database's reference before closeProject() drops it,
        // then close that captured reference explicitly (deterministically) so the
        // WAL is flushed and the pool is fully closed before we copy the package --
        // closeProject() alone only drops DocumentManager's own reference and leaves
        // the actual close to whenever ARC happens to deinit it, which the plain
        // removeItem in the defer above can otherwise race.
        let originalDb = try #require(DocumentManager.shared.projectDatabase)
        DocumentManager.shared.closeProject()
        TestDatabaseTeardown.close(originalDb.dbWriter)

        // Copy the package
        let copyURL = tempProjectURL()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(copyURL) }
        try FileManager.default.copyItem(at: originalURL, to: copyURL)

        // Verify copy is independently openable
        let copyId = try DocumentManager.shared.openProject(at: copyURL)
        #expect(!copyId.isEmpty)
        #expect(DocumentManager.shared.hasOpenProject)

        // Verify content integrity
        let content = try DocumentManager.shared.loadContent()
        #expect(content != nil, "Copied project should have content")
    }

    // MARK: - Content Operations

    @Test("loadContent returns content after newProject")
    @MainActor
    func loadContentAfterNew() throws {
        TestMode.clearTestState()

        let url = tempProjectURL()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(url) }
        _ = try DocumentManager.shared.newProject(at: url, title: "Content Test", initialContent: "# Hello\n\nWorld.")

        let content = try DocumentManager.shared.loadContent()
        #expect(content != nil)
        #expect(content?.contains("Hello") == true)
    }
}
