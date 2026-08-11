//
//  ExportZoteroPreflightTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Coverage for `ExportService.requiresZoteroForExport`, the pure gate function that decides
//  whether a DOCX/ODT export must hard-stop with `ExportError.zoteroRequiredForCitations`
//  instead of proceeding into a lua filter that calls an unreachable Zotero. Before this gate
//  existed, that path could crash pandoc outright (exit 83) or silently emit unresolved
//  citations -- the user must instead see a clear, non-silenceable prompt.
//
//  The gate is pure and side-effect-free (a `static func`, not actor-isolated), so it is
//  exercised directly here across every format x hasCitations x luaScriptPath x zoteroStatus
//  combination, without needing a live Zotero connection or a real pandoc invocation.
//
//  `@Test(arguments:)` only has direct overloads for one or two collections (the two-collection
//  form runs the cartesian product of exactly two parameters). Tests below that vary three
//  inputs at once build their own cross product as an array of tuples and pass that as a
//  single collection instead -- Swift Testing destructures each tuple positionally into the
//  test function's parameters (the same mechanism as the documented `zip(a, b)` pattern).
//
//  Also covers: `ExportService.citationFilterErrorIfApplicable` (mapping a pandoc exit-83
//  failure to a friendly message, without wrongly implying Zotero isn't running), the
//  present-tense `zoteroPreflightReason` wording, and two real-actor integration tests --
//  a false-positive citation shape must never hard-stop, and the hard stop must fire before
//  pandoc is ever invoked.
//
//  A prior revision of this file included a `matchesDocumentedFormula` test that recomputed
//  the exact same boolean expression as its own oracle -- it could never fail no matter how
//  wrong the implementation became, so it was removed. The named cases below already form a
//  complete partition of the full format x hasCitations x luaScriptPath x zoteroStatus space
//  (`pdfIsAlwaysFalse` covers every combination with format == .pdf; the four `nonPDF...`
//  tests below partition every combination with format != .pdf), each checked against an
//  independently-reasoned expected value.

import Testing
import Foundation
import Darwin
@testable import final_final

@Suite("Export Zotero preflight gate — Tier 1: Silent Killers")
struct ExportZoteroPreflightTests {

    private static let someLuaPath = "/tmp/zotero.lua"
    private static let luaPaths: [String?] = [nil, someLuaPath]
    private static let allStatuses: [ZoteroStatus] = [
        .running, .notRunning, .betterBibTeXMissing, .timeout, .error("boom")
    ]
    private static let nonPDFFormats: [ExportFormat] = [.word, .odt]

