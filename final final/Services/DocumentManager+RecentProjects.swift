//
//  DocumentManager+RecentProjects.swift
//  final final
//

import Foundation

// MARK: - Recent Projects

extension DocumentManager {

    /// Entry for a recent project with bookmark data
    struct RecentProjectEntry: Codable, Identifiable {
        let id: String
        var title: String
        var bookmarkData: Data
        var lastOpenedAt: Date

        init(id: String = UUID().uuidString, title: String, bookmarkData: Data, lastOpenedAt: Date = Date()) {
            self.id = id
            self.title = title
            self.bookmarkData = bookmarkData
            self.lastOpenedAt = lastOpenedAt
        }
    }

    /// Add a project to the recent projects list
    func addToRecentProjects(url: URL, title: String) {
        do {
            // Create security-scoped bookmark
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            // Check if already in list
            if let existingIndex = recentProjects.firstIndex(where: { entry in
                resolveBookmark(entry.bookmarkData)?.path == url.path
            }) {
                // Update existing entry
                var entry = recentProjects[existingIndex]
                entry.title = title
                entry.lastOpenedAt = Date()
                entry.bookmarkData = bookmarkData
                recentProjects.remove(at: existingIndex)
                recentProjects.insert(entry, at: 0)
            } else {
                // Add new entry
                let entry = RecentProjectEntry(title: title, bookmarkData: bookmarkData)
                recentProjects.insert(entry, at: 0)

                // Trim to max size
                if recentProjects.count > maxRecentProjects {
                    recentProjects = Array(recentProjects.prefix(maxRecentProjects))
                }
            }

            saveRecentProjects()
        } catch {
            print("[DocumentManager] Failed to create bookmark for \(url.path): \(error)")
        }
    }

    /// Remove a project from the recent projects list
    func removeFromRecentProjects(_ entry: RecentProjectEntry) {
        recentProjects.removeAll { $0.id == entry.id }
        saveRecentProjects()
    }

    /// Clear all recent projects
    func clearRecentProjects() {
        recentProjects.removeAll()
        saveRecentProjects()
    }

    /// Resolve a bookmark to a URL (starting security-scoped access)
    func resolveBookmark(_ bookmarkData: Data) -> URL? {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                print("[DocumentManager] Bookmark is stale, may need refresh")
            }

            return url
        } catch {
            print("[DocumentManager] Failed to resolve bookmark: \(error)")
            return nil
        }
    }

    /// Open a recent project by entry
    @discardableResult
    func openRecentProject(_ entry: RecentProjectEntry) throws -> String {
        guard let url = resolveBookmark(entry.bookmarkData) else {
            throw DocumentError.bookmarkResolutionFailed
        }

        // Start security-scoped access
        guard url.startAccessingSecurityScopedResource() else {
            throw DocumentError.securityScopedAccessDenied
        }

        defer {
            // Note: We keep access open while project is open
            // Access is stopped when project is closed
        }

        return try openProject(at: url)
    }

    // MARK: - Last Project Persistence

    /// Stored bookmark data for the last opened project
    var lastProjectBookmark: Data? {
        get { UserDefaults.standard.data(forKey: lastProjectBookmarkKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastProjectBookmarkKey) }
    }

    /// Save a project URL as the last opened project (for restore on launch)
    func saveAsLastProject(url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            lastProjectBookmark = bookmarkData
        } catch {
            print("[DocumentManager] Failed to save last project bookmark: \(error)")
        }
    }

    /// Attempt to restore the last opened project
    /// - Returns: true if a project was successfully restored
    /// - Throws: DocumentError if bookmark resolution or project opening fails
    func restoreLastProject() throws -> Bool {
        guard let bookmarkData = lastProjectBookmark else { return false }

        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        guard url.startAccessingSecurityScopedResource() else {
            throw DocumentError.securityScopedAccessDenied
        }

        // Must stop access on any error path
        do {
            guard FileManager.default.fileExists(atPath: url.path) else {
                url.stopAccessingSecurityScopedResource()
                lastProjectBookmark = nil
                throw DocumentError.bookmarkResolutionFailed
            }

            try openProject(at: url)

            // Regenerate stale bookmark with fresh data
            if isStale {
                saveAsLastProject(url: url)
            }

            // Note: openProject now owns the security scope
            return true
        } catch {
            url.stopAccessingSecurityScopedResource()
            throw error
        }
    }

    // MARK: - Recent Projects Persistence

    func loadRecentProjects() {
        guard let data = UserDefaults.standard.data(forKey: recentProjectsKey) else {
            recentProjects = []
            return
        }

        do {
            recentProjects = try JSONDecoder().decode([RecentProjectEntry].self, from: data)
            // Validate bookmarks on load
            recentProjects = recentProjects.filter { entry in
                resolveBookmark(entry.bookmarkData) != nil
            }
        } catch {
            print("[DocumentManager] Failed to load recent projects: \(error)")
            recentProjects = []
        }
    }

    func saveRecentProjects() {
        do {
            let data = try JSONEncoder().encode(recentProjects)
            UserDefaults.standard.set(data, forKey: recentProjectsKey)
        } catch {
            print("[DocumentManager] Failed to save recent projects: \(error)")
        }
    }
}
