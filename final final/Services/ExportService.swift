//
//  ExportService.swift
//  final final
//
//  Core export service for converting markdown to Word/PDF/ODT via Pandoc.
//  Uses async/await with Process for non-blocking execution.
//

import Foundation

/// Errors that can occur during export
enum ExportError: Error, LocalizedError {
    case pandocNotFound
    case pandocFailed(exitCode: Int, message: String)
    case luaScriptNotFound(String)
    case referenceDocNotFound(String)
    case tempFileCreationFailed
    case invalidOutputPath
    case noContent
    case zoteroRequiredForCitations(format: ExportFormat, zoteroStatus: ZoteroStatus)
    case citationFilterFailed(format: ExportFormat)

    var errorDescription: String? {
        switch self {
        case .pandocNotFound:
            return "Pandoc is not installed. Please install Pandoc to export documents."
        case .pandocFailed(let code, let message):
            return "Pandoc failed with exit code \(code): \(message)"
        case .luaScriptNotFound(let path):
            return "Lua filter script not found: \(path)"
        case .referenceDocNotFound(let path):
            return "Reference document not found: \(path)"
        case .tempFileCreationFailed:
            return "Failed to create temporary file for export"
        case .invalidOutputPath:
            return "Invalid output file path"
        case .noContent:
            return "No content to export"
        case .zoteroRequiredForCitations(let format, let zoteroStatus):
            // Per-status reason (e.g. "Zotero is not running" vs. "Better BibTeX is not
            // installed"), not a single generic message -- see zoteroPreflightReason's doc
            // comment. This is a defense-in-depth backstop: ExportViewModel intercepts this
            // specific case before it reaches any generic error alert, so in practice the
            // user sees the ViewModel's own (identically-sourced) wording instead.
            let reason = ExportService.zoteroPreflightReason(for: zoteroStatus)
            return "This document has citations, and \(format.displayName) export needs Zotero " +
                "to resolve them. \(reason) Resolve this, then try exporting again."
        case .citationFilterFailed(let format):
            return "The citation processor failed while exporting to \(format.displayName). " +
                "Try again, and if this keeps happening, make sure Zotero and Better BibTeX are " +
                "working correctly."
        }
    }
}

/// Result of an export operation
struct ExportResult: Sendable {
    let outputURL: URL
    let format: ExportFormat
    let zoteroStatus: ZoteroStatus
    let warnings: [String]
}

/// Actor for performing exports (I/O work, off main thread)
actor ExportService {

    private let pandocLocator: PandocLocator
    private let zoteroChecker: ZoteroChecker

    init() {
        self.pandocLocator = PandocLocator()
        self.zoteroChecker = ZoteroChecker()
    }
}

// Everything below is in its own `extension` (rather than the primary actor declaration
// above) purely to keep `type_body_length` under its limit — SwiftLint counts an
// extension's body separately from the type's own declaration. Matches the "MARK/extension
// seam" convention the rest of this file's sibling ExportService+*.swift files already use;
// this just applies it one level further in, within the core file itself. No behavior
// change: methods and nested types are identical whether declared in the primary actor body
// or an extension of it.
extension ExportService {

    // MARK: - Configuration

    /// Configure Pandoc path from settings
    func configure(with settings: ExportSettings) async {
        await pandocLocator.setCustomPath(settings.customPandocPath)
    }

    // MARK: - Status Checks

    /// Check Pandoc status
    func checkPandoc() async -> PandocStatus {
        await pandocLocator.locate()
    }

    /// Refresh Pandoc status (clear cache and re-check)
    func refreshPandocStatus() async -> PandocStatus {
        await pandocLocator.clearCache()
        return await pandocLocator.locate()
    }

    // MARK: - Export Preprocessing

