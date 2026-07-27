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
        var path: String

        init(id: String = UUID().uuidString, title: String, bookmarkData: Data, lastOpenedAt: Date = Date(), path: String) {
            self.id = id
            self.title = title
            self.bookmarkData = bookmarkData
            self.lastOpenedAt = lastOpenedAt
            self.path = path
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, bookmarkData, lastOpenedAt, path
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            bookmarkData = try container.decode(Data.self, forKey: .bookmarkData)
            lastOpenedAt = try container.decode(Date.self, forKey: .lastOpenedAt)
            // Entries persisted before `path` was introduced won't have this key.
            path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
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
            let path = url.normalizedProjectPath

            // Check if already in list — compare plain paths, not resolved bookmarks,
            // so a transient bookmark-resolution hiccup can't cause a duplicate entry.
            if let existingIndex = recentProjects.firstIndex(where: { $0.path == path }) {
                // Update existing entry
                var entry = recentProjects[existingIndex]
                entry.title = title
                entry.lastOpenedAt = Date()
                entry.bookmarkData = bookmarkData
                entry.path = path
                recentProjects.remove(at: existingIndex)
                recentProjects.insert(entry, at: 0)
            } else {
                // Add new entry
                let entry = RecentProjectEntry(title: title, bookmarkData: bookmarkData, path: path)
                recentProjects.insert(entry, at: 0)

                // Trim to max size
                if recentProjects.count > maxRecentProjects {
                    recentProjects = Array(recentProjects.prefix(maxRecentProjects))
                }
            }

            saveRecentProjects()
        } catch {
            DebugLog.log(.lifecycle, "[DocumentManager] Failed to create bookmark for \(url.path): \(error)")
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
                DebugLog.log(.lifecycle, "[DocumentManager] Bookmark is stale, may need refresh")
            }

            return url
        } catch {
            DebugLog.log(.lifecycle, "[DocumentManager] Failed to resolve bookmark: \(error)")
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
            DebugLog.log(.lifecycle, "[DocumentManager] Failed to save last project bookmark: \(error)")
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
            let decodedEntries = try JSONDecoder().decode([RecentProjectEntry].self, from: data)
            var needsResave = false

            let processedEntries: [RecentProjectEntry] = decodedEntries.compactMap { decodedEntry in
                var entry = decodedEntry
                var resolvedURL: URL?

                // Migration: backfill `path` for entries persisted before it existed.
                if entry.path.isEmpty {
                    resolvedURL = resolveBookmark(entry.bookmarkData)
                    if let resolvedURL {
                        entry.path = resolvedURL.normalizedProjectPath
                        needsResave = true
                    }
                }

                // Cheap check first — no security-scope access needed.
                if FileManager.default.fileExists(atPath: entry.path) {
                    return entry
                }

                // Fall back to bookmark resolution (reuse the result above if we already tried).
                if resolvedURL == nil {
                    resolvedURL = resolveBookmark(entry.bookmarkData)
                }

                guard let resolvedURL else {
                    DebugLog.log(.lifecycle, "[DocumentManager] Dropping recent project '\(entry.title)' (path: \(entry.path)): file missing and bookmark failed to resolve")
                    return nil
                }

                // fileExists failed but the bookmark still resolved (e.g. the project
                // was moved or renamed since this entry was saved) — update the stored
                // path to the new location so future dedup doesn't compare against a
                // permanently stale path.
                entry.path = resolvedURL.normalizedProjectPath
                needsResave = true

                return entry
            }

            // Clean up duplicate entries (same path) that may have accumulated before
            // this fix landed. The list is already ordered most-recent-first, so
            // keeping the first occurrence per path keeps the most-recently-opened one.
            var seenPaths = Set<String>()
            let dedupedEntries = processedEntries.filter { seenPaths.insert($0.path).inserted }
            if dedupedEntries.count != processedEntries.count {
                needsResave = true
            }
            recentProjects = dedupedEntries

            if needsResave {
                saveRecentProjects()
            }
        } catch {
            DebugLog.log(.lifecycle, "[DocumentManager] Failed to load recent projects: \(error)")
            recentProjects = []
        }
    }

    func saveRecentProjects() {
        do {
            let data = try JSONEncoder().encode(recentProjects)
            UserDefaults.standard.set(data, forKey: recentProjectsKey)
        } catch {
            DebugLog.log(.lifecycle, "[DocumentManager] Failed to save recent projects: \(error)")
        }
    }
}
