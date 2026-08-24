//
//  ExportSettings.swift
//  final final
//
//  Settings model for export configuration.
//  Stored in UserDefaults with type-safe keys.
//

import Foundation

/// Export format options
enum ExportFormat: String, CaseIterable, Identifiable, Sendable, Codable {
    case word = "docx"
    case pdf = "pdf"
    case odt = "odt"

    var id: String { rawValue }

    /// Display name for UI
    var displayName: String {
        switch self {
        case .word: return "Word (.docx)"
        case .pdf: return "PDF"
        case .odt: return "OpenDocument (.odt)"
        }
    }

    /// File extension
    var fileExtension: String {
        rawValue
    }

    /// Pandoc output format argument
    var pandocFormat: String {
        switch self {
        case .word, .odt:
            return rawValue + "+native_numbering"
        case .pdf:
            return rawValue
        }
    }

    /// UTType identifier for save panel
    var contentTypeIdentifier: String {
        switch self {
        case .word: return "org.openxmlformats.wordprocessingml.document"
        case .pdf: return "com.adobe.pdf"
        case .odt: return "org.oasis-open.opendocument.text"
        }
    }
}

/// Export settings stored in UserDefaults
struct ExportSettings: Codable, Sendable {

    /// Custom Pandoc path (nil = auto-detect)
    var customPandocPath: String?

    /// Use custom Lua filter for Zotero citations
    var useCustomLuaScript: Bool = false

    /// Path to custom Lua filter (nil = use bundled)
    var customLuaScriptPath: String?

    /// Use custom reference document
    var useCustomReferenceDoc: Bool = false

    /// Path to custom reference document (nil = use bundled)
    var customReferenceDocPath: String?

    /// Show Zotero warning when not running
    var showZoteroWarning: Bool = true

    /// Default export format
    var defaultFormat: ExportFormat = .word

    /// Include annotations in exported documents
    /// When false, annotation comments (<!-- ::type:: text -->) are stripped before export
    var includeAnnotations: Bool = false

    /// Header name for auto-generated bibliography section
    /// Common options: Bibliography, References, Works Cited
    var bibliographyHeaderName: String = "Bibliography"

    /// Use a custom CSL citation style, in place of the bundled Chicago author-date style
    var useCustomCSLStyle: Bool = false

    /// Path to custom CSL style file (nil = use bundled Chicago)
    var customCSLStylePath: String?

    /// No-arg initializer using each property's declared default value. Swift stops
    /// synthesizing the normal memberwise initializer once any custom initializer is
    /// declared -- the custom `init(from decoder:)` below counts -- so this restores the
    /// `ExportSettings()` call `.default` (just below) relies on.
    init() {}

    // MARK: - Defaults

