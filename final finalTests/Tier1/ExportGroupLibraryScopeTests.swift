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
//     citationArguments` gains a `groupLibraryScope: ExportService.GroupLibraryScope` parameter
//     (bundling `names: [String]` and `ids: [Int]` -- a parameter-object, to stay under
//     SwiftLint's function_parameter_count limit) and, for DOCX/ODT only, appends `--metadata
//     zotero-group-libraries=<JSON array>` and/or `--metadata zotero-group-library-ids=<JSON
//     array>` alongside `--lua-filter`. The two arrays come from `ZoteroService.
//     groupLibraryMetadata(from:)`,
//     which reuses the SAME collision-safe partition (`groupLibraryScopes`) the citekey-lookup
//     path already uses, instead of the old exact-string dedupe of `groupLibraryNames(from:)`
//     (deleted) that silently collapsed two same-named group libraries into one entry.
//  2. Lua side (the "LOCAL PATCH (zotero-group-libraries)" block in zotero.lua itself): a
//     second BBT lookup phase, scoped to those group libraries (batched names plus one call per
//     colliding-or-nameless id), for any citekey still unresolved after the existing
//     personal-library-only call -- including a name-by-name retry fallback for when BBT rejects
//     a whole batched name call over one stale library name, and cross-scope/self-reported
//     duplicate withholding (keyed on lowercased citekeys, matching the Swift-side
//     `mergeGroupOutcomes`) so a citekey that resolves in more than one scope is reported as a
//     duplicate rather than picked arbitrarily. This is the highest-risk, otherwise-undertested
//     part of the whole fix -- `ExportGroupLibraryScopeLuaMergeTests` drives the REAL, patched
//     zotero.lua file (not a hand-duplicated reimplementation) via `pandoc lua`, which bundles a
//     full Lua 5.4 interpreter and needs no separate `lua`/`luajit` binary. It covers the
//     success path, the total-failure negative path, the duplicate-group-library-name id-scoped
//     path, the cross-scope duplicate withhold, and the single-scope self-ambiguous withhold. A
//     behavioral test naturally also guards against this logic silently disappearing if this
//     vendored file is ever refreshed from upstream -- a naive revert of the LOCAL PATCH block
//     would make the success-path scenarios fail outright, since phase 2 would simply never run.
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

    private static let idsMetadataPrefix = "zotero-group-library-ids="

    private func buildArguments(
        format: ExportFormat, luaScriptPath: String?, groupLibraryNames: [String], groupLibraryIDs: [Int] = []
    ) async -> [String] {
        let service = ExportService()
        let result = await service.citationArguments(
            format: format,
            luaScriptPath: luaScriptPath,
            pdfBibliography: ExportService.PDFBibliographyRequest(
                settings: ExportSettings(), tempDir: FileManager.default.temporaryDirectory
            ),
            bibliography: nil,
            groupLibraryScope: ExportService.GroupLibraryScope(names: groupLibraryNames, ids: groupLibraryIDs)
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

    /// Extracts and JSON-decodes the value of a `--metadata zotero-group-library-ids=<json>`
    /// argument, if one is present in `arguments`.
    private func decodedGroupLibraryIDs(in arguments: [String]) -> [Int]? {
        for (index, arg) in arguments.enumerated() where arg == "--metadata" {
            guard index + 1 < arguments.count else { continue }
            let value = arguments[index + 1]
            guard value.hasPrefix(Self.idsMetadataPrefix) else { continue }
            let jsonString = String(value.dropFirst(Self.idsMetadataPrefix.count))
            guard let data = jsonString.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data) as? [Int] else {
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

    @Test("Non-empty groupLibraryIDs on .word produce a correctly JSON-encoded --metadata zotero-group-library-ids argument")
    func nonEmptyIDsProduceMetadataArgument() async {
        let arguments = await buildArguments(
            format: .word, luaScriptPath: Self.dummyLuaPath, groupLibraryNames: ["Foo"], groupLibraryIDs: [7, 8]
        )
        #expect(decodedGroupLibraryIDs(in: arguments) == [7, 8])
    }

    @Test("Empty groupLibraryIDs produce no --metadata zotero-group-library-ids argument")
    func emptyIDsProduceNoMetadataArgument() async {
        let arguments = await buildArguments(
            format: .word, luaScriptPath: Self.dummyLuaPath, groupLibraryNames: ["Foo"], groupLibraryIDs: []
        )
        #expect(decodedGroupLibraryIDs(in: arguments) == nil)
    }

    /// [M5 regression] The single most important assertion in this whole round: the two
    /// `--metadata` emissions (names, ids) are INDEPENDENT sibling `if` blocks, never one nested
    /// inside the other's non-empty check. "Every group library collides" -- groupLibraryNames
    /// empty, groupLibraryIDs non-empty -- is the exact scenario the whole export-path fix exists
    /// for; if the ids emission were gated on names being non-empty, this would be the one case
    /// where the fix goes silently dead.
    @Test("groupLibraryNames empty AND groupLibraryIDs non-empty STILL produces the ids metadata argument")
    func namesEmptyIDsNonEmptyStillProducesIDsMetadataArgument() async {
        let arguments = await buildArguments(
            format: .word, luaScriptPath: Self.dummyLuaPath, groupLibraryNames: [], groupLibraryIDs: [7, 8]
        )
        #expect(decodedGroupLibraryNames(in: arguments) == nil, "No names to send -- correctly nothing here")
        #expect(
            decodedGroupLibraryIDs(in: arguments) == [7, 8],
            "The ids argument must still be emitted even though groupLibraryNames is empty"
        )
        #expect(arguments.contains("--lua-filter"), "The lua filter itself is unaffected by an all-colliding library set")
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
/// - `zotero-group-library-case-variance-withhold-harness.lua` /
///   `zotero-group-library-case-variance-resolve-harness.lua` /
///   `zotero-group-library-case-variance-unrelated-key-harness.lua` -- reconciliation must be
///   anchored to the REQUESTED citekey spelling (`unresolved`), not to whichever spelling a BBT
///   response happens to use for the same lowercased identity: a requested spelling can be
///   withheld/resolved even when no response ever echoes that exact casing back, and a response
///   spelling must never be projected onto an unrelated, already-resolved citekey.
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

    /// The duplicate-group-library-name fix itself: one uniquely-named library batches via
    /// `groupLibraryNames`, two same-named libraries are id-scoped via `groupLibraryIDs`, and
    /// the citekey living only in the SECOND of those two ids still resolves -- proving id-scoped
    /// calls aren't silently shadowed by the first id's miss. See
    /// `zotero-group-library-duplicate-name-harness.lua`'s header comment for the exact scenario.
    func testDuplicateGroupLibraryNameResolvesViaIDScope() throws {
        try runHarness(named: "zotero-group-library-duplicate-name-harness.lua")
    }

    /// Cross-scope duplicate withhold: two id-scoped libraries (both named "Shared", so neither
    /// can be name-scoped) each genuinely resolve the SAME citekey to a different item. Per
    /// `mergeGroupOutcomes`'s Swift-side contract mirrored here, the citekey must be withheld
    /// and reported as a duplicate rather than resolved to an arbitrary winner. See
    /// `zotero-group-library-cross-scope-duplicate-harness.lua`'s header comment.
    func testCrossScopeDuplicateIsWithheldAndReportedAsDuplicate() throws {
        try runHarness(named: "zotero-group-library-cross-scope-duplicate-harness.lua")
    }

    /// Single-scope self-ambiguous withhold: one id-scoped library's OWN response reports
    /// `errors[key] >= 2` (BBT itself found 2+ matches inside that one library, no cross-scope
    /// collision involved at all). See
    /// `zotero-group-library-self-ambiguous-scope-harness.lua`'s header comment.
    func testSelfAmbiguousWithinOneScopeIsWithheld() throws {
        try runHarness(named: "zotero-group-library-self-ambiguous-scope-harness.lua")
    }

    /// Case-variance withhold: two id-scoped calls each genuinely resolve the SAME citekey
    /// identity to a DIFFERENT item, but under DIFFERENT casings of that identity (`roy2022` /
    /// `ROY2022`) -- neither matching the requested spelling `Roy2022` exactly. Reconciliation
    /// must still be anchored to the requested spelling: `Roy2022` must be withheld and reported
    /// as a duplicate, not left at its stale phase-1 "not found" value just because no response
    /// happened to use that exact casing. See
    /// `zotero-group-library-case-variance-withhold-harness.lua`'s header comment.
    func testCaseVarianceAcrossScopesIsWithheldAndReportedAsDuplicate() throws {
        try runHarness(named: "zotero-group-library-case-variance-withhold-harness.lua")
    }

    /// Case-variance resolve: a single id-scoped call resolves the requested citekey `Roy2022`
    /// to an item keyed under a different casing (`roy2022`) -- a single match, no duplicate.
    /// The outcome must land on the REQUESTED spelling's entry (`get('Roy2022')` must return the
    /// item), not on the response spelling's entry. See
    /// `zotero-group-library-case-variance-resolve-harness.lua`'s header comment.
    func testCaseVarianceSingleMatchResolvesUnderRequestedSpelling() throws {
        try runHarness(named: "zotero-group-library-case-variance-resolve-harness.lua")
    }

    /// Guards the second case-variance failure mode: `Roy2022` (already resolved in phase 1,
    /// from the personal library) and `ROY2022` (a separate, unresolved citekey) are both cited.
    /// A group-scoped call answering the `ROY2022` lookup happens to key its result `Roy2022`
    /// (BBT's own spelling choice) -- the exact same string as the unrelated, already-resolved
    /// citekey. That response spelling must never clobber `Roy2022`'s untouched phase-1 entry.
    /// See `zotero-group-library-case-variance-unrelated-key-harness.lua`'s header comment.
    func testCaseVarianceResponseSpellingNeverClobbersUnrelatedResolvedKey() throws {
        try runHarness(named: "zotero-group-library-case-variance-unrelated-key-harness.lua")
    }
}
