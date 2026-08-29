//
//  ExportService+PandocArguments.swift
//  final final
//

import Foundation

extension ExportService {

    /// Assembles the base Pandoc arguments shared by all formats: input/output paths,
    /// resource path, PDF engine + font + figure-placement arguments (PDF only), and the
    /// reference document (DOCX/ODT only). Citations and the diagnostic dump are layered on
    /// separately by `export()` since they need async work this function doesn't.
    ///
    /// Takes `pdfPrep`/`resourcePaths` (rather than their individual fields) to stay at or
    /// under the function-parameter-count limit — both are already constructed by the time
    /// `export()` calls this, and `pdfPrep.content` is always identical to `processedContent`
    /// at the call site (it was just assigned from it).
    ///
    /// Not `private`: BareCitationExportTests.swift calls this REAL function directly (via
    /// `@testable import`) to assert on its actual returned argument order for PDF, rather than
    /// hand-duplicating this argument list in a test file where it could silently drift out of
    /// sync with production. See `ResourcePaths.bareCitationsLuaPathOverride`'s doc comment for
    /// why the test needs to inject a path here instead of relying on `Bundle.main`.
    func buildBaseArguments(
        inputURL: URL,
        outputURL: URL,
        format: ExportFormat,
        pdfPrep: PDFContentPreparation,
        resourcePaths: ResourcePaths
    ) -> [String] {
        var arguments = [
            inputURL.path,
            "--from", "markdown",
            "--to", format.pandocFormat,
            "--output", outputURL.path
        ]

        // Resource path for image resolution (media/ paths relative to .ff package)
        if let url = pdfPrep.effectiveResourceURL {
            arguments.append(contentsOf: ["--resource-path", url.path])
        }

        // PDF: engine + font variables + figure placement pinning (fixes drift at page
        // breaks — see figure-placement.lua/float-package.tex). Both are optional: if the
        // bundled resources are somehow missing, PDF export still proceeds without the
        // placement fix rather than failing outright.
        if format == .pdf {
            arguments.append(contentsOf: pdfEngineArguments())
            arguments.append(contentsOf: fontArguments(for: pdfPrep.content))
            if let figurePlacementLuaPath = ExportService.bundledFigurePlacementLuaPath {
                arguments.append(contentsOf: ["--lua-filter", figurePlacementLuaPath])
            }
            // Bare `@key` is not a citation in this app (see bare-citations-literal.lua). Added
            // here rather than in citationArguments so it is guaranteed to precede --citeproc on
            // the command line -- pandoc applies filters in argument order, and a Cite node has to
            // be flattened before citeproc gets a chance to render it as a broken marker.
            if let bareCitationsLuaPath = resourcePaths.bareCitationsLuaPathOverride ?? ExportService.bundledBareCitationsLuaPath {
                arguments.append(contentsOf: ["--lua-filter", bareCitationsLuaPath])
            }
            // Escapes `&`/`#`/`%` inside math spans so they don't crash xelatex (or, for `%`,
            // silently truncate the rest of the line) -- see math-special-chars.lua's header
            // comment. Ordering relative to the other PDF-only filters IN THIS BLOCK is free:
            // this filter only touches Math AST nodes, which none of them read or write.
            //
            // Ordering relative to `--citeproc` (appended later, in citationArguments/
            // assembleFinalArguments) is a different question, and NOT free in general: citeproc
            // can itself generate fresh Math nodes out of a bibliography field's raw LaTeX (e.g.
            // a `.bib` entry's `title = {$x & y$}`), and this filter runs before `--citeproc` on
            // the command line, so any math citeproc generates is never seen by it -- confirmed
            // by direct reproduction: with a `.bib` bibliography and this exact filter order, an
            // unescaped `&` in a title's math survives uncaught and would crash xelatex; with the
            // filter moved to run AFTER `--citeproc` instead, it gets escaped correctly. That
            // reproduction is NOT reachable today only because this app's actual PDF bibliography
            // path is CSL JSON from Zotero, not `.bib` -- confirmed separately: pandoc's CSL-JSON
            // reader always treats a `$...$` title substring as literal text (escaping the `$`
            // itself), never as a math span, regardless of this filter's position. If that
            // bibliography source ever changes to something that can hand citeproc raw LaTeX
            // (e.g. a `.bib`/BibLaTeX path), this ordering would need revisiting too.
            if let mathSpecialCharsLuaPath = resourcePaths.mathSpecialCharsLuaPathOverride ?? ExportService.bundledMathSpecialCharsLuaPath {
                arguments.append(contentsOf: ["--lua-filter", mathSpecialCharsLuaPath])
            }
            if let floatPackagePath = ExportService.bundledFloatPackageTexPath {
                arguments.append(contentsOf: ["--include-in-header", floatPackagePath])
            }
            // Long citation/DOI URLs with no natural break points (no slashes/hyphens)
            // otherwise overflow the page margin -- see xurl-workaround.tex for why.
            if let xurlWorkaroundPath = ExportService.bundledXurlWorkaroundTexPath {
                arguments.append(contentsOf: ["--include-in-header", xurlWorkaroundPath])
            }
        }

        // Reference document (DOCX/ODT only)
        if let refPath = resourcePaths.referenceDocPath, format != .pdf {
            arguments.append(contentsOf: ["--reference-doc", refPath])
        }

        return arguments
    }

