//
//  ExportCitekeyCanonicalizationTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Coverage for the citekey-case-insensitivity export fix: a document citing the same
//  reference under two casings (`[@Smith2020]` and `[@smith2020]`) now renders correctly
//  in-app, but until this fix the miscased spelling still exported as unresolved -- PDF (via
//  pandoc's case-SENSITIVE `--citeproc`/CSL-JSON matching) and DOCX/ODT (via zotero.lua's own
//  live BBT lookup, keyed by the exact literal citekey string) both matched case-sensitively
//  against the item's `id`. The fix rewrites the citekey TEXT itself in the temp export copy,
//  for all formats: `ExportService.canonicalCitekeyMap` proposes a `requested -> canonical`
//  rewrite map from a resolved bibliography batch, and `ExportService.canonicalizeCitekeys`
//  applies it to the exported markdown.
//
//  Split into two parts:
//  - `ExportCitekeyCanonicalizationTests` (Swift Testing): pure-function coverage of
//    `canonicalCitekeyMap`/`canonicalizeCitekeys`/`MarkdownUtils.maskCodeContent`, plus the
//    network-mocked (no pandoc) coverage of `fetchBibliographyJSON`'s dedupe and the
//    ambiguity-veto interaction with `mergeRawOutcomes`'s clearing behavior.
//  - `ExportCitekeyCanonicalizationIntegrationTests` (XCTest): real-pandoc, mocked-BBT
//    integration tests proving the rewrite actually reaches the temp file pandoc reads --
//    matching the existing real-pandoc idiom in ImageCaptionExportTests.swift /
//    ExportDiagnosticCaptureGatingTests.swift (XCTSkip if pandoc isn't installed).
//

import Testing
import XCTest
import Foundation
@testable import final_final

@Suite("Export citekey canonicalization — Tier 1: Silent Killers")
struct ExportCitekeyCanonicalizationTests {

    // MARK: - canonicalCitekeyMap: exact spelling is never rewritten

    @Test("A citekey already spelled exactly as the resolved id is never proposed for rewrite")
    func exactSpellingNeverRewritten() {
        let map = ExportService.canonicalCitekeyMap(
            requested: ["smith2020"],
            resolvedIDs: ["smith2020"],
            rawAmbiguousKeys: []
        )
        #expect(map.isEmpty)
    }

    // MARK: - canonicalCitekeyMap: legacy Extra-field shape (id diverges for reasons other than case)

    @Test(
        """
        A citekey resolving to an id that differs for reasons OTHER than case -- the legacy \
        Zotero "Extra" field shape, where a document cites the stale `citation-key` value and \
        BBT resolves it to a completely different canonical `id` -- is never renamed. Renames \
        are only ever proposed for a PURE case difference (requested/canonical are case-folds \
        of each other), and are always pinned to `id`, never `citation-key` -- see \
        ZoteroLibraryScopeTests.citationKeyIdAndRequestedKeyAllDifferStillResolvesAndCaches for \
        the resolution-layer test of this same fixture shape (unaffected by this change).
        """
    )
    func legacyExtraFieldShapeMapStaysEmpty() async {
        // requested = "oldLegacyKey2010" (what the document actually cites -- the stale
        // Extra-field citation-key value); resolved id = "friedman2010" (BBT's real canonical
        // match). Not a case fold of each other, so rule 1 rejects it outright.
        let map = ExportService.canonicalCitekeyMap(
            requested: ["oldLegacyKey2010"],
            resolvedIDs: ["friedman2010"],
            rawAmbiguousKeys: []
        )
        #expect(map.isEmpty)

        let service = ExportService()
        let content = "See [@oldLegacyKey2010] for details."
        let rewritten = await service.canonicalizeCitekeys(in: content, using: map)
        #expect(rewritten == content, "An empty map must leave content completely untouched")
    }

    // MARK: - canonicalCitekeyMap: collision guard

