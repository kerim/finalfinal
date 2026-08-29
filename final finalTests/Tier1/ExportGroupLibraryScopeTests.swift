//
//  ExportGroupLibraryScopeTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Coverage for the group/shared-library citekey resolution fix: a citekey that lives only in
//  a Zotero group/shared library (not the personal library) used to silently export as plain
//  text instead of a live field code in DOCX/ODT, because the vendored `zotero.lua` Lua filter
//  (Resources/Export/zotero.lua) made its own unscoped Better BibTeX JSON-RPC call that only
//  ever searches the personal library. The fix has two halves:
//
//  1. Swift side (`ExportGroupLibraryScopeArgumentTests` below): `ExportService.
//     citationArguments` gains a `groupLibraryNames: [String]` parameter and, for DOCX/ODT
//     only, appends `--metadata zotero-group-libraries=<JSON array>` alongside `--lua-filter`.
//  2. Lua side (the "LOCAL PATCH (zotero-group-libraries)" block in zotero.lua itself): a
//     second BBT lookup phase, scoped to those group libraries, for any citekey still
//     unresolved after the existing personal-library-only call -- including a name-by-name
//     retry fallback for when BBT rejects a whole batched call over one stale library name.
//     This is the highest-risk, otherwise-untested part of the whole fix --
//     `ExportGroupLibraryScopeLuaMergeTests` drives the REAL, patched zotero.lua file (not a
//     hand-duplicated reimplementation) via `pandoc lua`, which bundles a full Lua 5.4
//     interpreter and needs no separate `lua`/`luajit` binary. It covers both the success path
//     (phase 2 resolves a citekey phase 1 missed, and the phase-2 request itself carries the
//     configured library scope) and the negative path (a total phase-2 failure must not
//     clobber what phase 1 already resolved). A behavioral test naturally also guards against
//     the two-phase logic silently disappearing if this vendored file is ever refreshed from
//     upstream -- a naive revert of the LOCAL PATCH block would make the success-path scenario
//     fail outright, since phase 2 would simply never run.
//

import Testing
import XCTest
import Foundation
@testable import final_final

// MARK: - Swift-side argument shape

@Suite("Export group-library scope -- Swift-side argument shape")
struct ExportGroupLibraryScopeArgumentTests {

    private static let dummyLuaPath = "/tmp/does-not-need-to-exist-for-this-test/zotero.lua"
    private static let metadataPrefix = "zotero-group-libraries="

    private func buildArguments(
        format: ExportFormat, luaScriptPath: String?, groupLibraryNames: [String]
    ) async -> [String] {
        let service = ExportService()
        let result = await service.citationArguments(
            format: format,
            luaScriptPath: luaScriptPath,
            pdfBibliography: ExportService.PDFBibliographyRequest(
                settings: ExportSettings(), tempDir: FileManager.default.temporaryDirectory
            ),
            bibliography: nil,
            groupLibraryNames: groupLibraryNames
        )
        return result.arguments
    }

    /// Extracts and JSON-decodes the value of a `--metadata zotero-group-libraries=<json>`
    /// argument, if one is present in `arguments`.
    private func decodedGroupLibraryNames(in arguments: [String]) -> [String]? {
        for (index, arg) in arguments.enumerated() where arg == "--metadata" {
            guard index + 1 < arguments.count else { continue }
            let value = arguments[index + 1]
            guard value.hasPrefix(Self.metadataPrefix) else { continue }
            let jsonString = String(value.dropFirst(Self.metadataPrefix.count))
            guard let data = jsonString.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data) as? [String] else {
                return nil
            }
            return decoded
        }
        return nil
    }

    @Test("Non-empty group library names on .word produce a correctly JSON-encoded --metadata argument")
    func nonEmptyNamesProduceMetadataArgument() async {
        let names = ["Sifo-Futing", "Some Shared Library"]
        let arguments = await buildArguments(
            format: .word, luaScriptPath: Self.dummyLuaPath, groupLibraryNames: names
        )

        #expect(arguments.contains("--lua-filter"))
        #expect(arguments.contains(Self.dummyLuaPath))
        #expect(decodedGroupLibraryNames(in: arguments) == names)
    }

    @Test("The same holds for .odt")
    func nonEmptyNamesProduceMetadataArgumentForODT() async {
        let names = ["Some Shared Library"]
        let arguments = await buildArguments(
            format: .odt, luaScriptPath: Self.dummyLuaPath, groupLibraryNames: names
        )
        #expect(decodedGroupLibraryNames(in: arguments) == names)
    }

    @Test("Empty group library names produce no --metadata zotero-group-libraries argument")
    func emptyNamesProduceNoMetadataArgument() async {
        let arguments = await buildArguments(
            format: .word, luaScriptPath: Self.dummyLuaPath, groupLibraryNames: []
        )
        #expect(decodedGroupLibraryNames(in: arguments) == nil)
        // The --lua-filter argument itself is unaffected by an empty group-library list.
        #expect(arguments.contains("--lua-filter"))
    }

    @Test(".pdf format never receives the --metadata argument, regardless of group library names")
    func pdfNeverReceivesMetadataArgument() async {
        let arguments = await buildArguments(
            format: .pdf, luaScriptPath: Self.dummyLuaPath, groupLibraryNames: ["A Library"]
        )
        #expect(decodedGroupLibraryNames(in: arguments) == nil)
        // PDF never appends --lua-filter from citationArguments at all (that's the DOCX/ODT
        // branch only -- PDF's own lua filters, if any, are appended elsewhere).
        #expect(!arguments.contains("--lua-filter"))
    }

    @Test("A library name containing a quote and a backslash round-trips correctly through JSON encode/decode")
    func specialCharacterNameRoundTrips() async {
        let names = ["Weird \"Quoted\" \\ Library"]
        let arguments = await buildArguments(
            format: .word, luaScriptPath: Self.dummyLuaPath, groupLibraryNames: names
        )
        #expect(decodedGroupLibraryNames(in: arguments) == names)
    }

    @Test("With no lua filter path at all, no --metadata zotero-group-libraries argument is ever appended")
    func noLuaScriptPathMeansNoMetadataArgumentEvenWithNames() async {
        let arguments = await buildArguments(
            format: .word, luaScriptPath: nil, groupLibraryNames: ["A Library"]
        )
        #expect(decodedGroupLibraryNames(in: arguments) == nil)
        #expect(arguments.isEmpty)
    }
}

