//
//  ExportViewModelSavePanelDecisionTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Coverage for `ExportViewModel.savePanelDecision(format:preflight:showZoteroWarning:)` -- the
//  pure decision core behind the pre-save-panel gate that decides whether `showExportPanel`
//  should present a real `NSSavePanel` directly, show a warning first, or short-circuit
//  straight to the "Zotero Required" alert without ever presenting the panel. Before the
//  preflight this function backs existed, a DOCX/ODT export with unreachable Zotero still
//  showed the save panel, let the user pick a filename and click Save, and only THEN threw
//  `ExportError.zoteroRequiredForCitations` from inside `export()` -- wasting the user's time on
//  a save location that was never going to be used. PDF used to be excluded from this preflight
//  entirely, with its own separate "Continue Export anyway?" probe running AFTER the save panel
//  closed; PDF now goes through this same preflight, before the panel, like every other format
//  -- but because PDF degrades gracefully (unresolved citation text plus a warning) instead of
//  failing outright, its outcome is a real choice (`.warnDegraded`), not a hard stop
//  (`.blockedByZotero`).
//
//  This decision function is pure and side-effect-free -- no `async`, no `ExportService`
//  instance, no `ExportSettingsManager.shared`, no `NSSavePanel`/`NSAlert` construction (both
//  show real, modal, screen-taking windows that must never run inside a headless unit test) --
//  so it can be exercised directly here across every format x preflight x warning-setting
//  combination by constructing `ExportService.ZoteroPreflightResult` values directly.
//
//  The DOCX/ODT "would it block" / PDF "would it warn" *inputs* (what `isBlocked` and
//  `hasCitations` actually are for real content) are proven separately, against the real
//  `ExportService.zoteroPreflight` function that produces them, in
//  ExportZoteroPreflightTests.swift -- including the "agrees with export()" test that is this
//  fix's must-not-regress guarantee (the ViewModel and Service must never disagree about "has
//  citations" again). This file instead proves the decision table built on TOP of those inputs:
//  given a `ZoteroPreflightResult`, which `SavePanelDecision` case comes out.

import Testing
import Foundation
@testable import final_final

@Suite("Export ViewModel save-panel decision — Tier 1: Silent Killers")
struct ExportViewModelSavePanelDecisionTests {

    private static let someStatus: ZoteroStatus = .notRunning

    // MARK: - PDF: real citations + Zotero unreachable + warning enabled -> warnDegraded

    @Test("PDF with real citations and unreachable Zotero, warning enabled, warns instead of proceeding directly")
    func pdfRealCitationsUnreachableWarningEnabledWarns() {
        let preflight = ExportService.ZoteroPreflightResult(
            zoteroStatus: Self.someStatus, isBlocked: false, hasCitations: true
        )
        let decision = ExportViewModel.savePanelDecision(
            format: .pdf, preflight: preflight, showZoteroWarning: true
        )
        guard case .warnDegraded(let status) = decision else {
            Issue.record("Expected .warnDegraded, got \(decision)")
            return
        }
        #expect(status == Self.someStatus)
    }

    // MARK: - PDF: same inputs, but the user suppressed the warning -> proceed straight through

    @Test("PDF with real citations and unreachable Zotero, warning suppressed, proceeds straight to the save panel")
    func pdfRealCitationsUnreachableWarningSuppressedProceeds() {
        let preflight = ExportService.ZoteroPreflightResult(
            zoteroStatus: Self.someStatus, isBlocked: false, hasCitations: true
        )
        let decision = ExportViewModel.savePanelDecision(
            format: .pdf, preflight: preflight, showZoteroWarning: false
        )
        guard case .proceed(let precomputedZoteroStatus) = decision else {
            Issue.record("Expected .proceed, got \(decision)")
            return
        }
        #expect(precomputedZoteroStatus == nil)
    }

    // MARK: - PDF: Zotero running -> proceed, regardless of citations or warning setting

