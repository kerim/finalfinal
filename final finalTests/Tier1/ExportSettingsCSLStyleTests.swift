//
//  ExportSettingsCSLStyleTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Regression coverage for the custom-CSL-citation-style feature's plan-review must-fixes:
//  1. Decoding a settings payload saved before this feature existed (missing the two new
//     keys) must succeed and leave every OTHER field intact, not fall through `load()`'s
//     `try?` and reset the entire struct -- including unrelated fields -- to `.default`.
//  4. `effectiveCSLStylePath` must reject a custom file that exists but isn't well-formed
//     CSL, not just a missing one, and `bibliographyWriteArguments` must warn and fall back
//     to the bundled Chicago style for both failure modes rather than handing pandoc's
//     `--csl` argument a garbage path.
//

import Testing
import Foundation
@testable import final_final

@Suite("Export Settings — custom CSL citation style")
struct ExportSettingsCSLStyleTests {

    // MARK: - Codable round-trip (must-fix #1)

    @Test("Decoding a settings payload missing the CSL keys succeeds and preserves every other field")
    func decodingMissingCSLKeysPreservesOtherFields() throws {
        let json = Data("""
        {
            "customPandocPath": "/usr/local/bin/pandoc",
            "useCustomLuaScript": true,
            "customLuaScriptPath": "/tmp/custom.lua",
            "useCustomReferenceDoc": true,
            "customReferenceDocPath": "/tmp/reference.docx",
            "showZoteroWarning": false,
            "defaultFormat": "pdf",
            "includeAnnotations": true,
            "bibliographyHeaderName": "Works Cited"
        }
        """.utf8)

        let settings = try JSONDecoder().decode(ExportSettings.self, from: json)

        // Every OTHER field must survive unchanged. Under synthesized Codable, a missing key
        // for a non-optional property throws keyNotFound regardless of that property's
        // declared default -- and load()'s `try?` would catch that by resetting EVERYTHING,
        // not just the two new fields, to .default. This is the exact bug must-fix #1 covers.
        #expect(settings.customPandocPath == "/usr/local/bin/pandoc")
        #expect(settings.useCustomLuaScript == true)
        #expect(settings.customLuaScriptPath == "/tmp/custom.lua")
        #expect(settings.useCustomReferenceDoc == true)
        #expect(settings.customReferenceDocPath == "/tmp/reference.docx")
        #expect(settings.showZoteroWarning == false)
        #expect(settings.defaultFormat == .pdf)
        #expect(settings.includeAnnotations == true)
        #expect(settings.bibliographyHeaderName == "Works Cited")

        // New fields fall back to their declared defaults when absent from the payload.
        #expect(settings.useCustomCSLStyle == false)
        #expect(settings.customCSLStylePath == nil)
    }

    @Test("Round-tripping through encode/decode preserves a custom CSL style setting")
    func roundTripPreservesCustomCSLStyle() throws {
        var settings = ExportSettings.default
        settings.useCustomCSLStyle = true
        settings.customCSLStylePath = "/tmp/my-style.csl"

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ExportSettings.self, from: data)