    static let `default` = ExportSettings()

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let settingsKey = "com.kerim.final-final.exportSettings"
    }

    // MARK: - Codable

    /// Custom decode: every field EXCEPT the two CSL-style fields below is decoded with
    /// plain `decode` (throwing on a missing key), exactly matching what synthesized
    /// `Codable` already did for them -- no behavior change for real saved payloads, which
    /// have always carried all of those keys. The two new fields use `decodeIfPresent` with
    /// an explicit fallback to their declared default instead.
    ///
    /// This exists because Swift's SYNTHESIZED `init(from:)` does NOT fall back to a
    /// property's declared default for a missing key -- it throws `keyNotFound`. `load()`
    /// below catches any decode failure with `try?` and resets the ENTIRE settings struct to
    /// `.default`, including unrelated fields like `customPandocPath`. Without this custom
    /// `init(from:)`, adding `useCustomCSLStyle`/`customCSLStylePath` would silently wipe
    /// every existing user's saved export settings the first time they upgrade and load an
    /// old settings blob that predates these two keys.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        customPandocPath = try container.decodeIfPresent(String.self, forKey: .customPandocPath)
        useCustomLuaScript = try container.decode(Bool.self, forKey: .useCustomLuaScript)
        customLuaScriptPath = try container.decodeIfPresent(String.self, forKey: .customLuaScriptPath)
        useCustomReferenceDoc = try container.decode(Bool.self, forKey: .useCustomReferenceDoc)
        customReferenceDocPath = try container.decodeIfPresent(String.self, forKey: .customReferenceDocPath)
        showZoteroWarning = try container.decode(Bool.self, forKey: .showZoteroWarning)
        defaultFormat = try container.decode(ExportFormat.self, forKey: .defaultFormat)
        includeAnnotations = try container.decode(Bool.self, forKey: .includeAnnotations)
        bibliographyHeaderName = try container.decode(String.self, forKey: .bibliographyHeaderName)
        useCustomCSLStyle = try container.decodeIfPresent(Bool.self, forKey: .useCustomCSLStyle) ?? false
        customCSLStylePath = try container.decodeIfPresent(String.self, forKey: .customCSLStylePath)
    }

    // MARK: - Persistence

    /// Test seam: `BlockParserBibliographyHeaderNameTests` overrides this to a per-test
    /// isolated `UserDefaults(suiteName:)` instance so tests never read/write the real
    /// `UserDefaults.standard` domain -- a crash mid-test between a write and its cleanup
    /// would otherwise permanently change the user's real bibliography header name.
    /// Defaults to `AppDefaults.store` -- `.standard` in production, unchanged -- because
    /// unit tests run inside the real app process (see `AppDefaults.swift`'s doc comment):
    /// `UserDefaults.standard` during ANY test run is the user's live settings domain, not
    /// a sandboxed double. Every OTHER path into `save()` besides this suite's own isolated
    /// override -- the settings-pane setters, `resetToDefaults()`, etc. -- would otherwise
    /// keep writing the user's real export settings for the whole duration of any test run.
    /// Same shape as `DiagnosticLogFile._userDefaults`/`.userDefaults` (see that file's doc
    /// comment); `nonisolated(unsafe)` because `load()`/`save()` below are plain,
    /// non-actor-isolated struct methods called from both @MainActor call sites and
    /// non-@MainActor contexts (e.g. `BlockParser.isBibliographyHeading`, a `nonisolated
    /// static func`).
    nonisolated(unsafe) private static var _userDefaults: UserDefaults = AppDefaults.store
    static var userDefaults: UserDefaults {
        get { _userDefaults }
        set { _userDefaults = newValue }
    }

    /// Load settings from UserDefaults
    static func load() -> ExportSettings {
        guard let data = userDefaults.data(forKey: Keys.settingsKey),
              let settings = try? JSONDecoder().decode(ExportSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    /// Save settings to UserDefaults
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            ExportSettings.userDefaults.set(data, forKey: Keys.settingsKey)
        }
    }

    // MARK: - Computed Properties

    /// Effective Lua script path (custom or bundled)
    var effectiveLuaScriptPath: String? {
        if useCustomLuaScript, let custom = customLuaScriptPath, !custom.isEmpty {
            return custom
        }
        return Bundle.main.url(forResource: "zotero", withExtension: "lua", subdirectory: "Export")?.path
    }

    /// Effective reference document path (custom or bundled) for a given export format.
    ///
    /// Pandoc's `--reference-doc` must match the output format's container type: a `.docx`
    /// reference for Word output, a `.odt` reference for ODT output. Passing a `.docx` reference
    /// to an ODT export merges the Word file's internals into the `.odt` output — including its
    /// sample body text — producing a malformed hybrid file. So each format only ever receives a
    /// reference doc whose extension matches.
    func effectiveReferenceDocPath(for format: ExportFormat) -> String? {
        switch format {
        case .pdf:
            // Reference-doc is unused for PDF export.
            return nil

        case .word:
            if useCustomReferenceDoc, let custom = customReferenceDocPath, !custom.isEmpty,
               custom.lowercased().hasSuffix(".docx") {
                return custom
            }
            return Bundle.main.url(forResource: "reference", withExtension: "docx", subdirectory: "Export")?.path

        case .odt:
            if useCustomReferenceDoc, let custom = customReferenceDocPath, !custom.isEmpty,
               custom.lowercased().hasSuffix(".odt") {
                return custom
            }
            return Bundle.main.url(forResource: "reference", withExtension: "odt", subdirectory: "Export")?.path
        }
    }

    /// Check if custom Lua script path is valid
    var isCustomLuaScriptValid: Bool {
        guard useCustomLuaScript, let path = customLuaScriptPath, !path.isEmpty else {
            return true  // Not using custom, so valid
        }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Check if custom reference doc path is valid
    var isCustomReferenceDocValid: Bool {
        guard useCustomReferenceDoc, let path = customReferenceDocPath, !path.isEmpty else {
            return true  // Not using custom, so valid
        }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Outcome of resolving the configured custom CSL style, computed by a SINGLE read+parse
    /// of the file via `resolveCSLStyle()`. Exists so a caller that needs more than one fact
    /// about the custom style (e.g. `bibliographyWriteArguments`, which needs both "which
    /// path to hand pandoc" and "which warning to show") can get them all from one
    /// computation instead of calling `effectiveCSLStylePath`/`isCustomCSLStyleValid`
    /// separately and re-reading/re-parsing the file each time -- which also risks the two
    /// answers disagreeing if the file changes between calls.
    enum CSLStyleResolution: Equatable {
        /// The toggle is off -- no custom style is in play.
        case notCustom
        /// The toggle is on, but no path has been configured yet (nil or empty). Distinct
        /// from `.notFound`: nothing was looked up and found missing, nothing was set.
        case notConfigured
        /// The toggle is on, a path is configured, but no file exists there.
        case notFound
        /// The toggle is on, the configured file exists, but it isn't a usable CSL style:
        /// not well-formed XML, a `<style>` root with no `<citation>` rules of its own, or a
        /// "dependent" style (a `<link rel="independent-parent">` referencing a parent style
        /// instead of carrying its own formatting).
        case invalidCSL
        /// The toggle is on and a usable custom style was found at `path`.
        case valid(path: String)
    }

    /// Resolve the custom CSL style's current state with exactly one file read + parse. See
    /// `CSLStyleResolution`'s doc comment for why every caller that needs more than a single
    /// yes/no about the custom style should go through this instead of composing
    /// `effectiveCSLStylePath` and `isCustomCSLStyleValid` (each of which -- see below --
    /// still exist as convenience wrappers around this same resolution, for the many callers
    /// that only need one fact).
    func resolveCSLStyle() -> CSLStyleResolution {
        guard useCustomCSLStyle else { return .notCustom }
        guard let path = customCSLStylePath, !path.isEmpty else { return .notConfigured }
        guard FileManager.default.fileExists(atPath: path) else { return .notFound }
        guard ExportSettings.isWellFormedCSLStyle(atPath: path) else { return .invalidCSL }
        return .valid(path: path)
    }

    /// Effective CSL citation style path (custom or bundled Chicago author-date).
    ///
    /// This is the single source of truth both consumers read from: pandoc's `--csl`
    /// argument (`ExportService+Citations.swift`'s `bibliographyWriteArguments`) and the
    /// live in-editor citeproc engine (`MilkdownCoordinator+MessageHandlers.swift`'s
    /// `pushCitationStyle`). Keeping them on one shared computation means they can never
    /// disagree about which style is "the" active one.
    ///
    /// Falls back to the bundled style unless ALL of: the toggle is on, a non-empty path is
    /// configured, the file exists, AND the file is well-formed, usable CSL XML (see
    /// `isWellFormedCSLStyle`'s doc comment). The content check matters specifically for
    /// pandoc: a garbled custom style handed to `--csl` is a hard, cryptic pandoc failure,
    /// not a graceful one -- unlike the editor's citeproc engine, which has its own
    /// defense-in-depth try/catch (see `setStyle()` in
    /// `web/milkdown/src/citeproc-engine.ts`) but shouldn't need to rely on it for a file
    /// this check can already reject up front.
    var effectiveCSLStylePath: String? {
        if case .valid(let path) = resolveCSLStyle() { return path }
        return Bundle.main.url(forResource: "chicago-author-date", withExtension: "csl", subdirectory: "Export")?.path
    }

    /// Check if custom CSL style path is valid. Mirrors `isCustomLuaScriptValid`/
    /// `isCustomReferenceDocValid` -- existence only -- and drives one part of the
    /// preferences-pane red caption (see `customCSLStyleCaption`) the same way those do.
    ///
    /// This is deliberately NOT the same check `effectiveCSLStylePath` uses: a file that
    /// exists but isn't well-formed/usable CSL still reads `true` here (the path itself is
    /// fine, just its contents), while `effectiveCSLStylePath` additionally rejects it and
    /// falls back to bundled. `customCSLStyleCaption` below covers that gap for the
    /// preferences pane; an export-time warning in `bibliographyWriteArguments` covers it at
    /// export time.
    var isCustomCSLStyleValid: Bool {
        if case .notFound = resolveCSLStyle() { return false }
        return true
    }

    /// Preferences-pane caption for the custom CSL style row, distinguishing a missing file
    /// from one that exists but isn't a usable CSL style -- two different, common situations
    /// that used to share one misleading message. `nil` means nothing to show: the toggle is
    /// off, no path has been configured yet (the very first state after checking the box),
    /// or the configured file is a usable style.
    var customCSLStyleCaption: String? {
        switch resolveCSLStyle() {
        case .notCustom, .notConfigured, .valid:
            return nil
        case .notFound:
            return "File not found at specified path"
        case .invalidCSL:
            return "File exists but isn't a usable CSL style"
        }
    }

    /// Well-formedness check for a CSL style file: valid XML with a root `<style>` element
    /// (the CSL 1.0 schema's root element name, matched by local name regardless of any
    /// namespace prefix -- see below) that also carries its own `<citation>` formatting
    /// rules and isn't a "dependent" style. Deliberately NOT a full CSL schema validation --
    /// just enough to reject "not actually a usable CSL file" (garbage text, a truncated
    /// download, an unrelated XML document, or a dependent style with no rules of its own)
    /// before pandoc or citeproc-js ever see it. citeproc-js itself is the final authority
    /// for anything well-formed-but-still-invalid that this check lets through -- see that
    /// engine's `setStyle()` try/catch rollback in `web/milkdown/src/citeproc-engine.ts`.
    ///
    /// Two things this rejects beyond the original "has a `<style>` root" check:
    /// - A "dependent" CSL style: real, commonly-distributed CSL files that reference a
    ///   parent style via `<info><link rel="independent-parent" .../></info>` and contain no
    ///   actual formatting rules of their own. These are well-formed XML with a `<style>`
    ///   root, so they used to pass this check as "valid" and then make pandoc's `--csl`
    ///   fail with a cryptic low-level error -- exactly the failure mode this function exists
    ///   to prevent. Caught two ways here: no `<citation>` element (a dependent style has
    ///   none), and the `independent-parent` link explicitly, so the more specific case is
    ///   never silently swallowed by "just" the missing-citation signal.
    /// - A `shouldProcessNamespaces = false` (the `XMLParser` default) rejection of a
    ///   legitimately-prefixed root like `<csl:style xmlns:csl="...">`: with namespace
    ///   processing off, the delegate sees the raw tag name `"csl:style"`, which never equals
    ///   `"style"`. Turning namespace processing on makes the delegate see the LOCAL name
    ///   (`"style"`) regardless of prefix, matching both the common unprefixed form (as used
    ///   by the bundled Chicago style and every CSL file on zotero.org) and a prefixed one.
    private static func isWellFormedCSLStyle(atPath path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        let capture = CSLRootElementCapture()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = capture
        guard parser.parse() else { return false }
        guard capture.rootElementName == "style" else { return false }
        guard !capture.hasIndependentParentLink else { return false }
        return capture.hasCitationElement
    }

    /// Bibliography header name for pandoc's `--metadata reference-section-title`, guaranteed
    /// non-empty. Falls back to the shipped default ("Bibliography") for an empty or
    /// whitespace-only configured name — omitting the argument instead would reintroduce a
    /// headless reference list for that one degenerate input, which is the exact bug this
    /// setting exists to fix.
    var effectiveBibliographyHeaderName: String {
        let trimmed = bibliographyHeaderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ExportSettings.default.bibliographyHeaderName : trimmed
    }
}

/// `XMLParserDelegate` helper for `ExportSettings.isWellFormedCSLStyle` — captures the name
/// of the first (root) element seen while parsing, plus two further signals needed to tell a
/// usable independent CSL style apart from a "dependent" one: whether a `<citation>` element
/// (the actual formatting rules) appears anywhere, and whether an `<info>/<link
/// rel="independent-parent">` element (the dependent-style marker) appears anywhere. Requires
/// `parser.shouldProcessNamespaces = true` on the `XMLParser` this delegate is attached to --
/// see `isWellFormedCSLStyle`'s doc comment -- so `elementName` here is always the local name
/// with any namespace prefix already stripped.
private final class CSLRootElementCapture: NSObject, XMLParserDelegate {
    private(set) var rootElementName: String?
    private(set) var hasCitationElement = false
    private(set) var hasIndependentParentLink = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if rootElementName == nil {
            rootElementName = elementName
        }
        if elementName == "citation" {
            hasCitationElement = true
        }
        if elementName == "link", attributeDict["rel"] == "independent-parent" {
            hasIndependentParentLink = true
        }
    }
}