    // MARK: - Real on-disk resource helpers (mirrors BareCitationExportTests.swift's
    // #filePath-relative pattern -- Bundle.main doesn't resolve bundled Export/ resources
    // correctly from the unit-test host).

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tier1/
            .deletingLastPathComponent()  // final finalTests/
            .deletingLastPathComponent()  // repo root
    }

    private static var zoteroLuaPath: String {
        repoRoot().appendingPathComponent("final final/Resources/Export/zotero.lua").path
    }

    // MARK: - PDF is always false, regardless of every other input

    private static let citationsLuaStatusCombos: [(Bool, String?, ZoteroStatus)] =
        [true, false].flatMap { hasCitations in
            luaPaths.flatMap { luaPath in
                allStatuses.map { status in (hasCitations, luaPath, status) }
            }
        }

    @Test(
        "PDF never requires the Zotero hard stop, regardless of citations/lua/status",
        arguments: citationsLuaStatusCombos
    )
    func pdfIsAlwaysFalse(combo: (hasCitations: Bool, luaScriptPath: String?, zoteroStatus: ZoteroStatus)) {
        #expect(!ExportService.requiresZoteroForExport(
            format: .pdf,
            hasCitations: combo.hasCitations,
            luaScriptPath: combo.luaScriptPath,
            zoteroStatus: combo.zoteroStatus
        ))
    }

    // MARK: - Non-PDF fires only for the exact combination: citations + a lua path + not running

    @Test(
        "DOCX/ODT with citations, a lua path, and Zotero unreachable requires the hard stop",
        arguments: nonPDFFormats,
        [ZoteroStatus.notRunning, .betterBibTeXMissing, .timeout, .error("boom")]
    )
    func nonPDFFiresWhenUnreachable(format: ExportFormat, zoteroStatus: ZoteroStatus) {
        #expect(ExportService.requiresZoteroForExport(
            format: format,
            hasCitations: true,
            luaScriptPath: Self.someLuaPath,
            zoteroStatus: zoteroStatus
        ))
    }

    @Test(
        "DOCX/ODT with citations, a lua path, and Zotero running does NOT require the hard stop",
        arguments: nonPDFFormats
    )
    func nonPDFDoesNotFireWhenRunning(format: ExportFormat) {
        #expect(!ExportService.requiresZoteroForExport(
            format: format,
            hasCitations: true,
            luaScriptPath: Self.someLuaPath,
            zoteroStatus: .running
        ))
    }

    private static let formatLuaStatusCombos: [(ExportFormat, String?, ZoteroStatus)] =
        nonPDFFormats.flatMap { format in
            luaPaths.flatMap { luaPath in
                allStatuses.map { status in (format, luaPath, status) }
            }
        }

    @Test(
        "DOCX/ODT with no citations never requires the hard stop, regardless of lua/status",
        arguments: formatLuaStatusCombos
    )
    func nonPDFDoesNotFireWithoutCitations(combo: (format: ExportFormat, luaScriptPath: String?, zoteroStatus: ZoteroStatus)) {
        #expect(!ExportService.requiresZoteroForExport(
            format: combo.format,
            hasCitations: false,
            luaScriptPath: combo.luaScriptPath,
            zoteroStatus: combo.zoteroStatus
        ))
    }

    @Test(
        "DOCX/ODT with citations but no lua script path never requires the hard stop, regardless of status",
        arguments: nonPDFFormats,
        allStatuses
    )
    func nonPDFDoesNotFireWithoutLuaPath(format: ExportFormat, zoteroStatus: ZoteroStatus) {
        #expect(!ExportService.requiresZoteroForExport(
            format: format,
            hasCitations: true,
            luaScriptPath: nil,
            zoteroStatus: zoteroStatus
        ))
    }

    // MARK: - zoteroRequiredForCitations error description is plain-English, format-specific,
    // and per-status (not one generic "open Zotero" message for every status)

    @Test(
        "zoteroRequiredForCitations error mentions the format and tells the user to resolve the Zotero problem",
        arguments: nonPDFFormats
    )
    func errorDescriptionMentionsFormat(format: ExportFormat) {
        let error = ExportError.zoteroRequiredForCitations(format: format, zoteroStatus: .notRunning)
        let description = error.errorDescription ?? ""
        #expect(description.contains(format.displayName))
        #expect(description.localizedCaseInsensitiveContains("Zotero"))
    }

    @Test("zoteroRequiredForCitations error description is per-status, not one generic message for every status")
    func errorDescriptionVariesByStatus() {
        let notRunning = ExportError.zoteroRequiredForCitations(format: .word, zoteroStatus: .notRunning).errorDescription ?? ""
        let bbtMissing = ExportError.zoteroRequiredForCitations(format: .word, zoteroStatus: .betterBibTeXMissing).errorDescription ?? ""
        #expect(notRunning != bbtMissing)
        #expect(bbtMissing.localizedCaseInsensitiveContains("Better BibTeX"))
    }

    // MARK: - zoteroPreflightReason is present-tense-friendly (not "Citations were not resolved"
    // in a context where export was never attempted)

    @Test(
        "zoteroPreflightReason drops zoteroWarnings' past-tense tail",
        arguments: [ZoteroStatus.notRunning, .betterBibTeXMissing, .timeout, .error("boom")]
    )
    func preflightReasonIsPresentTenseFriendly(status: ZoteroStatus) {
        let reason = ExportService.zoteroPreflightReason(for: status)
        #expect(!reason.isEmpty)
        #expect(!reason.localizedCaseInsensitiveContains("were not resolved"))
        #expect(!reason.localizedCaseInsensitiveContains("may not be resolved"))
    }

    // MARK: - citationFilterErrorIfApplicable: map pandoc exit 83 to a friendly message ONLY
    // for a non-PDF export with a lua filter configured -- never claiming Zotero isn't
    // running, since the pre-flight probe already confirmed it was reachable in this scenario

    @Test(
        "citationFilterErrorIfApplicable maps exit 83 for non-PDF with a lua path configured",
        arguments: nonPDFFormats
    )
    func citationFilterErrorMapsForNonPDFWithLuaPath(format: ExportFormat) {
        let mapped = ExportService.citationFilterErrorIfApplicable(
            exitCode: 83, format: format, luaScriptPath: Self.someLuaPath
        )
        guard case .citationFilterFailed(let mappedFormat) = mapped else {
            Issue.record("Expected .citationFilterFailed, got \(String(describing: mapped))")
            return
        }
        #expect(mappedFormat == format)
    }

    @Test("citationFilterErrorIfApplicable does not map for PDF, a non-83 exit code, or a missing lua path")
    func citationFilterErrorDoesNotMapOutsideItsScope() {
        #expect(ExportService.citationFilterErrorIfApplicable(exitCode: 83, format: .pdf, luaScriptPath: Self.someLuaPath) == nil)
        #expect(ExportService.citationFilterErrorIfApplicable(exitCode: 1, format: .word, luaScriptPath: Self.someLuaPath) == nil)
        #expect(ExportService.citationFilterErrorIfApplicable(exitCode: 83, format: .word, luaScriptPath: nil) == nil)
    }

    @Test(
        "citationFilterFailed's message is friendly, mentions the format, and never claims Zotero isn't running",
        arguments: nonPDFFormats
    )
    func citationFilterFailedDescriptionIsFriendly(format: ExportFormat) {
        let description = ExportError.citationFilterFailed(format: format).errorDescription ?? ""
        #expect(description.contains(format.displayName))
        #expect(!description.localizedCaseInsensitiveContains("is not running"))
        #expect(!description.contains("83"))
    }
}