    @Test(
        """
        Two genuinely DISTINCT resolved items whose ids differ only by case must never be \
        merged into one canonical spelling -- the collision guard drops that whole fold-group \
        from consideration, so neither spelling gets rewritten to the other.
        """
    )
    func collisionGuardDropsAmbiguousFoldGroup() {
        // "Anderson2020" and "anderson2020" are two REAL, DIFFERENT works here (not a
        // case-variant pair of the same work) -- resolvedIDs contains both as distinct ids.
        let map = ExportService.canonicalCitekeyMap(
            requested: ["Anderson2020", "anderson2020"],
            resolvedIDs: ["Anderson2020", "anderson2020"],
            rawAmbiguousKeys: []
        )
        #expect(map.isEmpty, "Neither spelling may be rewritten when two distinct ids share a case fold")
    }

    // MARK: - canonicalizeCitekeys: all citation bracket syntax forms preserved

    @Test("Every pandoc citation bracket form has its key rewritten while surrounding syntax is preserved")
    func allCitationBracketFormsPreserved() async {
        let service = ExportService()
        let map = ["Smith2020": "smith2020"]

        #expect(await service.canonicalizeCitekeys(in: "[@Smith2020]", using: map) == "[@smith2020]")
        #expect(
            await service.canonicalizeCitekeys(in: "[@Smith2020, p. 21]", using: map) == "[@smith2020, p. 21]"
        )
        #expect(
            await service.canonicalizeCitekeys(in: "[@Smith2020{p. 21}]", using: map) == "[@smith2020{p. 21}]"
        )
        #expect(
            await service.canonicalizeCitekeys(in: "[see @Smith2020]", using: map) == "[see @smith2020]"
        )
        #expect(
            await service.canonicalizeCitekeys(in: "[-@Smith2020]", using: map) == "[-@smith2020]"
        )
    }

    // MARK: - canonicalizeCitekeys: multiple occurrences all rewritten

    @Test("Every occurrence of a miscased citekey in a document is rewritten, not just the first")
    func multipleOccurrencesAllRewritten() async {
        let service = ExportService()
        let content = "First [@Smith2020]. Second [@Smith2020]. Third [@Smith2020]."
        let rewritten = await service.canonicalizeCitekeys(in: content, using: ["Smith2020": "smith2020"])
        #expect(rewritten == "First [@smith2020]. Second [@smith2020]. Third [@smith2020].")
    }

    // MARK: - canonicalizeCitekeys: code-block / inline-code exclusion

    @Test("A citekey-shaped token inside a fenced code block or inline code is never rewritten")
    func codeContentExcluded() async {
        let service = ExportService()
        let map = ["Smith2020": "smith2020"]

        let fenced = "```\n[@Smith2020]\n```\n\nReal cite [@Smith2020] here."
        let rewrittenFenced = await service.canonicalizeCitekeys(in: fenced, using: map)
        #expect(rewrittenFenced == "```\n[@Smith2020]\n```\n\nReal cite [@smith2020] here.")

        let inline = "Example: `[@Smith2020]` shows the syntax. Real cite [@Smith2020] here."
        let rewrittenInline = await service.canonicalizeCitekeys(in: inline, using: map)
        #expect(rewrittenInline == "Example: `[@Smith2020]` shows the syntax. Real cite [@smith2020] here.")
    }

    // MARK: - canonicalizeCitekeys: email/npm/URL shapes untouched

    @Test("Email, npm-scoped-package, and URL-handle shapes are never mistaken for a citekey to rewrite")
    func nonCitekeyAtShapesUntouched() async {
        let service = ExportService()
        // These map keys are deliberately chosen so that IF the extraction regex mistakenly
        // matched inside these shapes, the rewrite would be visible -- proving the exclusion
        // is real, not just that the map happened to miss.
        let map = ["example.com": "changed", "scope/pkg": "changed", "handle": "changed"]

        let email = "[contact me@example.com]"
        #expect(await service.canonicalizeCitekeys(in: email, using: map) == email)

        let npm = "[install @scope/pkg]"
        #expect(await service.canonicalizeCitekeys(in: npm, using: map) == npm)

        let url = "[see bsky.app/@handle]"
        #expect(await service.canonicalizeCitekeys(in: url, using: map) == url)
    }

    // MARK: - canonicalizeCitekeys: reverse-order application under a length-changing replacement

    @Test(
        """
        A length-CHANGING replacement (a Turkish İ-style case fold, which does not preserve \
        UTF-16 length) earlier in the document must not corrupt the offset of a LATER, \
        unrelated replacement -- proves replacements are applied in reverse document order, \
        not forward using pre-computed offsets.
        """
    )
    func reverseOrderApplicationSurvivesLengthChange() async throws {
        let original = "İstanbul2020"
        let canonical = original.lowercased()
        try #require(
            canonical.utf16.count != original.utf16.count,
            "Sanity check: this example must actually change length for the test to be meaningful"
        )

        let content = "See [@\(original)] and later [@Ankara2021] too."
        let map = [original: canonical, "Ankara2021": "ankara2021"]

        let service = ExportService()
        let rewritten = await service.canonicalizeCitekeys(in: content, using: map)

        #expect(rewritten == "See [@\(canonical)] and later [@ankara2021] too.")
    }

    // MARK: - MarkdownUtils.maskCodeContent: length-exactness with emoji/CJK content

    @Test("maskCodeContent preserves UTF-16 length exactly, even with emoji/CJK content inside and outside code spans")
    func maskCodeContentPreservesUTF16LengthWithEmojiAndCJK() {
        let content = "Prose 🎉 before. `inline 🎉 code` then ```\nfenced 你好 code\n``` and 你好 after."
        let masked = MarkdownUtils.maskCodeContent(in: content)

        #expect(masked.utf16.count == content.utf16.count, "Masking must never change the overall UTF-16 length")
        #expect(masked.contains("Prose 🎉 before."), "Text outside code spans must survive untouched")
        #expect(masked.contains("你好 after."), "Text outside code spans must survive untouched")
        #expect(!masked.contains("inline"), "Inline code content must be blanked out")
        #expect(!masked.contains("fenced"), "Fenced code content must be blanked out")
    }

    // MARK: - fetchBibliographyJSON: dedupe by id before serializing

    @Test(
        """
        fetchBibliographyJSON dedupes resolved items by CSL `id` (first occurrence wins) \
        BEFORE serializing to JSON and before deriving resolvedIDs -- needed because the \
        item.export fallback path (unlike item.pandoc_filter's own dict-keyed-by-id \
        re-keying) can return the SAME item twice when two differently-cased requests both \
        match it, which would otherwise duplicate the work in the exported reference list.
        """
    )
    @MainActor
    func fetchBibliographyJSONDedupesResolvedItemsById() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()
            // Force resolveRawViaPandocFilter to fail so fetchRawItemsForCitekeys falls back
            // to item.export -- the array-based path that doesn't dedupe on its own. Mirrors
            // ZoteroLibraryScopeTests+RawBatchFallback.swift's forced-failure idiom.
            let errorJSON = #"{"jsonrpc":"2.0","error":{"code":-1,"message":"forced failure for test"},"id":1}"#
            MockBBTURLProtocol.responses["item.pandoc_filter"] = (200, Data(errorJSON.utf8))

            // item.export returns the SAME item twice -- once matched against each of the two
            // differently-cased requested citekeys, exactly as BBT's case-insensitive
            // citekey matching (with no per-item dedupe of its own) can produce.
            let fallbackJSON = """
            [{"id":"smith2020","type":"book","citation-key":"smith2020","title":"Canonical Copy"}, \
            {"id":"smith2020","type":"book","citation-key":"smith2020","title":"Canonical Copy"}]
            """
            MockBBTURLProtocol.responses["item.export"] =
                (200, Data(#"{"jsonrpc":"2.0","result":\#(fallbackJSON),"id":2}"#.utf8))

            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer { URLProtocol.unregisterClass(MockBBTURLProtocol.self) }

            let service = ExportService()
            let result = await service.fetchBibliographyJSON(for: ["Smith2020", "smith2020"])

            #expect(result.resolvedIDs == ["smith2020"], "The duplicate id must be collapsed to a single entry")
            let json = try #require(result.json)
            let decoded = try #require(
                (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]]
            )
            #expect(decoded.count == 1, "The serialized bibliography JSON must not contain the duplicate")
        }
    }

    // MARK: - Ambiguity veto: rawAmbiguousKeys survives even when ambiguousKeys is cleared

    @Test(
        """
        mergeRawOutcomes's fully-resolved-after-phase-1 branch clears the regular \
        `ambiguousKeys` (intersected against the now-empty unresolved set), but \
        `rawAmbiguousKeys` is a plain union that survives that clearing -- so \
        canonicalCitekeyMap still refuses to rename a citekey off an arbitrary winner among \
        2+ real BBT matches, even on the exact branch where the ordinary ambiguity signal \
        went silent.
        """
    )
    @MainActor
    func ambiguityVetoSurvivesEvenWhenRegularAmbiguousKeysIsCleared() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()
            // "Smith2020" has 2 real BBT matches (genuinely ambiguous), while "smith2020"
            // (a different spelling in the same batch) cleanly resolves to one item. Because
            // "Smith2020" case-folds to the same string as the resolved "smith2020" item,
            // resolveRawViaPandocFilter's fully-resolved-after-phase-1 branch fires and
            // mergeRawOutcomes clears the regular ambiguousKeys wholesale (see that
            // function's doc comment) -- but rawAmbiguousKeys must still carry "Smith2020"
            // through.
            // swiftlint:disable line_length
            let json = """
            {"jsonrpc":"2.0","result":{"errors":{"Smith2020":2},"items":{"smith2020":{"id":"smith2020","type":"book","citation-key":"smith2020","title":"Canonical Copy"}}},"id":1}
            """
            // swiftlint:enable line_length
            MockBBTURLProtocol.responses["item.pandoc_filter"] = (200, Data(json.utf8))
            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer { URLProtocol.unregisterClass(MockBBTURLProtocol.self) }

            let service = ExportService()
            let bibliography = await service.fetchBibliographyJSON(for: ["Smith2020", "smith2020"])

            #expect(
                bibliography.ambiguousKeys.isEmpty,
                "The regular ambiguity signal is cleared on this branch -- this is pre-existing, disclosed behavior"
            )
            #expect(
                bibliography.rawAmbiguousKeys == ["Smith2020"],
                "The raw ambiguity signal must survive the clearing so the rename veto still has something to check"
            )

            let map = ExportService.canonicalCitekeyMap(
                requested: ["Smith2020", "smith2020"],
                resolvedIDs: bibliography.resolvedIDs,
                rawAmbiguousKeys: bibliography.rawAmbiguousKeys
            )
            #expect(
                map.isEmpty,
                "Smith2020 must not be renamed off an arbitrary winner among its 2 real BBT matches"
            )
        }
    }

    // MARK: - Divergent citation-key: never a rewrite target (must-fix, review round 2)

    @Test(
        """
        An item whose `citation-key` differs from its `id` -- even by nothing more than case \
        (e.g. citation-key "Smith2020", id "smith2020"; the legacy Zotero Extra-field shape) \
        -- must never become a rewrite target. PDF's --citeproc matches by `id`, but DOCX/ODT's \
        zotero.lua does its own live BBT lookup keyed by `citation-key`, not `id`. Rewriting the \
        document's citekey text to the `id` spelling would fix PDF but silently break the \
        DOCX/ODT lookup for this exact item, since the literal string zotero.lua looks up would \
        no longer match its `citation-key` at all. fetchBibliographyJSON must exclude such an \
        item from `resolvedIDs` entirely, so canonicalCitekeyMap never sees it as a candidate.
        """
    )
    @MainActor
    func divergentCitationKeyIsNeverARewriteTarget() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()
            // citation-key "Smith2020" (the stale legacy value BBT's raw items-dict is keyed
            // by) differs from id "smith2020" ONLY by case -- indistinguishable from a genuine
            // pure-case rename target by canonicalCitekeyMap's rule alone, which is exactly
            // why the filtering must happen upstream, in fetchBibliographyJSON, before
            // resolvedIDs is ever built.
            // swiftlint:disable line_length
            let json = """
            {"jsonrpc":"2.0","result":{"errors":{},"items":{"Smith2020":{"id":"smith2020","citation-key":"Smith2020","type":"book","title":"Divergent Key Item"}}},"id":1}
            """
            // swiftlint:enable line_length
            MockBBTURLProtocol.responses["item.pandoc_filter"] = (200, Data(json.utf8))
            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer { URLProtocol.unregisterClass(MockBBTURLProtocol.self) }

            let service = ExportService()
            let bibliography = await service.fetchBibliographyJSON(for: ["Smith2020"])

            #expect(
                bibliography.resolvedIDs.isEmpty,
                "An item with a divergent citation-key must never appear in resolvedIDs, even though it resolved fine"
            )
            // Sanity check: the item DID resolve and IS in the bibliography JSON -- only its
            // eligibility as a rewrite TARGET is affected, not whether PDF's --citeproc gets
            // to use it at all.
            let bibJSON = try #require(bibliography.json)
            #expect(bibJSON.contains("Divergent Key Item"))

            let map = ExportService.canonicalCitekeyMap(
                requested: ["Smith2020"],
                resolvedIDs: bibliography.resolvedIDs,
                rawAmbiguousKeys: bibliography.rawAmbiguousKeys
            )
            #expect(map.isEmpty, "No rewrite may be proposed for a citekey whose only resolved match has a divergent citation-key")
        }
    }

    // MARK: - Fallback path: rewrite map must never be built, even when it would look safe

    @Test(
        """
        The item.export fallback path (used when the primary item.pandoc_filter lookup fails \
        for any reason) reports NO ambiguity information of any kind -- not "zero ambiguous \
        keys" but structurally incapable of reporting any. supportsAmbiguityReporting must be \
        false on that path, and the caller (mirroring ExportService.swift's export() sequencing \
        exactly) must skip building a rewrite map entirely rather than trust an ambiguity veto \
        that has nothing to veto with. This scenario is deliberately shaped to LOOK safe to \
        rewrite (a clean case-fold match, empty rawAmbiguousKeys) -- proving the gate is doing \
        real protective work, not just trivially passing on obviously-bad input.
        """
    )
    @MainActor
    func fallbackPathNeverBuildsARewriteMap() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()
            // Force the primary path to fail, triggering the item.export fallback.
            let errorJSON = #"{"jsonrpc":"2.0","error":{"code":-1,"message":"forced failure for test"},"id":1}"#
            MockBBTURLProtocol.responses["item.pandoc_filter"] = (200, Data(errorJSON.utf8))

            // The fallback resolves "Smith2020" to a single item id "smith2020" -- a clean
            // case-fold match with zero ambiguity signal (item.export has none to give). Taken
            // in isolation, this looks exactly like a safe rewrite candidate.
            let fallbackJSON = """
            [{"id":"smith2020","type":"book","citation-key":"smith2020","title":"Canonical Copy"}]
            """
            MockBBTURLProtocol.responses["item.export"] =
                (200, Data(#"{"jsonrpc":"2.0","result":\#(fallbackJSON),"id":2}"#.utf8))

            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer { URLProtocol.unregisterClass(MockBBTURLProtocol.self) }

            let service = ExportService()
            let bibliography = await service.fetchBibliographyJSON(for: ["Smith2020"])

            #expect(!bibliography.supportsAmbiguityReporting, "The item.export fallback path must never claim ambiguity reporting")
            #expect(bibliography.resolvedIDs == ["smith2020"], "Sanity check: this really is a clean case-fold match")
            #expect(bibliography.rawAmbiguousKeys.isEmpty, "Sanity check: the fallback has no ambiguity signal to report, safe or not")

            // Mirrors ExportService.swift's export() sequencing exactly: the map must be built
            // ONLY when supportsAmbiguityReporting is true.
            let map = bibliography.supportsAmbiguityReporting
                ? ExportService.canonicalCitekeyMap(
                    requested: ["Smith2020"],
                    resolvedIDs: bibliography.resolvedIDs,
                    rawAmbiguousKeys: bibliography.rawAmbiguousKeys
                )
                : [:]
            #expect(map.isEmpty, "No rewrite may ever be proposed from a batch resolved via the item.export fallback")

            // Confirms the gate is doing real work: without it, this exact scenario WOULD
            // have proposed a rewrite -- demonstrating this is a live guard, not a no-op.
            let mapWithoutGate = ExportService.canonicalCitekeyMap(
                requested: ["Smith2020"],
                resolvedIDs: bibliography.resolvedIDs,
                rawAmbiguousKeys: bibliography.rawAmbiguousKeys
            )
            #expect(!mapWithoutGate.isEmpty, "Sanity check: canonicalCitekeyMap alone has no way to know this batch came from the fallback")
        }
    }
}

