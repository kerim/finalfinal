//
//  ExportSettingsBibliographyHeaderTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Regression coverage for the headless-PDF-bibliography bug: PDF export passed
//  --citeproc --bibliography --csl to pandoc but never --metadata reference-section-title,
//  so pandoc emitted a reference list with no heading above it. ExportSettings.
//  effectiveBibliographyHeaderName guarantees the value handed to that pandoc argument is
//  never empty -- omitting the argument for a degenerate (empty/whitespace) configured
//  name would silently reintroduce the exact bug this property exists to fix.
//

import Testing
import Foundation
@testable import final_final

@Suite("Export Settings — bibliography header name")
struct ExportSettingsBibliographyHeaderTests {

    @Test("Empty bibliographyHeaderName falls back to the shipped default")
    func emptyNameFallsBackToDefault() {
        var settings = ExportSettings.default
        settings.bibliographyHeaderName = ""
        #expect(settings.effectiveBibliographyHeaderName == ExportSettings.default.bibliographyHeaderName)
        #expect(!settings.effectiveBibliographyHeaderName.isEmpty, "Must never be empty -- that's the exact bug this property fixes")
    }

    @Test("Whitespace-only bibliographyHeaderName falls back to the shipped default")
    func whitespaceOnlyNameFallsBackToDefault() {
        var settings = ExportSettings.default
        settings.bibliographyHeaderName = "   \n\t  "
        #expect(settings.effectiveBibliographyHeaderName == ExportSettings.default.bibliographyHeaderName)
    }

    @Test("Custom bibliographyHeaderName passes through unchanged")
    func customNamePassesThroughUnchanged() {
        var settings = ExportSettings.default
        settings.bibliographyHeaderName = "Works Cited"
        #expect(settings.effectiveBibliographyHeaderName == "Works Cited")
    }

    @Test("Custom bibliographyHeaderName with surrounding whitespace is trimmed, not rejected")
    func customNameWithSurroundingWhitespaceIsTrimmed() {
        var settings = ExportSettings.default
        settings.bibliographyHeaderName = "  Works Cited  "
        #expect(settings.effectiveBibliographyHeaderName == "Works Cited")
    }
}
