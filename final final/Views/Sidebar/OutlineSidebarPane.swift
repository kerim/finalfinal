//
//  OutlineSidebarPane.swift
//  final final
//

import SwiftUI

/// Wraps the Outline sidebar (zoom breadcrumb + `OutlineSidebar` itself) in its own view so its
/// body only re-evaluates when something it actually reads changes -- not on every
/// `ContentView.body` pass (bt t-fecee361). `ContentView.body` previously built `OutlineSidebar`
/// inline inside `sidebarView`, which meant every property that construction read
/// (`editorState.sections`, `.zoomedSection`, `.currentSectionId`, the whole
/// `OutlineSidebarRenderKey`, etc.) was a dependency of `ContentView.body` itself.
/// `OutlineSidebar`'s own `.equatable()` protects `OutlineSidebar.body` from re-running on an
/// unchanged reconstruction, but does nothing for `ContentView.body`, which had already paid the
/// cost of re-evaluating and re-reading those `@Observable` properties before `.equatable()` ever
/// got a look -- every keystroke that moved the caret's section touched `currentSectionId`,
/// which `@Observable` treats as a dependency the instant it's read here, regardless of whether
/// the value actually changed.
///
/// **Invariant, compiler-enforced: a read added to this initializer as anything but a closure
/// defeats this extraction.** The only non-closure parameter is `editorState` -- the object
/// itself, nothing else (no `sections:`, no `currentSectionId:`, no theme param). Adding a
/// dedicated initializer parameter for any of those would make ITS read happen back in
/// `ContentView.sidebarView` at construction time, reintroducing the exact per-keystroke coupling
/// this file exists to remove. `ThemeManager` comes from `@Environment` here (already injected
/// app-wide via `.environment(ThemeManager.shared)` in `FinalFinalApp.swift`; `StatusBar.swift`
/// does the identical lookup), not a parameter, for the same reason.
///
/// This pane is also the single owner of the sidebar's width in the window: its min/ideal/max
/// bounds, the observed-width bookkeeping, and the show/hide animation all live here (see
/// `widthObserver`/`animateToggle` below), so `OutlineSidebar.swift` -- already the largest file in
/// this area -- carries none of it. What it does NOT own is where the divider actually sits while
/// the app is not animating: `HSplitView` ignores this pane's `idealWidth`, so the pane asks
/// `SplitViewAutosaveNaming` to position the top-level split view's divider (see
/// `OutlineSidebarWidth`'s doc comment) both on first layout and on every show/hide transition.
/// `ContentView`'s `HSplitView` mounts this pane unconditionally and never removes it from the
/// layout.
struct OutlineSidebarPane: View {
    @Bindable var editorState: EditorViewState

    let onScrollToSection: (String) -> Void
    let onSectionUpdated: (SectionViewModel) -> Void
    let onSectionReorder: (SectionReorderRequest) -> Void
    let onZoomToSection: (String, ZoomMode) -> Void
    let onZoomOutFromSidebar: () -> Void
    let onZoomOutFromBreadcrumb: () -> Void
    let onDragStarted: () -> Void
    let onDragEnded: () -> Void
    let onDuplicateSection: (String) -> Void
    let onDeleteSection: (String) -> Void

    @Environment(ThemeManager.self) private var themeManager

    /// The pane's in-session width: starts at the shared default (`OutlineSidebarWidth.idealWidth`),
    /// tracks genuine drag-resizes via `widthObserver`, and is driven to the show/hide target by
    /// `animateToggle`. Feeds the frame's `idealWidth`, which is a hint only -- `HSplitView` does
    /// not apply it (see `OutlineSidebarWidth`), so the DIVIDER is what actually determines this
    /// pane's width and is positioned explicitly by `SplitViewAutosaveNaming` from this view.
    @State private var sidebarWidth: CGFloat = OutlineSidebarWidth.idealWidth