// Everything below is in its own `extension` (rather than the primary struct declaration
// above) purely to keep `type_body_length` under its limit -- SwiftLint counts an extension's
// body separately from the type's own declaration. Mirrors the identical seam already used in
// `final final/Services/ExportService.swift` itself (see that file's own doc comment on the
// same convention) -- applied here to keep this growing test suite's real-actor integration
// tests alongside the pure gate-function tests above, in one file, without tripping the limit.
// No behavior change: `private` members declared here remain accessible from (and to) the
// primary struct above -- Swift's `private` extends to same-file extensions of the same type.
extension ExportZoteroPreflightTests {

    // MARK: - Real-actor integration tests

    /// Whether something is currently listening on Better BibTeX's JSON-RPC port. Used to skip
    /// `exportThrowsBeforePandocInvocation` below (and the `zoteroPreflight` integration tests
    /// further down) in the case where Zotero happens to be running while these tests execute
    /// -- mirrors this test suite's existing "skip if pandoc isn't installed" idiom (see
    /// BareCitationExportTests.swift), just for network reachability instead of a binary on
    /// disk. `falsePositiveCitationShapeNeverHardStops` deliberately does NOT gate on this: its
    /// assertion holds regardless of Zotero's status (see its own comment), so gating it would
    /// only skip the test on exactly the machines (Zotero installed and running, like a real
    /// user's) most worth proving it on.
    private static func isBetterBibTeXPortOpen() -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(23119).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connectResult = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(sock, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connectResult == 0
    }

