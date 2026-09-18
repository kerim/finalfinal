//
//  Animations.swift
//  final final
//

import SwiftUI

/// Shared timing for `.panelToggle` below -- kept as its own numeric constant (not just
/// inlined into the `Animation` value) so it has one obvious place to tune. Both
/// `AnnotationPanel` and `OutlineSidebarPane` tie their "animation finished" callback to the
/// animation itself via `withAnimation(_:completionCriteria:_:completion:)` rather than
/// scheduling a timer against this duration (review round 2, should-fix 5) -- a
/// `DispatchQueue.main.asyncAfter` guess at the animation's wall-clock length could fire before
/// the animation had visually finished under main-thread load.
enum PanelToggleTiming {
    static let duration: TimeInterval = 0.25
}

extension Animation {
    /// The show/hide width animation both side panels use. Each panel animates its OWN
    /// `idealWidth` with it -- neither rides a `NavigationSplitView` column-visibility behavior
    /// any more (the Outline's split container is an `HSplitView` whose sidebar pane carries this
    /// same animation in `OutlineSidebarPane.animateToggle`), so this constant is now genuinely
    /// shared code rather than an approximation of AppKit's. Matching the two panels' look is
    /// still a by-eye judgment made in manual/e2e verification, not something this curve can
    /// guarantee on its own.
    static let panelToggle: Animation = .easeOut(duration: PanelToggleTiming.duration)
}