    /// The width to come back to when the pane is re-shown: the last width observed while the pane
    /// was visible and above the floor. Seeded with the default so a show before any observation
    /// (or before first layout) still has a sane target. Kerim's decision: the app guarantees the
    /// re-show width itself rather than relying on AppKit happening to remember the divider.
    @State private var lastVisibleWidth: CGFloat = OutlineSidebarWidth.idealWidth

    /// True once the first layout after launch has been reconciled (see `reconcileWidth`). Guards
    /// the one-time "position the divider" step so it cannot run on every layout pass.
    @State private var hasReconciledFirstLayout = false

    /// Snapshot of `SplitViewAutosaveNaming.hasAutosavedDividerPosition` taken at `onAppear`, i.e.
    /// before this launch has laid the split view out. `nil` means the check could not be taken
    /// then, in which case it is retried at first layout. The snapshot exists because AppKit writes
    /// the autosave key as soon as it lays the split view out: a check taken after that would
    /// describe THIS launch's own default layout rather than what a previous session saved, and
    /// would wrongly suppress the 300pt default positioning.
    @State private var launchHadSavedDividerPosition: Bool?

    /// The in-flight divider animation, so a newer toggle can cancel a running one.
    @State private var dividerAnimationTask: Task<Void, Never>?

    /// True only while the show/hide width animation (`.panelToggle`) is in flight. Gates
    /// `widthObserver`: without this, the animation's own pass through every width between the
    /// default and zero would each get sampled by the geometry observer below and adopted as if
    /// the user had dragged there, so the pane would end its collapse on whatever intermediate
    /// width happened to be sampled last instead of on zero. Also temporarily relaxes
    /// `minWidth`/`maxWidth` in `.frame(...)` below so the pane can actually reach zero and can be
    /// positioned back out -- the pane's real drag-resize floor stays `minWidth` from
    /// `OutlineSidebarWidth` whenever this is false.
    @State private var isAnimatingToggle = false

    /// Identifies the most recently started toggle animation, so a stale completion callback
    /// from an EARLIER toggle (rapid show/hide/show clicks) can't clear `isAnimatingToggle`
    /// while a NEWER toggle's animation is still actually in flight.
    @State private var toggleAnimationToken = UUID()