    /// Proves the must-fix: a document whose only citation-shaped text is a false positive
    /// under the loose `hasPandocCitations` regex (an email address inside brackets) must
    /// never trigger the hard stop, because `export()`'s guard is fed the STRICT
    /// `extractCitekeys` result, not the loose detector. This holds regardless of whether
    /// Zotero is actually reachable -- `requiresZoteroForExport` short-circuits to `false`
    /// whenever `hasCitations` is `false`, independent of `zoteroStatus` -- so this is a
    /// faithful proxy for "the DOCX/ODT hard-stop alert is never shown for this document."
    @Test(
        "A document containing only [contact me@example.com] never hard-stops Word export, even with Zotero unreachable"
    )
    func falsePositiveCitationShapeNeverHardStops() async throws {
        let service = ExportService()
        var settings = ExportSettings()
        // Stand-in "pandoc": always exits 0 and does nothing, regardless of arguments. If the
        // gate incorrectly fired here, export() would throw zoteroRequiredForCitations instead
        // of returning a result.
        settings.customPandocPath = "/usr/bin/true"
        settings.useCustomLuaScript = true
        settings.customLuaScriptPath = Self.zoteroLuaPath

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("false-positive-citation-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let result = try await service.export(
            content: "For questions, see [contact me@example.com].",
            to: outputURL,
            format: .word,
            settings: settings,
            projectURL: nil
        )
        #expect(result.format == .word)
    }

    /// Proves the load-bearing part of this fix's placement: the hard-stop guard runs BEFORE
    /// pandoc is ever invoked. The stand-in "pandoc" (`/usr/bin/true`) always exits 0 and does
    /// nothing -- if the guard were ever moved to after pandoc runs (or removed), this stand-in
    /// would let the export silently "succeed" instead of throwing, so a passing test here
    /// specifically proves the guard runs first, not merely that it exists somewhere in
    /// `export()`.
    @Test(
        "export() enforces the hard stop before pandoc is ever invoked",
        .enabled(if: !ExportZoteroPreflightTests.isBetterBibTeXPortOpen())
    )
    func exportThrowsBeforePandocInvocation() async throws {
        let service = ExportService()
        var settings = ExportSettings()
        settings.customPandocPath = "/usr/bin/true"
        settings.useCustomLuaScript = true
        settings.customLuaScriptPath = Self.zoteroLuaPath

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("preflight-ordering-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        do {
            _ = try await service.export(
                content: "See [@smith2020] for details.",
                to: outputURL,
                format: .word,
                settings: settings,
                projectURL: nil
            )
            let message: String = "Expected export() to throw zoteroRequiredForCitations, but it returned " +
                "successfully -- the hard-stop guard did not run before pandoc was invoked"
            Issue.record("\(message)")
        } catch ExportError.zoteroRequiredForCitations(let format, _) {
            #expect(format == .word)
        } catch {
            Issue.record("Expected zoteroRequiredForCitations, got \(error)")
        }
    }

    // MARK: - zoteroPreflight: the pre-save-panel gate
    //
    // `ExportViewModel.showExportPanel` used to only discover the Zotero-required hard stop
    // from inside `export()` itself -- which only throws AFTER the save panel has already been
    // shown and the user has already picked a save location. `zoteroPreflight` lets the
    // ViewModel ask "would this fail?" before ever presenting that panel. These tests prove it
    // reuses the exact same gate `export()` enforces (never disagreeing with it), rather than
    // re-deriving "has citations" a second time and risking the two drifting apart again.

    @Test(
        "zoteroPreflight reports the block for DOCX/ODT with real citations and Zotero unreachable, without needing Pandoc at all",
        .enabled(if: !ExportZoteroPreflightTests.isBetterBibTeXPortOpen()),
        arguments: nonPDFFormats
    )
    func zoteroPreflightBlocksWhenUnreachable(format: ExportFormat) async throws {
        let service = ExportService()
        var settings = ExportSettings()
        // Deliberately no `customPandocPath` at all -- zoteroPreflight must be able to answer
        // "would this be blocked?" without ever needing a working Pandoc, since it runs before
        // the save panel and must never invoke Pandoc.
        settings.useCustomLuaScript = true
        settings.customLuaScriptPath = Self.zoteroLuaPath

        let preflight = try await service.zoteroPreflight(
            content: "See [@smith2020] for details.",
            format: format,
            settings: settings
        )
        #expect(preflight.isBlocked)
        #expect(preflight.zoteroStatus != .running)
    }