// MARK: - Observable Settings Manager

/// Main-thread observable wrapper for export settings
@MainActor
@Observable
final class ExportSettingsManager {

    /// Singleton instance
    static let shared = ExportSettingsManager()

    /// Current settings
    private(set) var settings: ExportSettings

    private init() {
        settings = ExportSettings.load()
    }

    /// Update settings and persist
    func update(_ block: (inout ExportSettings) -> Void) {
        block(&settings)
        settings.save()
    }

    /// Reset to defaults
    func resetToDefaults() {
        settings = .default
        settings.save()
        // Mirrors the `useCustomCSLStyle`/`customCSLStylePath` setters below: those are the
        // only settings whose individual setter currently posts a change notification (every
        // open editor's `MilkdownCoordinator` observes `.citationStyleChanged` to re-push the
        // effective CSL style). Posting it here too keeps a reset in sync with a normal edit --
        // without this, a reset back to the bundled style would leave any already-open
        // document showing a stale custom style until an unrelated trigger (e.g. reopening the
        // document) happened to re-push it. `bibliographyHeaderName` and every other setting
        // here have no such per-setter notification to mirror -- see their setters below.
        NotificationCenter.default.post(name: .citationStyleChanged, object: nil)
    }

    /// Convenience accessors

    var customPandocPath: String? {
        get { settings.customPandocPath }
        set { update { $0.customPandocPath = newValue } }
    }

