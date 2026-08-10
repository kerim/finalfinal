//
//  ExportViewModel.swift
//  final final
//
//  UI-facing state wrapper for export operations.
//  Provides @MainActor @Observable interface for SwiftUI views.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

/// State for export operations
@MainActor
@Observable
final class ExportViewModel {

    // MARK: - State

    /// Whether an export is currently in progress
    private(set) var isExporting = false

    /// Current export progress message
    private(set) var progressMessage: String?

    /// Last error from export operation
    private(set) var lastError: Error?

    /// Pandoc status (cached from last check)
    private(set) var pandocStatus: PandocStatus = .notFound

    /// Whether Pandoc is available
    var isPandocAvailable: Bool {
        if case .found = pandocStatus { return true }
        return false
    }

    // MARK: - Services

    private let exportService = ExportService()

    // MARK: - Initialization

    init() {}

    // MARK: - Status Checks

    /// Check and update Pandoc status
    func checkPandoc() async {
        pandocStatus = await exportService.checkPandoc()
    }

    /// Refresh Pandoc status (clear cache)
    func refreshPandocStatus() async {
        pandocStatus = await exportService.refreshPandocStatus()
    }

    /// Configure export service with current settings
    func configure() async {
        let settings = ExportSettingsManager.shared.settings
        await exportService.configure(with: settings)
        await checkPandoc()
    }

    // MARK: - Export Operations

    /// Export content to the specified format
    /// - Parameters:
    ///   - content: Markdown content to export
    ///   - url: Destination URL
    ///   - format: Export format
    ///   - precomputedZoteroStatus: Forwarded to `ExportService.export()` verbatim -- see its
    ///     doc comment. `showExportPanel`'s DOCX/ODT path passes the status `savePanelDecision`
    ///     already obtained here so the Service doesn't check Zotero a second time; every other
    ///     caller leaves this `nil` and gets the original check-now behavior.
    /// - Returns: ExportResult on success
    func export(
        content: String,
        to url: URL,
        format: ExportFormat,
        projectURL: URL? = nil,
        precomputedZoteroStatus: ZoteroStatus? = nil
    ) async throws -> ExportResult {
        isExporting = true
        progressMessage = "Exporting to \(format.displayName)..."
        lastError = nil

        defer {
            isExporting = false
            progressMessage = nil
        }

        do {
            let settings = ExportSettingsManager.shared.settings
            let result = try await exportService.export(
                content: content,
                to: url,
                format: format,
                settings: settings,
                projectURL: projectURL,
                precomputedZoteroStatus: precomputedZoteroStatus
            )

            return result
        } catch {
            lastError = error
            throw error
        }
    }

    /// Outcome of `savePanelDecision`: whether `showExportPanel` should proceed to present the
    /// save panel, or should instead show an alert without ever presenting the panel at all.
    /// Not `Equatable` -- `blockedByError` carries a plain `Error`, which isn't -- callers and
    /// tests pattern-match on it instead.
    enum SavePanelDecision {
        /// Safe to present the save panel. `precomputedZoteroStatus` is the Zotero status the
        /// preflight determined (a real preflight now runs for every format, including PDF);
        /// forwarding it into `export()` avoids checking Zotero a second time. For PDF, the
        /// static `savePanelDecision(format:preflight:showZoteroWarning:)` below deliberately
        /// returns `nil` here instead of the preflight's status, since a PDF export that reaches
        /// the save panel without ever having shown the degraded-export warning (either because
        /// there were no citations, or Zotero was already running) still benefits from
        /// `export()` re-checking fresh rather than trusting a status that's about to go stale
        /// while the user picks a save location.
        case proceed(precomputedZoteroStatus: ZoteroStatus?)
        case blockedByZotero(ZoteroStatus)
        /// PDF only. Zotero is unreachable and the document has real citations, but PDF degrades
        /// gracefully (unresolved citation text plus a warning) rather than failing, so this is a
        /// real choice, not a hard stop: show the two-button "Zotero Not Running" alert BEFORE
        /// the save panel. On "Continue Export" the panel is presented; on "Cancel" nothing is
        /// shown and nothing is exported.
        case warnDegraded(ZoteroStatus)
        /// The preflight found a *different* doomed-export condition than Zotero -- a
        /// misconfigured custom lua-script or reference-document path
        /// (`ExportError.luaScriptNotFound`/`.referenceDocNotFound`) -- that `export()` would
        /// also have hit. Surfaced the same way as the Zotero block: before the save panel, not
        /// after. In practice this can only fire for DOCX/ODT -- see `zoteroPreflight`'s doc
        /// comment for why PDF's resource-path validation never throws.
        case blockedByError(Error)
    }

