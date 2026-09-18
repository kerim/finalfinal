//
//  SplitViewAutosaveNaming.swift
//  final final
//
//  Attempts to assign a stable AppKit autosave name to the NSSplitView backing
//  ContentView's NavigationSplitView, so the sidebar divider position persists under a name
//  this app controls rather than a SwiftUI-derived one. There is no SwiftUI-level
//  `navigationSplitViewColumnWidth`/persistence API and no other `NSSplitView` reference in
//  the codebase — the AppKit-level `NSSplitView.autosaveName` is the only thing actually
//  saving the divider position (see ContentView.swift's `NavigationSplitView(columnVisibility:)`).
//
//  Whether this stabilization actually "sticks" (survives SwiftUI re-asserting its own derived
//  name) is verified empirically at call sites, not assumed. Regardless of outcome,
//  `currentTopLevelAutosaveName(in:)` reads the LIVE name off the object, so the autosave-key
//  sweep (`AppDelegate+AutosaveKeyTracking.swift`) stays correct whether or not stabilization
//  held.
//

import AppKit

enum SplitViewAutosaveNaming {
    static let stableName = "final-final.mainSplitView"

    /// Walks `window`'s content view tree and returns every `NSSplitView` found, each paired
    /// with whether it has an `NSSplitView` ancestor (i.e. is nested inside another split view,
    /// as opposed to being a top-level one).
    static func allSplitViews(in window: NSWindow) -> [(splitView: NSSplitView, hasSplitViewAncestor: Bool)] {
        guard let contentView = window.contentView else { return [] }
        var results: [(NSSplitView, Bool)] = []
        walk(contentView, hasSplitViewAncestor: false, results: &results)
        return results
    }

    private static func walk(_ view: NSView, hasSplitViewAncestor: Bool, results: inout [(NSSplitView, Bool)]) {
        if let splitView = view as? NSSplitView {
            results.append((splitView, hasSplitViewAncestor))
            for subview in view.subviews {
                walk(subview, hasSplitViewAncestor: true, results: &results)
            }
            return
        }
        for subview in view.subviews {
            walk(subview, hasSplitViewAncestor: hasSplitViewAncestor, results: &results)
        }
    }

    /// The outermost (no-`NSSplitView`-ancestor) split view's *current* `autosaveName`, as
    /// actually read off the live object right now — `stableName` if `stabilize(for:)` ran and
    /// held, or SwiftUI's own derived name if it didn't (or hasn't run/found the tree yet).
    /// `nil` if no window/content view/split view is available yet, or if more than one
    /// top-level split view is found (ambiguous — same refusal condition as `stabilize`).
    static func currentTopLevelAutosaveName(in window: NSWindow) -> String? {
        let topLevel = allSplitViews(in: window).filter { !$0.hasSplitViewAncestor }
        guard topLevel.count == 1, let name = topLevel[0].splitView.autosaveName, !name.isEmpty else {
            return nil
        }
        return name
    }

    /// Sets `autosaveName` on the single top-level split view found in `window`'s tree, so the
    /// sidebar divider position persists under a name this app controls. No-ops (and logs) if
    /// the count of top-level split views isn't exactly 1 — this is a stabilization attempt,
    /// not a guaranteed assignment.
    static func stabilize(for window: NSWindow) {
        let all = allSplitViews(in: window)
        let topLevel = all.filter { !$0.hasSplitViewAncestor }

        DebugLog.log(
            .lifecycle,
            "[SplitViewAutosaveNaming] Found \(all.count) NSSplitView(s) total, "
                + "\(topLevel.count) top-level; names: \(all.map { $0.splitView.autosaveName ?? "nil" })"
        )

        guard topLevel.count == 1 else {
            DebugLog.log(
                .lifecycle,
                "[SplitViewAutosaveNaming] Expected exactly 1 top-level split view, found \(topLevel.count) — not assigning"
            )
            return
        }

        topLevel[0].splitView.autosaveName = stableName
        DebugLog.log(.lifecycle, "[SplitViewAutosaveNaming] Set autosaveName='\(stableName)' on top-level split view")
    }
}