// MARK: - Real-pandoc, mocked-BBT integration tests

// Not renamed despite the SwiftLint length warning: scripts/vmtest keys its persistent
// diagnosis-tracking records (streak counts, recorded diagnoses under its state directory)
// by the fully-qualified test identifier, which embeds this exact class name. Shortening it
// would silently orphan any existing tracked diagnoses for tests in this class.
//
/// Real-pandoc integration tests, matching ImageCaptionExportTests.swift's pandoc-lookup +
/// XCTSkip idiom, calling ExportService().export(...) directly (the same call the app makes).
/// Uses the export-diagnostic-capture seam (ExportService.isDiagnosticCaptureEnabled /
/// recentExportDiagnosticDirectories) to read back the EXACT temp file pandoc consumed --
/// the only sanctioned way to inspect it, since TempExportArtifacts.cleanup() deletes it via
/// `defer` before export() returns.
final class ExportCitekeyCanonicalizationIntegrationTests: XCTestCase { // swiftlint:disable:this type_name

    private static func findPandocPath() -> String? {
        let candidates = ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc", "/usr/bin/pandoc"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The DOCX/ODT path runs pandoc's `zotero.lua`, which does its OWN live BBT lookup from a
    /// separate process -- `MockBBTURLProtocol` (a URLProtocol inside this process) cannot
    /// intercept it, and `ZoteroChecker.check()` being mocked is exactly what lets the export
    /// past `requiresZoteroForExport`'s hard stop into a pandoc failure. Probe with an ephemeral
    /// session so a registered mock can never answer it.
    private static func isLiveZoteroBBTReachable() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:23119/better-bibtex/json-rpc")!)
        request.timeoutInterval = 2
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = []
        guard let (_, response) = try? await URLSession(configuration: config).data(for: request) else {
            return false
        }
        return response is HTTPURLResponse
    }