    /// Preprocess raw markdown content before handing it to Pandoc: strips annotation HTML
    /// comments (only when the user has opted out via `ExportSettings.includeAnnotations`)
    /// and always strips `==highlight==` markers. Highlight *rendering* isn't implemented
    /// for exported documents, so a raw `==` marker surviving into PDF/DOCX/ODT output is
    /// meaningless literal punctuation, not preserved formatting — that strip runs
    /// unconditionally, regardless of `includeAnnotations` (a different concept: authoring
    /// comments, not text formatting). See `MarkdownUtils.stripHighlightMarkers` for the
    /// full rationale and known gaps.
    ///
    /// Factored out of `export()` (its only call site) so a test can exercise this exact
    /// preprocessing step directly — proving the strip actually fires from the real
    /// pipeline — instead of re-declaring the same regex in isolation.
    func preprocessContentForExport(_ content: String, settings: ExportSettings) -> String {
        var result = content
        if !settings.includeAnnotations {
            result = stripAnnotations(from: result)
        }
        return MarkdownUtils.stripHighlightMarkers(from: result)
    }

    // MARK: - Export Preflight

    /// True when an export must hard-stop rather than proceed: a non-PDF (DOCX/ODT) export
    /// whose content has citations, where a Zotero lua filter is configured
    /// (`luaScriptPath != nil`), but Zotero is not reachable (`zoteroStatus != .running`).
    ///
    /// PDF is excluded unconditionally -- PDF resolves citations via `--citeproc` and a
    /// fetched bibliography JSON, not the lua filter, and already degrades gracefully (see
    /// `citationArguments`'s PDF branch and its warnings) rather than crashing. DOCX/ODT feed
    /// the lua filter a live JSON-RPC call to Better BibTeX with no fallback; when Zotero is
    /// unreachable that filter either emits broken citations or -- observed in the field --
    /// pandoc exits 83. A hard stop with a clear prompt replaces that crash/silent-degrade.
    ///
    /// Pure and side-effect-free by design so it can be exercised directly by tests (see
    /// `ExportZoteroPreflightTests.swift`) across every format x hasCitations x luaScriptPath x
    /// zoteroStatus combination without needing a live Zotero connection or a real export run.
    /// Not actor-isolated (a `static func`, not an instance method) so `ExportViewModel` can
    /// call it synchronously from `@MainActor` to decide whether to show the hard-stop alert
    /// before an export is even attempted, using the same logic `export()` itself enforces.
    static func requiresZoteroForExport(
        format: ExportFormat,
        hasCitations: Bool,
        luaScriptPath: String?,
        zoteroStatus: ZoteroStatus
    ) -> Bool {
        format != .pdf && hasCitations && luaScriptPath != nil && zoteroStatus != .running
    }

    /// Maps a pandoc failure to a friendly "citation filter failed" error when it's plausibly
    /// caused by the Zotero lua filter, rather than surfacing the raw
    /// `"Pandoc failed with exit code 83: <lua traceback>"` message. Returns nil (leave the
    /// original error alone) for every other case.
    ///
    /// This covers a gap `requiresZoteroForExport` cannot: Zotero can be reachable at the
    /// moment the pre-flight probe runs, then fail specifically while zotero.lua processes
    /// THIS document's citations (a Better BibTeX RPC error mid-export, a malformed citekey,
    /// etc.) -- pandoc surfaces a Lua runtime error as exit code 83. Deliberately does NOT
    /// word this as "Zotero is not running" (the probe just confirmed it was) -- see
    /// `ExportError.citationFilterFailed`'s message.
    ///
    /// `luaScriptPath != nil` (not `hasCitations`) is the condition, matching exactly how the
    /// review described this gap ("a non-PDF export with a lua filter configured") and keeping
    /// this pure and testable without needing to re-derive whether the filter was actually
    /// attached to this particular pandoc invocation.
    static func citationFilterErrorIfApplicable(
        exitCode: Int,
        format: ExportFormat,
        luaScriptPath: String?
    ) -> ExportError? {
        guard exitCode == 83, format != .pdf, luaScriptPath != nil else { return nil }
        return .citationFilterFailed(format: format)
    }