    var useCustomLuaScript: Bool {
        get { settings.useCustomLuaScript }
        set { update { $0.useCustomLuaScript = newValue } }
    }

    var customLuaScriptPath: String? {
        get { settings.customLuaScriptPath }
        set { update { $0.customLuaScriptPath = newValue } }
    }

    var useCustomReferenceDoc: Bool {
        get { settings.useCustomReferenceDoc }
        set { update { $0.useCustomReferenceDoc = newValue } }
    }

    var customReferenceDocPath: String? {
        get { settings.customReferenceDocPath }
        set { update { $0.customReferenceDocPath = newValue } }
    }

    var showZoteroWarning: Bool {
        get { settings.showZoteroWarning }
        set { update { $0.showZoteroWarning = newValue } }
    }

    var defaultFormat: ExportFormat {
        get { settings.defaultFormat }
        set { update { $0.defaultFormat = newValue } }
    }

    var includeAnnotations: Bool {
        get { settings.includeAnnotations }
        set { update { $0.includeAnnotations = newValue } }
    }

    var bibliographyHeaderName: String {
        get { settings.bibliographyHeaderName }
        set { update { $0.bibliographyHeaderName = newValue } }
    }

    /// Trimmed, never-empty header name — the value every consumer that matches or
    /// displays the bibliography heading should read. See
    /// `ExportSettings.effectiveBibliographyHeaderName`.
    var effectiveBibliographyHeaderName: String { settings.effectiveBibliographyHeaderName }

    var useCustomCSLStyle: Bool {
        get { settings.useCustomCSLStyle }
        set {
            update { $0.useCustomCSLStyle = newValue }
            // Live editors re-push the effective style (custom or bundled) on this
            // notification -- see MilkdownCoordinator+NotificationObservers.swift. Posted
            // unconditionally, including when this flips back to false, so a revert to the
            // bundled style is pushed explicitly rather than left showing the stale custom
            // one until relaunch.
            NotificationCenter.default.post(name: .citationStyleChanged, object: nil)
        }
    }

    var customCSLStylePath: String? {
        get { settings.customCSLStylePath }
        set {
            update { $0.customCSLStylePath = newValue }
            NotificationCenter.default.post(name: .citationStyleChanged, object: nil)
        }
    }
}
