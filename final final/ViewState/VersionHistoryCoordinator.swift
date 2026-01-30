//
//  VersionHistoryCoordinator.swift
//  final final
//
//  Coordinator for version history window that captures state at open time.
//  This avoids race conditions where the user might switch projects between
//  opening the window and rendering.
//

import SwiftUI

/// Coordinator that captures database state when version history window opens
@Observable
@MainActor
final class VersionHistoryCoordinator {
    /// Database reference captured at open time
    var database: ProjectDatabase?

    /// Project ID captured at open time
    var projectId: String?

    /// Current sections captured at open time (for comparison column)
    var currentSections: [SectionViewModel] = []

    /// Whether the version history window is active
    var isActive: Bool = false

    /// Prepare state before opening the window
    /// Call this before `openWindow(id: "version-history")`
    func prepareForOpen(database: ProjectDatabase, projectId: String, sections: [SectionViewModel]) {
        self.database = database
        self.projectId = projectId
        self.currentSections = sections
        self.isActive = true
    }

    /// Called when the window is closed
    func close() {
        self.isActive = false
    }

    /// Clear all captured state
    func reset() {
        database = nil
        projectId = nil
        currentSections = []
        isActive = false
    }
}