    @Test(
        "zoteroPreflight never blocks a document whose only citation-shaped text is a false positive",
        .enabled(if: !ExportZoteroPreflightTests.isBetterBibTeXPortOpen())
    )
    func zoteroPreflightAllowsFalsePositiveCitationShape() async throws {
        let service = ExportService()
        var settings = ExportSettings()
        settings.useCustomLuaScript = true
        settings.customLuaScriptPath = Self.zoteroLuaPath

        let preflight = try await service.zoteroPreflight(
            content: "For questions, see [contact me@example.com].",
            format: .word,
            settings: settings
        )
        #expect(!preflight.isBlocked)
    }

    /// The must-fix for the loose-vs-strict detector split: a false-positive bracket shape
    /// like `[contact me@example.com]` matches the LOOSE `hasPandocCitations` regex (it
    /// contains `@` followed by word/dot characters, closed by `]`) even though it has zero
    /// real citekeys under the strict `extractCitekeys`. Before this fix, `zoteroPreflight`
    /// used that loose match as its probe trigger, so a document shaped like this one still
    /// made a real, live network call to Zotero -- pointlessly, since `isBlocked` was already
    /// guaranteed `false` for it regardless of what that probe found. Gated on Zotero actually
    /// being unreachable (mirrors this suite's other `isBetterBibTeXPortOpen` guards): with
    /// Zotero down, the OLD code's needless probe would return `.notRunning`, not `.running`,
    /// making this assertion a faithful proxy for "the probe never fired at all."
    @Test(
        "zoteroPreflight does not probe Zotero for a false-positive citation shape -- zoteroStatus stays .running even with Zotero unreachable",
        .enabled(if: !ExportZoteroPreflightTests.isBetterBibTeXPortOpen())
    )
    func falsePositiveCitationShapeNeverTriggersZoteroProbe() async throws {
        let service = ExportService()
        var settings = ExportSettings()
        settings.useCustomLuaScript = true
        settings.customLuaScriptPath = Self.zoteroLuaPath

        let preflight = try await service.zoteroPreflight(
            content: "For questions, see [contact me@example.com].",
            format: .word,
            settings: settings
        )
        #expect(preflight.zoteroStatus == .running)
    }

    @Test(
        "zoteroPreflight never blocks a PDF export, even with real citations and a lua path configured -- and reports hasCitations == true, the exact combination that makes .warnDegraded reachable",
        .enabled(if: !ExportZoteroPreflightTests.isBetterBibTeXPortOpen())
    )
    func zoteroPreflightNeverBlocksPDF() async throws {
        let service = ExportService()
        var settings = ExportSettings()
        settings.useCustomLuaScript = true
        settings.customLuaScriptPath = Self.zoteroLuaPath

        let preflight = try await service.zoteroPreflight(
            content: "See [@smith2020] for details.",
            format: .pdf,
            settings: settings
        )
        #expect(!preflight.isBlocked)
        // isBlocked == false AND hasCitations == true simultaneously is exactly the combination
        // `ExportViewModel.savePanelDecision` needs to reach `.warnDegraded` for PDF -- if either
        // flipped, the degraded-citations warning would never show for a real PDF citation.
        #expect(preflight.hasCitations)
    }

    // MARK: - zoteroPreflight's hasCitations field (must-fix: lets ExportViewModel decide
    // whether a PDF export should show the degraded-citations warning at all)

    @Test(
        "zoteroPreflight reports hasCitations == true for a document with a real citekey, for every format",
        .enabled(if: !ExportZoteroPreflightTests.isBetterBibTeXPortOpen()),
        arguments: [ExportFormat.pdf, .word, .odt]
    )
    func zoteroPreflightReportsHasCitationsTrueForRealCitekey(format: ExportFormat) async throws {
        let service = ExportService()
        var settings = ExportSettings()
        settings.useCustomLuaScript = true
        settings.customLuaScriptPath = Self.zoteroLuaPath

        let preflight = try await service.zoteroPreflight(
            content: "See [@smith2020] for details.",
            format: format,
            settings: settings
        )
        #expect(preflight.hasCitations)
    }