    /// Decides whether `showExportPanel` should present the save panel for this content and
    /// format, or short-circuit straight to an alert. Split out from `showExportPanel` itself
    /// purely so a test can exercise this exact decision directly -- `NSSavePanel` and
    /// `NSAlert` both show real, modal, screen-taking windows that must never run inside a
    /// headless unit test.
    ///
    /// This is the fix for a regression: an earlier round made `ExportService` the sole source
    /// of truth for "does this document have citations" (removing a separate, looser ViewModel
    /// pre-check that could disagree with the Service), but that meant the Zotero-required hard
    /// stop was only ever discovered from inside `export()` -- which only throws AFTER
    /// `NSSavePanel.begin` has already shown the panel and the user has already picked a save
    /// location. The user would pick a filename, click Save, and only then learn the export
    /// couldn't proceed. This method restores the "check before wasting the user's time"
    /// behavior without reintroducing the disagreement bug: it calls the exact same
    /// `ExportService.zoteroPreflight` (built on `requiresZoteroForExport` and the strict
    /// citekey extractor) that `export()` itself uses, rather than re-deriving "has citations"
    /// separately here.
    ///
    /// PDF now goes through this exact same preflight as every other format -- it used to be
    /// excluded unconditionally, with its own separate "Continue Export anyway?" probe running
    /// AFTER the save panel closed (inside `presentSavePanel`'s completion handler). That probe
    /// is gone; PDF's degrade-gracefully warning is now decided here too, before the save panel,
    /// via the pure `savePanelDecision(format:preflight:showZoteroWarning:)` below.
    func savePanelDecision(content: String, format: ExportFormat) async -> SavePanelDecision {
        let settings = ExportSettingsManager.shared.settings
        do {
            let preflight = try await exportService.zoteroPreflight(
                content: content, format: format, settings: settings
            )
            return Self.savePanelDecision(
                format: format,
                preflight: preflight,
                showZoteroWarning: settings.showZoteroWarning
            )
        } catch let error as ExportError {
            switch error {
            case .luaScriptNotFound, .referenceDocNotFound:
                // Already computed before the save panel would appear -- surface immediately
                // instead of discarding it and letting export() re-discover it after the panel.
                return .blockedByError(error)
            default:
                // zoteroPreflight cannot currently throw any other ExportError case; kept as a
                // defensive fallback so an unrelated future error still surfaces later exactly
                // as it did before this preflight existed, once export() itself runs.
                return .proceed(precomputedZoteroStatus: nil)
            }
        } catch {
            return .proceed(precomputedZoteroStatus: nil)
        }
    }

    /// Pure decision core of `savePanelDecision(content:format:)` above -- no `async`, no
    /// singleton reads, no network -- so a test can exercise every format x preflight x
    /// warning-setting combination directly, without a live `ExportService` or
    /// `ExportSettingsManager.shared`.
    ///
    /// `isBlocked` always wins first: `ExportService.requiresZoteroForExport` never returns
    /// `true` for PDF, so `.blockedByZotero` is reachable only for DOCX/ODT, and `.warnDegraded`
    /// is reachable only for PDF (the `format == .pdf` guard below is what makes that mutual
    /// exclusion explicit, rather than relying on `isBlocked`'s PDF-excludes-itself behavior
    /// alone). A citation-free document (`hasCitations == false`) never sees the warning,
    /// regardless of Zotero's status -- there's nothing for Zotero to resolve.
    nonisolated static func savePanelDecision(
        format: ExportFormat,
        preflight: ExportService.ZoteroPreflightResult,
        showZoteroWarning: Bool
    ) -> SavePanelDecision {
        if preflight.isBlocked { return .blockedByZotero(preflight.zoteroStatus) }
        if format == .pdf,
           preflight.hasCitations,
           preflight.zoteroStatus != .running,
           showZoteroWarning {
            return .warnDegraded(preflight.zoteroStatus)
        }
        return .proceed(precomputedZoteroStatus: format == .pdf ? nil : preflight.zoteroStatus)
    }