    /// Points `ExportService.userDefaults` at a fresh isolated `UserDefaults` suite for the
    /// duration of `body` -- same idiom as ExportDiagnosticCaptureGatingTests.swift.
    private func withIsolatedUserDefaults(_ body: (UserDefaults) async throws -> Void) async throws {
        let suiteName = "com.kerim.final-final.tests.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        let originalUserDefaults = ExportService.userDefaults
        ExportService.userDefaults = testDefaults
        defer {
            ExportService.userDefaults = originalUserDefaults
            testDefaults.removePersistentDomain(forName: suiteName)
        }
        try await body(testDefaults)
    }

    /// Runs `body` with diagnostic capture enabled and returns whatever new dump directory
    /// (if any) appeared while `body` ran, reading `input.md` from it -- the literal bytes
    /// pandoc consumed for this export.
    private func captureInputMD(_ body: () async throws -> Void) async throws -> String? {
        var result: String?
        try await withIsolatedUserDefaults { testDefaults in
            testDefaults.set(true, forKey: ExportService.diagnosticCaptureEnabledDefaultsKey)
            let before = Set(ExportService.recentExportDiagnosticDirectories(limit: 1000))
            try await body()
            let after = Set(ExportService.recentExportDiagnosticDirectories(limit: 1000))
            guard let dumpDir = after.subtracting(before).first else { return }
            result = try? String(contentsOf: dumpDir.appendingPathComponent("input.md"), encoding: .utf8)
        }
        return result
    }