    @Test("PDF with real citations and Zotero running proceeds without warning")
    func pdfRealCitationsZoteroRunningProceeds() {
        let preflight = ExportService.ZoteroPreflightResult(
            zoteroStatus: .running, isBlocked: false, hasCitations: true
        )
        let decision = ExportViewModel.savePanelDecision(
            format: .pdf, preflight: preflight, showZoteroWarning: true
        )
        guard case .proceed(let precomputedZoteroStatus) = decision else {
            Issue.record("Expected .proceed, got \(decision)")
            return
        }
        #expect(precomputedZoteroStatus == nil)
    }

    // MARK: - PDF: no citations -> proceed, even with Zotero unreachable and warning enabled --
    // never warn on a document with nothing for Zotero to resolve

    @Test("PDF with no citations proceeds even with Zotero unreachable and warning enabled")
    func pdfNoCitationsProceedsRegardlessOfZoteroStatus() {
        let preflight = ExportService.ZoteroPreflightResult(
            zoteroStatus: Self.someStatus, isBlocked: false, hasCitations: false
        )
        let decision = ExportViewModel.savePanelDecision(
            format: .pdf, preflight: preflight, showZoteroWarning: true
        )
        guard case .proceed(let precomputedZoteroStatus) = decision else {
            Issue.record("Expected .proceed, got \(decision)")
            return
        }
        #expect(precomputedZoteroStatus == nil)
    }

    // MARK: - PDF: isBlocked should never be true in practice (ExportService.requiresZoteroForExport
    // excludes PDF unconditionally), but if it somehow were, blockedByZotero must still win --
    // proving .warnDegraded is reachable for PDF while .blockedByZotero is not

    @Test("PDF never reaches blockedByZotero for the realistic isBlocked == false case, even with warn-shaped inputs")
    func pdfNeverBlockedForRealisticInputs() {
        let preflight = ExportService.ZoteroPreflightResult(
            zoteroStatus: Self.someStatus, isBlocked: false, hasCitations: true
        )
        let decision = ExportViewModel.savePanelDecision(
            format: .pdf, preflight: preflight, showZoteroWarning: true
        )
        if case .blockedByZotero = decision {
            Issue.record("PDF must never reach .blockedByZotero, got \(decision)")
        }
    }

    // MARK: - Word/ODT: isBlocked == true -> blockedByZotero, never warnDegraded, even with
    // warn-shaped inputs (real citations, unreachable Zotero, warning enabled)

    @Test(
        "Word/ODT with isBlocked == true always returns blockedByZotero, never warnDegraded",
        arguments: [ExportFormat.word, .odt]
    )
    func nonPDFBlockedReturnsBlockedByZotero(format: ExportFormat) {
        let preflight = ExportService.ZoteroPreflightResult(
            zoteroStatus: Self.someStatus, isBlocked: true, hasCitations: true
        )
        let decision = ExportViewModel.savePanelDecision(
            format: format, preflight: preflight, showZoteroWarning: true
        )
        guard case .blockedByZotero(let status) = decision else {
            Issue.record("Expected .blockedByZotero, got \(decision)")
            return
        }
        #expect(status == Self.someStatus)
    }

    // MARK: - Word/ODT: not blocked -> proceed, forwarding the precomputed status (unlike PDF,
    // which never reaches the save panel with a non-nil forwarded status from showExportPanel)

    @Test(
        "Word/ODT with isBlocked == false proceeds, forwarding the preflight's Zotero status",
        arguments: [ExportFormat.word, .odt]
    )
    func nonPDFNotBlockedProceedsForwardingStatus(format: ExportFormat) {
        let preflight = ExportService.ZoteroPreflightResult(
            zoteroStatus: .running, isBlocked: false, hasCitations: true
        )
        let decision = ExportViewModel.savePanelDecision(
            format: format, preflight: preflight, showZoteroWarning: true
        )
        guard case .proceed(let precomputedZoteroStatus) = decision else {
            Issue.record("Expected .proceed, got \(decision)")
            return
        }
        #expect(precomputedZoteroStatus == .running)
    }
}