    /// Appends citation arguments to `baseArguments`, then -- for PDF exports only, when
    /// `linkifyUrlsLuaPath` is available -- appends the document-wide linkify-urls Lua filter
    /// AFTER them. Pandoc applies `--lua-filter`/`--citeproc` in command-line order, and
    /// `--citeproc` is what turns a citation's CSL field text into the bare-URL `Str` nodes the
    /// linkify filter looks for -- so this ordering is load-bearing, not cosmetic (an earlier
    /// draft of this fix appended the linkify filter from inside `buildBaseArguments`, which
    /// runs before `--citeproc` gets appended, and silently missed every citation-field URL).
    ///
    /// Not `private` and takes `linkifyUrlsLuaPath` as a parameter
    /// rather than reading `ExportService.bundledLinkifyUrlsLuaPath` internally, so
    /// `ExportArgumentOrderingTests` can call this exact function -- the one `export()` itself
    /// delegates to for final argument assembly -- with a hand-fed citation-argument list and a
    /// repo-relative filter path, without needing a live Zotero connection or `Bundle.main`
    /// (which in a unit-test host resolves to the XCTest runner's own bundle, not the app's --
    /// same reasoning as `ImageCaptionExportTests`'s `figurePlacementLuaPath`).
    func assembleFinalArguments(
        baseArguments: [String],
        citationArguments: [String],
        format: ExportFormat,
        linkifyUrlsLuaPath: String?
    ) -> [String] {
        var arguments = baseArguments
        arguments.append(contentsOf: citationArguments)
        if format == .pdf, let linkifyUrlsLuaPath {
            arguments.append(contentsOf: ["--lua-filter", linkifyUrlsLuaPath])
        }
        return arguments
    }

    /// Build PDF engine arguments (bundled TinyTeX → bundled xelatex → system xelatex)
    private func pdfEngineArguments() -> [String] {
        if let tinyTeX = try? prepareBundledTinyTeX() {
            return ["--pdf-engine", tinyTeX.xelatexPath,
                    "--pdf-engine-opt", tinyTeX.outputDriverArg]
        } else if let bundledPath = ExportService.bundledXelatexPath {
            return ["--pdf-engine", bundledPath]
        } else {
            return ["--pdf-engine", "xelatex"]
        }
    }

    /// Result of `citationArguments`: the Pandoc arguments to append, the temp bibliography
    /// file to clean up afterward (if one was written), and any warnings.
    struct CitationBuildResult {
        let arguments: [String]
        let tempBibURL: URL?
        let warnings: [String]
    }

    /// `settings` and `tempDir`, grouped: both are needed only by `citationArguments`'s PDF
    /// branch (passed straight through to `bibliographyWriteArguments`), always travel
    /// together, and DOCX/ODT never touches either. Bundling them keeps `citationArguments`
    /// under SwiftLint's `function_parameter_count` limit -- mirrors `ExportDiagnosticsRequest`
    /// in `ExportService+Diagnostics.swift`, the same parameter-object pattern already used
    /// elsewhere in this file's call graph.
    struct PDFBibliographyRequest {
        let settings: ExportSettings
        let tempDir: URL
    }

