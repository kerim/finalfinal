//
//  Spacing.swift
//  final final
//
//  Named spacing and corner-radius constants — UX contract §7/D12. New views use these
//  instead of inline point literals; existing inline literals migrate journey by journey,
//  not as one sweep (see the contract's §0). Introduced for the toast component (t-15cb7dd8);
//  first migrated journey: Version History (list and preview views — the restore-confirmation
//  sheet is not yet migrated).
//

import CoreGraphics

/// Spacing ladder: 2 (hairline gaps only), 4, 8, 12, 16, 24, 32 — contract §7.
enum Spacing {
    static let s2: CGFloat = 2
    static let s4: CGFloat = 4
    static let s8: CGFloat = 8
    static let s12: CGFloat = 12
    static let s16: CGFloat = 16
    static let s24: CGFloat = 24
    static let s32: CGFloat = 32
}

/// Corner radii: 4 for controls and pills, 8 for cards, popovers, and toasts — contract §7.
enum CornerRadius {
    static let control: CGFloat = 4
    static let card: CGFloat = 8
}