    @Test(
        "zoteroPreflight reports hasCitations == false for a document whose only bracketed text is a false-positive shape like an email address, for every format",
        .enabled(if: !ExportZoteroPreflightTests.isBetterBibTeXPortOpen()),
        arguments: [ExportFormat.pdf, .word, .odt]
    )
    func zoteroPreflightReportsHasCitationsFalseForFalsePositiveShape(format: ExportFormat) async throws {
        let service = ExportService()
        var settings = ExportSettings()
        settings.useCustomLuaScript = true
        settings.customLuaScriptPath = Self.zoteroLuaPath

        let preflight = try await service.zoteroPreflight(
            content: "For questions, see [contact me@example.com].",
            format: format,
            settings: settings
        )
        #expect(!preflight.hasCitations)
    }

    /// The must-not-regress test for this fix: `zoteroPreflight` (what the ViewModel now
    /// consults BEFORE showing the save panel) and `export()` (what actually runs the export,
    /// and still enforces its own hard stop as a race-case safety net) must agree on the exact
    /// same document and settings -- proving the pre-panel check and the real gate can never
    /// give different answers, which is exactly the disagreement bug a prior round of fixes
    /// eliminated by making `export()`'s gate the sole source of truth. This deliberately does
    /// NOT forward `zoteroPreflight`'s status into `export()`'s `precomputedZoteroStatus` --
    /// that would make agreement trivially true by construction. Each side checks Zotero
    /// independently here, matching how `ExportViewModel` actually calls both in sequence.
    @Test(
        "zoteroPreflight and export() agree: both block the same DOCX with the same content and settings",
        .enabled(if: !ExportZoteroPreflightTests.isBetterBibTeXPortOpen())
    )
    func zoteroPreflightAgreesWithExport() async throws {
        let service = ExportService()
        let content = "See [@smith2020] for details."

        var preflightSettings = ExportSettings()
        preflightSettings.useCustomLuaScript = true
        preflightSettings.customLuaScriptPath = Self.zoteroLuaPath

        let preflight = try await service.zoteroPreflight(
            content: content,
            format: .word,
            settings: preflightSettings
        )
        #expect(preflight.isBlocked)

        // Same content, same lua configuration, plus a stand-in Pandoc so export() can run far
        // enough to reach its own gate (see exportThrowsBeforePandocInvocation above).
        var exportSettings = preflightSettings
        exportSettings.customPandocPath = "/usr/bin/true"

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("preflight-agreement-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        do {
            _ = try await service.export(
                content: content,
                to: outputURL,
                format: .word,
                settings: exportSettings,
                projectURL: nil
            )
            Issue.record("Expected export() to throw zoteroRequiredForCitations to match zoteroPreflight's block, but it succeeded")
        } catch ExportError.zoteroRequiredForCitations(let format, let exportZoteroStatus) {
            #expect(format == .word)
            #expect(exportZoteroStatus == preflight.zoteroStatus)
        } catch {
            Issue.record("Expected zoteroRequiredForCitations, got \(error)")
        }
    }

    // MARK: - zoteroPreflight surfaces a misconfigured resource path (must-fix: these used to
    // be silently swallowed by the ViewModel's `try?` and only discovered after the save panel)

    @Test("zoteroPreflight throws luaScriptNotFound for a configured-but-missing custom Lua script, for DOCX/ODT", arguments: nonPDFFormats)
    func zoteroPreflightThrowsForMissingCustomLuaScript(format: ExportFormat) async throws {
        let service = ExportService()
        var settings = ExportSettings()
        settings.useCustomLuaScript = true
        settings.customLuaScriptPath = "/nonexistent/path/does-not-exist-\(UUID().uuidString).lua"

        do {
            // No citations at all -- keeps this deterministic (no real Zotero network attempt)
            // and proves the lua-path check isn't gated on citations either.
            _ = try await service.zoteroPreflight(content: "Plain text, no citations here.", format: format, settings: settings)
            Issue.record("Expected zoteroPreflight to throw luaScriptNotFound")
        } catch ExportError.luaScriptNotFound {
            // Expected.
        } catch {
            Issue.record("Expected luaScriptNotFound, got \(error)")
        }
    }