        #expect(decoded.useCustomCSLStyle == true)
        #expect(decoded.customCSLStylePath == "/tmp/my-style.csl")
    }

    // MARK: - effectiveCSLStylePath / isCustomCSLStyleValid (must-fix #4)

    @Test("effectiveCSLStylePath falls back to the bundled Chicago style when the toggle is off")
    func effectivePathBundledWhenToggleOff() {
        var settings = ExportSettings.default
        settings.useCustomCSLStyle = false
        settings.customCSLStylePath = "/tmp/whatever.csl"
        #expect(settings.effectiveCSLStylePath == ExportService.bundledCSLStylePath)
    }

    @Test("effectiveCSLStylePath falls back to the bundled Chicago style when the custom file is missing")
    func effectivePathBundledWhenFileMissing() {
        var settings = ExportSettings.default
        settings.useCustomCSLStyle = true
        settings.customCSLStylePath = "/nonexistent-\(UUID().uuidString)/style.csl"
        #expect(settings.effectiveCSLStylePath == ExportService.bundledCSLStylePath)
        #expect(settings.isCustomCSLStyleValid == false)
    }

    @Test("effectiveCSLStylePath falls back to the bundled Chicago style when the file exists but isn't valid CSL")
    func effectivePathBundledWhenFileInvalid() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".csl")
        try "this is not xml at all, just garbage text".write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var settings = ExportSettings.default
        settings.useCustomCSLStyle = true
        settings.customCSLStylePath = tempURL.path

        // isCustomCSLStyleValid only checks existence (mirrors isCustomLuaScriptValid /
        // isCustomReferenceDocValid) -- the file DOES exist, so this stays true even though
        // the content is garbage. See its doc comment for why that split is intentional.
        #expect(settings.isCustomCSLStyleValid == true)
        // effectiveCSLStylePath additionally validates content, so it still falls back.
        #expect(settings.effectiveCSLStylePath == ExportService.bundledCSLStylePath)
    }

    @Test("effectiveCSLStylePath uses the custom path when the file exists and is well-formed CSL")
    func effectivePathUsesCustomWhenValid() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".csl")
        try Self.minimalCSL.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var settings = ExportSettings.default
        settings.useCustomCSLStyle = true
        settings.customCSLStylePath = tempURL.path

        #expect(settings.isCustomCSLStyleValid == true)
        #expect(settings.effectiveCSLStylePath == tempURL.path)
    }

    // MARK: - bibliographyWriteArguments CSL warnings (must-fix #3 & #4)

    @Test("bibliographyWriteArguments warns and falls back to bundled CSL when the custom file is missing")
    func bibliographyWriteArgumentsWarnsOnMissingCSL() async {
        let service = ExportService()
        var settings = ExportSettings.default
        settings.useCustomCSLStyle = true
        settings.customCSLStylePath = "/nonexistent-\(UUID().uuidString)/style.csl"
        let tempDir = FileManager.default.temporaryDirectory

        let result = await service.bibliographyWriteArguments(
            bibJSON: "[]", notFoundKeys: [], ambiguousKeys: [], settings: settings, tempDir: tempDir
        )
        defer { if let url = result.tempBibURL { try? FileManager.default.removeItem(at: url) } }

        #expect(result.warnings.contains { $0.contains("Custom citation style not found") })
        if let bundled = ExportService.bundledCSLStylePath {
            #expect(result.arguments.contains(bundled))
        }
    }

    @Test("bibliographyWriteArguments warns and falls back to bundled CSL when the custom file isn't valid CSL")
    func bibliographyWriteArgumentsWarnsOnInvalidCSL() async throws {
        let tempCSLURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".csl")
        try "garbage, not xml".write(to: tempCSLURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempCSLURL) }

        let service = ExportService()
        var settings = ExportSettings.default
        settings.useCustomCSLStyle = true
        settings.customCSLStylePath = tempCSLURL.path
        let tempDir = FileManager.default.temporaryDirectory

        let result = await service.bibliographyWriteArguments(
            bibJSON: "[]", notFoundKeys: [], ambiguousKeys: [], settings: settings, tempDir: tempDir
        )
        defer { if let url = result.tempBibURL { try? FileManager.default.removeItem(at: url) } }

        #expect(result.warnings.contains { $0.contains("not valid CSL") })
        if let bundled = ExportService.bundledCSLStylePath {
            #expect(result.arguments.contains(bundled))
        }
        #expect(!result.arguments.contains(tempCSLURL.path), "The garbage custom path must never reach pandoc's --csl argument")
    }

    @Test("bibliographyWriteArguments uses the custom CSL path and emits no CSL warning when it is valid")
    func bibliographyWriteArgumentsUsesValidCustomCSL() async throws {
        let tempCSLURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".csl")
        try Self.minimalCSL.write(to: tempCSLURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempCSLURL) }

        let service = ExportService()
        var settings = ExportSettings.default
        settings.useCustomCSLStyle = true
        settings.customCSLStylePath = tempCSLURL.path
        let tempDir = FileManager.default.temporaryDirectory

        let result = await service.bibliographyWriteArguments(
            bibJSON: "[]", notFoundKeys: [], ambiguousKeys: [], settings: settings, tempDir: tempDir
        )
        defer { if let url = result.tempBibURL { try? FileManager.default.removeItem(at: url) } }

        #expect(!result.warnings.contains { $0.localizedCaseInsensitiveContains("citation style") })
        #expect(result.arguments.contains(tempCSLURL.path))
    }

    // MARK: - Strengthened well-formedness check (must-fix #2)
    //
    // The original check only verified "valid XML with a <style> root" -- which a
    // well-formed-but-unusable file can trivially satisfy (wrong root element entirely, or a
    // real CSL shape that carries no formatting rules of its own). None of the "invalid"
    // fixtures above exercise that: they're all non-XML garbage, which the ORIGINAL check
    // already rejected via `parser.parse()` failing outright. These cases specifically
    // exercise the check's actual distinguishing logic -- valid XML that still isn't usable.

    @Test("effectiveCSLStylePath rejects well-formed XML with the wrong root element")
    func effectivePathRejectsWrongRootElement() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".csl")
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <notAStyle>
            <citation/>
        </notAStyle>
        """.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var settings = ExportSettings.default
        settings.useCustomCSLStyle = true
        settings.customCSLStylePath = tempURL.path

        // Well-formed XML, parses fine -- but the root element isn't <style>, so this must
        // still be rejected and fall back to bundled, exactly like garbage-text input does.
        #expect(settings.effectiveCSLStylePath == ExportService.bundledCSLStylePath)
    }

    @Test("effectiveCSLStylePath rejects a dependent CSL style with no formatting rules of its own")
    func effectivePathRejectsDependentStyle() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".csl")
        // A real "dependent" CSL shape: a <style> root containing only <info>, which points
        // at a parent style via <link rel="independent-parent">, and no <citation> element at
        // all. Common in real citation-style repositories (a style that's just an alias/
        // variant of another). Well-formed XML with a <style> root -- the original check
        // accepted this as "valid", and pandoc's --csl then failed on it with a cryptic
        // low-level error instead of the clear warning this check exists to produce.
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <style xmlns="http://purl.org/net/xbiblio/csl" class="in-text" version="1.0">
          <info>
            <title>A Dependent Style</title>
            <id>http://example.com/dependent-style</id>
            <link href="http://example.com/parent-style" rel="independent-parent"/>
          </info>
        </style>
        """.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var settings = ExportSettings.default
        settings.useCustomCSLStyle = true
        settings.customCSLStylePath = tempURL.path

        #expect(settings.effectiveCSLStylePath == ExportService.bundledCSLStylePath)
    }

    @Test("effectiveCSLStylePath accepts a namespace-prefixed <csl:style> root")
    func effectivePathAcceptsNamespacePrefixedRoot() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".csl")
        // Namespace processing must be ON for this to be recognized as a <style> root --
        // with it off (the XMLParser default), the delegate sees the raw tag name
        // "csl:style", which never equals "style", so a legitimately-prefixed file like this
        // one was wrongly rejected before this must-fix.
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <csl:style xmlns:csl="http://purl.org/net/xbiblio/csl" class="in-text" version="1.0">
          <csl:citation>
            <csl:layout>
              <csl:text variable="title"/>
            </csl:layout>
          </csl:citation>
        </csl:style>
        """.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var settings = ExportSettings.default
        settings.useCustomCSLStyle = true
        settings.customCSLStylePath = tempURL.path

        #expect(settings.effectiveCSLStylePath == tempURL.path)
    }

    // MARK: - Preferences-pane caption distinguishes not-found from not-usable (must-fix #3)

    @Test("customCSLStyleCaption is nil when the toggle is on but no path has been configured yet")
    func captionNilWhenNotConfigured() {
        var settings = ExportSettings.default
        settings.useCustomCSLStyle = true
        settings.customCSLStylePath = nil

        // This is the very first state after checking the box -- distinct from "I looked for
        // a file and it's missing." Must not show a red caption at all.
        #expect(settings.customCSLStyleCaption == nil)
    }

    @Test("customCSLStyleCaption distinguishes a missing file from one that exists but isn't usable CSL")
    func captionDistinguishesNotFoundFromInvalid() throws {
        var missing = ExportSettings.default
        missing.useCustomCSLStyle = true
        missing.customCSLStylePath = "/nonexistent-\(UUID().uuidString)/style.csl"
        #expect(missing.customCSLStyleCaption == "File not found at specified path")

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".csl")
        try "garbage, not xml".write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var invalid = ExportSettings.default
        invalid.useCustomCSLStyle = true
        invalid.customCSLStylePath = tempURL.path
        #expect(invalid.customCSLStyleCaption == "File exists but isn't a usable CSL style")
    }

    // MARK: - bibliographyWriteArguments: "no path configured" is not "invalid CSL" (must-fix #3)

    @Test("bibliographyWriteArguments warns distinctly when no custom CSL path is configured yet")
    func bibliographyWriteArgumentsWarnsWhenNotConfigured() async {
        let service = ExportService()
        var settings = ExportSettings.default
        settings.useCustomCSLStyle = true
        settings.customCSLStylePath = nil
        let tempDir = FileManager.default.temporaryDirectory

        let result = await service.bibliographyWriteArguments(
            bibJSON: "[]", notFoundKeys: [], ambiguousKeys: [], settings: settings, tempDir: tempDir
        )
        defer { if let url = result.tempBibURL { try? FileManager.default.removeItem(at: url) } }

        // This must NOT be the "is not valid CSL" message -- nothing was configured to be
        // invalid. It must also not be the "not found" message -- nothing was looked up.
        #expect(result.warnings.contains { $0.contains("No custom citation style file specified") })
        #expect(!result.warnings.contains { $0.contains("not valid CSL") })
        #expect(!result.warnings.contains { $0.contains("not found") })
        if let bundled = ExportService.bundledCSLStylePath {
            #expect(result.arguments.contains(bundled))
        }
    }

    // MARK: - Fixtures

    private static let minimalCSL = """
    <?xml version="1.0" encoding="utf-8"?>
    <style xmlns="http://purl.org/net/xbiblio/csl" class="in-text" version="1.0">
      <citation>
        <layout>
          <text variable="title"/>
        </layout>
      </citation>
    </style>
    """
}
