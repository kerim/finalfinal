//
//  EditorTypeScale.swift
//  final final
//
//  The document (in-editor) type scale — ux-contract D14: "the type scale crosses the
//  bridge like colours do". Sizes and line heights are declared once here, in Swift, and
//  reach the Milkdown/CodeMirror editors as CSS custom properties through the same
//  `AppColorScheme.cssVariables` -> `window.FinalFinal.setTheme()` channel colours already
//  use — see `Theme/ColorScheme.swift`.
//
//  Deliberately different numbers from `TypeScale` (Theme/Typography.swift), which is app
//  CHROME and copies the Mac's native text styles (ux-contract D13). D14's "cannot drift"
//  means each scale is declared once, in Swift — not that the two scales share numbers.
//
//  Pinned by `final finalTests/EditorTypeScaleBridgeTests.swift`, which also guards that
//  `web/shared/typography.css` never re-declares these variables, that every belt-and-
//  braces `var(--font-size-body, 18px)`-style fallback in web/ still matches these numbers,
//  and that every bridged `var()` usage in web/ has a fallback at all (a first-paint,
//  before-`setTheme()` guard — a fallback-less usage is CSS "guaranteed-invalid" and the
//  whole declaration is dropped, not rendered at some size).
//

import CoreGraphics

enum EditorTypeScale {
    // Document type scale (reading-oriented, not the app-chrome ladder in TypeScale).
    static let body: CGFloat = 18
    static let h1: CGFloat = 31
    static let h2: CGFloat = 26
    static let h3: CGFloat = 22
    static let h4: CGFloat = 18
    static let h5: CGFloat = 16
    static let h6: CGFloat = 14

    static let lineHeightBody: Double = 1.75
    static let lineHeightHeading: Double = 1.2

    // Font weights are theme-dependent (lighter in dark themes, for legibility on a dark
    // background) — emitted per-theme by `AppColorScheme.typographyCssVariables` in
    // ColorScheme.swift, not by `cssVariables` below.
    static let weightHeadingLight = 600
    static let weightBodyLight = 400
    static let weightHeadingDark = 500
    static let weightBodyDark = 300

    /// CSS custom-property declarations for the document type scale — sizes and line
    /// heights only. See the note on the weight constants above for why weights aren't
    /// emitted here.
    static var cssVariables: String {
        """
        --font-size-body: \(pxString(body));
        --font-size-h1: \(pxString(h1));
        --font-size-h2: \(pxString(h2));
        --font-size-h3: \(pxString(h3));
        --font-size-h4: \(pxString(h4));
        --font-size-h5: \(pxString(h5));
        --font-size-h6: \(pxString(h6));
        --line-height-body: \(decimalString(lineHeightBody));
        --line-height-heading: \(decimalString(lineHeightHeading));
        """
    }

    /// Formats a size as a whole-pixel CSS length, e.g. `18` -> `"18px"`. Rounds rather
    /// than truncates, so a non-integral value (e.g. `18.6`) becomes `19px`, not `18px`.
    /// Internal (not `private`) so `EditorTypeScaleBridgeTests` calls this directly instead
    /// of reimplementing the same formatting with its own `Int(...)` truncation — that
    /// duplication would let the test silently agree with a future wrong value instead of
    /// catching it.
    static func pxString(_ size: CGFloat) -> String {
        "\(Int(size.rounded()))px"
    }

    /// Formats a line-height multiplier as a trimmed decimal, e.g. `1.75` -> `"1.75"`,
    /// never `"1.7500"` — and `1.2` -> `"1.2"`, never `"1.20"`. Internal for the same
    /// direct-call-from-tests reason as `pxString` above.
    static func decimalString(_ value: Double) -> String {
        var text = String(value)
        guard text.contains(".") else { return text }
        while text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }
}
