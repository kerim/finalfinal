//
//  OutlineSidebarWidth.swift
//  final final
//

import Foundation
import CoreGraphics

/// Shared min/ideal/max width constants for the Outline sidebar pane.
/// `OutlineSidebarPane.swift`'s `.frame(minWidth:idealWidth:maxWidth:)` reads these rather than
/// duplicating the 250/300/400 literals, so the pane's bounds and its default width cannot drift
/// apart.
///
/// `idealWidth` is the DEFAULT the pane opens at (Kerim's decision: 300pt) and the width the
/// in-session pane state starts from. It is NOT by itself what positions the divider: `HSplitView`
/// does not apply this pane's `idealWidth` at first layout (measured -- with nothing saved, the pane
/// opens at `maxWidth`, 400pt), so both the launch position and the re-show width are applied to the
/// divider explicitly, through
/// `SplitViewAutosaveNaming.setTopLevelDividerPosition(_:in:animated:)`:
/// - on first layout, `OutlineSidebarPane` positions the divider at `idealWidth` when there is no
///   autosaved position to honour (see `SplitViewAutosaveNaming.hasAutosavedDividerPosition(in:)`);
/// - on re-show, it positions the divider at the last width the user dragged to, so the app
///   guarantees that width rather than relying on AppKit happening to remember it;
/// - on hide, it positions the divider at 0.
///
/// The divider position that survives a launch is still AppKit's `NSSplitView.autosaveName`
/// (`SplitViewAutosaveNaming.stabilize(for:)`), as it always was. A `UserDefaults` width PAIR was
/// tried on this branch and withdrawn -- not because storing a width is wrong, but because a stored
/// value that never reaches the divider is inert; positioning the divider is the fix, and this type
/// therefore stays constants-only.
///
/// Deliberately its own type rather than a shared "PanelWidth" abstraction: the two panels have
/// different bounds (200/320/260 vs 250/300/400), the Annotations panel persists its own width in
/// `UserDefaults`, and the UX contract's requirement (§2, §10) is that the two panels BEHAVE
/// identically from the user's seat -- same toggle animation, both remembering their width -- while
/// their implementations stay separate (D1, D17).
enum OutlineSidebarWidth {
    static let minWidth: CGFloat = 250
    static let idealWidth: CGFloat = 300
    static let maxWidth: CGFloat = 400

    /// Clamps an arbitrary width into the sidebar's valid `[minWidth, maxWidth]` range.
    static func clamp(_ width: CGFloat) -> CGFloat {
        min(max(width, minWidth), maxWidth)
    }
}