    /// Result of `zoteroPreflight`: the Zotero status this preflight determined -- a real
    /// check if the document has citations, `.running` (no check needed) if it doesn't --
    /// plus whether that status means the export would currently hit the Zotero-required hard
    /// stop, plus whether the document has real citations at all.
    ///
    /// `zoteroStatus` is returned on every outcome, not just the blocked one, so a caller that
    /// goes on to call `export()` can forward it via `export()`'s `precomputedZoteroStatus`
    /// parameter regardless of whether this preflight blocked the export -- eliminating the
    /// second, redundant Zotero network round-trip that would otherwise happen on the common
    /// path (Zotero reachable, document has citations): before `precomputedZoteroStatus`
    /// existed, `zoteroPreflight` checked Zotero once to decide whether to show the save panel,
    /// and then `export()` checked it again from scratch right after the user picked a save
    /// location.
    ///
    /// `hasCitations` is the STRICT citekey check (same as `isBlocked`'s inputs, not the loose
    /// `hasPandocCitations` regex) -- it's what lets `ExportViewModel.savePanelDecision` decide
    /// whether a PDF export should show the degraded-citations warning at all: a document whose
    /// only bracketed text is a false-positive shape (e.g. an email address) must never trigger
    /// that warning, exactly as it must never trigger the DOCX/ODT hard stop.
    struct ZoteroPreflightResult: Sendable {
        let zoteroStatus: ZoteroStatus
        let isBlocked: Bool
        let hasCitations: Bool
    }

    /// Ask whether calling `export()` with this content/format/settings would currently hit
    /// the Zotero-required hard stop (`requiresZoteroForExport`) -- WITHOUT running Pandoc,
    /// writing any temp files, or requiring a destination URL at all. Exists so
    /// `ExportViewModel` can decide whether to show a Zotero alert *before* ever presenting the
    /// save panel, for every export format including PDF: previously the save panel appeared,
    /// the user picked a filename and clicked Save, and only THEN did `export()` throw (or, for
    /// PDF, only then did a separate post-panel probe run) -- wasting the user's time on a save
    /// location that might never get used. See `ExportViewModel.savePanelDecision`'s doc
    /// comment for the full history.
    ///
    /// Reuses the exact same preprocessing (`preprocessContentForExport`), citation detection
    /// (`hasPandocCitations`/`extractCitekeys`), resource-path resolution
    /// (`resolveAndValidateResourcePaths`), and `requiresZoteroForExport` gate that `export()`
    /// itself uses below -- the same single source of truth `requiresZoteroForExport`'s
    /// original extraction established -- so this preflight can never disagree with what
    /// `export()` will actually do for the same inputs. `isBlocked` is always `false` for PDF
    /// (`requiresZoteroForExport` excludes it unconditionally), so PDF can only ever reach
    /// `ExportViewModel`'s `.warnDegraded` outcome, never `.blockedByZotero`.
    ///
    /// The narrow race where Zotero disappears between this preflight call and the real export
    /// is NOT covered by a second check inside `export()` for DOCX/ODT -- when a caller
    /// forwards this preflight's result via `export()`'s `precomputedZoteroStatus` (as
    /// `ExportViewModel` does for the DOCX/ODT path), `export()` uses that value verbatim
    /// instead of re-checking, by design, to avoid a redundant network round-trip. That race is
    /// instead covered by an already-existing, different mechanism further down this file:
    /// `citationFilterErrorIfApplicable` maps the pandoc exit-83 failure that a now-unreachable
    /// Zotero's lua filter would actually produce into the friendly `citationFilterFailed`
    /// error, so the export still fails with a clear message rather than a raw pandoc
    /// traceback -- it just isn't caught this early anymore. PDF, by contrast, deliberately does
    /// NOT forward this preflight's status into `export()` -- see
    /// `ExportViewModel.showExportPanel`'s doc comment -- so a user who starts Zotero and clicks
    /// "Continue Export" after seeing the warning gets export()'s own fresh check, not this
    /// stale pre-panel one.
    ///
    /// Propagates `luaScriptNotFound`/`referenceDocNotFound` exactly as
    /// `resolveAndValidateResourcePaths` would if a configured resource path is missing on
    /// disk -- these are a *different* doomed-export condition than the Zotero one, so a caller
    /// should surface them the same way (before ever showing the save panel), not fold them
    /// into "not blocked by Zotero, proceed". In practice this can only fire for DOCX/ODT: PDF's
    /// reference-doc path is hardcoded `nil` and its lua-script validation is guarded to
    /// non-PDF formats, so `resolveAndValidateResourcePaths` never throws for PDF.
    func zoteroPreflight(
        content: String,
        format: ExportFormat,
        settings: ExportSettings
    ) async throws -> ZoteroPreflightResult {
        let processedContent = preprocessContentForExport(content, settings: settings)
        let hasCitations = hasPandocCitations(in: processedContent)
        let zoteroStatus: ZoteroStatus = hasCitations
            ? await zoteroChecker.check()
            : .running
        let resourcePaths = try resolveAndValidateResourcePaths(format: format, settings: settings)
        let hasRealCitations = !extractCitekeys(from: processedContent).isEmpty

        let isBlocked = Self.requiresZoteroForExport(
            format: format,
            hasCitations: hasRealCitations,
            luaScriptPath: resourcePaths.luaScriptPath,
            zoteroStatus: zoteroStatus
        )
        return ZoteroPreflightResult(zoteroStatus: zoteroStatus, isBlocked: isBlocked, hasCitations: hasRealCitations)
    }

