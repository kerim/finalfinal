//
//  ExportAlertTruncationTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Coverage for `ExportViewModel.truncatedForAlert(_:limit:)` -- the pure helper
//  `showExportErrorAlert` uses to shorten a long pandoc/export error message for display in an
//  `NSAlert`, breaking at a sentence or word boundary instead of mid-word, or returning `nil`
//  when no truncation is needed at all. Previously untested despite its own doc comment
//  claiming a test could exercise every boundary case directly -- this file closes that gap.
//
//  `truncatedForAlert` is a pure, `nonisolated static func` (no alert construction, no
//  clipboard access), so every case below is exercised directly with a small, explicit
//  `limit`, without needing `NSAlert`, `NSPasteboard`, or a live export.

import Testing
import Foundation
@testable import final_final

@Suite("Export error alert truncation — Tier 1: Silent Killers")
struct ExportAlertTruncationTests {

    @Test("A message at or under the limit is returned unchanged as nil (no truncation needed)")
    func underLimitReturnsNil() {
        let message = "Short message"
        #expect(message.count < 20)
        #expect(ExportViewModel.truncatedForAlert(message, limit: 20) == nil)
    }

    @Test("A message exactly at the limit is also returned as nil -- the guard is strictly greater-than")
    func exactlyAtLimitReturnsNil() {
        let message = String(repeating: "A", count: 20)
        #expect(message.count == 20)
        #expect(ExportViewModel.truncatedForAlert(message, limit: 20) == nil)
    }

    @Test("A sentence boundary inside the window truncates at the sentence end, no ellipsis")
    func sentenceBoundaryInsideWindowTruncatesThere() {
        // window (first 20 chars) = "AAAAAAAAAA. BBBBBBBB" -- the period at position 11 is the
        // only ".!?" in the window, and the resulting head ("AAAAAAAAAA.", 11 chars) clears the
        // `head.count >= limit / 2` (10) floor, so this is the sentence-boundary branch, not the
        // whitespace fallback below it.
        let message = "AAAAAAAAAA. " + String(repeating: "B", count: 20)
        let result = ExportViewModel.truncatedForAlert(message, limit: 20)
        #expect(result == "AAAAAAAAAA.")
    }

    @Test("No sentence punctuation in the window falls back to the last whitespace boundary, plus an ellipsis")
    func whitespaceOnlyBoundaryFallsBackWithEllipsis() {
        // window (first 20 chars) = 19 A's + a trailing space -- no ".!?" anywhere in the
        // message, so the sentence-boundary branch never matches and this falls through to the
        // whitespace fallback.
        let message = String(repeating: "A", count: 19) + " " + String(repeating: "B", count: 20)
        let result = ExportViewModel.truncatedForAlert(message, limit: 20)
        #expect(result == String(repeating: "A", count: 19) + "\u{2026}")
    }

    @Test("A single long unbroken token (no punctuation, no whitespace) hard-cuts at the limit, plus an ellipsis")
    func unbrokenTokenHardCutsAtLimit() {
        let message = String(repeating: "A", count: 30)
        let result = ExportViewModel.truncatedForAlert(message, limit: 20)
        #expect(result == String(repeating: "A", count: 20) + "\u{2026}")
    }
}
