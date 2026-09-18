//
//  OutlineSidebarWidthTests.swift
//  final finalTests
//
//  Tier 1: the Outline sidebar pane's shared width constants and its `clamp`.
//
//  There is no persistence to test here any more. A `UserDefaults` width pair lived on this type
//  briefly and was removed: a VM run showed the pane opens at `maxWidth` on every launch (400pt,
//  including the very first launch on a fresh VM), because `HSplitView` does not honour the pane's
//  `idealWidth` at first layout -- so a stored width could round-trip perfectly and still never be
//  applied to the divider. Launch persistence is AppKit's `NSSplitView.autosaveName`
//  (`SplitViewAutosaveNaming.stabilize(for:)`), which is deliberately skipped whenever
//  `TestMode.isTesting`; it is verified by hand, not from any automated tier.
//
//  What remains IS worth pinning: the three constants the pane's `.frame(...)` reads, and the
//  clamp that keeps an observed width inside them. No UserDefaults anywhere.
//

import Testing
import Foundation
@testable import final_final

@Suite
struct OutlineSidebarWidthTests {

    @Test("The shared bounds are the pane's 250/300/400 ladder")
    func constants() {
        #expect(OutlineSidebarWidth.minWidth == 250)
        #expect(OutlineSidebarWidth.idealWidth == 300)
        #expect(OutlineSidebarWidth.maxWidth == 400)
    }

    @Test("The ideal width sits inside the bounds it is clamped against")
    func idealWidthIsWithinBounds() {
        #expect(OutlineSidebarWidth.idealWidth > OutlineSidebarWidth.minWidth)
        #expect(OutlineSidebarWidth.idealWidth < OutlineSidebarWidth.maxWidth)
    }

    @Test("A width inside the range is returned unchanged")
    func clampLeavesInRangeWidthsAlone() {
        #expect(OutlineSidebarWidth.clamp(275) == 275)
        #expect(OutlineSidebarWidth.clamp(OutlineSidebarWidth.minWidth) == OutlineSidebarWidth.minWidth)
        #expect(OutlineSidebarWidth.clamp(OutlineSidebarWidth.maxWidth) == OutlineSidebarWidth.maxWidth)
    }

    @Test("A width below the range is clamped up to the minimum")
    func clampRaisesBelowMinimum() {
        #expect(OutlineSidebarWidth.clamp(50) == OutlineSidebarWidth.minWidth)
        #expect(OutlineSidebarWidth.clamp(0) == OutlineSidebarWidth.minWidth)
        #expect(OutlineSidebarWidth.clamp(-40) == OutlineSidebarWidth.minWidth)
    }

    @Test("A width above the range is clamped down to the maximum")
    func clampLowersAboveMaximum() {
        #expect(OutlineSidebarWidth.clamp(1_000) == OutlineSidebarWidth.maxWidth)
        #expect(OutlineSidebarWidth.clamp(99_999) == OutlineSidebarWidth.maxWidth)
    }
}