// MARK: - Lua-side merge logic (real-tool integration)

/// Drives the REAL, patched `zotero.lua` file's phase-1/phase-2 merge logic via `pandoc lua`
/// (pandoc bundles a full Lua 5.4 interpreter -- including `lpeg`, `pandoc.mediabag`, and
/// `pandoc.json` -- runnable standalone with no separate `lua`/`luajit` binary needed). Not a
/// hand-duplicated reimplementation of the merge logic: each harness script under
/// `final finalTests/Fixtures/` `dofile`s the actual vendored file, monkey-patches
/// `pandoc.mediabag.fetch` to return canned JSON-RPC responses instead of hitting a real Better
/// BibTeX server, and exercises the module's own public `get(citekey)` entry point. See each
/// harness file's header comment for its exact scenario and expected outcome:
/// - `zotero-group-library-merge-harness.lua` -- the success path: phase 2 resolves a citekey
///   phase 1 missed, and the phase-2 request itself is asserted to carry the configured
///   library scope.
/// - `zotero-group-library-merge-failure-harness.lua` -- the negative path: a total phase-2
///   failure (batch call fails, then every per-name retry also fails) must not clobber what
///   phase 1 already resolved.
final class ExportGroupLibraryScopeLuaMergeTests: XCTestCase {

    private static func findPandocPath() -> String? {
        let candidates = ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc", "/usr/bin/pandoc"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tier1/
            .deletingLastPathComponent()  // final finalTests/
            .deletingLastPathComponent()  // repo root
    }

    private static func harnessPath(_ filename: String) -> String {
        repoRoot().appendingPathComponent("final finalTests/Fixtures/\(filename)").path
    }

    private static var zoteroLuaPath: String {
        repoRoot().appendingPathComponent("final final/Resources/Export/zotero.lua").path
    }

    /// Runs one standalone `pandoc lua` harness script against the real vendored `zotero.lua`
    /// and asserts it exits 0 and prints "PASS". Shared by both the success-path and the
    /// failure-path (negative) merge-logic scenarios below -- see each harness file's header
    /// comment for what it specifically proves.
    private func runHarness(named filename: String) throws {
        guard let pandocPath = Self.findPandocPath() else {
            throw XCTSkip("Pandoc not installed — skipping zotero.lua group-library merge verification")
        }
        let harnessPath = Self.harnessPath(filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harnessPath),
                      "merge-logic harness should exist at \(harnessPath)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.zoteroLuaPath),
                      "zotero.lua should exist at \(Self.zoteroLuaPath)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pandocPath)
        process.arguments = ["lua", harnessPath, Self.zoteroLuaPath]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertEqual(process.terminationStatus, 0,
                       "merge-logic harness (\(filename)) should exit 0. stdout:\n\(stdout)\nstderr:\n\(stderr)")
        XCTAssertTrue(stdout.contains("PASS"),
                      "merge-logic harness (\(filename)) should print PASS. stdout:\n\(stdout)\nstderr:\n\(stderr)")
    }

    func testPhase2MergeResolvesCitekeyAndClearsStalePhase1Error() throws {
        try runHarness(named: "zotero-group-library-merge-harness.lua")
    }

    /// Negative path: a total phase-2 failure (the batched call fails, and the per-name retry
    /// for every configured group library also fails) must never clobber what phase 1 already
    /// resolved. See `zotero-group-library-merge-failure-harness.lua`'s header comment for the
    /// exact scenario.
    func testPhase2FailureDoesNotClobberPhase1() throws {
        try runHarness(named: "zotero-group-library-merge-failure-harness.lua")
    }
}