    /// Show export save panel and perform export
    /// - Parameters:
    ///   - content: Markdown content to export
    ///   - format: Export format
    ///   - defaultName: Default file name (without extension)
    func showExportPanel(content: String, format: ExportFormat, defaultName: String, projectURL: URL? = nil) {
        // Check Pandoc first
        guard isPandocAvailable else {
            showPandocNotFoundAlert()
            return
        }

        // See `savePanelDecision`'s doc comment: this asks the Service whether the export would
        // hit the Zotero-required hard stop (DOCX/ODT), the degraded-citations warning (PDF),
        // or a misconfigured resource path -- BEFORE the save panel ever appears, so a doomed
        // (or degraded) export never wastes the user's time on picking a save location without
        // being asked first.
        //
        // For PDF specifically, `precomputedZoteroStatus` ends up `nil` by the time it reaches
        // `presentSavePanel` below -- in both the `.proceed` branch (where the static
        // `savePanelDecision` already returned `nil` for PDF) and the `.warnDegraded` branch
        // (passed explicitly below) -- rather than forwarding the status this preflight already
        // found. That status is about to go stale while the user picks a save location (and,
        // for `.warnDegraded`, while they possibly go start Zotero and click "Continue Export");
        // PDF degrades gracefully either way, so there's no reason not to let `export()`
        // re-check fresh instead of risking an unnecessarily degraded PDF from a now-outdated
        // status. This costs nothing new: PDF's export already re-checks Zotero itself whenever
        // `precomputedZoteroStatus` is `nil` (see `ExportService.export`'s doc comment), which was already happening on
        // every PDF export before this preflight existed. DOCX/ODT, by contrast, keeps
        // forwarding its precomputed status as before -- a fresh recheck isn't meaningful for
        // DOCX/ODT the same way, since it hard-stops rather than degrading.
        Task { @MainActor in
            switch await self.savePanelDecision(content: content, format: format) {
            case .blockedByZotero(let zoteroStatus):
                self.showZoteroRequiredAlert(format: format, zoteroStatus: zoteroStatus)
            case .blockedByError(let error):
                self.showExportErrorAlert(error: error)
            case .warnDegraded(let zoteroStatus):
                if await self.showZoteroWarningAlert(zoteroStatus: zoteroStatus) {
                    self.presentSavePanel(
                        content: content,
                        format: format,
                        defaultName: defaultName,
                        projectURL: projectURL,
                        precomputedZoteroStatus: nil
                    )
                }
            case .proceed(let precomputedZoteroStatus):
                self.presentSavePanel(
                    content: content,
                    format: format,
                    defaultName: defaultName,
                    projectURL: projectURL,
                    precomputedZoteroStatus: precomputedZoteroStatus
                )
            }
        }
    }

    /// Presents the actual save panel and, once the user picks a location, performs the
    /// export. Factored out of `showExportPanel` so the pre-panel Zotero preflight in
    /// `savePanelDecision` can run first -- and short-circuit (or, for PDF, prompt) before any
    /// save panel appears -- without duplicating the panel-construction/export/error-handling
    /// logic below.
    ///
    /// `precomputedZoteroStatus` is forwarded straight into `export()`. For DOCX/ODT it's the
    /// status `savePanelDecision` already found, so `export()` doesn't check Zotero a second
    /// time. For PDF, `showExportPanel` always passes `nil` here deliberately -- see its doc
    /// comment -- so `export()` performs its own fresh check instead of trusting a status that
    /// may have gone stale while the user picked a save location.
    private func presentSavePanel(
        content: String,
        format: ExportFormat,
        defaultName: String,
        projectURL: URL?,
        precomputedZoteroStatus: ZoteroStatus?
    ) {
        let savePanel = NSSavePanel()
        savePanel.title = "Export as \(format.displayName)"
        savePanel.nameFieldLabel = "Export As:"
        savePanel.nameFieldStringValue = defaultName

        // Set allowed content type
        if let utType = UTType(format.contentTypeIdentifier) {
            savePanel.allowedContentTypes = [utType]
        }

        savePanel.canCreateDirectories = true

        savePanel.begin { [weak self] response in
            guard let self = self, response == .OK, let url = savePanel.url else { return }

            Task { @MainActor in
                do {
                    // DOCX/ODT's hard stop, and PDF's degraded-citations warning, are both
                    // decided BEFORE this panel even appears -- see `savePanelDecision`, called
                    // from `showExportPanel`. For DOCX/ODT that also passes its precomputed
                    // Zotero status into `export()` below, so `export()` does NOT re-check
                    // Zotero here -- the narrow race where Zotero disappears between that
                    // preflight and now isn't caught by a re-check; it surfaces instead when the
                    // real pandoc invocation's lua filter fails against the now-unreachable
                    // Zotero (pandoc exit 83), which `ExportService.citationFilterErrorIfApplicable`
                    // maps to the friendly `citationFilterFailed` error caught below. PDF instead
                    // always passes `nil` here (see `presentSavePanel`'s doc comment), so
                    // `export()` re-checks Zotero fresh right now regardless of what the earlier
                    // preflight found.

                    let result = try await self.export(
                        content: content,
                        to: url,
                        format: format,
                        projectURL: projectURL,
                        precomputedZoteroStatus: precomputedZoteroStatus
                    )

                    // Show success with warnings
                    self.showExportSuccessAlert(result: result)

                } catch ExportError.zoteroRequiredForCitations(let failedFormat, let zoteroStatus) {
                    self.showZoteroRequiredAlert(format: failedFormat, zoteroStatus: zoteroStatus)
                } catch {
                    self.showExportErrorAlert(error: error)
                }
            }
        }
    }