    /// Build citation-related Pandoc arguments from an already-fetched bibliography.
    ///
    /// Takes `luaScriptPath` as its own parameter (rather than recomputing it from
    /// `pdfBibliography.settings`) so the non-PDF branch below stays byte-for-byte identical
    /// to what it resolved and validated in `resolveAndValidateResourcePaths` — not a second,
    /// separately-computed `settings.effectiveLuaScriptPath` expression that merely happens to
    /// match today. `pdfBibliography` is still threaded through for the PDF-only
    /// `effectiveBibliographyHeaderName` metadata argument and the temp directory to write the
    /// bibliography JSON into; DOCX/ODT never reads it at all.
    ///
    /// `bibliography` is fetched exactly once, by `applyCitekeyCanonicalization` (called from
    /// `export()`, shared with the citekey-case rewrite, which needs the same fetch for every
    /// format, not just PDF) and passed in here — this function no longer fetches on its own.
    /// `nil` means the fetch was skipped entirely (no citations, Zotero not running, or no real
    /// citekeys extracted — see `applyCitekeyCanonicalization`'s three-part guard, in
    /// `ExportService+Citations.swift`), in which case PDF appends nothing, exactly as before
    /// this function stopped fetching internally.
    ///
    /// `groupLibraryNames` -- DOCX/ODT only (PDF resolves citations itself via `--citeproc`,
    /// never touches `zotero.lua`) -- is the user's group/shared library display names, passed
    /// through as `--metadata zotero-group-libraries=<JSON array>` for `zotero.lua`'s own
    /// phase-2 Better BibTeX lookup (see that file's LOCAL PATCH block): a citekey living only
    /// in a group/shared library, not the personal one, otherwise fails `zotero.lua`'s
    /// unscoped BBT call and exports as plain text instead of a live field code. Nested inside
    /// the `luaScriptPath` binding below so it's never appended when there's no lua filter at
    /// all, and skipped entirely when `groupLibraryNames` is empty -- an empty array is
    /// "nothing to add," not "clear whatever zotero.lua would otherwise use."
    func citationArguments(
        format: ExportFormat,
        luaScriptPath: String?,
        pdfBibliography: PDFBibliographyRequest,
        bibliography: BibliographyFetchResult?,
        groupLibraryNames: [String]
    ) -> CitationBuildResult {
        var args: [String] = []
        var tempBibURL: URL?
        var warnings: [String] = []

        if format == .pdf {
            if let bibliography {
                if let bibJSON = bibliography.json {
                    // See bibliographyWriteArguments's doc comment: the write-failure and
                    // partial-bibliography warnings are mutually exclusive by construction.
                    let result = bibliographyWriteArguments(
                        bibJSON: bibJSON,
                        notFoundKeys: bibliography.notFoundKeys,
                        ambiguousKeys: bibliography.ambiguousKeys,
                        settings: pdfBibliography.settings,
                        tempDir: pdfBibliography.tempDir
                    )
                    args.append(contentsOf: result.arguments)
                    tempBibURL = result.tempBibURL
                    warnings.append(contentsOf: result.warnings)
                } else {
                    // See fetchFailureWarning's doc comment: mutually exclusive with the
                    // partial-bibliography warning above rather than always pairing with it.
                    warnings.append(fetchFailureWarning(
                        notFound: bibliography.notFoundKeys, ambiguous: bibliography.ambiguousKeys
                    ))
                }
            }
        } else {
            if let luaPath = luaScriptPath {
                args.append(contentsOf: ["--lua-filter", luaPath])

                if !groupLibraryNames.isEmpty,
                   let data = try? JSONSerialization.data(withJSONObject: groupLibraryNames),
                   let jsonString = String(data: data, encoding: .utf8) {
                    args.append(contentsOf: ["--metadata", "zotero-group-libraries=\(jsonString)"])
                }
            }
        }

        return CitationBuildResult(arguments: args, tempBibURL: tempBibURL, warnings: warnings)
    }
}
