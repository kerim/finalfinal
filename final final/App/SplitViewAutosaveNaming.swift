//
//  SplitViewAutosaveNaming.swift
//  final final
//
//  Assigns a stable AppKit autosave name to the NSSplitView backing ContentView's `HSplitView`
//  (this said "NavigationSplitView" before the Outline sidebar's container swap), so the sidebar
//  divider position persists under a name this app controls rather than a SwiftUI-derived one.
//  There is no SwiftUI-level persistence API for a split view's divider position, and no other
//  `NSSplitView` reference in the codebase — the AppKit-level `NSSplitView.autosaveName` is the
//  only thing actually saving the divider position (see ContentView.swift's `editorSplitViewContent`).
//  That is load-bearing again, not merely historical: a `UserDefaults` width pair for the Outline
//  pane was tried and withdrawn, because `HSplitView` does not honour the pane's `idealWidth` at
//  first layout, so a stored width could be written and never applied (see
//  `OutlineSidebarWidth`'s doc comment). This mechanism is therefore the ONLY thing that restores
//  the user's sidebar width across launches.
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

    // MARK: - Divider positioning
    //
    // Why this exists: `HSplitView` does not apply the Outline pane's `idealWidth` at first layout,
    // so with no autosaved divider position AppKit gives the leading pane its maximum width
    // (measured: the pane opens at 400pt on a fresh launch). `idealWidth` therefore cannot express
    // either the 300pt default or "come back at the width I dragged to"; the divider has to be
    // positioned explicitly. These are the only two operations that need, both keyed off the same
    // top-level split view `stabilize(for:)` names.

    /// The single top-level (no-`NSSplitView`-ancestor) split view in `window`'s tree, or `nil`
    /// when there is not exactly one — the same ambiguity refusal `stabilize(for:)` applies.
    static func topLevelSplitView(in window: NSWindow) -> NSSplitView? {
        let topLevel = allSplitViews(in: window).filter { !$0.hasSplitViewAncestor }
        guard topLevel.count == 1 else { return nil }
        return topLevel[0].splitView
    }

    /// Whether AppKit has a divider position saved for the top-level split view that is worth
    /// honouring: the split view carries a non-empty `autosaveName` AND the corresponding
    /// `NSSplitView Subview Frames <name>` default is present. `false` also covers "no window /
    /// no unambiguous top-level split view yet", which callers should treat as "nothing saved" —
    /// positioning the divider at the default is the correct action in that state too.
    ///
    /// Deliberately only a PRESENCE check, not a value read: AppKit's stored frame format is not a
    /// contract this app should parse, and when the key is present AppKit's own restore is the
    /// authority. The key shape comes from `AutosaveKeySweep.splitViewPrefix`, so this cannot
    /// drift from the sweep's own understanding of `NSSplitView Subview Frames ` keys.
    static func hasAutosavedDividerPosition(in window: NSWindow) -> Bool {
        guard let name = currentTopLevelAutosaveName(in: window) else { return false }
        return UserDefaults.standard.object(forKey: AutosaveKeySweep.splitViewPrefix + name) != nil
    }

    /// The leading pane's current width in the top-level split view — the divider's position, as
    /// `setPosition(_:ofDividerAt:)` defines it. `nil` when there is no unambiguous top-level
    /// split view or it does not have two arranged panes to divide.
    static func topLevelDividerPosition(in window: NSWindow) -> CGFloat? {
        guard let splitView = topLevelSplitView(in: window),
              splitView.arrangedSubviews.count >= 2 else { return nil }
        return splitView.arrangedSubviews[0].frame.width
    }

    /// Positions the top-level split view's first divider, i.e. sets the leading pane's width.
    /// Returns whether the split view was found and the call made; no-ops when the split view is
    /// absent or has fewer than two arranged panes.
    ///
    /// `animated: true` uses the split view's animator proxy; the Outline pane passes `false` and
    /// steps the position itself instead, because `NSSplitView`'s animator proxy is not documented
    /// to animate `setPosition(_:ofDividerAt:)` and the pane's animation must be observable.
    @discardableResult
    static func setTopLevelDividerPosition(
        _ position: CGFloat,
        in window: NSWindow,
        animated: Bool
    ) -> Bool {
        guard let splitView = topLevelSplitView(in: window),
              splitView.arrangedSubviews.count >= 2 else { return false }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = PanelToggleTiming.duration
                splitView.animator().setPosition(position, ofDividerAt: 0)
            }
        } else {
            splitView.setPosition(position, ofDividerAt: 0)
        }
        return true
    }
}