    var body: some View {
        VStack(spacing: 0) {
            // Zoom breadcrumb when zoomed into a section
            if let zoomedSection = editorState.zoomedSection {
                ZoomBreadcrumb(
                    zoomedSection: zoomedSection,
                    onZoomOut: onZoomOutFromBreadcrumb,
                    isZoomOutDisabled: editorState.contentState != .idle
                )
                Divider()
            }

            OutlineSidebar(
                sections: $editorState.sections,
                statusFilter: $editorState.statusFilter,
                headerLevelFilter: $editorState.headerLevelFilter,
                zoomedSectionId: $editorState.zoomedSectionId,
                zoomedSectionIds: editorState.zoomedSectionIds,
                // Built fresh each body pass, by VALUE (not through the `$`-prefixed bindings
                // above) -- see `OutlineSidebarRenderKey`'s doc comment
                // (OutlineSidebar+Models.swift) for exactly why this exists: it's what lets
                // `OutlineSidebar`'s `.equatable()` below tell a keystroke that changed none of
                // these render-relevant values apart from one that did, instead of forcing
                // `OutlineSidebar.body` to re-run on every reconstruction regardless (bt
                // t-ef411da3).
                renderKey: OutlineSidebarRenderKey(
                    sections: editorState.sections,
                    statusFilter: editorState.statusFilter,
                    headerLevelFilter: editorState.headerLevelFilter,
                    zoomedSectionId: editorState.zoomedSectionId,
                    documentGoal: editorState.documentGoal,
                    documentGoalType: editorState.documentGoalType,
                    excludeBibliography: editorState.excludeBibliography
                ),
                documentGoal: $editorState.documentGoal,
                documentGoalType: $editorState.documentGoalType,
                excludeBibliography: $editorState.excludeBibliography,
                onScrollToSection: onScrollToSection,
                onSectionUpdated: onSectionUpdated,
                onSectionReorder: onSectionReorder,
                currentSectionId: editorState.currentSectionId,
                onZoomToSection: onZoomToSection,
                onZoomOut: onZoomOutFromSidebar,
                onDragStarted: onDragStarted,
                onDragEnded: onDragEnded,
                sectionDropInFlight: $editorState.sectionDropInFlight,
                onDuplicateSection: onDuplicateSection,
                onDeleteSection: onDeleteSection
            )
            // The actual root-cause fix for bt t-ef411da3: `sidebarView` reconstructs
            // `OutlineSidebar` fresh on every `ContentView.body` pass (every keystroke), and
            // without `.equatable()` here SwiftUI has no way to distinguish that reconstruction
            // from a genuine content change -- `OutlineSidebar.body` re-ran unconditionally.
            // Paired with `OutlineSidebar: Equatable` (OutlineSidebar+Models.swift), this lets
            // SwiftUI skip re-invoking `OutlineSidebar.body` when `renderKey` and the other
            // compared fields are unchanged. Must stay directly on `OutlineSidebar` itself, not
            // on the enclosing `VStack` -- `.equatable()` compares the view value it's attached
            // to, not its container.
            .equatable()
        }
        .frame(
            // Floors at OutlineSidebarWidth.minWidth ONLY in the steady visible state (real
            // drag-resize needs that floor). Both while animating AND in the steady HIDDEN
            // state, the floor must be 0 -- if it snapped back to minWidth the instant a
            // hide animation's completion callback clears isAnimatingToggle, the pane would
            // immediately re-expand to 250pt right after finishing its collapse to 0, since
            // idealWidth (0) would then be fighting a 250pt floor every frame.
            minWidth: editorState.isOutlineSidebarVisible && !isAnimatingToggle ? OutlineSidebarWidth.minWidth : 0,
            idealWidth: sidebarWidth,
            // Ceiling pinned to 0 in the steady HIDDEN state: leaving it at maxWidth (400) would
            // give the HSplitView divider slack to travel while the pane is meant to be gone, and
            // a drag there would never have updated isOutlineSidebarVisible. Pinning min AND max
            // to 0 together gives the pane a fixed 0pt size while hidden. Relaxed back to the real
            // ceiling whenever visible OR animating (both directions need room for `sidebarWidth`
            // to travel between 0 and the real width), matching the floor's own
            // animating-relaxation above.
            maxWidth: editorState.isOutlineSidebarVisible || isAnimatingToggle ? OutlineSidebarWidth.maxWidth : 0
        )
        .clipped()
        .background(themeManager.currentTheme.sidebarBackground)
        // Scopes XCUITest queries to just this pane's own elements (e.g. its section cards),
        // so a query like `app.groups["outline-sidebar"].textViews[...]` cannot accidentally
        // match the web editor's own ProseMirror contenteditable, which XCUITest also exposes
        // as a TextView elsewhere in the accessibility tree. Health-checked by
        // `SmokeTests.testSidebarToggles`: this must keep resolving as a Group with a ScrollView
        // child, so no other accessibility modifier may be layered onto this view.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("outline-sidebar")
        .accessibilityHidden(!editorState.isOutlineSidebarVisible)
        .allowsHitTesting(editorState.isOutlineSidebarVisible)
        .background(widthObserver)
        .onAppear {
            // `sidebarWidth` starts at `OutlineSidebarWidth.idealWidth` -- but this view can be
            // constructed while isOutlineSidebarVisible is ALREADY false (e.g. a window rebuilt
            // mid Focus Mode, where EditorViewState+FocusMode.swift sets
            // isOutlineSidebarVisible = false before this view exists). Nothing fires an
            // onChange for a property that was already false at seed time, so without this the
            // pane would render at its ideal width with only the (now pinned-to-0) max width
            // silently clipping it -- reconcile the state itself instead of relying on that side
            // effect.
            if !editorState.isOutlineSidebarVisible {
                sidebarWidth = 0
            }
            // Snapshot whether this launch has an autosaved divider position to honour, BEFORE
            // this launch's own layout can write that key (see the property's doc comment).
            if let window = AppDelegate.shared?.mainWindow {
                launchHadSavedDividerPosition = SplitViewAutosaveNaming.hasAutosavedDividerPosition(in: window)
            }
            // t-784ff3aa: a stale instant-toggle flag set before this view existed (e.g. the
            // window was rebuilt mid Focus Mode, the same scenario the comment above already
            // accounts for) has no onChange left to consume it -- clear it defensively so it
            // can't wrongly de-snap this fresh pane's next, unrelated toggle.
            editorState.isOutlineSidebarToggleInstant = false
        }
        .onChange(of: editorState.isOutlineSidebarVisible) { _, newValue in
            if editorState.isOutlineSidebarToggleInstant {
                editorState.isOutlineSidebarToggleInstant = false
                snapToggle(becomingVisible: newValue)
            } else {
                animateToggle(becomingVisible: newValue)
            }
        }
    }