    // MARK: - Export

    /// Export markdown content to the specified format
    /// - Parameters:
    ///   - content: Markdown content to export
    ///   - outputURL: Destination file URL
    ///   - format: Export format (docx, pdf, odt)
    ///   - settings: Export settings
    ///   - precomputedZoteroStatus: When non-nil, used as-is instead of checking Zotero again
    ///     here. Lets a caller that already ran `zoteroPreflight` (as `ExportViewModel` does
    ///     for DOCX/ODT) forward the status it already obtained, instead of this function
    ///     repeating the same network round-trip a second time right after the save panel
    ///     closes. `nil` (the default) preserves the original behavior -- check now -- so every
    ///     other caller of `export()` is unaffected.
    /// - Returns: ExportResult with details
    func export(
        content: String,
        to outputURL: URL,
        format: ExportFormat,
        settings: ExportSettings,
        projectURL: URL? = nil,
        precomputedZoteroStatus: ZoteroStatus? = nil
    ) async throws -> ExportResult {

        // Validate content
        guard !content.isEmpty else {
            throw ExportError.noContent
        }

        // Strip annotations (if not including them) and highlight markers before handing
        // content to Pandoc. Factored into one function so it can be exercised directly by
        // tests (see ExportIntegrityTests.swift) as well as by this real call site.
        var processedContent = preprocessContentForExport(content, settings: settings)

        // Check Pandoc availability
        guard let pandocPath = await pandocLocator.getPath() else {
            throw ExportError.pandocNotFound
        }

        // Only check Zotero if content appears to have citations -- unless the caller already
        // did (see `precomputedZoteroStatus`'s doc comment above).
        let hasCitations = hasPandocCitations(in: processedContent)
        // Zotero status only matters for citation processing
        // When no citations, .running means "no issue" (status is irrelevant)
        let zoteroStatus: ZoteroStatus
        if let precomputedZoteroStatus {
            zoteroStatus = precomputedZoteroStatus
        } else {
            zoteroStatus = hasCitations ? await zoteroChecker.check() : .running
        }

        // Get and validate resource paths (lua filter, reference doc)
        let resourcePaths = try resolveAndValidateResourcePaths(format: format, settings: settings)

        // Hard stop -- before any temp file or pandoc invocation -- rather than let a
        // DOCX/ODT export run its lua filter against an unreachable Zotero (pandoc exit 83)
        // or silently emit unresolved citations. See requiresZoteroForExport's doc comment.
        //
        // Uses the strict citekey extractor here, NOT the loose `hasCitations` above:
        // `hasPandocCitations`'s regex also matches non-citation shapes like
        // `[contact me@example.com]` or `[install @scope/pkg]` (see extractCitekeys's doc
        // comment), and a document with zero real citekeys must never be hard-blocked just
        // because it happens to contain one of those shapes.
        let hasRealCitations = !extractCitekeys(from: processedContent).isEmpty
        guard !Self.requiresZoteroForExport(
            format: format,
            hasCitations: hasRealCitations,
            luaScriptPath: resourcePaths.luaScriptPath,
            zoteroStatus: zoteroStatus
        ) else {
            throw ExportError.zoteroRequiredForCitations(format: format, zoteroStatus: zoteroStatus)
        }

        // Create temp files
        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent(UUID().uuidString + ".md")

        do {
            try processedContent.write(to: inputURL, atomically: true, encoding: .utf8)
        } catch {
            throw ExportError.tempFileCreationFailed
        }

        // Cleanup fires on every exit path — including thrown errors — because the defer is
        // placed immediately after the artifacts are created, not deferred to function end.
        var artifacts = TempExportArtifacts(inputURL: inputURL)
        defer { artifacts.cleanup() }

        // Collect warnings
        var warnings: [String] = []

        // For PDF export, convert unsupported images (WebP, HEIC, etc.) to PNG
        var pdfPrep = try prepareContentForPDFIfNeeded(
            format: format,
            content: processedContent,
            projectURL: projectURL,
            inputURL: inputURL
        )
        processedContent = pdfPrep.content
        artifacts.tempMediaDir = pdfPrep.tempMediaDir
        warnings.append(contentsOf: pdfPrep.warnings)

        // Citekey case canonicalization: rewrite any citekey spelling that differs only in
        // case from the citekey Zotero/BBT actually resolved, so PDF's `--citeproc` (which
        // matches CSL-JSON case-sensitively) and DOCX/ODT's `zotero.lua` (which does its own
        // live BBT lookup keyed by the exact literal citekey text) both see the identical
        // string. MUST run after the PDF image-prep block above (which does its own file
        // rewrite -- an earlier canonicalization would be silently overwritten by it) and
        // BEFORE `buildBaseArguments` below (whose PDF branch reads `pdfPrep.content` for
        // font-argument detection) and `citationArguments` (which needs the fetched
        // bibliography to build `--citeproc`/`--bibliography` args without fetching again).
        let citekeys = Array(Set(extractCitekeys(from: processedContent)))
        var bibliographyForCitations: BibliographyFetchResult?
        if hasCitations, zoteroStatus == .running, !citekeys.isEmpty {
            // One fetch, shared by both the citekey-case rewrite below (all formats) and
            // `citationArguments`'s PDF-only `--citeproc`/`--bibliography` argument building
            // further down -- never fetched twice for the same export.
            let bibliography = await fetchBibliographyJSON(for: citekeys)
            bibliographyForCitations = bibliography

            // supportsAmbiguityReporting is false whenever this batch resolved via the
            // item.export fallback, which has NO ambiguity concept at all -- not "reports zero
            // ambiguous keys," but structurally incapable of reporting any. rawAmbiguousKeys
            // being empty there means "no information," not "verified unambiguous," so the
            // ambiguity veto inside canonicalCitekeyMap is silently inert on that path. Rather
            // than rely on an inert veto, skip building a rewrite map entirely when ambiguity
            // reporting isn't available -- see RawCitekeyBatchResult.supportsAmbiguityReporting's
            // doc comment for the exact failure this prevents (a citekey silently repointed at
            // a completely different, wrong reference).
            let map = bibliography.supportsAmbiguityReporting
                ? ExportService.canonicalCitekeyMap(
                    requested: citekeys,
                    resolvedIDs: bibliography.resolvedIDs,
                    rawAmbiguousKeys: bibliography.rawAmbiguousKeys
                )
                : [:]
            let rewritten = canonicalizeCitekeys(in: processedContent, using: map)
            if rewritten != processedContent {
                do {
                    try rewritten.write(to: inputURL, atomically: true, encoding: .utf8)
                    processedContent = rewritten
                    pdfPrep = PDFContentPreparation(
                        content: rewritten,
                        effectiveResourceURL: pdfPrep.effectiveResourceURL,
                        tempMediaDir: pdfPrep.tempMediaDir,
                        warnings: pdfPrep.warnings
                    )
                } catch {
                    DebugLog.log(
                        .fileOps,
                        "[ExportService] Failed to write canonicalized citekeys back to temp input file: \(error) " +
                        "-- continuing export with the pre-rewrite content"
                    )
                    // Continue with pre-rewrite content -- today's behavior when this step
                    // can't happen; never fail the whole export over it.
                }
            }
        }

        // Build Pandoc arguments
        var arguments = buildBaseArguments(
            inputURL: inputURL,
            outputURL: outputURL,
            format: format,
            pdfPrep: pdfPrep,
            resourcePaths: resourcePaths
        )

        // Citations
        var citationArgs: [String] = []
        if hasCitations {
            let citation = citationArguments(
                format: format,
                luaScriptPath: resourcePaths.luaScriptPath,
                pdfBibliography: PDFBibliographyRequest(settings: settings, tempDir: tempDir),
                bibliography: bibliographyForCitations
            )
            citationArgs = citation.arguments
            artifacts.tempBibURL = citation.tempBibURL
            warnings.append(contentsOf: citation.warnings)
        }

        // Append citation arguments, then -- for PDF only -- the document-wide linkify-urls
        // Lua filter AFTER them. Pandoc applies --lua-filter/--citeproc in command-line order,
        // and citeproc is what turns a bare CSL field's URL text into a Str the linkify filter
        // needs to see -- so this must run after --citeproc, not before (see
        // assembleFinalArguments's doc comment and linkify-urls.lua's header comment). Applied
        // unconditionally for PDF (not gated on hasCitations) because bare URLs typed directly
        // into document body text need this fix too, with no citation involved at all.
        arguments = assembleFinalArguments(
            baseArguments: arguments,
            citationArguments: citationArgs,
            format: format,
            linkifyUrlsLuaPath: ExportService.bundledLinkifyUrlsLuaPath
        )

        // DIAGNOSTIC (temporary, opt-in — see docs/plans/mossy-tumbling-stroustrup.md, removed
        // once the fix for the PDF page-1 reorder bug lands). Off by default; gated by
        // isDiagnosticCaptureEnabled (Preferences -> Diagnostics -> Export Diagnostic Capture).
        // When enabled, fires for every format so a PDF -> Word -> PDF reproduction sequence
        // captures three side-by-side dumps. Never contributes to `warnings` — a diagnostic
        // dump succeeding or failing is not itself a user-facing export warning.
        let diagnosticDirURL = await dumpExportDiagnostics(ExportDiagnosticsRequest(
            rawContent: content,
            inputURL: inputURL,
            pandocPath: pandocPath,
            arguments: arguments,
            format: format,
            projectURL: projectURL
        ))

        // Run Pandoc
        do {
            try await runPandoc(
                at: pandocPath,
                arguments: arguments,
                stderrCaptureURL: diagnosticDirURL?.appendingPathComponent("pandoc-stderr.log")
            )
        } catch let error as ExportError {
            if case .pandocFailed(let exitCode, _) = error,
               let mapped = Self.citationFilterErrorIfApplicable(
                   exitCode: exitCode,
                   format: format,
                   luaScriptPath: resourcePaths.luaScriptPath
               ) {
                // Zotero WAS reachable when the pre-flight probe ran (requiresZoteroForExport
                // above didn't fire), so a raw exit-83 crash message here would wrongly imply
                // the probe was wrong. See citationFilterErrorIfApplicable's doc comment.
                throw mapped
            }
            throw error
        }

        // Zotero warnings (after export — export still runs, warnings inform after)
        if hasCitations {
            warnings.append(contentsOf: Self.zoteroWarnings(for: zoteroStatus))
        }

        return ExportResult(
            outputURL: outputURL,
            format: format,
            zoteroStatus: zoteroStatus,
            warnings: warnings
        )
    }

