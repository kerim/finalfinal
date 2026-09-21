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

    /// True once the launch step (see `positionDividerAtLaunchWidthIfUnsaved`) has been RESOLVED:
    /// the divider was positioned, a saved position was left to AppKit, or the launch poll gave
    /// up. Until then `reconcileWidth` adopts nothing, so AppKit's default width can never be
    /// written into `sidebarWidth`/`lastVisibleWidth`, and an unresolved flag makes it return
    /// early forever. It is set through `resolveLaunchStep()`, which every exit of the launch poll
    /// uses except two that write nothing: `.onDisappear`, where the view is going away and nothing
    /// reads the flag again, and a poll that was cancelled from outside -- its canceller either is
    /// `.onDisappear` or (`endLaunchPositioningPoll`) has already resolved the step itself.
    @State private var hasReconciledFirstLayout = false

    /// The active retry for the launch step, started at `onAppear`. `reconcileWidth` alone cannot
    /// retry it: it only runs when the pane's width CHANGES, and a pane stuck at AppKit's default
    /// never reports another change (bt t-218cac62).
    @State private var launchPositioningTask: Task<Void, Never>?

    /// Attempt count and last-logged outcome, so the `[OutlineLaunchWidth]` diagnostic line is
    /// throttled instead of written once per poll tick. A reference box on purpose: mutating a
    /// value-type `@State` on every attempt would invalidate this pane's body up to 30 times
    /// during a slow launch, and a box's contents changing invalidates nothing.
    @State private var launchPositioningProgress = LaunchPositioningProgress()

    /// The launch poll's budget: 30 ticks 100 ms apart, about 3 s. That full budget is spent only
    /// WAITING (no window, name unreadable, stabilization pending, split view not laid out yet).
    /// A reachable split view that `setPosition` ran against but that did not land is capped at
    /// `launchPositioningMaxNotLanded` consecutive ticks instead (10, about 1 s, which leaves about
    /// 2 s of the budget for the other waits). A landing is believed only once
    /// `launchPositioningConfirmingLandings` consecutive attempts have read it back, or on the
    /// final attempt.
    private static let launchPositioningMaxTicks = 30
    private static let launchPositioningMaxNotLanded = 10
    private static let launchPositioningConfirmingLandings = 2
    private static let launchPositioningInterval: Duration = .milliseconds(100)

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
            startLaunchPositioningPoll()
            // t-784ff3aa: a stale instant-toggle flag set before this view existed (e.g. the
            // window was rebuilt mid Focus Mode, the same scenario the comment above already
            // accounts for) has no onChange left to consume it -- clear it defensively so it
            // can't wrongly de-snap this fresh pane's next, unrelated toggle.
            editorState.isOutlineSidebarToggleInstant = false
        }
        .onDisappear {
            // The one exit that cancels the launch poll WITHOUT resolving the launch step: the view
            // is going away, so nothing reads `hasReconciledFirstLayout` again, and neither the poll
            // nor a divider animation may outlive the window and touch
            // `AppDelegate.shared?.mainWindow` after teardown.
            launchPositioningTask?.cancel()
            launchPositioningTask = nil
            dividerAnimationTask?.cancel()
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

        // One-time launch step (the fast path; the launch poll is its retry). Only a saved position
        // falls through to adoption. A positioned divider returns because this pass's `newWidth` is
        // the PRE-move layout (AppKit's maximum), and an unresolved attempt returns because adopting
        // now would write AppKit's default width into `sidebarWidth`/`lastVisibleWidth`.
        if !hasReconciledFirstLayout {
            guard attemptLaunchPositioning(isFinalAttempt: false) == .savedPositionWins else { return }
        }

        adoptObservedWidth(newWidth)
    }

    /// Adopts `width` as the in-session width, ignoring one below `minWidth` (see
    /// `reconcileWidth`). Shared with the launch poll's exits, because no geometry callback follows
    /// a poll that resolves without moving the divider, so nothing else would adopt the width AppKit
    /// left there.
    private func adoptObservedWidth(_ width: CGFloat) {
        guard width >= OutlineSidebarWidth.minWidth else { return }
        #if DEBUG
        DebugLog.log(.viewUpdates, "[OutlineWidth] adopt \(width)")
        #endif
        sidebarWidth = OutlineSidebarWidth.clamp(width)
        lastVisibleWidth = sidebarWidth
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
        // A toggle inside the launch poll's first ~3 s takes over the divider: end the poll, and
        // resolve the launch step so it does not compete with `animateDivider` below.
        endLaunchPositioningPoll()
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
        // Same as `animateToggle`: the snap takes over the divider from the launch poll, and the
        // launch step is resolved on the way out.
        endLaunchPositioningPoll()
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

// MARK: - Launch positioning
// The Outline's launch-width step (bt t-218cac62), in an extension so the view struct stays inside
// the type-body limit; the state it works on stays in the struct.

extension OutlineSidebarPane {
    /// First-layout step: give the divider an explicit position for this launch.
    ///
    /// `HSplitView` does not apply the pane's `idealWidth`, so with nothing saved AppKit gives the
    /// leading pane its maximum (400pt) instead of the 300pt default. When a previous session saved
    /// a divider position, AppKit's restore is authoritative and this does nothing. The outcome is
    /// explicit so "AppKit's restore wins", "not decidable yet" and "moved but did not land" are
    /// never the same answer.
    ///
    /// The rule itself is `SplitViewAutosaveNaming.launchDecision`, a pure function; this method
    /// only gathers what AppKit can tell it (`reading`) and acts on the answer. The launch snapshot
    /// is consumed HERE, and only on a path where it answered and the step resolved (a saved
    /// position left to AppKit, or the divider positioned and confirmed) -- never on a wait, and
    /// never by the hidden-pane, toggle or exhaustion exits, which resolve without consulting it.
    /// Landing and its confirmation are in `positionDivider(atLaunchWidthIn:isFinalAttempt:)`.
    private func positionDividerAtLaunchWidthIfUnsaved(
        _ reading: LaunchPositioningReading,
        isFinalAttempt: Bool
    ) -> LaunchPositioningOutcome {
        let liveKeyPresent = reading.snapshotKeys == nil
            && (reading.window.map { SplitViewAutosaveNaming.hasAutosavedDividerPosition(in: $0) } ?? false)
        let inputs = SplitViewAutosaveNaming.LaunchInputs(
            snapshotKeys: reading.snapshotKeys,
            hasWindow: reading.window != nil,
            liveName: reading.liveName,
            liveKeyPresent: liveKeyPresent,
            currentPosition: reading.dividerPosition,
            paneIsVisible: editorState.isOutlineSidebarVisible,
            isFinalAttempt: isFinalAttempt
        )
        switch SplitViewAutosaveNaming.launchDecision(inputs) {
        case .wait(let reason):
            return .waiting(reason)
        case .savedPositionWins:
            SplitViewAutosaveNaming.consumeLaunchSplitViewFrameKeys()
            return .savedPositionWins
        case .positionAtLaunchWidth:
            return reading.window.map {
                positionDivider(atLaunchWidthIn: $0, isFinalAttempt: isFinalAttempt)
            } ?? .waiting(.noWindow)
        }
    }

    /// Sets the divider to the launch width and reports whether it landed and whether that landing
    /// is believed. On any landing it adopts the READ-BACK position (not the target) into
    /// `sidebarWidth`/`lastVisibleWidth`, so a divider AppKit clamped to the floor is adopted where
    /// it is. Only a CONFIRMED landing -- the second consecutive one (`launchPositioningConfirmingLandings`),
    /// or the final attempt -- returns `.positioned`, which resolves the step and retires the launch
    /// snapshot. The first is `.landedUnconfirmed`: a single synchronous read-back can be true while
    /// `HSplitView` has not yet run its own first layout, which would then apply AppKit's 400pt to a
    /// step already resolved and no longer watched. `.notLanded` (reachable, set, read back elsewhere)
    /// is capped at `launchPositioningMaxNotLanded` consecutive attempts; `.splitViewNotReady`
    /// (`setPosition` refused: not laid out) keeps the full poll budget.
    ///
    /// `outcome=positioned landed=250.0` beside a failing width assertion means window and panel
    /// geometry (a constrained Outline legitimately sits at its floor), not the decision rule.
    private func positionDivider(atLaunchWidthIn window: NSWindow, isFinalAttempt: Bool) -> LaunchPositioningOutcome {
        let launchWidth = OutlineSidebarWidth.idealWidth
        guard SplitViewAutosaveNaming.setTopLevelDividerPosition(launchWidth, in: window, animated: false) else {
            return .splitViewNotReady
        }
        let readBack = SplitViewAutosaveNaming.topLevelDividerPosition(in: window)
        guard let landed = SplitViewAutosaveNaming.landedPosition(
            readBack, target: launchWidth, floor: OutlineSidebarWidth.minWidth
        ) else {
            return .notLanded(readBack)
        }
        sidebarWidth = OutlineSidebarWidth.clamp(landed)
        lastVisibleWidth = sidebarWidth
        let landings = launchPositioningProgress.landedStreak + 1
        guard isFinalAttempt || landings >= Self.launchPositioningConfirmingLandings else {
            return .landedUnconfirmed(landed)
        }
        SplitViewAutosaveNaming.consumeLaunchSplitViewFrameKeys()
        return .positioned(landed)
    }

    /// Everything one attempt can read, gathered BEFORE it acts. The diagnostic line reports this
    /// rather than re-reading afterwards, because acting can consume the launch snapshot and move
    /// the divider, and the line is the only evidence the manual verification steps have.
    private func readLaunchPositioningState() -> LaunchPositioningReading {
        let window = AppDelegate.shared?.mainWindow
        return LaunchPositioningReading(
            window: window,
            liveName: window.flatMap { SplitViewAutosaveNaming.currentTopLevelAutosaveName(in: $0) },
            snapshotKeys: SplitViewAutosaveNaming.launchSplitViewFrameKeys,
            dividerPosition: window.flatMap { SplitViewAutosaveNaming.topLevelDividerPosition(in: $0) }
        )
    }

    /// One attempt at the launch step, called from BOTH `reconcileWidth` (the fast path) and the
    /// launch poll; `isFinalAttempt` is true only for the poll's last tick. Resolves the step only
    /// on a resolved outcome (`.positioned` once confirmed, or `.savedPositionWins`): resolving
    /// before the outcome is known is what let a reachable window with an unreachable split view
    /// burn the one-time step. An unconfirmed landing leaves the step open for the poll, on the
    /// fast path too; the `launchPositioningMaxNotLanded`th consecutive `.notLanded` gives up (see
    /// `giveUpLaunchPositioning`). Both callers run on the main actor and are gated by
    /// `hasReconciledFirstLayout`, so the divider is never moved twice.
    fileprivate func attemptLaunchPositioning(isFinalAttempt: Bool) -> LaunchPositioningOutcome {
        let reading = readLaunchPositioningState()
        let outcome = positionDividerAtLaunchWidthIfUnsaved(reading, isFinalAttempt: isFinalAttempt)
        if launchPositioningProgress.recordAttempt(outcome) {
            DebugLog.log(
                .lifecycle,
                launchPositioningLogLine(reading, outcome: outcome.label, landed: outcome.readBackPosition)
            )
        }
        if outcome.isResolved {
            resolveLaunchStep()
        } else if launchPositioningProgress.notLandedStreak >= Self.launchPositioningMaxNotLanded {
            giveUpLaunchPositioning(
                outcome: "notLandedCap", detail: "streak=\(launchPositioningProgress.notLandedStreak)"
            )
        }
        return outcome
    }

    /// Resolves the launch step: `reconcileWidth` may now adopt widths. It does ONLY that, and
    /// deliberately does not consume the launch snapshot: it is reached from exits that never
    /// consulted it (the hidden-pane gate, `endLaunchPositioningPoll` on every toggle), and consuming
    /// there would leave the next pane a live check that can only see this launch's own autosave.
    private func resolveLaunchStep() {
        hasReconciledFirstLayout = true
    }

    /// Retries the launch step actively, because `reconcileWidth` cannot: it only runs when the
    /// pane's width changes, and a pane stuck at AppKit's default never reports another change.
    /// Started from `onAppear`; polls up to `launchPositioningMaxTicks` times, stopping at the
    /// first resolved outcome. Every way out resolves the step through `resolveLaunchStep` (a
    /// resolved outcome, a tick that finds the poll no longer applicable, exhaustion), except a
    /// cancelled poll, which writes nothing (see `hasReconciledFirstLayout`): an unresolved flag
    /// would make `reconcileWidth` return early forever.
    ///
    /// The last tick is the FINAL attempt: a launch still waiting for `stabilize(for:)` then
    /// positions the divider at the launch width and adopts where it read back. So exhaustion moves
    /// nothing only when the window, the split view or its autosave name stayed unreadable (or the
    /// split view never laid out) for all `launchPositioningMaxTicks` ticks; it then adopts the
    /// width the divider is at and resolves the step.
    fileprivate func startLaunchPositioningPoll() {
        guard launchPositioningTask == nil else { return }
        launchPositioningTask = Task { @MainActor in
            // Only a poll that ran to its own end clears the handle. A cancelled one was already
            // cleared by its canceller, and a poll started since must not lose ITS handle to this
            // one draining late.
            defer { if !Task.isCancelled { launchPositioningTask = nil } }
            for tick in 1...Self.launchPositioningMaxTicks {
                guard !Task.isCancelled else { return }
                if launchPositioningTickIsFinal(isFinalAttempt: tick == Self.launchPositioningMaxTicks) { return }
                if tick < Self.launchPositioningMaxTicks {
                    try? await Task.sleep(for: Self.launchPositioningInterval)
                }
            }
            giveUpLaunchPositioning(outcome: "exhausted", detail: "ticks=\(Self.launchPositioningMaxTicks)")
        }
    }

    /// One poll tick; true when the poll is over (the step is resolved, however -- an attempt can
    /// resolve it by giving up on a `.notLanded` streak). The gate is re-evaluated on EVERY tick: an
    /// in-flight toggle ends the poll rather than competing with `animateDivider`/`snapToggle`, and
    /// a pane hidden at launch has nothing to position. A poll-side `.savedPositionWins` adopts the
    /// width AppKit restored, because no geometry callback follows to do it.
    private func launchPositioningTickIsFinal(isFinalAttempt: Bool) -> Bool {
        guard launchPollCanRun else {
            resolveLaunchStep()
            return true
        }
        if attemptLaunchPositioning(isFinalAttempt: isFinalAttempt) == .savedPositionWins {
            adoptLiveDividerWidth()
        }
        return hasReconciledFirstLayout
    }

    /// Whether the launch poll may still act; see `launchPositioningTickIsFinal`.
    private var launchPollCanRun: Bool {
        !hasReconciledFirstLayout && !isAnimatingToggle && editorState.isOutlineSidebarVisible
    }

    /// Adopts wherever the divider currently sits, when it can be read.
    private func adoptLiveDividerWidth() {
        if let live = currentDividerPosition() {
            adoptObservedWidth(live)
        }
    }

    /// Ends the launch poll because a toggle took over the divider (as opposed to the view going
    /// away, which is `.onDisappear`'s plain cancel). Resolves the launch step synchronously,
    /// before cancelling, so `reconcileWidth` is handed back to normal width adoption instead of
    /// returning early forever -- nothing depends on the cancelled poll's own drain to do it. It
    /// does not consume the launch snapshot (see `resolveLaunchStep`).
    fileprivate func endLaunchPositioningPoll() {
        resolveLaunchStep()
        launchPositioningTask?.cancel()
        launchPositioningTask = nil
    }

    /// Gives up on positioning the divider: the poll ran out (`exhausted`) or the divider stayed
    /// reachable but never landed (`notLandedCap`). Resolves the step and adopts the width the
    /// divider is at, since no geometry callback is guaranteed. Not "AppKit's layout stands" in
    /// general: a launch only waiting for stabilization was already positioned by the final
    /// attempt. It does not consume the launch snapshot, which it never consulted.
    private func giveUpLaunchPositioning(outcome: String, detail: String) {
        DebugLog.log(
            .lifecycle,
            launchPositioningLogLine(readLaunchPositioningState(), outcome: outcome, detail: detail)
        )
        resolveLaunchStep()
        adoptLiveDividerWidth()
    }

    /// The `[OutlineLaunchWidth]` diagnostic line, from what the attempt READ before it acted
    /// (`reading`), joined from an array so the type checker is not handed one long `+` chain.
    /// `name` is the live autosave name (nil while unreadable), `launchKeys` the launch snapshot's
    /// key count (nil once consumed or never captured), `divider` the leading pane's width before
    /// the attempt acted, `landed` where it read back afterwards (nil when nothing was set).
    private func launchPositioningLogLine(
        _ reading: LaunchPositioningReading,
        outcome: String,
        landed: CGFloat? = nil,
        detail: String? = nil
    ) -> String {
        var fields = [
            "[OutlineLaunchWidth] attempt=\(launchPositioningProgress.attempts)",
            "window=\(reading.window != nil)",
            "name=\(describe(reading.liveName))",
            "launchKeys=\(describe(reading.snapshotKeys?.count))",
            "divider=\(describe(reading.dividerPosition))",
            "landed=\(describe(landed))",
            "target=\(OutlineSidebarWidth.idealWidth)",
            "outcome=\(outcome)"
        ]
        if let detail { fields.append(detail) }
        return fields.joined(separator: " ")
    }

    /// An Optional as plain text -- `nil`, or the value without `Optional(...)` around it.
    private func describe<T>(_ value: T?) -> String {
        value.map { "\($0)" } ?? "nil"
    }
}

/// What one attempt at the launch positioning step concluded. `positioned` and `savedPositionWins`
/// RESOLVE the step; the rest leave it open. They are kept apart because they mean different things
/// to whoever debugs a 400pt launch (each `label` is what the log's `outcome=` field prints).
private enum LaunchPositioningOutcome: Equatable {
    /// The divider was moved to the launch width and read back there (the payload), and the landing
    /// is CONFIRMED: this is the second consecutive landing, or the final attempt.
    case positioned(CGFloat)
    /// The divider read back at the launch width (the payload) for the first time in a row. Not
    /// believed yet, so it resolves and consumes nothing; the poll re-sets the divider to confirm.
    case landedUnconfirmed(CGFloat)
    /// A previous session saved a divider position, so AppKit's own restore is authoritative.
    case savedPositionWins
    /// Not decidable yet: no window, the split view's autosave name unreadable, or stabilization
    /// still pending. Retried on the full poll budget; consumes nothing.
    case waiting(SplitViewAutosaveNaming.LaunchWaitReason)
    /// The decision was to position, but `setPosition` was refused: the split view is not laid out
    /// yet (or does not have two panes). Retried on the full poll budget.
    case splitViewNotReady
    /// `setPosition` ran against a reachable split view but the divider read back elsewhere (the
    /// payload). Capped at `launchPositioningMaxNotLanded` consecutive attempts.
    case notLanded(CGFloat?)

    /// Whether this outcome resolves the launch step.
    var isResolved: Bool {
        switch self {
        case .positioned, .savedPositionWins: return true
        case .landedUnconfirmed, .waiting, .splitViewNotReady, .notLanded: return false
        }
    }

    /// The `outcome=` text: the case, with the wait reason spelled out.
    var label: String {
        switch self {
        case .positioned: return "positioned"
        case .landedUnconfirmed: return "landedUnconfirmed"
        case .savedPositionWins: return "savedPositionWins"
        case .waiting(let reason): return "waiting(\(reason.rawValue))"
        case .splitViewNotReady: return "splitViewNotReady"
        case .notLanded: return "notLanded"
        }
    }

    /// Where the divider read back after `setPosition`, for the diagnostic line.
    var readBackPosition: CGFloat? {
        switch self {
        case .positioned(let landed), .landedUnconfirmed(let landed): return landed
        case .notLanded(let readBack): return readBack
        case .savedPositionWins, .waiting, .splitViewNotReady: return nil
        }
    }

    /// Whether `setPosition` ran and the divider read back at the launch width, confirmed or not.
    var isLanding: Bool {
        switch self {
        case .positioned, .landedUnconfirmed: return true
        case .savedPositionWins, .waiting, .splitViewNotReady, .notLanded: return false
        }
    }
}

/// What one launch attempt could read, gathered before it acted (see
/// `OutlineSidebarPane.readLaunchPositioningState`).
private struct LaunchPositioningReading {
    let window: NSWindow?
    /// The top-level split view's live autosave name; nil when it cannot be read.
    let liveName: String?
    /// The launch snapshot as it stood BEFORE this attempt could consume it.
    let snapshotKeys: Set<String>?
    /// The leading pane's width before the attempt acted; nil when unreadable.
    let dividerPosition: CGFloat?
}

/// Throttle and streak state for the launch step, which must not write the `[OutlineLaunchWidth]`
/// diagnostic line once per poll tick. A class, held in the pane's `@State`, so that recording an
/// attempt mutates the box and never the `@State` value itself -- the latter would invalidate the
/// pane's body on every tick.
private final class LaunchPositioningProgress {
    /// The diagnostic line is also written unconditionally on every Nth attempt, so a stuck state
    /// shows its duration instead of one line and seconds of silence.
    private static let heartbeatEvery = 10

    private(set) var attempts = 0
    /// Consecutive `.notLanded` attempts; any other outcome resets it, and a landing does.
    private(set) var notLandedStreak = 0
    /// Consecutive landings (`.landedUnconfirmed` or `.positioned`) BEFORE the attempt in flight;
    /// a non-landing resets it. Read to decide whether an attempt's own landing is the confirming one.
    private(set) var landedStreak = 0
    private var lastLabel: String?

    /// Counts one attempt, updates both streaks, and returns whether the attempt deserves a
    /// diagnostic line: the first attempt, every change of outcome (which covers the final
    /// resolution, always a change from an unresolved outcome or the first attempt), and every
    /// `heartbeatEvery`th attempt regardless, so a long wait reports on a fixed cadence.
    func recordAttempt(_ outcome: LaunchPositioningOutcome) -> Bool {
        attempts += 1
        if case .notLanded = outcome {
            notLandedStreak += 1
        } else {
            notLandedStreak = 0
        }
        landedStreak = outcome.isLanding ? landedStreak + 1 : 0
        defer { lastLabel = outcome.label }
        return attempts == 1 || attempts % Self.heartbeatEvery == 0 || outcome.label != lastLabel
    }
}
