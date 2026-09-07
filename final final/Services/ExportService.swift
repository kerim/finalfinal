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
    /// Whether `zoteroStatus` above came from an actual live check of Zotero during this
    /// export, as opposed to the unprobed `.running` default a document with no real
    /// citekeys short-circuits to (see `export()`'s `hasRealCitations` gate) or a status the
    /// caller precomputed and forwarded in via `precomputedZoteroStatus`. Lets a caller (see
    /// `ZoteroService.applyProbedStatus`) fold a fresh, real probe result into app-wide cached
    /// Zotero connection state without also overwriting that state with a value that was
    /// never actually checked.
    let zoteroStatusWasProbed: Bool
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
        // Strict citekey extraction (not the loose `hasPandocCitations` regex) gates the
        // Zotero probe itself: a false-positive bracket shape like `[contact me@example.com]`
        // matches the loose regex but has zero real citekeys, and must never trigger a live
        // network round-trip to Zotero just to compute a status nobody needs. See
        // `export()`'s identical split further down for why the loose detector still has a
        // legitimate (and deliberately unchanged) job elsewhere -- gating pandoc argument
        // construction, not this probe.
        let hasRealCitations = !extractCitekeys(from: processedContent).isEmpty
        let zoteroStatus: ZoteroStatus = hasRealCitations
            ? await zoteroChecker.check()
            : .running // Not an actual probe result -- a document with no real citekeys
                       // (including a loose-only false-positive match) short-circuits here
                       // without ever checking Zotero, so this value is NOT authoritative
                       // about real Zotero connectivity. See `ExportResult.zoteroStatusWasProbed`.
        let resourcePaths = try resolveAndValidateResourcePaths(format: format, settings: settings)

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

        // Strict citekey extraction (not the loose `hasPandocCitations` regex below) gates
        // both the Zotero probe just below and the hard-stop check further down. Hoisted up
        // here -- rather than computed separately, later, only for the hard-stop check as it
        // used to be -- so the same single computation drives both: a false-positive bracket
        // shape like `[contact me@example.com]` or `[install @scope/pkg]` (see
        // `extractCitekeys`'s doc comment for the full accept/reject rules) must never trigger
        // a live Zotero network round-trip in the first place, not just avoid the hard stop
        // after needlessly probing. Mirrors `zoteroPreflight`'s identical split above.
        let hasRealCitations = !extractCitekeys(from: processedContent).isEmpty

        // Only check Zotero if content appears to have real citations -- unless the caller
        // already did (see `precomputedZoteroStatus`'s doc comment above).
        let zoteroStatus: ZoteroStatus
        if let precomputedZoteroStatus {
            zoteroStatus = precomputedZoteroStatus
        } else {
            zoteroStatus = hasRealCitations
                ? await zoteroChecker.check()
                : .running // Not an actual probe -- see `zoteroPreflight`'s identical comment;
                           // not authoritative about real Zotero connectivity. See
                           // `ExportResult.zoteroStatusWasProbed`.
        }

        // Get and validate resource paths (lua filter, reference doc)
        let resourcePaths = try resolveAndValidateResourcePaths(format: format, settings: settings)

        // Loose citation detection (`hasPandocCitations`) still gates the pandoc-argument
        // construction below (the bibliography fetch and the --lua-filter/--citeproc
        // arguments) -- deliberately kept distinct from the strict `hasRealCitations` used
        // for the probe/hard-stop above. `extractCitekeys` has documented gaps (e.g.
        // `[@some/key]`, `[@{key with spaces}]` -- see its doc comment) where this looser
        // regex is intentionally more permissive; narrowing those call sites to
        // `hasRealCitations` would strip `--lua-filter`/`--citeproc` from those real
        // citations and regress them to literal, unresolved text instead.
        let hasCitations = hasPandocCitations(in: processedContent)

        // Hard stop -- before any temp file or pandoc invocation -- rather than let a
        // DOCX/ODT export run its lua filter against an unreachable Zotero (pandoc exit 83)
        // or silently emit unresolved citations. See requiresZoteroForExport's doc comment.
        //
        // Uses the strict `hasRealCitations` computed above, NOT the loose `hasCitations`
        // just above: `hasPandocCitations`'s regex also matches non-citation shapes like
        // `[contact me@example.com]` or `[install @scope/pkg]` (see extractCitekeys's doc
        // comment), and a document with zero real citekeys must never be hard-blocked just
        // because it happens to contain one of those shapes.
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
        let canonical = await applyCitekeyCanonicalization(
            content: processedContent, pdfPrep: pdfPrep,
            hasCitations: hasCitations, zoteroStatus: zoteroStatus, inputURL: inputURL
        )
        processedContent = canonical.content
        pdfPrep = canonical.pdfPrep
        let bibliographyForCitations = canonical.bibliography

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
            // Group-library scope for zotero.lua's phase-2 BBT lookup (DOCX/ODT only -- PDF
            // never invokes zotero.lua, it resolves citations itself via `--citeproc`).
            // `fetchLibraries()` here is typically a session-cache hit (`cachedLibraries`),
            // NOT a fresh fetch -- it only calls out to BBT the first time this session needs
            // the library list. That's exactly why zotero.lua's own phase-2 retry (see the
            // "LOCAL PATCH (zotero-group-libraries)" block's failure-handling comment) matters:
            // a cached name can go stale mid-session (the user renames or leaves a group), and
            // BBT rejects a whole batched item.pandoc_filter call over a single bad name, so
            // the Lua side must be able to recover name-by-name rather than relying on this
            // cache always being fresh. Degrades to two empty arrays (the exact unscoped
            // behavior from before this fix) on any failure or timeout, and whenever this
            // export wouldn't reach zotero.lua at all -- this can never fail or stall an export
            // on its own.
            //
            // `ZoteroService.groupLibraryMetadata(from:)` -- not the old exact-string
            // `groupLibraryNames(from:)` dedupe (deleted; it IS the duplicate-group-library-name
            // bug shape) -- partitions the fetched libraries the same collision-safe way the
            // citekey-resolution path already does: every uniquely-named group library batches
            // into `groupLibraryNames`, while a library whose display name collides with
            // another's -- or has no usable name at all -- travels as a bare numeric id in
            // `groupLibraryIDs` instead, each in its own zotero.lua call, so a stale/shadowed
            // name can no longer hide it from being searched at all.
            //
            // Gated on the STRICT `hasRealCitations` (not the loose `hasCitations` this whole
            // block is nested under) and on `resourcePaths.luaScriptPath != nil`: a
            // false-positive bracket shape like `[contact me@example.com]` has zero real
            // citekeys and must never trigger this live Zotero network round-trip (see the
            // `hasRealCitations`/`zoteroStatus` invariant comment above), and there is nothing
            // for zotero.lua to scope if no lua filter is even configured for this export.
            var groupLibraryScope = GroupLibraryScope(names: [], ids: [])
            if format != .pdf, hasRealCitations, resourcePaths.luaScriptPath != nil, zoteroStatus == .running {
                let libraries = (try? await ZoteroService.shared.fetchLibraries()) ?? []
                let metadata = ZoteroService.groupLibraryMetadata(from: libraries)
                groupLibraryScope = GroupLibraryScope(names: metadata.names, ids: metadata.ids)
            }

            let citation = citationArguments(
                format: format,
                luaScriptPath: resourcePaths.luaScriptPath,
                pdfBibliography: PDFBibliographyRequest(settings: settings, tempDir: tempDir),
                bibliography: bibliographyForCitations,
                groupLibraryScope: groupLibraryScope
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
        try await runPandocMappingCitationErrors(
            at: pandocPath,
            arguments: arguments,
            format: format,
            luaScriptPath: resourcePaths.luaScriptPath,
            stderrCaptureURL: diagnosticDirURL?.appendingPathComponent("pandoc-stderr.log")
        )

        // Zotero warnings (after export — export still runs, warnings inform after)
        if hasCitations {
            warnings.append(contentsOf: Self.zoteroWarnings(for: zoteroStatus))
        }

        return ExportResult(
            outputURL: outputURL,
            format: format,
            zoteroStatus: zoteroStatus,
            warnings: warnings,
            // True only when THIS export actually ran a live Zotero check itself -- not when
            // the caller forwarded a precomputed status (that check happened earlier,
            // elsewhere) and not when there were no real citekeys to check in the first place
            // (zoteroStatus above is then the unprobed `.running` default, not a real result).
            // Uses the strict `hasRealCitations` (item 1's probe trigger), not the loose
            // `hasCitations` above -- the two can disagree for a loose-only-match document,
            // and it's `hasRealCitations` that actually decided whether `zoteroChecker.check()`
            // ran a few lines up.
            zoteroStatusWasProbed: precomputedZoteroStatus == nil && hasRealCitations
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
}