    // MARK: - Extracted Helpers

    /// Resolved lua-script and reference-doc paths for an export.
    ///
    /// `bareCitationsLuaPathOverride` exists purely as a test seam: `resolveAndValidateResourcePaths`
    /// (the only production call site) always leaves it nil, so `buildBaseArguments` falls
    /// through to the real `ExportService.bundledBareCitationsLuaPath` (a `Bundle.main` lookup)
    /// exactly as before -- no behavior change. It lets a test call the REAL `buildBaseArguments`
    /// and assert on its actual returned argument order instead of hand-duplicating pandoc's
    /// argument list (see BareCitationExportTests.swift): `Bundle.main` doesn't resolve bundled
    /// `Export/` resources correctly from the unit-test host, so the test injects the file's
    /// real on-disk path (resolved via `#filePath`) here instead. Kept as a field on this
    /// struct rather than a new `buildBaseArguments` parameter so the function's parameter
    /// count doesn't cross SwiftLint's `function_parameter_count` threshold.
    /// `mathSpecialCharsLuaPathOverride` is the same test seam for `bundledMathSpecialCharsLuaPath`.
    struct ResourcePaths {
        let luaScriptPath: String?
        let referenceDocPath: String?
        let bareCitationsLuaPathOverride: String?
        let mathSpecialCharsLuaPathOverride: String?
    }

