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
}