    /// Adopts the pane's own rendered width as the in-session width -- the only way to see a
    /// divider drag, since HSplitView resizes the view's frame directly rather than through any
    /// SwiftUI binding this view owns. `.onGeometryChange` rather than a `GeometryReader` +
    /// `.onChange`: unlike `.onChange`, this form reports the INITIAL size too, which is what makes
    /// the one-time first-layout step below possible.
    ///
    /// By the user's decision this is the observer's ONLY branch: there is no collapse branch and
    /// it never writes `isOutlineSidebarVisible` in either direction, so a window resize, a
    /// divider drag, or a Focus Mode exit can never silently hide or un-hide the pane.
    private var widthObserver: some View {
        Color.clear
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                reconcileWidth(newWidth)
            }
    }

    /// Adopts an observed width only when it is a genuine, in-range pane width, and runs the
    /// one-time first-layout step.
    ///
    /// A width below `minWidth` is the split view's own layout clamp (a window too narrow to honour
    /// the pane's floor, or a sample taken mid-resize), not a width the pane should treat as its
    /// own -- so it is ignored rather than adopted. The other two guards are equally load-bearing:
    /// while the show/hide animation is in flight every intermediate width is a transient of that
    /// animation, and while the pane is hidden the only width it can report is its pinned 0.
    ///
    /// Nothing here persists anything, and nothing here runs on every pass beyond the two
    /// assignments: the divider is positioned only on first layout and on the show/hide
    /// transitions, never while the user is dragging.
    private func reconcileWidth(_ newWidth: CGFloat) {
        guard !isAnimatingToggle else { return }
        guard editorState.isOutlineSidebarVisible else { return }

        // One-time launch step. Deliberately only consumed when the window is actually reachable:
        // if the app delegate has not captured it yet, a later observation retries rather than
        // leaving the pane at whatever AppKit's default layout produced.
        if !hasReconciledFirstLayout, AppDelegate.shared?.mainWindow != nil {
            hasReconciledFirstLayout = true
            if positionDividerAtLaunchWidthIfUnsaved() {
                // The divider has just been moved to the launch width, so this pass's `newWidth`
                // is the PRE-move layout (AppKit's maximum). Do not adopt it.
                return
            }
        }

        guard newWidth >= OutlineSidebarWidth.minWidth else { return }
        #if DEBUG
        DebugLog.log(.viewUpdates, "[OutlineWidth] adopt \(newWidth)")
        #endif
        sidebarWidth = OutlineSidebarWidth.clamp(newWidth)
        lastVisibleWidth = sidebarWidth
    }

    /// First-layout step: give the divider an explicit position for this launch.
    ///
    /// `HSplitView` does not apply the pane's `idealWidth`, so with nothing saved AppKit gives the
    /// leading pane its maximum (400pt) instead of the 300pt default. When AppKit does have a saved
    /// divider position to honour, that restore is authoritative and this does nothing. Uses the
    /// `onAppear` snapshot when it exists, and re-checks otherwise. Returns whether it positioned
    /// the divider.
    private func positionDividerAtLaunchWidthIfUnsaved() -> Bool {
        guard let window = AppDelegate.shared?.mainWindow else { return false }
        let hadSavedPosition = launchHadSavedDividerPosition
            ?? SplitViewAutosaveNaming.hasAutosavedDividerPosition(in: window)
        guard !hadSavedPosition else { return false }

        let launchWidth = OutlineSidebarWidth.idealWidth
        guard SplitViewAutosaveNaming.setTopLevelDividerPosition(launchWidth, in: window, animated: false) else {
            return false
        }
        sidebarWidth = launchWidth
        lastVisibleWidth = launchWidth
        return true
    }

    /// The current divider position, or `nil` when the split view cannot be reached yet.
    private func currentDividerPosition() -> CGFloat? {
        guard let window = AppDelegate.shared?.mainWindow else { return nil }
        return SplitViewAutosaveNaming.topLevelDividerPosition(in: window)
    }

    /// Moves the divider to `position`. False when the split view cannot be reached.
    @discardableResult
    private func setDividerPosition(_ position: CGFloat) -> Bool {
        #if DEBUG
        DebugLog.log(.viewUpdates, "[OutlineDivider] set \(position)")
        #endif
        guard let window = AppDelegate.shared?.mainWindow else { return false }
        return SplitViewAutosaveNaming.setTopLevelDividerPosition(position, in: window, animated: false)
    }

    /// Width-animation for the Outline sidebar's show/hide. HSplitView does not honor a SwiftUI
    /// insertion `.transition` on a conditionally-mounted child and does not apply this pane's
    /// `idealWidth`, so the pane stays mounted at all times and the SPLIT VIEW'S DIVIDER is what is
    /// animated: out to 0 on hide, back to `lastVisibleWidth` (the width the user last dragged to)
    /// on show. This is the pane's ONLY animation point, and the app -- not AppKit happening to
    /// remember the divider -- guarantees the re-show width.
    ///
    /// The divider is stepped here rather than handed to `NSAnimationContext`/the animator proxy,
    /// because `NSSplitView`'s animator proxy is not documented to animate
    /// `setPosition(_:ofDividerAt:)`; stepping on `PanelToggleTiming.duration` with a quadratic
    /// ease-out matches `.panelToggle` (Theme/Animations.swift, the Annotations panel's curve) and
    /// is deterministically observable. `sidebarWidth` still rides `withAnimation(.panelToggle)`
    /// so the frame hint moves with the divider.
    ///
    /// The nested-curve problem this method used to carry a "Known follow-up, NOT fixed here"
    /// note about is now gone for the Focus Mode path: Focus Mode no longer wraps
    /// `isOutlineSidebarVisible` in its own `.easeInOut(duration: 0.3)` transaction, so it never
    /// nests with this method's `.panelToggle` curve -- it assigns the property plainly and the
    /// pane's `onChange` snaps instead, via `snapToggle` (ux-contract §12/D18). The plain path
    /// (toolbar button, View menu, ⌘[) keeps this method and its stepped divider unchanged, and
    /// `.panelToggle` remains its only curve.
    private func animateToggle(becomingVisible: Bool) {
        isAnimatingToggle = true
        let token = UUID()
        toggleAnimationToken = token

        let target = becomingVisible ? lastVisibleWidth : 0
        withAnimation(.panelToggle) {
            sidebarWidth = target
        }
        animateDivider(to: target, token: token)
    }

    /// Steps the divider to `target` over `PanelToggleTiming.duration`, clearing
    /// `isAnimatingToggle` when the LAST step of the current animation lands (a superseded
    /// animation's loop is cancelled and returns without touching the flag).
    private func animateDivider(to target: CGFloat, token: UUID) {
        dividerAnimationTask?.cancel()
        let start = currentDividerPosition() ?? target

        dividerAnimationTask = Task { @MainActor in
            let steps = 15
            let stepDuration = PanelToggleTiming.duration / Double(steps)
            for step in 1...steps {
                if Task.isCancelled { return }
                let fraction = Double(step) / Double(steps)
                // Quadratic ease-out by hand: no `pow` import needed, and it matches the shape of
                // `Animation.easeOut` closely enough to read as the same motion.
                let eased = 1 - (1 - fraction) * (1 - fraction)
                setDividerPosition(start + (target - start) * CGFloat(eased))
                if step < steps {
                    try? await Task.sleep(for: .seconds(stepDuration))
                }
            }
            // A newer toggle (rapid show/hide/show) already superseded this one -- let ITS own
            // loop be the one that clears isAnimatingToggle.
            guard toggleAnimationToken == token else { return }
            isAnimatingToggle = false
        }
    }

    /// Snaps the pane and the divider straight to their final positions with no animation -- the
    /// ONE transition where Focus Mode itself drives `isOutlineSidebarVisible` (ux-contract
    /// §12/D18), gated by `editorState.isOutlineSidebarToggleInstant`. Every other trigger (the
    /// toolbar button, the View menu, ⌘[) still runs `animateToggle` and its stepped divider.
    /// Matches the release build's old behavior of removing the pane from the view tree outright
    /// on Focus Mode entry/exit.
    ///
    /// The order here is load-bearing. Cancelling the in-flight task and bumping
    /// `toggleAnimationToken` FIRST is what deterministically invalidates a stepped animation
    /// already in flight: its loop returns at its next step on cancellation, and a loop already
    /// past that check cannot clear `isAnimatingToggle` out from under this snap, because the
    /// fresh token fails the completion guard.
    ///
    /// Clearing `isAnimatingToggle` (rather than setting it true) deliberately leaves
    /// `widthObserver` live for this whole transition -- `reconcileWidth` guards on that flag, so
    /// unlike the animated path there is no 250 ms window excluding intermediate widths here.
    /// That is the behaviour change this design accepts, and it was measured: on a Focus Mode
    /// exit with the Outline dragged to 330pt the observer adopted a transient (`adopt 250.0`)
    /// and then the settled value (`adopt 330.0`), which is what the user ends up with.
    ///
    /// `snapToggle` itself must not write `lastVisibleWidth`: it only READS it as the restore
    /// target. The adopt branch of `reconcileWidth` is what legitimately writes it, whenever its
    /// three guards pass -- `isAnimatingToggle` false, the pane visible, and the observed width
    /// at or above the 250pt floor -- which includes a width AppKit clamps or a transient during
    /// a transition. The remembered width is therefore whatever that observer last adopted at or
    /// above the floor, not necessarily the width the user last dragged to.
    ///
    /// Known, accepted interleaving: if a plain ⌘[ hide is already in flight when Focus Mode is
    /// entered, the visibility is already false at that moment, so nothing arms and no `onChange`
    /// fires -- the in-flight step animation simply finishes, and that particular entry is not
    /// instant (the final state is still correct).
    ///
    /// No-window case: if `setDividerPosition` returns false there is no split view to move, so
    /// the pane ends up at AppKit's 250pt floor rather than `lastVisibleWidth` -- acceptable,
    /// since nothing could have positioned the divider anyway.
    private func snapToggle(becomingVisible: Bool) {
        let restore = lastVisibleWidth
        #if DEBUG
        DebugLog.log(.viewUpdates, "[OutlineSnap] read lastVisibleWidth \(restore) becomingVisible \(becomingVisible)")
        #endif

        dividerAnimationTask?.cancel()
        toggleAnimationToken = UUID()
        isAnimatingToggle = false

        if becomingVisible {
            sidebarWidth = restore
            let moved = setDividerPosition(restore)
            #if DEBUG
            DebugLog.log(.viewUpdates, "[OutlineSnap] move ok \(moved) target \(restore)")
            #endif
        } else {
            sidebarWidth = 0
            let moved = setDividerPosition(0)
            #if DEBUG
            DebugLog.log(.viewUpdates, "[OutlineSnap] move ok \(moved) target 0")
            #endif
        }
    }
}