    /// Resolves the lua-script and reference-doc paths from settings and validates that any
    /// path that was specified actually exists on disk (DOCX/ODT use the lua filter; PDF uses
    /// `--citeproc` instead, so its lua path is not checked).
    private func resolveAndValidateResourcePaths(
        format: ExportFormat,
        settings: ExportSettings
    ) throws -> ResourcePaths {
        let luaScriptPath = settings.effectiveLuaScriptPath
        let referenceDocPath = settings.effectiveReferenceDocPath(for: format)

        // Validate Lua script if needed (DOCX/ODT only; PDF uses --citeproc)
        if format != .pdf, let luaPath = luaScriptPath {
            guard FileManager.default.fileExists(atPath: luaPath) else {
                throw ExportError.luaScriptNotFound(luaPath)
            }
        }

        // Validate reference doc if specified
        if let refPath = referenceDocPath {
            guard FileManager.default.fileExists(atPath: refPath) else {
                throw ExportError.referenceDocNotFound(refPath)
            }
        }

        return ResourcePaths(
            luaScriptPath: luaScriptPath,
            referenceDocPath: referenceDocPath,
            bareCitationsLuaPathOverride: nil,
            mathSpecialCharsLuaPathOverride: nil
        )
    }

    /// Groups the temp filesystem artifacts an export can create (the temp markdown input
    /// file, a temp bibliography JSON, and a temp media directory for converted images) so a
    /// single `defer` can clean up whichever of them ended up populated by the time of exit.
    private struct TempExportArtifacts {
        let inputURL: URL
        var tempBibURL: URL?
        var tempMediaDir: URL?

