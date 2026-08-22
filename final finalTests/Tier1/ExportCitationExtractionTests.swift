//
//  ExportCitationExtractionTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Coverage for `extractCitekeys`/`hasPandocCitations`'s bracket-span-scoped extraction: a
//  bare (unbracketed) `@citekey` is deliberately NEVER a citation in any export format -- it
//  is flattened to literal text on the PDF path by bare-citations-literal.lua (see the real-
//  pandoc integration test at the bottom of this file), and has always been literal on the
//  DOCX/ODT path (zotero.lua leaves AuthorInText Cite nodes alone). What DOES need to keep
//  resolving is every genuinely bracket-wrapped form: `[@key]`, `[@key, p. 21]`,
//  `[@key{p. 21}]` (no-space brace locator), `[see @key]` (prose before the `@`), and
//  `[-@key]` (suppress-author) -- `extractCitekeys` finds each closed `[...]` span first, then
//  pulls every `@citekey` inside it, so prose or a leading `-` before the `@` no longer defeats
//  extraction the way the old single-pass regex did.
//
//  Also covers `fetchBibliographyJSON`'s partial-success contract (a batch with some
//  unresolved citekeys still returns a bibliography for the ones that DID resolve, instead of
//  the old all-or-nothing throw) and `partialBibliographyWarning`'s message shape.
//

import Testing
import Foundation
@testable import final_final

@Suite("Export citation extraction — Tier 1: Silent Killers")
struct ExportCitationExtractionTests {

    // MARK: - Bracket form (regression: existing extractCitekeys/hasPandocCitations unchanged)

    @Test("Bracket-form citation: hasPandocCitations/extractCitekeys behave exactly as before")
    func bracketFormRegressionUnchanged() async {
        let service = ExportService()
        let content = "See [@smith2020] for details."

        #expect(await service.hasPandocCitations(in: content))
        #expect(await service.extractCitekeys(from: content) == ["smith2020"])
    }

    // MARK: - Indented list shapes must NOT be treated as code (regression: MarkdownUtils.
    // stripCodeContent -- which this function, DOCX/ODT, and BibliographySyncService.
    // extractCitekeys all depend on -- must never strip an indented-but-not-code paragraph.
    // CommonMark loose lists are DEFINED by a blank line between items/continuation
    // paragraphs, so a 4-space-indented paragraph preceded by a blank line is a completely
    // ordinary, common academic-writing shape, not code.

    @Test("A citation inside a loose (blank-line-separated) nested bulleted list is still extracted, not stripped as code")
    func citationInsideLooseNestedListIsStillExtracted() async {
        let service = ExportService()
        let content = "- Parent\n\n    - Nested cites [@jones1999]"

        #expect(await service.hasPandocCitations(in: content))
        #expect(await service.extractCitekeys(from: content) == ["jones1999"])
    }

    @Test("A citation inside a list-item continuation paragraph is still extracted, not stripped as code")
    func citationInsideListContinuationParagraphIsStillExtracted() async {
        let service = ExportService()
        let content = "- First point\n\n    More discussion here [@smith2020]."

        #expect(await service.hasPandocCitations(in: content))
        #expect(await service.extractCitekeys(from: content) == ["smith2020"])
    }

    // MARK: - Bare `@key` is never a citation

    @Test("A bare @key in running text is not a citation -- hasPandocCitations/extractCitekeys both ignore it")
    func bareAtKeyIsNotACitation() async {
        let service = ExportService()
        let content = "As @jones2019 argues, bare @keys are literal."

        #expect(!(await service.hasPandocCitations(in: content)))
        #expect(await service.extractCitekeys(from: content).isEmpty)
    }

    // MARK: - Prose-inside-brackets and suppress-author forms (now caught by the plain extractor)

    @Test("[see @key]: prose before the @ inside brackets is extracted")
    func proseBeforeAtInsideBracketsIsExtracted() async {
        let service = ExportService()
        let content = "Background [see @seekey2021] is relevant."

        #expect(await service.hasPandocCitations(in: content))
        #expect(await service.extractCitekeys(from: content) == ["seekey2021"])
    }

