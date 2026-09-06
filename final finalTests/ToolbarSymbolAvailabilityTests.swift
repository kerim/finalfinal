//
//  ToolbarSymbolAvailabilityTests.swift
//  final finalTests
//
//  Regression coverage for the toolbar-icon-cleanup task (bt t-450d5a45): guards the exact SF
//  Symbols this task standardizes on against a typo or a name renamed/removed in a newer SF
//  Symbols catalog. `NSImage(systemSymbolName:)` fails silently -- it returns nil rather than
//  crashing or failing a build -- so a bad name would otherwise show up only as a missing icon
//  in the running app, never here.
//
//  Covers: the Cite/Footnote toolbar icons (EditorToolbar.swift), the one reset symbol used
//  app-wide (Reset to default / Reset to theme default buttons), and the chevron.right/
//  chevron.down disclosure pair used where something collapses/expands (FindBarView's
//  Replace-row toggle, AnnotationCardView's card expand, AnnotationPanel). ChevronButton uses
//  a different pair (chevron.left/chevron.right) and is not covered by these two names.
//

import Testing
import AppKit

@Suite
struct ToolbarSymbolAvailabilityTests {

    /// The 5 SF Symbols this task standardizes on.
    private static let symbolNames = [
        "text.book.closed",       // Cite/Citation toolbar button
        "text.append",            // Footnote toolbar button
        "arrow.counterclockwise", // reset-to-default icon buttons
        "chevron.right",          // disclosure, collapsed
        "chevron.down"            // disclosure, expanded
    ]

    @Test("Toolbar SF Symbols resolve on this macOS SDK")
    func toolbarSymbolsResolve() {
        for name in Self.symbolNames {
            #expect(
                NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                "NSImage(systemSymbolName:) failed to resolve '\(name)' -- check for a typo, or a symbol renamed/removed."
            )
        }
    }
}