    // MARK: - Write-back reaches the temp file pandoc reads; no new DOCX warnings

    func testCanonicalizedWriteBackReachesTempFileWithNoNewDOCXWarnings() async throws {
        guard Self.findPandocPath() != nil else {
            throw XCTSkip("Pandoc not installed — skipping citekey canonicalization write-back verification")
        }

        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()
            // swiftlint:disable line_length
            let json = """
            {"jsonrpc":"2.0","result":{"errors":{"Smith2020":0},"items":{"smith2020":{"id":"smith2020","type":"book","citation-key":"smith2020","title":"Canonical Copy"}}},"id":1}
            """
            // swiftlint:enable line_length
            MockBBTURLProtocol.responses["item.pandoc_filter"] = (200, Data(json.utf8))
            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer { URLProtocol.unregisterClass(MockBBTURLProtocol.self) }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("citekey-canon-writeback-\(UUID().uuidString).docx")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let service = ExportService()
            let content = "First cite [@Smith2020]. Second cite [@smith2020]."

            var capturedResult: ExportResult?
            let inputMD = try await captureInputMD {
                do {
                    capturedResult = try await service.export(
                        content: content,
                        to: tempURL,
                        format: .word,
                        settings: ExportSettings(),
                        projectURL: nil
                    )
                } catch ExportError.citationFilterFailed {
                    // Expected when there's no live Zotero + Better BibTeX listening on
                    // 127.0.0.1:23119 in this environment: pandoc's own zotero.lua filter runs
                    // as a SEPARATE process and does its own live BBT lookup that
                    // MockBBTURLProtocol (a URLProtocol registered only inside this test
                    // process) cannot intercept -- see isLiveZoteroBBTReachable's doc comment.
                    // The canonicalization assertion right below reads the diagnostic input.md
                    // pandoc was actually given, which dumpExportDiagnostics writes BEFORE
                    // pandoc ever runs, so it's unaffected by whether pandoc itself then
                    // succeeded.
                }
            }

            // Never depends on pandoc succeeding -- proves the rewrite itself reached the temp
            // file pandoc reads, independent of a live Zotero + BBT connection being available.
            let markdown = try XCTUnwrap(inputMD, "Diagnostic capture should have produced an input.md for this export")
            XCTAssertTrue(
                markdown.contains("[@smith2020]") && !markdown.contains("Smith2020"),
                "The temp file pandoc actually reads must contain the canonicalized spelling, not the original casing: \(markdown)"
            )

            // Everything below requires pandoc's zotero.lua filter to have actually SUCCEEDED --
            // its own live BBT lookup against 127.0.0.1:23119 from a separate process, which
            // MockBBTURLProtocol cannot fake. Skip only this tail when there's no live Zotero +
            // Better BibTeX to satisfy it; the canonicalization assertion above already ran
            // unconditionally.
            guard await Self.isLiveZoteroBBTReachable() else {
                throw XCTSkip(
                    "No live Zotero + Better BibTeX reachable on 127.0.0.1:23119 — skipping DOCX pandoc-warnings verification"
                )
            }

            let result = try XCTUnwrap(capturedResult, "A live Zotero + BBT connection should let export() fully succeed")
            XCTAssertTrue(
                result.warnings.isEmpty,
                "A fully-resolved citekey-case rewrite must not introduce any new DOCX warning: \(result.warnings)"
            )
        }
    }

    // Zotero-unreachable + real citekeys now hard-stops `export()` before pandoc ever runs
    // (see ExportService.requiresZoteroForExport) -- the old "degrade with a warning, skip
    // canonicalization" contract this file used to verify here no longer applies to DOCX/ODT.
    // That hard-stop is covered at the integration level by
    // ExportZoteroPreflightTests.exportThrowsBeforePandocInvocation and
    // .zoteroPreflightAgreesWithExport, which assert the same scenario -- a real `export()`
    // call, DOCX, real citekeys, Zotero unreachable -- throws `zoteroRequiredForCitations`.
}
