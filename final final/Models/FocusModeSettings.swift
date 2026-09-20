//
//  FocusModeSettings.swift
//  final final
//
//  Settings model for focus mode configuration.
//  Stored in UserDefaults as a JSON blob.
//

import Foundation

/// What Focus Mode does to the annotations shown INSIDE the text (the annotations PANEL is a
/// separate choice: `FocusModeSettings.hideRightSidebar`).
///
/// Layer model: Focus Mode's inline setting > the project's own saved display setting > the
/// app-wide default (the display popover's "Set as Default"). Focus Mode's layer is in memory
/// only -- it is never written to the project.
enum FocusInlineAnnotationMode: String, Codable, CaseIterable, Sendable {
    /// Focus Mode does not touch the annotations in the text.
    case leaveAsIs
    /// Every annotation type shows collapsed while Focus Mode is on.
    case collapse
    /// Annotations are hidden from the text while Focus Mode is on (the Panel Only mechanism).
    case hide

    var displayName: String {
        switch self {
        case .leaveAsIs: return "Leave As Is"
        case .collapse: return "Collapse"
        case .hide: return "Hide"
        }
    }
}

/// Focus mode settings stored in UserDefaults
struct FocusModeSettings: Codable, Equatable, Sendable {
    var hideLeftSidebar: Bool = true
    /// Whether Focus Mode hides the Annotations PANEL. (It used to also decide whether inline
    /// annotations collapse -- that is now `inlineAnnotations`.)
    var hideRightSidebar: Bool = true
    var hideToolbar: Bool = true
    var hideStatusBar: Bool = true
    var enableParagraphHighlighting: Bool = true
    var inlineAnnotations: FocusInlineAnnotationMode = .collapse

    // MARK: - Defaults

    static let `default` = FocusModeSettings()

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let settingsKey = "com.kerim.final-final.focusModeSettings"
    }

    // Declared explicitly (rather than synthesized) because the decode-time migration in the
    // extension below refers to them.
    private enum CodingKeys: String, CodingKey {
        case hideLeftSidebar
        case hideRightSidebar
        case hideToolbar
        case hideStatusBar
        case enableParagraphHighlighting
        case inlineAnnotations
    }

    // MARK: - Persistence

    /// Load settings from UserDefaults.
    ///
    /// Routed through `AppDefaults.store` (`.standard` in production, an isolated test-only
    /// suite while any kind of test is running) rather than `UserDefaults.standard` directly —
    /// `com.kerim.final-final.focusModeSettings` is one of the eight keys
    /// `TestMode.clearTestState()` resets, and reading it straight from `.standard` would mean
    /// a unit test run reads (and, via `save()` below, could overwrite) the real user's
    /// persisted focus mode preferences. See `AppDefaults.swift`.
    static func load() -> FocusModeSettings {
        guard let data = AppDefaults.store.data(forKey: Keys.settingsKey),
              let settings = try? JSONDecoder().decode(FocusModeSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    /// Save settings to UserDefaults. See `load()` for why this goes through `AppDefaults.store`.
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            AppDefaults.store.set(data, forKey: Keys.settingsKey)
        }
    }
}

// MARK: - Decoding (with migration)

