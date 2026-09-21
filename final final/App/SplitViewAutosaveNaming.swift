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

    // MARK: - Launch snapshot
    //
    // Why this exists: `hasAutosavedDividerPosition(in:)` is a LIVE read, and AppKit writes the
    // autosave key as soon as it lays the split view out -- so any live read taken once the window
    // exists can be answering "did THIS launch's own default layout save a width" instead of "did a
    // PREVIOUS session". The only point no split view can exist yet is before the first window, so
    // `AppDelegate.applicationWillFinishLaunching` captures the defaults domain's split-view keys
    // there, and `OutlineSidebarPane` asks that snapshot, by the top-level split view's name,
    // instead of re-asking the live split view.

    /// The `NSSplitView Subview Frames ` keys the defaults domain held when this process started.
    /// `nil` means "not captured": unit tests, a read before `applicationWillFinishLaunching` has
    /// run, a launch with no bundle identifier, or a snapshot already consumed. The pane then falls
    /// back to the live check.
    ///
    /// A SET of keys rather than one flag, because the app has more than one split view: the nested
    /// editor / Annotations one autosaves under a SwiftUI-derived name of its own whenever it moves,
    /// and only the key under the TOP-LEVEL split view's name says anything about the Outline's
    /// width (see `savedDividerPosition(in:forAutosaveName:)`).
    ///
    /// Consume-once, WHEN THE SNAPSHOT ANSWERED: the first pane whose launch step consulted it and
    /// reached a resolved outcome (a saved position left to AppKit, or the divider positioned and
    /// landed) clears it (`consumeLaunchSplitViewFrameKeys()`). A pane built for a later project
    /// open is then no longer deciding against this process's start state -- by then a key under the
    /// live name really is a width the user set -- so it uses the live check. A pane that resolves
    /// WITHOUT consulting it (hidden at launch, ended by a toggle, waiting that ran out) leaves it
    /// for the next pane: consuming there would hand that pane a live check that can only see this
    /// launch's own autosave write.
    @MainActor private(set) static var launchSplitViewFrameKeys: Set<String>?

    /// Whether `domainKeys` holds a saved divider position for the split view named `name`: the
    /// exact key `AutosaveKeySweep.splitViewPrefix + name`, not any `NSSplitView Subview Frames `
    /// key.
    ///
    /// `name` is the top-level split view's LIVE autosave name, which the caller reads off the
    /// object (`currentTopLevelAutosaveName(in:)`), because AppKit restores under whatever name is
    /// live. That keeps a width saved under `stableName` counting when `stabilize` held, and keeps a
    /// width saved under SwiftUI's own derived name counting when that derived name IS the live
    /// one. A key under any other name -- the nested Annotations split view's own derived name, or
    /// a dead SwiftUI-derived key from an old launch -- says nothing about the Outline's width and
    /// must not suppress the 300pt launch positioning, so it does not match. An empty name never
    /// matches: AppKit does not save under one, and the bare prefix is not a key.
    ///
    /// Pure: no `UserDefaults`, no AppKit, so it is testable on a plain key set.
    static func savedDividerPosition(in domainKeys: Set<String>, forAutosaveName name: String) -> Bool {
        !name.isEmpty && domainKeys.contains(AutosaveKeySweep.splitViewPrefix + name)
    }

    /// Records the launch snapshot: the `NSSplitView Subview Frames ` subset of `domainKeys`. A
    /// second call replaces the first.
    @MainActor
    static func captureLaunchSplitViewFrameKeys(domainKeys: Set<String>) {
        launchSplitViewFrameKeys = domainKeys.filter { $0.hasPrefix(AutosaveKeySweep.splitViewPrefix) }
    }

    /// Captures the launch snapshot from the real defaults domain; called once from
    /// `applicationWillFinishLaunching`. A hermetic UI-test launch has just wiped the domain, so it
    /// captures the empty set WITHOUT reading the domain back: a read right after a write to the
    /// same domain is the shape documented as a ~5s cfprefsd stall (see
    /// `AppDelegate.flushWindowFrame`). With no bundle identifier there is nothing to read, and the
    /// snapshot stays `nil` -- reading a nameless domain would answer "nothing saved" and make the
    /// pane position the divider over a real saved width.
    @MainActor
    static func captureLaunchSplitViewFrameKeys(fromDomainNamed bundleID: String?, domainWasWiped: Bool) {
        guard let bundleID else { return }
        var keys = Set<String>()
        if !domainWasWiped, let domain = UserDefaults.standard.persistentDomain(forName: bundleID) {
            keys = Set(domain.keys)
        }
        captureLaunchSplitViewFrameKeys(domainKeys: keys)
    }

    /// Whether the launch snapshot held a saved divider position for `name`. `nil` when there is no
    /// snapshot to ask, so the caller can fall through to the live check.
    @MainActor
    static func launchSavedDividerPosition(forAutosaveName name: String) -> Bool? {
        launchSplitViewFrameKeys.map { savedDividerPosition(in: $0, forAutosaveName: name) }
    }

    /// Retires the launch snapshot after it has answered a pane's launch step (consume-once; see
    /// `launchSplitViewFrameKeys` for when that is and is not).
    @MainActor
    static func consumeLaunchSplitViewFrameKeys() {
        launchSplitViewFrameKeys = nil
    }

    /// Puts the snapshot back to `keys`, which is what a test read before it changed anything.
    /// Unit tests only: they run inside the real app process, whose launch already captured a real
    /// snapshot, so a test must restore that value rather than leave its own or wipe it.
    @MainActor
    static func restoreLaunchSplitViewFrameKeysForTesting(_ keys: Set<String>?) {
        launchSplitViewFrameKeys = keys
    }

    // MARK: - Launch decision

    /// What the Outline pane's launch step should do on one attempt. See `launchDecision`.
    enum LaunchDecision: Equatable {
        /// Not decidable yet: retry on the next tick, consuming nothing.
        case wait(LaunchWaitReason)
        /// A width saved by a previous session is authoritative; leave the divider to AppKit.
        case savedPositionWins
        /// Nothing saved is going to be restored: put the divider at the 300pt launch width.
        case positionAtLaunchWidth
    }

    /// Why a launch decision is being held back. Distinct so the diagnostic line can tell them
    /// apart: "waiting on the window" and "waiting on stabilization" send a reader to different
    /// places.
    enum LaunchWaitReason: String {
        /// The app delegate has not captured the main window yet.
        case noWindow
        /// The top-level split view's autosave name cannot be read: no content view, no
        /// `NSSplitView` in the tree yet, or more than one top-level split view.
        case nameUnreadable
        /// The live name is still SwiftUI-derived while the snapshot holds a key under
        /// `stableName`: `stabilize(for:)` has not landed yet, and AppKit may still restore that
        /// width once it does.
        case stabilizationPending
    }

    /// Everything `launchDecision` needs, as plain values the pane gathers from AppKit.
    struct LaunchInputs {
        /// The launch snapshot; nil when never captured or already consumed.
        let snapshotKeys: Set<String>?
        let hasWindow: Bool
        /// The top-level split view's live autosave name; nil when it cannot be read.
        let liveName: String?
        /// The live `hasAutosavedDividerPosition` answer, consulted only when there is no snapshot.
        let liveKeyPresent: Bool
        /// The leading pane's width now; nil when unreadable.
        let currentPosition: CGFloat?
        let paneIsVisible: Bool
        /// True only for the launch poll's last tick.
        let isFinalAttempt: Bool
    }

    /// The whole rule for the Outline pane's launch step, as a pure function of what the pane
    /// could read (`LaunchInputs`), so it can be tested over its entire table. The pane does only
    /// the AppKit work: gather the inputs, call this, act on the answer.
    ///
    /// The rules are ORDERED; the first that applies decides:
    ///
    /// 1. No window: `.wait(.noWindow)`.
    /// 2. A snapshot EXISTS and is EMPTY -- the captured set holds no `NSSplitView Subview Frames `
    ///    key of ANY name (it is prefix-filtered at capture): `.positionAtLaunchWidth`, whatever the
    ///    live name is, readable or not. There is nothing AppKit could restore under any name the
    ///    split view later acquires, so the name has nothing left to decide. This is what makes a
    ///    UI-test launch work: the wiped domain captures the empty set, and `stabilize(for:)`, the
    ///    only assigner of the top-level split view's name, never runs under test, so the name stays
    ///    unreadable for the whole process. It is NOT a `stableName` fallback -- no key is matched
    ///    -- so it does not bring back the defect rule 3 exists to prevent.
    /// 3. Live name unreadable (nil or empty): `.wait(.nameUnreadable)`. Deliberately NO fallback to
    ///    `stableName` -- the name is a precondition for asking a non-empty snapshot at all, and the
    ///    pane's poll exists to wait for it; substituting `stableName` for "cannot read the name"
    ///    answers "saved" before any split view exists and burns the step. A NIL snapshot (never
    ///    captured, or consumed by an earlier pane) is not rule 2 and waits here too, as does a
    ///    non-empty one; a nil snapshot with a name that never becomes readable therefore waits the
    ///    whole poll budget, which is acceptable: it is reachable only for a pane built after the
    ///    snapshot was consumed.
    /// 4. Live name readable and a snapshot present (`snapshotKeys`):
    ///    a. the snapshot holds the key under the LIVE name: `.savedPositionWins`, unless the pane
    ///       is visible and the divider reads back below `OutlineSidebarWidth.minWidth` -- the
    ///       Outline was hidden when the user quit, so AppKit autosaved ~0 -- in which case (c).
    ///       An unreadable `currentPosition` cannot show that, so it stays `.savedPositionWins`;
    ///    b. no key under the live name, the live name is not `stableName`, and the snapshot DOES
    ///       hold a key under `stableName`: `.wait(.stabilizationPending)`. On the final attempt
    ///       (c) instead, so the wait cannot run forever;
    ///    c. otherwise `.positionAtLaunchWidth`.
    /// 5. Live name readable and NO snapshot: the same as 4, with `liveKeyPresent` -- the live
    ///    `hasAutosavedDividerPosition` answer -- standing in for "the snapshot holds the key", and
    ///    no wait in (b): a live key under the live name is the only answer available.
    static func launchDecision(_ inputs: LaunchInputs) -> LaunchDecision {
        guard inputs.hasWindow else { return .wait(.noWindow) }
        if inputs.snapshotKeys?.isEmpty == true { return .positionAtLaunchWidth }
        guard let liveName = inputs.liveName, !liveName.isEmpty else { return .wait(.nameUnreadable) }

        let snapshotKeys = inputs.snapshotKeys
        let hasSavedKey = snapshotKeys.map { savedDividerPosition(in: $0, forAutosaveName: liveName) }
            ?? inputs.liveKeyPresent
        if hasSavedKey {
            let hiddenAtQuit = inputs.paneIsVisible
                && (inputs.currentPosition ?? .infinity) < OutlineSidebarWidth.minWidth
            return hiddenAtQuit ? .positionAtLaunchWidth : .savedPositionWins
        }
        if let snapshotKeys, !inputs.isFinalAttempt, stabilizationMayStillRestore(snapshotKeys, liveName: liveName) {
            return .wait(.stabilizationPending)
        }
        return .positionAtLaunchWidth
    }

    /// Whether a width saved under `stableName` could still be restored: the snapshot holds that
    /// key but the live name is not (yet) `stableName`.
    private static func stabilizationMayStillRestore(_ snapshotKeys: Set<String>, liveName: String) -> Bool {
        liveName != stableName && savedDividerPosition(in: snapshotKeys, forAutosaveName: stableName)
    }

    /// The divider position a `setPosition` call actually LANDED at, or `nil` when it did not:
    /// `position` (read back after the call) counts when it is within 1pt of `target` or of `floor`,
    /// the pane's `minWidth`, which is AppKit's legitimate clamp for a narrow window. Returns the
    /// read-back value itself so the caller adopts where the divider is, not where it was asked to
    /// go. `nil` in, `nil` out.
    ///
    /// Reading a divider at the floor as landed is deliberate, and it can look like a false
    /// positive: under a narrow window with the Annotations panel open, a constrained Outline can
    /// legitimately sit at 250pt and be reported as landed. That is not silent -- the pane's
    /// diagnostic line carries `landed=` -- so `outcome=positioned landed=250.0` next to a failing
    /// width assertion points at window/panel geometry, not at the decision rule.
    static func landedPosition(_ position: CGFloat?, target: CGFloat, floor: CGFloat) -> CGFloat? {
        guard let position else { return nil }
        return abs(position - target) <= 1 || abs(position - floor) <= 1 ? position : nil
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
    /// absent, has fewer than two arranged panes, or has zero-width bounds -- not laid out yet, so
    /// `setPosition` would clamp against nothing and AppKit's first layout would then overwrite it.
    /// A caller that needs the position to have TAKEN EFFECT reads it back with
    /// `topLevelDividerPosition(in:)`; this only reports that the call was made.
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
              splitView.arrangedSubviews.count >= 2,
              splitView.bounds.width > 0 else { return false }

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