    // MARK: - Alerts

    /// Shows the standard "Pandoc Not Found" alert. Not private: reused by
    /// `PrintOperations.handlePrintFormatted()` so the Print > Formatted... path shows
    /// the exact same alert as "Export as PDF..." instead of a duplicate.
    func showPandocNotFoundAlert() {
        let alert = NSAlert()
        alert.messageText = "Pandoc Not Found"
        alert.informativeText = PandocLocator.installInstructions
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Download Page")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(PandocLocator.downloadURL)
        }
    }

    private func showZoteroWarningAlert(zoteroStatus: ZoteroStatus) async -> Bool {
        await withCheckedContinuation { continuation in
            let reason = ExportService.zoteroPreflightReason(for: zoteroStatus)

            let alert = NSAlert()
            alert.messageText = "Zotero Not Running"
            alert.informativeText = """
                \(reason)

                Citations like [@Smith2020] will appear as-is in the exported document instead of being resolved to proper citations.

                Would you like to continue anyway?
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Continue Export")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't warn again"

            let response = alert.runModal()

            // Handle suppression
            if alert.suppressionButton?.state == .on {
                ExportSettingsManager.shared.showZoteroWarning = false
            }

            continuation.resume(returning: response == .alertFirstButtonReturn)
        }
    }

    /// Hard-stop alert for DOCX/ODT exports when Zotero is unreachable: a single OK button,
    /// no "Continue Export" and no suppression checkbox (unlike `showZoteroWarningAlert`,
    /// which is PDF-only and suppressible). DOCX/ODT citations depend on Zotero's lua filter
    /// at export time with no fallback path, so there is nothing to "continue" into other
    /// than a crash or a broken document -- see ExportService.requiresZoteroForExport.
    ///
    /// Reuses `ExportService.zoteroPreflightReason(for:)` for the informative text so a user
    /// whose Zotero is running but missing Better BibTeX is told that specifically, rather
    /// than a single "open Zotero" message that would be misleading when Zotero is already
    /// open. Severity is `.warning`, matching `showZoteroWarningAlert` above -- nothing
    /// destructive happened, export simply didn't run.
    private func showZoteroRequiredAlert(format: ExportFormat, zoteroStatus: ZoteroStatus) {
        let reason = ExportService.zoteroPreflightReason(for: zoteroStatus)

        let alert = NSAlert()
        alert.messageText = "Zotero Required for \(format.displayName) Export"
        alert.informativeText = """
            This document has citations, and \(format.displayName) export needs Zotero to resolve them.

            \(reason)

            Resolve this, then try exporting again.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showExportSuccessAlert(result: ExportResult) {
        let alert = NSAlert()

        if result.warnings.isEmpty {
            alert.messageText = "Export Complete"
            alert.informativeText = "Document exported successfully to \(result.format.displayName)."
            alert.alertStyle = .informational
        } else {
            alert.messageText = "Export Complete with Warnings"
            alert.informativeText = result.warnings.joined(separator: "\n\n")
            alert.alertStyle = .warning
        }

        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.selectFile(result.outputURL.path, inFileViewerRootedAtPath: "")
        }
    }

    private func showExportErrorAlert(error: Error) {
        let fullErrorMessage = error.localizedDescription

        // Truncate for display (first 200 chars + indicator)
        let displayMessage: String
        if fullErrorMessage.count > 200 {
            let truncated = String(fullErrorMessage.prefix(200))
            displayMessage = truncated + "...\n\n(Full error copied to clipboard)"

            // Copy full error to clipboard
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(fullErrorMessage, forType: .string)
        } else {
            displayMessage = fullErrorMessage
        }

        let alert = NSAlert()
        alert.messageText = "Export Failed"
        alert.informativeText = displayMessage
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