        func cleanup() {
            try? FileManager.default.removeItem(at: inputURL)
            if let tempBibURL {
                try? FileManager.default.removeItem(at: tempBibURL)
            }
            if let tempMediaDir {
                try? FileManager.default.removeItem(at: tempMediaDir)
            }
        }
    }

    /// Result of `prepareContentForPDFIfNeeded`: possibly-rewritten content (with converted
    /// image paths), the resource directory Pandoc should resolve `media/` paths against, the
    /// temp media directory to clean up afterward (if image conversion created one), and any
    /// conversion warnings.
    struct PDFContentPreparation {
        let content: String
        let effectiveResourceURL: URL?
        let tempMediaDir: URL?
        let warnings: [String]
    }

    /// For PDF export, convert unsupported images (WebP, HEIC, etc.) to PNG and rewrite the
    /// temp input file in place if any conversion happened. No-op for non-PDF formats or when
    /// there's no project to resolve `media/` paths against — `effectiveResourceURL` then
    /// simply passes `projectURL` through unchanged, mirroring the original default.
    private func prepareContentForPDFIfNeeded(
        format: ExportFormat,
        content: String,
        projectURL: URL?,
        inputURL: URL
    ) throws -> PDFContentPreparation {
        guard format == .pdf, let projURL = projectURL else {
            return PDFContentPreparation(content: content, effectiveResourceURL: projectURL, tempMediaDir: nil, warnings: [])
        }

        let prep = prepareImagesForPDF(content: content, projectURL: projURL)
        guard prep.resourceDir != projURL else {
            return PDFContentPreparation(content: content, effectiveResourceURL: projectURL, tempMediaDir: nil, warnings: [])
        }

        // Conversion happened — use temp dir and rewritten content.
        // Re-write temp input file with updated image paths.
        try prep.content.write(to: inputURL, atomically: true, encoding: .utf8)

        return PDFContentPreparation(
            content: prep.content,
            effectiveResourceURL: prep.resourceDir,
            tempMediaDir: prep.resourceDir,
            warnings: prep.warnings
        )
    }

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
    /// Not `private` (unlike its sibling helpers) and takes `linkifyUrlsLuaPath` as a parameter
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
    private struct CitationBuildResult {
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
    private struct PDFBibliographyRequest {
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
    /// `bibliography` is fetched exactly once by `export()` itself (shared with the
    /// citekey-case rewrite, which needs the same fetch for every format, not just PDF) and
    /// passed in here — this function no longer fetches on its own. `nil` means the fetch was
    /// skipped entirely (no citations, Zotero not running, or no real citekeys extracted — see
    /// `export()`'s guard), in which case PDF appends nothing, exactly as before this function
    /// stopped fetching internally.
    private func citationArguments(
        format: ExportFormat,
        luaScriptPath: String?,
        pdfBibliography: PDFBibliographyRequest,
        bibliography: BibliographyFetchResult?
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
            }
        }

