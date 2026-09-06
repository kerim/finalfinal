//
//  Animations.swift
//  final final
//

import SwiftUI

/// Shared timing for `.panelToggle` below -- kept as its own numeric constant (not just
/// inlined into the `Animation` value) so it has one obvious place to tune. `AnnotationPanel`'s
/// width-animation fallback ties its "animation finished" callback to the animation itself via
/// `withAnimation(_:completionCriteria:_:completion:)` rather than scheduling a timer against
/// this duration (review round 2, should-fix 5) -- a `DispatchQueue.main.asyncAfter` guess at
/// the animation's wall-clock length could fire before the animation had visually finished
/// under main-thread load.
enum PanelToggleTiming {
    static let duration: TimeInterval = 0.25
}

extension Animation {
    /// Approximates the AppKit divider-collapse animation for the Annotations panel's own
    /// show/hide ONLY -- this is NOT shared with the Outline sidebar. The Outline sidebar
    /// animates through AppKit's `NavigationSplitView` column-visibility behavior, which does
    /// not take a SwiftUI `Animation` value at all, so there is no shared code to point both
    /// panels at; matching the two panels' look is a by-eye judgment made in manual/e2e
    /// verification, not something this constant can guarantee on its own.
    static let panelToggle: Animation = .easeOut(duration: PanelToggleTiming.duration)
}