extension FocusModeSettings {
    /// Every field is optional in the stored blob, so a blob written by an older build (which
    /// had no `inlineAnnotations`) still decodes.
    ///
    /// THIS IS THE ENTIRE MIGRATION of the old "Hide Annotations" toggle. That toggle
    /// (`hideRightSidebar`) used to decide both whether the Annotations panel hides AND whether
    /// inline annotations collapse. A stored blob with no `inlineAnnotations` key therefore
    /// takes its value from the old toggle -- on keeps collapsing, off leaves the text alone --
    /// so nobody's behaviour changes on update. It happens at decode time, with no write: a
    /// user who never opens the Focus pane keeps the old blob until their first change re-saves
    /// it with the explicit key. (A plain default of `.collapse` would silently start
    /// collapsing for everyone who had the toggle off.) With no stored blob at all (fresh
    /// install), this never runs and `.default` applies.
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hideLeftSidebar = try container.decodeIfPresent(Bool.self, forKey: .hideLeftSidebar) ?? hideLeftSidebar
        hideRightSidebar = try container.decodeIfPresent(Bool.self, forKey: .hideRightSidebar) ?? hideRightSidebar
        hideToolbar = try container.decodeIfPresent(Bool.self, forKey: .hideToolbar) ?? hideToolbar
        hideStatusBar = try container.decodeIfPresent(Bool.self, forKey: .hideStatusBar) ?? hideStatusBar
        enableParagraphHighlighting = try container.decodeIfPresent(Bool.self, forKey: .enableParagraphHighlighting)
            ?? enableParagraphHighlighting
        // Decoded as a plain String and mapped, so an unrecognised value (a typo, a hand edit, a
        // newer build's case after a downgrade) falls back to the migration rule below instead
        // of throwing -- a throw would make `load()` discard the WHOLE blob and reset every
        // other Focus preference to its default.
        let storedInline = try? container.decodeIfPresent(String.self, forKey: .inlineAnnotations)
        inlineAnnotations = storedInline.flatMap(FocusInlineAnnotationMode.init(rawValue:))
            ?? (hideRightSidebar ? .collapse : .leaveAsIs)
    }
}

// MARK: - Observable Settings Manager

/// Main-thread observable wrapper for focus mode settings
@MainActor
@Observable
final class FocusModeSettingsManager {

    /// Singleton instance
    static let shared = FocusModeSettingsManager()

    /// Current settings
    private(set) var settings: FocusModeSettings

    private init() {
        settings = FocusModeSettings.load()
    }

    /// Update settings and persist. Posts `.focusInlineAnnotationsChanged` when the block
    /// actually changed `inlineAnnotations`, so an open project can re-arm Focus Mode's
    /// override immediately (see `EditorViewState.reconcileFocusInlineOverride()`).
    func update(_ block: (inout FocusModeSettings) -> Void) {
        let previousInline = settings.inlineAnnotations
        block(&settings)
        settings.save()
        postInlineAnnotationsChangeIfNeeded(from: previousInline)
    }

    /// Reset to defaults. Goes through the same change-detecting post as `update`: a reset
    /// that flips `inlineAnnotations` (say Leave As Is back to Collapse) must reach an open
    /// project already in Focus Mode, or that project keeps a stale override.
    func resetToDefaults() {
        let previousInline = settings.inlineAnnotations
        settings = .default
        settings.save()
        postInlineAnnotationsChangeIfNeeded(from: previousInline)
    }

    /// Post `.focusInlineAnnotationsChanged` only if `inlineAnnotations` differs from `previous`.
    private func postInlineAnnotationsChangeIfNeeded(from previous: FocusInlineAnnotationMode) {
        guard settings.inlineAnnotations != previous else { return }
        NotificationCenter.default.post(name: .focusInlineAnnotationsChanged, object: nil)
    }

    /// Convenience accessors

    var hideLeftSidebar: Bool {
        get { settings.hideLeftSidebar }
        set { update { $0.hideLeftSidebar = newValue } }
    }

    var hideRightSidebar: Bool {
        get { settings.hideRightSidebar }
        set { update { $0.hideRightSidebar = newValue } }
    }

    var hideToolbar: Bool {
        get { settings.hideToolbar }
        set { update { $0.hideToolbar = newValue } }
    }

    var hideStatusBar: Bool {
        get { settings.hideStatusBar }
        set { update { $0.hideStatusBar = newValue } }
    }

    var enableParagraphHighlighting: Bool {
        get { settings.enableParagraphHighlighting }
        set { update { $0.enableParagraphHighlighting = newValue } }
    }

    var inlineAnnotations: FocusInlineAnnotationMode {
        get { settings.inlineAnnotations }
        set { update { $0.inlineAnnotations = newValue } }
    }
}