        return CitationBuildResult(arguments: args, tempBibURL: tempBibURL, warnings: warnings)
    }

    /// Map Zotero status to user-facing warnings. A `static func` (not an instance method, and
    /// not `private`) so `ExportViewModel`'s DOCX/ODT hard-stop alert can reuse this exact
    /// per-status wording -- a user whose Zotero is running but missing Better BibTeX needs a
    /// different message than one whose Zotero isn't running at all -- without duplicating
    /// these strings or needing actor isolation to call it.
    static func zoteroWarnings(for status: ZoteroStatus) -> [String] {
        switch status {
        case .notRunning:
            return ["Zotero is not running. Citations were not resolved."]
        case .betterBibTeXMissing:
            return ["Better BibTeX is not installed. Citations were not resolved."]
        case .timeout:
            return ["Could not connect to Zotero. Citations may not be resolved."]
        case .error(let msg):
            return ["Zotero error: \(msg)"]
        case .running:
            return []
        }
    }

    /// A present-tense-friendly variant of `zoteroWarnings(for:)`'s first sentence, for
    /// pre-flight contexts (like the DOCX/ODT hard-stop) where export was never attempted --
    /// `zoteroWarnings`'s full message is written past-tense ("Citations were not resolved"),
    /// which reads oddly before anything has run. Reuses `zoteroWarnings` as the single source
    /// of truth for the substantive per-status reason (so the two never drift out of sync)
    /// rather than maintaining a second, separately-worded set of per-status strings.
    static func zoteroPreflightReason(for status: ZoteroStatus) -> String {
        let warning = zoteroWarnings(for: status).first ?? "Zotero with Better BibTeX is not reachable."
        guard let periodIndex = warning.firstIndex(of: ".") else { return warning }
        return String(warning[..<warning.index(after: periodIndex)])
    }

    // MARK: - Pandoc Execution

    /// Run Pandoc with the given arguments
    /// - Parameters:
    ///   - path: Path to Pandoc executable
    ///   - arguments: Command line arguments
    ///   - stderrCaptureURL: DIAGNOSTIC (temporary, see dumpExportDiagnostics) — when set,
    ///     the full pandoc stderr is written here regardless of exit status. Best-effort:
    ///     failure to write is silently ignored.
    private func runPandoc(at path: String, arguments: [String], stderrCaptureURL: URL? = nil) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments

                let stderrPipe = Pipe()
                process.standardError = stderrPipe
                process.standardOutput = Pipe()  // Discard stdout

                var hasResumed = false  // Guard against double-resume

                process.terminationHandler = { proc in
                    guard !hasResumed else { return }
                    hasResumed = true

                    // DIAGNOSTIC: always read stderr to disk, not just on failure, so a
                    // successful-but-wrong export (the PDF reorder bug) still leaves a trail.
                    let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    if let stderrCaptureURL {
                        try? errorData.write(to: stderrCaptureURL)
                    }

                    if proc.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let errorMessage = String(data: errorData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
                        continuation.resume(throwing: ExportError.pandocFailed(
                            exitCode: Int(proc.terminationStatus),
                            message: errorMessage
                        ))
                    }
                }

                do {
                    try process.run()
                } catch {
                    guard !hasResumed else { return }
                    hasResumed = true
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            // Task was cancelled - process will be terminated when it goes out of scope
            DebugLog.log(.fileOps, "[ExportService] Export cancelled")
        }
    }
}
