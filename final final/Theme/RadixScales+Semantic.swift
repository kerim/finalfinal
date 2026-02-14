//
//  RadixScales+Semantic.swift
//  final final
//
//  Semantic color scales for status and annotations.
//

import SwiftUI

// MARK: - Semantic Colors (Status & Annotations)

extension RadixScales {

    // MARK: Green (Success, Final, Completed)

    /// Green light scale
    static let green = RadixScale(
        step1: Color(hex: "#fbfefb"),
        step2: Color(hex: "#f4fbf4"),
        step3: Color(hex: "#e6f6e6"),
        step4: Color(hex: "#d6f1d6"),
        step5: Color(hex: "#c4e8c4"),
        step6: Color(hex: "#addaad"),
        step7: Color(hex: "#8ec98e"),
        step8: Color(hex: "#5bb45b"),
        step9: Color(hex: "#30a46c"),
        step10: Color(hex: "#2b9a66"),
        step11: Color(hex: "#218358"),
        step12: Color(hex: "#193b2d")
    )

    /// Green dark scale
    static let greenDark = RadixScale(
        step1: Color(hex: "#0e1512"),
        step2: Color(hex: "#121b17"),
        step3: Color(hex: "#132d21"),
        step4: Color(hex: "#113b29"),
        step5: Color(hex: "#174933"),
        step6: Color(hex: "#20573e"),
        step7: Color(hex: "#28684a"),
        step8: Color(hex: "#2f7c57"),
        step9: Color(hex: "#30a46c"),
        step10: Color(hex: "#33b074"),
        step11: Color(hex: "#3dd68c"),
        step12: Color(hex: "#b1f1cb")
    )

    // MARK: Red (Errors)

    /// Red light scale
    static let red = RadixScale(
        step1: Color(hex: "#fffcfc"),
        step2: Color(hex: "#fff7f7"),
        step3: Color(hex: "#feebec"),
        step4: Color(hex: "#ffdbdc"),
        step5: Color(hex: "#ffcdce"),
        step6: Color(hex: "#fdbdbe"),
        step7: Color(hex: "#f4a9aa"),
        step8: Color(hex: "#eb8e90"),
        step9: Color(hex: "#e5484d"),
        step10: Color(hex: "#dc3e42"),
        step11: Color(hex: "#ce2c31"),
        step12: Color(hex: "#641723")
    )

    /// Red dark scale
    static let redDark = RadixScale(
        step1: Color(hex: "#191111"),
        step2: Color(hex: "#201314"),
        step3: Color(hex: "#3b1219"),
        step4: Color(hex: "#500f1c"),
        step5: Color(hex: "#611623"),
        step6: Color(hex: "#72232d"),
        step7: Color(hex: "#8c333a"),
        step8: Color(hex: "#b54548"),
        step9: Color(hex: "#e5484d"),
        step10: Color(hex: "#ec5d5e"),
        step11: Color(hex: "#ff9592"),
        step12: Color(hex: "#ffd1d9")
    )

    // MARK: Yellow (Warning, Waiting)

    /// Yellow light scale
    static let yellow = RadixScale(
        step1: Color(hex: "#fdfdf9"),
        step2: Color(hex: "#fefce9"),
        step3: Color(hex: "#fffab8"),
        step4: Color(hex: "#fff394"),
        step5: Color(hex: "#ffe770"),
        step6: Color(hex: "#f3d768"),
        step7: Color(hex: "#e4c767"),
        step8: Color(hex: "#d5ae39"),
        step9: Color(hex: "#ffe629"),
        step10: Color(hex: "#ffdc00"),
        step11: Color(hex: "#9e6c00"),
        step12: Color(hex: "#473b1f")
    )

    /// Yellow dark scale
    static let yellowDark = RadixScale(
        step1: Color(hex: "#14120b"),
        step2: Color(hex: "#1b180f"),
        step3: Color(hex: "#2d2305"),
        step4: Color(hex: "#362b00"),
        step5: Color(hex: "#433500"),
        step6: Color(hex: "#524202"),
        step7: Color(hex: "#665417"),
        step8: Color(hex: "#836a21"),
        step9: Color(hex: "#ffe629"),
        step10: Color(hex: "#ffff57"),
        step11: Color(hex: "#f5e147"),
        step12: Color(hex: "#f6eeb4")
    )

    // MARK: Violet (Review, Reference)

    /// Violet light scale
    static let violet = RadixScale(
        step1: Color(hex: "#fdfcfe"),
        step2: Color(hex: "#faf8ff"),
        step3: Color(hex: "#f4f0fe"),
        step4: Color(hex: "#ebe4ff"),
        step5: Color(hex: "#e1d9ff"),
        step6: Color(hex: "#d4cafe"),
        step7: Color(hex: "#c2b5f5"),
        step8: Color(hex: "#aa99ec"),
        step9: Color(hex: "#6e56cf"),
        step10: Color(hex: "#654dc4"),
        step11: Color(hex: "#6550b9"),
        step12: Color(hex: "#2f265f")
    )

    /// Violet dark scale
    static let violetDark = RadixScale(
        step1: Color(hex: "#14121f"),
        step2: Color(hex: "#1b1525"),
        step3: Color(hex: "#291f43"),
        step4: Color(hex: "#33255b"),
        step5: Color(hex: "#3c2e69"),
        step6: Color(hex: "#473876"),
        step7: Color(hex: "#56468b"),
        step8: Color(hex: "#6958ad"),
        step9: Color(hex: "#6e56cf"),
        step10: Color(hex: "#7d66d9"),
        step11: Color(hex: "#baa7ff"),
        step12: Color(hex: "#e2ddfe")
    )
}