    @Test("zoteroPreflight throws referenceDocNotFound for a configured-but-missing custom Word reference document")
    func zoteroPreflightThrowsForMissingCustomReferenceDoc() async throws {
        let service = ExportService()
        var settings = ExportSettings()
        settings.useCustomReferenceDoc = true
        settings.customReferenceDocPath = "/nonexistent/path/does-not-exist-\(UUID().uuidString).docx"

        do {
            // No citations at all -- proves the reference-doc check isn't gated on citations.
            _ = try await service.zoteroPreflight(content: "Plain text, no citations here.", format: .word, settings: settings)
            Issue.record("Expected zoteroPreflight to throw referenceDocNotFound")
        } catch ExportError.referenceDocNotFound {
            // Expected.
        } catch {
            Issue.record("Expected referenceDocNotFound, got \(error)")
        }
    }

    // MARK: - export()'s precomputedZoteroStatus (must-fix: eliminate the duplicate Zotero
    // network check between zoteroPreflight and export() on the common path)
    //
    // Both tests below are deliberately NOT gated on `isBetterBibTeXPortOpen()`: passing
    // `precomputedZoteroStatus` should make `export()` honor it unconditionally, regardless of
    // Zotero's real, live status on the machine running the test -- if `export()` ever ignored
    // the precomputed value and checked again itself, these assertions would become sensitive
    // to that live status and could flip depending on whether Zotero happens to be running,
    // which is exactly the bug this proves does NOT happen.

    @Test("export() honors a precomputed blocking ZoteroStatus instead of checking again, regardless of Zotero's real status")
    func exportHonorsPrecomputedBlockingStatus() async throws {
        let service = ExportService()
        var settings = ExportSettings()
        settings.customPandocPath = "/usr/bin/true"
        settings.useCustomLuaScript = true
        settings.customLuaScriptPath = Self.zoteroLuaPath

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("precomputed-blocking-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        do {
            _ = try await service.export(
                content: "See [@smith2020] for details.",
                to: outputURL,
                format: .word,
                settings: settings,
                projectURL: nil,
                precomputedZoteroStatus: .notRunning
            )
            Issue.record("Expected export() to throw zoteroRequiredForCitations using the precomputed status")
        } catch ExportError.zoteroRequiredForCitations(let format, let zoteroStatus) {
            #expect(format == .word)
            #expect(zoteroStatus == .notRunning)
        } catch {
            Issue.record("Expected zoteroRequiredForCitations, got \(error)")
        }
    }

    @Test("export() honors a precomputed .running ZoteroStatus and proceeds, regardless of Zotero's real status")
    func exportHonorsPrecomputedRunningStatus() async throws {
        let service = ExportService()
        var settings = ExportSettings()
        settings.customPandocPath = "/usr/bin/true"
        settings.useCustomLuaScript = true
        settings.customLuaScriptPath = Self.zoteroLuaPath

        // `export()` only ever reads the actor's OWN `pandocLocator.customPath` (set via
        // `configure`), never `settings.customPandocPath` directly. Without this call,
        // `pandocLocator.getPath()` falls through to searching real system pandoc install
        // locations -- and content with a genuine citekey like `[@smith2020]` would then run
        // through a REAL pandoc + the real zotero.lua filter, making a real (and here, doomed,
        // since there's no real Zotero/Better BibTeX in a test environment) network call. That
        // surfaces as `.citationFilterFailed` (pandoc's exit-83 mapping), not the clean success
        // this test wants to assert -- a test-setup gap, not a product bug (see the earlier
        // `exportHonorsPrecomputedBlockingStatus` test above, which never reaches pandoc at
        // all, so it never hit this). Calling `configure` first makes the `/usr/bin/true`
        // stand-in -- a real, always-present, always-exits-0, touches-nothing executable --
        // actually take effect, so this test provably never depends on a real Zotero
        // connection or a real pandoc installation being present on the machine running it.
        await service.configure(with: settings)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("precomputed-running-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let result = try await service.export(
            content: "See [@smith2020] for details.",
            to: outputURL,
            format: .word,
            settings: settings,
            projectURL: nil,
            precomputedZoteroStatus: .running
        )
        #expect(result.zoteroStatus == .running)
    }
}
