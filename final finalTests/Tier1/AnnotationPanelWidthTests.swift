//
//  AnnotationPanelWidthTests.swift
//  final finalTests
//
//  Tier 1: width-persistence round-trip and clamping for the Annotations panel. The clamp is
//  the load-bearing piece -- AnnotationPanel's write-back gating (see its own doc comments)
//  is what's supposed to stop a width of 0 from ever being persisted mid-toggle-animation, but
//  this suite proves the SECOND line of defense holds too: even if a 0, negative, or absurdly
//  large value ends up in UserDefaults (a stale value from before the gating existed, or any
//  other bypass), `load(from:)` never hands it back to the view unclamped.
//
//  Isolation: each test gets its own throwaway UserDefaults suite (never `.standard`), matching
//  the pattern in DiagnosticsSettingsTests.swift -- no shared mutable state, so no `.serialized`
//  suite trait is needed.
//

import Testing
import Foundation
@testable import final_final

@Suite
struct AnnotationPanelWidthTests {

    /// A fresh, isolated UserDefaults suite -- never the real `com.kerim.final-final` domain.
    private func freshDefaults() -> UserDefaults {
        let suiteName = "com.kerim.final-final.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("UserDefaults(suiteName:) returned nil for a fixed, valid literal")
            return .standard
        }
        return defaults
    }

    @Test("A valid width round-trips through save/load unchanged")
    func roundTrip() {
        let defaults = freshDefaults()
        AnnotationPanelWidth.save(275, to: defaults)
        #expect(AnnotationPanelWidth.load(from: defaults) == 275)
    }

    @Test("Loading with nothing persisted yet returns the shared default width")
    func loadWithNothingPersisted() {
        let defaults = freshDefaults()
        #expect(AnnotationPanelWidth.load(from: defaults) == AnnotationPanelWidth.defaultWidth)
    }

    @Test("A width below the shared minimum is clamped up to it on save")
    func clampsBelowMinOnSave() {
        let defaults = freshDefaults()
        AnnotationPanelWidth.save(50, to: defaults)
        #expect(AnnotationPanelWidth.load(from: defaults) == AnnotationPanelWidth.minWidth)
    }

    @Test("A width above the shared maximum is clamped down to it on save")
    func clampsAboveMaxOnSave() {
        let defaults = freshDefaults()
        AnnotationPanelWidth.save(1_000, to: defaults)
        #expect(AnnotationPanelWidth.load(from: defaults) == AnnotationPanelWidth.maxWidth)
    }

    @Test("A garbage value written directly to the defaults key (bypassing save's own clamp) is clamped on load")
    func clampsGarbagePersistedValueOnLoad() {
        let defaults = freshDefaults()

        // A small-but-positive out-of-range value: clamped up to minWidth, same as save() would.
        defaults.set(50.0, forKey: AnnotationPanelWidth.defaultsKey)
        #expect(AnnotationPanelWidth.load(from: defaults) == AnnotationPanelWidth.minWidth)

        // An absurdly large value: clamped down to maxWidth.
        defaults.set(99_999.0, forKey: AnnotationPanelWidth.defaultsKey)
        #expect(AnnotationPanelWidth.load(from: defaults) == AnnotationPanelWidth.maxWidth)

        // A width of 0 -- exactly what a write-back mid-toggle-animation would produce if the
        // gating in AnnotationPanel ever regressed -- is treated as "nothing persisted" and
        // falls back to the shared default, not clamped to minWidth: 0 is never a real dragged
        // width, so it must not silently become "the user's preference is 200".
        defaults.set(0.0, forKey: AnnotationPanelWidth.defaultsKey)
        #expect(AnnotationPanelWidth.load(from: defaults) == AnnotationPanelWidth.defaultWidth)

        // A negative value: same treatment as 0.
        defaults.set(-40.0, forKey: AnnotationPanelWidth.defaultsKey)
        #expect(AnnotationPanelWidth.load(from: defaults) == AnnotationPanelWidth.defaultWidth)
    }

    // MARK: - sampleAction: what the panel does with one sampled rendered width

    @Test("Existing guard: a width read after the flag hid the panel but before the panel applied it is ignored")
    func hiddenPanelSampleBeforeTheHideIsAppliedIsIgnored() {
        // Values from the user's diagnostic log at 11:56:34.654: rendered width 232, flag already
        // hidden, panelWidth still 200. This passed before t-c86ccc4c too -- it is a regression
        // guard on the earlier fix, not one of this task's reproductions.
        #expect(
            AnnotationPanelWidth.sampleAction(
                newWidth: 232, previousWidth: 260, isVisible: false, isAnimating: false, panelWidth: 200
            ) == .ignoreUnsettled
        )
    }

    @Test("t-c86ccc4c (red): the tail of a hide animation, delivered after the completion cleared the animating flag, never re-shows")
    func hideAnimationTailAfterCompletionDoesNotReshow() {
        // Today this returns .reshow(200) and re-opens the panel. The hide sets panelWidth = 0 at
        // the START of the animation, so "settled hidden" is true throughout it. It is a quiet
        // .ignore, not .ignoreUnsettled: every frame of every hide lands here, and the panel logs
        // .ignoreUnsettled.
        #expect(
            AnnotationPanelWidth.sampleAction(
                newWidth: 4, previousWidth: 18, isVisible: false, isAnimating: false, panelWidth: 0
            ) == .ignore
        )
        #expect(
            AnnotationPanelWidth.sampleAction(
                newWidth: 40, previousWidth: 120, isVisible: false, isAnimating: false, panelWidth: 0
            ) == .ignore
        )
    }

    @Test("t-c86ccc4c (red): a whole hide animation's readings, replayed in order, never re-show once the flag clears")
    func replayedHideAnimationNeverReshows() {
        // Every frame of a 260 -> 0 hide that clears the 1pt threshold (.panelToggle is .easeOut,
        // monotonic, no overshoot -- the ordering argument holds only while that stays true).
        // The animating flag is modelled as already cleared for EVERY frame, the earliest possible
        // clear, which is the delivery order the fix must not depend on. `previous` is seeded with
        // the settled reading from before the hide, which an onChange would really have delivered.
        let frames: [CGFloat] = [210, 150, 96, 54, 24, 9, 3]
        var previous: CGFloat? = 260
        for frame in frames {
            let action = AnnotationPanelWidth.sampleAction(
                newWidth: frame, previousWidth: previous, isVisible: false, isAnimating: false, panelWidth: 0
            )
            #expect(action == .ignore, "frame \(frame) was not quietly ignored (got \(action))")
            previous = frame
        }
    }

    @Test("A genuine drag-open from a settled zero still re-shows")
    func settledHiddenPanelDraggedOpenIsReshown() {
        #expect(
            AnnotationPanelWidth.sampleAction(
                newWidth: 232, previousWidth: 0, isVisible: false, isAnimating: false, panelWidth: 0
            ) == .reshow(232)
        )
        #expect(
            AnnotationPanelWidth.sampleAction(
                newWidth: 999, previousWidth: 0, isVisible: false, isAnimating: false, panelWidth: 0
            ) == .reshow(320)
        )
        #expect(
            AnnotationPanelWidth.sampleAction(
                newWidth: 90, previousWidth: 0.5, isVisible: false, isAnimating: false, panelWidth: 0
            ) == .reshow(200)
        )
    }

    @Test("The previous reading must be at or under the threshold to count as growth from a settled zero")
    func reshowNeedsAPreviousReadingAtOrUnderTheThreshold() {
        #expect(
            AnnotationPanelWidth.sampleAction(
                newWidth: 232, previousWidth: AnnotationPanelWidth.hiddenSettledThreshold,
                isVisible: false, isAnimating: false, panelWidth: 0
            ) == .reshow(232)
        )
        #expect(
            AnnotationPanelWidth.sampleAction(
                newWidth: 232, previousWidth: 1.5, isVisible: false, isAnimating: false, panelWidth: 0
            ) == .ignore
        )
    }

    @Test("A drag-open replayed frame by frame re-shows on its first frame past the threshold")
    func replayedDragOpenReshows() {
        // `previous` is seeded with the settled reading from before the drag, not with a copy of
        // the first frame: an onChange never delivers a reading equal to its predecessor.
        let frames: [CGFloat] = [3, 14, 60, 140, 232]
        var previous: CGFloat? = 0
        var reshowCount = 0
        for frame in frames {
            let action = AnnotationPanelWidth.sampleAction(
                newWidth: frame, previousWidth: previous, isVisible: false, isAnimating: false, panelWidth: 0
            )
            if case .reshow = action { reshowCount += 1 }
            previous = frame
        }
        #expect(reshowCount == 1)
    }

    @Test("t-c86ccc4c (red): with no previous reading on record, a hidden panel is never re-shown")
    func hiddenPanelWithNoPreviousReadingIsNotReshown() {
        // This is what a programmatic toggle leaves behind: it clears the reading history, so a
        // stale frame from a superseded animation has nothing to look like a drag-open from.
        // Quiet .ignore, like the hide tail: not evidence of anything, so not worth a log line.
        #expect(
            AnnotationPanelWidth.sampleAction(
                newWidth: 232, previousWidth: nil, isVisible: false, isAnimating: false, panelWidth: 0
            ) == .ignore
        )
        #expect(
            AnnotationPanelWidth.sampleAction(
                newWidth: 12, previousWidth: nil, isVisible: false, isAnimating: false, panelWidth: 0
            ) == .ignore
        )
    }

    @Test("A settled hidden panel at or under 1pt is just its divider: ignored")
    func settledHiddenPanelAtRestIsIgnored() {
        for width: CGFloat in [0, 0.5, 1] {
            #expect(
                AnnotationPanelWidth.sampleAction(
                    newWidth: width, previousWidth: 0, isVisible: false, isAnimating: false, panelWidth: 0
                ) == .ignore
            )
        }
    }

    @Test("The mirror gap: a width read after the flag showed the panel but before the panel applied it is ignored")
    func visiblePanelSampleBeforeTheShowIsAppliedIsIgnored() {
        // The minimum width forced by the frame bounds (200) must never be saved over the user's real width.
        #expect(
            AnnotationPanelWidth.sampleAction(
                newWidth: 200, previousWidth: 0, isVisible: true, isAnimating: false, panelWidth: 0
            ) == .ignoreUnsettled
        )
    }

    @Test("A settled visible panel's width is tracked, and clamped to the ceiling, whatever moved it")
    func settledVisiblePanelWidthIsPersistedClamped() {
        #expect(
            AnnotationPanelWidth.sampleAction(
                newWidth: 275, previousWidth: 260, isVisible: true, isAnimating: false, panelWidth: 260
            ) == .persist(275)
        )
        #expect(
            AnnotationPanelWidth.sampleAction(
                newWidth: 999, previousWidth: 260, isVisible: true, isAnimating: false, panelWidth: 260
            ) == .persist(320)
        )
        // A reading exactly at the floor is the floor's own width, not below it: it still persists.
        #expect(
            AnnotationPanelWidth.sampleAction(
                newWidth: AnnotationPanelWidth.minWidth, previousWidth: 260,
                isVisible: true, isAnimating: false, panelWidth: 260
            ) == .persist(AnnotationPanelWidth.minWidth)
        )
        // A visible panel persists even with no reading history -- only .reshow needs evidence.
        #expect(
            AnnotationPanelWidth.sampleAction(
                newWidth: 275, previousWidth: nil, isVisible: true, isAnimating: false, panelWidth: 260
            ) == .persist(275)
        )
    }

    @Test("t-c86ccc4c (red): a sub-floor reading of a visible panel, the transient of an interrupted snap, is never persisted")
    func visiblePanelSubFloorReadingIsIgnoredNotClampedUp() {
        // A snap to visible over an in-flight hide leaves the observer live, so a frame from the
        // interrupted animation can arrive while the panel is visible and not animating. The frame
        // enforces the 200pt floor, so anything below it is a layout artifact, never a user width:
        // clamping it UP to 200 and persisting would replace the user's real width (here 260).
        #expect(
            AnnotationPanelWidth.sampleAction(
                newWidth: 40, previousWidth: 260, isVisible: true, isAnimating: false, panelWidth: 260
            ) == .ignoreUnsettled
        )
        #expect(
            AnnotationPanelWidth.sampleAction(
                newWidth: 150, previousWidth: 260, isVisible: true, isAnimating: false, panelWidth: 260
            ) == .ignoreUnsettled
        )
        #expect(
            AnnotationPanelWidth.sampleAction(
                newWidth: AnnotationPanelWidth.minWidth - 0.5, previousWidth: 260,
                isVisible: true, isAnimating: false, panelWidth: 260
            ) == .ignoreUnsettled
        )
    }

    @Test("A zero-width read of a visible panel is never persisted")
    func visiblePanelZeroWidthIsIgnored() {
        #expect(
            AnnotationPanelWidth.sampleAction(
                newWidth: 0, previousWidth: 260, isVisible: true, isAnimating: false, panelWidth: 260
            ) == .ignore
        )
        #expect(
            AnnotationPanelWidth.sampleAction(
                newWidth: 0, previousWidth: 200, isVisible: true, isAnimating: false, panelWidth: 0
            ) == .ignore
        )
    }

    @Test("Nothing is acted on while a show/hide animation runs")
    func animatingIsAlwaysIgnored() {
        for isVisible in [true, false] {
            for panelWidth: CGFloat in [0, 200, 260] {
                for width: CGFloat in [0, 1, 232, 999] {
                    for previous: CGFloat? in [nil, 0, 260] {
                        #expect(
                            AnnotationPanelWidth.sampleAction(
                                newWidth: width, previousWidth: previous,
                                isVisible: isVisible, isAnimating: true, panelWidth: panelWidth
                            ) == .ignore
                        )
                    }
                }
            }
        }
    }

    // MARK: - widthAfterToggleCompletion: what a finished toggle animation leaves behind

    @Test("A show animation that finished on a still-visible panel clamps its width")
    func completionOfAnHonestShowClamps() {
        #expect(
            AnnotationPanelWidth.widthAfterToggleCompletion(
                becomingVisible: true, isVisible: true, panelWidth: 260
            ) == 260
        )
        #expect(
            AnnotationPanelWidth.widthAfterToggleCompletion(
                becomingVisible: true, isVisible: true, panelWidth: 150
            ) == AnnotationPanelWidth.minWidth
        )
    }

    @Test("t-c86ccc4c: a show retargeted to hidden must not clamp 0 up to 200")
    func completionOfARetargetedShowKeepsTheHiddenInvariant() {
        // Defence in depth: snapToggle now retires the animation token so this completion is
        // discarded, but the invariant "0 means hidden" is stated here rather than left implicit.
        #expect(
            AnnotationPanelWidth.widthAfterToggleCompletion(
                becomingVisible: true, isVisible: false, panelWidth: 0
            ) == 0
        )
    }

    @Test("A hide animation's completion leaves the width alone")
    func completionOfAHideChangesNothing() {
        #expect(
            AnnotationPanelWidth.widthAfterToggleCompletion(
                becomingVisible: false, isVisible: false, panelWidth: 0
            ) == nil
        )
        #expect(
            AnnotationPanelWidth.widthAfterToggleCompletion(
                becomingVisible: false, isVisible: true, panelWidth: 260
            ) == nil
        )
    }

    // MARK: - frameBounds: the pane's width bounds, and the divider slack they allow

    @Test("A settled hidden panel is pinned to zero, leaving the divider no slack at all")
    func hiddenSettledPanelHasNoSlack() {
        let bounds = AnnotationPanelWidth.frameBounds(isVisible: false, isAnimating: false)
        #expect(bounds.min == 0)
        #expect(bounds.max == 0)
    }

    @Test("t-c86ccc4c: a panel Focus Mode snapped away must not keep an animating panel's 320pt ceiling")
    func snappedHiddenPanelHasNoSlackEvenAfterAToggleAnimation() {
        // snapToggle clears isAnimatingToggle precisely so this is the state reached ~50ms into a
        // show that a Focus Mode snap interrupts. With the flag left true, max would still be 320.
        #expect(AnnotationPanelWidth.frameBounds(isVisible: false, isAnimating: false).max == 0)
        #expect(AnnotationPanelWidth.frameBounds(isVisible: false, isAnimating: true).max == AnnotationPanelWidth.maxWidth)
    }

    @Test("A settled visible panel keeps its real drag-resize floor and ceiling")
    func visibleSettledPanelHasItsRealBounds() {
        let bounds = AnnotationPanelWidth.frameBounds(isVisible: true, isAnimating: false)
        #expect(bounds.min == AnnotationPanelWidth.minWidth)
        #expect(bounds.max == AnnotationPanelWidth.maxWidth)
    }

    @Test("While animating, the floor relaxes to zero in both directions so the width can travel")
    func animatingPanelFloorRelaxesToZero() {
        #expect(AnnotationPanelWidth.frameBounds(isVisible: true, isAnimating: true).min == 0)
        #expect(AnnotationPanelWidth.frameBounds(isVisible: false, isAnimating: true).min == 0)
    }
}
