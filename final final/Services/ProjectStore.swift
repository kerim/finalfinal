//
//  ProjectStore.swift
//  final final
//

import Foundation
import GRDB

@MainActor
@Observable
final class ProjectStore {
    // MARK: - Published State

    private(set) var project: Project?
    private(set) var content: Content?
    private(set) var outlineNodes: [OutlineNode] = []
    private(set) var isLoading = false
    private(set) var error: Error?

    // MARK: - Private State

    private var database: ProjectDatabase?
    private var observationTask: Task<Void, Never>?

    // MARK: - Lifecycle

    /// Opens a project from an existing .ff package
    func open(package: ProjectPackage) async throws {
        isLoading = true
        error = nil

        do {
            database = try ProjectDatabase(package: package)
            project = try database?.fetchProject()

            if let projectId = project?.id {
                content = try database?.fetchContent(for: projectId)
                outlineNodes = try database?.fetchOutlineNodes(for: projectId) ?? []
            }

            startObserving()
            isLoading = false
            print("[ProjectStore] Opened project: \(project?.title ?? "unknown")")
        } catch {
            self.error = error
            isLoading = false
            throw error
        }
    }

    /// Creates a new project
    func createNew(at url: URL, title: String) async throws {
        isLoading = true
        error = nil

        do {
            let package = try ProjectPackage.create(at: url, title: title)
            database = try ProjectDatabase.create(package: package, title: title)
            project = try database?.fetchProject()

            if let projectId = project?.id {
                content = try database?.fetchContent(for: projectId)
            }

            outlineNodes = []
            startObserving()
            isLoading = false
            print("[ProjectStore] Created project: \(title)")
        } catch {
            self.error = error
            isLoading = false
            throw error
        }
    }

    /// Closes the current project
    func close() {
        observationTask?.cancel()
        observationTask = nil
        database = nil
        project = nil
        content = nil
        outlineNodes = []
        error = nil
        print("[ProjectStore] Closed project")
    }

    // MARK: - Content Operations

    /// Updates the markdown content (triggers outline rebuild)
    func updateContent(_ markdown: String) async throws {
        guard let projectId = project?.id else {
            throw ProjectStoreError.noProjectOpen
        }

        // Update local state immediately for responsive UI
        content?.markdown = markdown
        content?.updatedAt = Date()

        // Perform database write off main thread
        let db = database
        try await Task.detached {
            try db?.saveContent(markdown: markdown, for: projectId)
        }.value
    }

    // MARK: - Observation

    private func startObserving() {
        guard let db = database, let projectId = project?.id else { return }

        observationTask?.cancel()
        observationTask = Task { [weak self] in
            let observation = ValueObservation.tracking { database in
                try OutlineNode
                    .filter(Column("projectId") == projectId)
                    .order(Column("sortOrder"))
                    .fetchAll(database)
            }

            do {
                for try await nodes in observation.values(in: db.dbWriter) {
                    guard let self, !Task.isCancelled else { return }
                    self.outlineNodes = nodes
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.error = error
            }
        }
    }

    // MARK: - Errors

    enum ProjectStoreError: Error, LocalizedError {
        case noProjectOpen

        var errorDescription: String? {
            switch self {
            case .noProjectOpen: return "No project is currently open"
            }
        }
    }
}
