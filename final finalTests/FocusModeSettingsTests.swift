//
//  FocusModeSettingsTests.swift
//  final finalTests
//
//  Typewriter-scrolling settings coverage (plan §7, "Swift units").
//
//  Two layers are exercised:
//   - `FocusModeSettings` decoding: a blob written by a build with no typewriter keys must
//     decode to `false` / `0`; a blob with an out-of-range offset must be clamped on decode.
//   - `FocusModeSettingsManager`: the convenience accessors round-trip through
//     `AppDefaults.store` (an isolated suite while a test is running — see AppDefaults.swift),
//     `resetToDefaults()` restores both new fields, and `typewriterConfig` follows both a
//     field write and a reset.
//
//  `.serialized`: the manager is a singleton over `AppDefaults.store`, so these tests must not
//  run concurrently with anything else touching the same isolated domain.
//
//  Expectation-free note: no existing test's expectations are touched by this file.
//

import Foundation
import Testing
@testable import final_final

@Suite(.serialized)
@MainActor
struct FocusModeSettingsTests {

    /// A blob in the shape an older build wrote: the two typewriter keys are absent.
    private static let legacyBlob = Data(
        """
        {
          "hideLeftSidebar": true,
          "hideRightSidebar": true,
          "hideToolbar": true,
          "hideStatusBar": true,
          "enableParagraphHighlighting": true,
          "inlineAnnotations": "collapse"
        }
        """.utf8
    )

    @Test("the new fields decode to false / 0 from a blob written without them")
    func decodesDefaultsFromLegacyBlob() throws {
        let decoded = try JSONDecoder().decode(FocusModeSettings.self, from: Self.legacyBlob)
        #expect(decoded.typewriterScrollingEnabled == false)
        #expect(decoded.typewriterLineOffset == 0)
        // The pre-existing fields are untouched by the new code.
        #expect(decoded.inlineAnnotations == .collapse)
        #expect(decoded.hideLeftSidebar == true)
    }

    @Test("a full round-trip preserves both new fields")
    func roundTrips() throws {
        var settings = FocusModeSettings.default
        settings.typewriterScrollingEnabled = true
        settings.typewriterLineOffset = -7

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(FocusModeSettings.self, from: data)

        #expect(decoded.typewriterScrollingEnabled == true)
        #expect(decoded.typewriterLineOffset == -7)
        #expect(decoded == settings)
    }

    @Test("an out-of-range stored offset is clamped on decode")
    func clampsOutOfRangeStoredOffset() throws {
        let high = Data(#"{"typewriterLineOffset": 99}"#.utf8)
        let low = Data(#"{"typewriterLineOffset": -99}"#.utf8)
        #expect(try JSONDecoder().decode(FocusModeSettings.self, from: high).typewriterLineOffset == 10)
        #expect(try JSONDecoder().decode(FocusModeSettings.self, from: low).typewriterLineOffset == -10)
    }

    @Test("the range is exactly (-10)...10")
    func rangeIsFrozen() {
        #expect(FocusModeSettings.typewriterLineOffsetRange.lowerBound == -10)
        #expect(FocusModeSettings.typewriterLineOffsetRange.upperBound == 10)
        #expect(FocusModeSettingsManager.typewriterLineOffsetRange == FocusModeSettings.typewriterLineOffsetRange)
    }

    @Test("resetToDefaults() returns both new fields to false / 0")
    func resetReturnsTypewriterFieldsToDefault() {
        let manager = FocusModeSettingsManager.shared
        manager.typewriterScrollingEnabled = true
        manager.typewriterLineOffset = 6
        #expect(manager.settings.typewriterScrollingEnabled == true)
        #expect(manager.settings.typewriterLineOffset == 6)

        manager.resetToDefaults()

        #expect(manager.settings.typewriterScrollingEnabled == false)
        #expect(manager.settings.typewriterLineOffset == 0)
        #expect(manager.settings == .default)
    }

    @Test("typewriterConfig follows a field write")
    func configFollowsFieldWrite() {
        let manager = FocusModeSettingsManager.shared
        manager.resetToDefaults()
        #expect(manager.typewriterConfig == TypewriterConfig(enabled: false, lineOffset: 0))

        manager.typewriterScrollingEnabled = true
        manager.typewriterLineOffset = 4

        #expect(manager.typewriterConfig == TypewriterConfig(enabled: true, lineOffset: 4))
        // The accessor clamps through the manager, so an out-of-range assignment cannot reach
        // `settings` or the config.
        manager.typewriterLineOffset = 40
        #expect(manager.settings.typewriterLineOffset == 10)
        #expect(manager.typewriterConfig.lineOffset == 10)

        manager.resetToDefaults()
    }

    @Test("typewriterConfig follows a reset")
    func configFollowsReset() {
        let manager = FocusModeSettingsManager.shared
        manager.typewriterScrollingEnabled = true
        manager.typewriterLineOffset = -3
        #expect(manager.typewriterConfig == TypewriterConfig(enabled: true, lineOffset: -3))

        manager.resetToDefaults()

        #expect(manager.typewriterConfig == TypewriterConfig(enabled: false, lineOffset: 0))
    }

    @Test("the manager's update path syncs the config without a reset")
    func updateSyncsConfig() {
        let manager = FocusModeSettingsManager.shared
        manager.resetToDefaults()
        manager.update { $0.typewriterScrollingEnabled = true; $0.typewriterLineOffset = -10 }
        #expect(manager.typewriterConfig == TypewriterConfig(enabled: true, lineOffset: -10))
        manager.resetToDefaults()
        #expect(manager.typewriterConfig == TypewriterConfig(enabled: false, lineOffset: 0))
    }
}