    @Test("[-@key] (suppress-author form) is extracted")
    func suppressAuthorFormIsExtracted() async {
        let service = ExportService()
        let content = "Prior work [-@suppresskey2022] established this."

        #expect(await service.hasPandocCitations(in: content))
        #expect(await service.extractCitekeys(from: content) == ["suppresskey2022"])
    }

    // MARK: - Locator forms

    @Test("Comma locator extracts only the key")
    func commaLocatorExtractsOnlyTheKey() async {
        let service = ExportService()
        let content = "See [@smith2020, p. 21] for details."

        #expect(await service.extractCitekeys(from: content) == ["smith2020"])
    }

    @Test("Brace locator (with and without a preceding space) extracts only the key")
    func braceLocatorExtractsOnlyTheKey() async {
        let service = ExportService()

        #expect(await service.extractCitekeys(from: "See [@smith2020 {p. 21}] for details.") == ["smith2020"])
        #expect(
            await service.extractCitekeys(from: "See [@smith2020{p. 21}] for details.") == ["smith2020"],
            "The no-space brace-locator form is valid pandoc syntax and must not swallow the brace into the key"
        )
    }

    @Test("Multiple keys in one bracket span are all extracted")
    func multipleKeysInOneBracketSpanAreAllExtracted() async {
        let service = ExportService()
        let content = "[@a1999; @b2000]"

        #expect(await service.extractCitekeys(from: content) == ["a1999", "b2000"])
    }

    // MARK: - Non-citation `@` tokens inside brackets must not be mistaken for citekeys

    @Test("An email address inside brackets is not a citekey")
    func emailInsideBracketsIsNotACitekey() async {
        let service = ExportService()
        let content = "[contact me@example.com]"

        #expect(await service.extractCitekeys(from: content).isEmpty)
    }

    @Test("A URL handle segment and an npm scoped package inside brackets are not citekeys")
    func urlHandleAndScopedPackageInsideBracketsAreNotCitekeys() async {
        let service = ExportService()

        #expect(await service.extractCitekeys(from: "[see bsky.app/@handle]").isEmpty)
        #expect(await service.extractCitekeys(from: "[install @scope/pkg]").isEmpty)
    }

    // MARK: - Known, accepted trade-off: an unclosed `[` can pull in a later bare token

    @Test("An unclosed bracket can pull in a later bare @token -- known, accepted trade-off, not a bug")
    func unclosedBracketCanPullInALaterBareToken() async {
        let service = ExportService()
        // See extractCitekeys's doc comment: excluding nested `[` entirely would break the
        // legitimate `[see @a [sic]]` shape, so an unmatched `[` is left free to greedily
        // extend its span to the NEXT `]` in the document -- here, past "para one" and
        // "para two" entirely, swallowing the bare `@MainActor` token along the way. This is
        // the documented, deliberately-not-fixed trade-off: a spurious "not found" warning is
        // judged less bad than breaking a real nested-bracket citation.
        let content = "para one [ oops\n\npara two @MainActor talk\n\npara three [@key] end"

        let keys = await service.extractCitekeys(from: content)
        #expect(keys.contains("MainActor"), "Documents the accepted trade-off -- not a desired behavior")
        #expect(keys.contains("key"))
    }

    // MARK: - fetchBibliographyJSON: partial success (never drops the whole bibliography)

    @Test("fetchBibliographyJSON: a handle-only batch (no real Zotero item) returns nil json and names the handle as not-found")
    @MainActor
    func fetchBibliographyJSONHandleOnlyReturnsNilJSONWithNotFoundKey() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()
            let previousCache = ZoteroService.shared.cachedLibraries
            ZoteroService.shared.cachedLibraries = [ZoteroLibrary(id: ZoteroService.personalLibraryID, name: "My Library")]
            defer { ZoteroService.shared.cachedLibraries = previousCache }

            let notFoundJSON = #"{"jsonrpc":"2.0","result":{"errors":{"kerim":0},"items":{}},"id":1}"#
            MockBBTURLProtocol.responses["item.pandoc_filter"] = (200, Data(notFoundJSON.utf8))

            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer { URLProtocol.unregisterClass(MockBBTURLProtocol.self) }

            let service = ExportService()
            let result = await service.fetchBibliographyJSON(for: ["kerim"])

            #expect(result.json == nil)
            #expect(result.notFoundKeys == ["kerim"])
            #expect(result.ambiguousKeys.isEmpty)
        }
    }

    @Test("fetchBibliographyJSON: a mixed real+handle batch resolves the real item and names only the handle as not-found")
    @MainActor
    func fetchBibliographyJSONMixedBatchReturnsPartialJSON() async throws {
        try await ZoteroNetworkTestLock.shared.run {
            MockBBTURLProtocol.reset()
            let previousCache = ZoteroService.shared.cachedLibraries
            ZoteroService.shared.cachedLibraries = [ZoteroLibrary(id: ZoteroService.personalLibraryID, name: "My Library")]
            defer { ZoteroService.shared.cachedLibraries = previousCache }

            // swiftlint:disable line_length
            let mixedJSON = """
            {"jsonrpc":"2.0","result":{"errors":{"kerim":0},"items":{"friedman2010":{"id":"friedman2010","type":"chapter","citation-key":"friedman2010","title":"Entering the Mountains"}}},"id":2}
            """
            // swiftlint:enable line_length
            MockBBTURLProtocol.responses["item.pandoc_filter"] = (200, Data(mixedJSON.utf8))

            URLProtocol.registerClass(MockBBTURLProtocol.self)
            defer { URLProtocol.unregisterClass(MockBBTURLProtocol.self) }

            let service = ExportService()
            let result = await service.fetchBibliographyJSON(for: ["friedman2010", "kerim"])

            let json = try #require(result.json, "A partial batch must still return the resolved item's JSON, not nil")
            #expect(json.contains("Entering the Mountains"), "The resolved item's data must be present")
            #expect(!json.contains("\"kerim\""), "The unresolved handle must not appear as a fabricated bibliography entry")
            #expect(result.notFoundKeys == ["kerim"])
            #expect(result.ambiguousKeys.isEmpty)
        }
    }

    // MARK: - partialBibliographyWarning

    @Test("partialBibliographyWarning names the skipped key and is a distinct message from the total-fetch-failure warning")
    func partialBibliographyWarningNamesKeyAndIsDistinctMessage() async {
        let service = ExportService()
        let warning = await service.partialBibliographyWarning(notFound: ["kerim"], ambiguous: [])

        #expect(warning.contains("kerim"))
        #expect(
            !warning.contains("Could not fetch bibliography data"),
            "Must read as its own distinct message, not the generic total-fetch-failure warning"
        )
    }

    @Test("partialBibliographyWarning names both not-found and ambiguous keys when both are present")
    func partialBibliographyWarningNamesBothCategories() async {
        let service = ExportService()
        let warning = await service.partialBibliographyWarning(notFound: ["missingkey"], ambiguous: ["dupkey"])

        #expect(warning.contains("missingkey"))
        #expect(warning.contains("dupkey"))
    }

    // MARK: - fetchFailureWarning: mutual exclusivity with the generic connection-failure message

    @Test("fetchFailureWarning uses only the specific partial-bibliography wording when a not-found key is known")
    func fetchFailureWarningIsSpecificWhenNotFoundKeysArePresent() async {
        let service = ExportService()
        let warning = await service.fetchFailureWarning(notFound: ["kerim"], ambiguous: [])

        #expect(warning.contains("kerim"))
        #expect(
            !warning.contains("Could not fetch bibliography data"),
            """
            Must not pair the generic Zotero-fetch-failure message with a specific not-found key -- \
            there's no bibliography to have omitted a key from if fetching itself supposedly failed
            """
        )
    }

    @Test("fetchFailureWarning uses only the specific partial-bibliography wording when an ambiguous key is known")
    func fetchFailureWarningIsSpecificWhenAmbiguousKeysArePresent() async {
        let service = ExportService()
        let warning = await service.fetchFailureWarning(notFound: [], ambiguous: ["dupkey"])

        #expect(warning.contains("dupkey"))
        #expect(!warning.contains("Could not fetch bibliography data"))
    }

    @Test("fetchFailureWarning falls back to the generic connection-failure wording only with no key information at all")
    func fetchFailureWarningIsGenericWithNoKeyInformation() async {
        let service = ExportService()
        let warning = await service.fetchFailureWarning(notFound: [], ambiguous: [])

        #expect(warning.contains("Could not fetch bibliography data"))
    }

    // MARK: - bibliographyWriteArguments: write-failure vs. partial-bibliography warning exclusivity
    //
    // Regression coverage for a must-fix: the write-failure path (bibJSON.write(to:) throws)
    // used to ALSO emit the partial-bibliography "...were omitted from the bibliography"
    // warning whenever notFoundKeys/ambiguousKeys were non-empty, because that check lived
    // outside the do/catch. That's self-contradictory -- nothing was "omitted from a
    // bibliography" that was never written and never passed to pandoc. The two warnings must
    // be mutually exclusive, the same way fetchFailureWarning's are (tested above).

    @Test("bibliographyWriteArguments emits only the write-failure warning when the write itself fails, even with a not-found key present")
    func bibliographyWriteArgumentsWriteFailureWarningIsExclusive() async {
        let service = ExportService()
        // A directory that cannot exist (nested under a nonexistent parent) forces
        // `bibJSON.write(to:)` to throw, exercising the catch branch deterministically.
        let unwritableDir = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/nested")

        let result = await service.bibliographyWriteArguments(
            bibJSON: "[]",
            notFoundKeys: ["kerim"],
            ambiguousKeys: [],
            settings: ExportSettings(),
            tempDir: unwritableDir
        )

        #expect(result.warnings.count == 1, "Only the write-failure warning should appear, never both")
        #expect(result.warnings.first?.contains("Could not write bibliography data") == true)
        #expect(
            !result.warnings.contains { $0.contains("omitted from the bibliography") },
            "Nothing was omitted from a bibliography that was never written"
        )
        #expect(result.tempBibURL == nil, "No bib file was actually written")
        #expect(result.arguments.isEmpty, "No --citeproc/--bibliography/--csl args when the write failed")
    }

    @Test("bibliographyWriteArguments emits only the partial-bibliography warning when the write succeeds but some keys are unresolved")
    func bibliographyWriteArgumentsPartialWarningOnSuccessfulWrite() async {
        let service = ExportService()
        let tempDir = FileManager.default.temporaryDirectory

        let result = await service.bibliographyWriteArguments(
            bibJSON: "[]",
            notFoundKeys: ["kerim"],
            ambiguousKeys: [],
            settings: ExportSettings(),
            tempDir: tempDir
        )
        defer { if let url = result.tempBibURL { try? FileManager.default.removeItem(at: url) } }

        #expect(result.warnings.count == 1)
        #expect(result.warnings.first?.contains("kerim") == true)
        #expect(
            !result.warnings.contains { $0.contains("Could not write bibliography data") },
            "A successful write must not also claim the write failed"
        )
        #expect(result.tempBibURL != nil, "The bibliography file was actually written")
        #expect(result.arguments.contains("--citeproc"))
    }

    @Test("bibliographyWriteArguments emits no warning at all when the write succeeds and every key resolved")
    func bibliographyWriteArgumentsNoWarningWhenFullyResolved() async {
        let service = ExportService()
        let tempDir = FileManager.default.temporaryDirectory

        let result = await service.bibliographyWriteArguments(
            bibJSON: "[]",
            notFoundKeys: [],
            ambiguousKeys: [],
            settings: ExportSettings(),
            tempDir: tempDir
        )
        defer { if let url = result.tempBibURL { try? FileManager.default.removeItem(at: url) } }

        #expect(result.warnings.isEmpty)
        #expect(result.tempBibURL != nil)
    }
}
