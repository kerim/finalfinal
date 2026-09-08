//
//  ProjectOpenErrorState.swift
//  final final
//
//  The single funnel every project-open failure routes into, and the shared,
//  stored state a single always-mounted host (ProjectOpenErrorHost.swift) renders
//  from. Storing the failure -- instead of posting it as a NotificationCenter event
//  -- is deliberate: some call sites (FinalFinalApp.determineInitialState(), which
//  runs from the .task on rootView before any view is mounted) fire before any
//  subscriber could possibly exist yet. A stored value has no such ordering
//  requirement; whichever view mounts first simply reads it.
//

import Foundation

/// What went wrong when a project failed to open.
enum ProjectOpenFailure: Identifiable {
    case integrity(report: IntegrityReport, url: URL)
    case other(message: String, url: URL)

    /// Derived from the failing project's URL alone -- not the case, not the
    /// report's issue list -- so any update that's still fundamentally "the
    /// current failure for this file" (a Repair pass revealing a new, still-broken
    /// report, or a Repair/Open Anyway attempt failing and switching from the
    /// integrity view to a plain error message) updates the sheet's content in
    /// place rather than dismissing and re-presenting it. `.sheet(item:)` only
    /// treats an update as a new presentation when `id` itself changes.
    var id: String {
        switch self {
        case .integrity(_, let url): url.path
        case .other(_, let url): url.path
        }
    }
}

@MainActor
@Observable
final class ProjectOpenErrorState {
    static let shared = ProjectOpenErrorState()

    /// Not private: lets a future test construct an isolated instance instead of
    /// sharing the app-wide singleton. No other behavior change.
    init() {}

    /// The failure to show, if any. Settable: ProjectOpenErrorHost binds two-way
    /// to this so a SwiftUI-initiated dismiss (Escape, sheet drag) clears it too,
    /// not just the explicit Cancel/OK button paths.
    var pending: ProjectOpenFailure?

    /// The single funnel every project-open failure (Finder double-click, File >
    /// Open, File > Open Recent, and the launch-time restore path) routes into.
    func report(_ error: Error, url: URL) {
        DebugLog.log(.lifecycle, "[ProjectOpenError] \(url.lastPathComponent): \(error)")
        if let report = (error as? IntegrityError)?.integrityReport {
            pending = .integrity(report: report, url: url)
        } else {
            pending = .other(message: error.localizedDescription, url: url)
        }
    }

    func clear() {
        pending = nil
    }
}
