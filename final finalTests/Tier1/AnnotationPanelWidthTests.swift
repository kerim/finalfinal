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

    // MARK: - sampleAction: what the panel does with a sampled rendered width

    @Test("The reported race: a width read after the flag hid the panel but before the panel applied it is ignored")
    func hiddenPanelSampleBeforeTheHideIsAppliedIsIgnored() {
        // Values from the user's diagnostic log at 11:56:34.654: rendered width 232, flag already hidden, panelWidth still 200.
        #expect(
            AnnotationPanelWidth.sampleAction(newWidth: 232, isVisible: false, isAnimating: false, panelWidth: 200) == .ignoreUnsettled
        )
    }

    @Test("A settled hidden panel wider than 1pt still counts as dragged open (the backstop keeps working)")
    func settledHiddenPanelDraggedOpenIsReshown() {
        #expect(AnnotationPanelWidth.sampleAction(newWidth: 232, isVisible: false, isAnimating: false, panelWidth: 0) == .reshow(232))
        #expect(AnnotationPanelWidth.sampleAction(newWidth: 999, isVisible: false, isAnimating: false, panelWidth: 0) == .reshow(320))
        #expect(AnnotationPanelWidth.sampleAction(newWidth: 90, isVisible: false, isAnimating: false, panelWidth: 0) == .reshow(200))
    }

    @Test("A settled hidden panel at or under 1pt is just its divider: ignored")
    func settledHiddenPanelAtRestIsIgnored() {
        for width: CGFloat in [0, 0.5, 1] {
            #expect(AnnotationPanelWidth.sampleAction(newWidth: width, isVisible: false, isAnimating: false, panelWidth: 0) == .ignore)
        }
    }

    @Test("The mirror gap: a width read after the flag showed the panel but before the panel applied it is ignored")
    func visiblePanelSampleBeforeTheShowIsAppliedIsIgnored() {
        // The minimum width forced by the frame bounds (200) must never be saved over the user's real width.
        #expect(AnnotationPanelWidth.sampleAction(newWidth: 200, isVisible: true, isAnimating: false, panelWidth: 0) == .ignoreUnsettled)
    }

    @Test("A settled visible panel's width is tracked and clamped, whatever moved it")
    func settledVisiblePanelWidthIsPersistedClamped() {
        #expect(AnnotationPanelWidth.sampleAction(newWidth: 275, isVisible: true, isAnimating: false, panelWidth: 260) == .persist(275))
        #expect(AnnotationPanelWidth.sampleAction(newWidth: 999, isVisible: true, isAnimating: false, panelWidth: 260) == .persist(320))
        #expect(AnnotationPanelWidth.sampleAction(newWidth: 150, isVisible: true, isAnimating: false, panelWidth: 260) == .persist(200))
    }

    @Test("A zero-width read of a visible panel is never persisted")
    func visiblePanelZeroWidthIsIgnored() {
        #expect(AnnotationPanelWidth.sampleAction(newWidth: 0, isVisible: true, isAnimating: false, panelWidth: 260) == .ignore)
        #expect(AnnotationPanelWidth.sampleAction(newWidth: 0, isVisible: true, isAnimating: false, panelWidth: 0) == .ignore)
    }

    @Test("Nothing is acted on while a show/hide animation runs")
    func animatingIsAlwaysIgnored() {
        for isVisible in [true, false] {
            for panelWidth: CGFloat in [0, 200, 260] {
                for width: CGFloat in [0, 1, 232, 999] {
                    #expect(
                        AnnotationPanelWidth.sampleAction(newWidth: width, isVisible: isVisible, isAnimating: true, panelWidth: panelWidth) == .ignore
                    )
                }
            }
        }
    }
}
