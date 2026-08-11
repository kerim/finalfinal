//
//  ZoteroApplyProbedStatusTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Coverage for `ZoteroService.applyProbedStatus(_:)` -- folds a freshly probed `ZoteroStatus`
//  (from an export preflight, or export()'s own live Zotero check) into a `ZoteroService`
//  instance's cached connection state, so UI reading `isConnected` doesn't keep showing a
//  stale "connected" long after Zotero actually went away. Before this existed, an export
//  flow's own Zotero probe was thrown away the moment it returned -- any UI surface that reads
//  `ZoteroService.shared.isConnected` (rather than running its own probe) could disagree with
//  what the export flow itself just observed.
//
//  Each test constructs a fresh `ZoteroService()` rather than reading or mutating the
//  process-wide `ZoteroService.shared` singleton, matching the pattern already used throughout
//  ZoteroLibraryScopeTests*.swift -- these tests never leave behind mutated global state.

import Testing
import Foundation
@testable import final_final

@Suite("Zotero applyProbedStatus — Tier 1: Silent Killers")
struct ZoteroApplyProbedStatusTests {

    private static let failureStatuses: [ZoteroStatus] = [
        .notRunning, .betterBibTeXMissing, .timeout, .error("boom")
    ]

    @Test("applyProbedStatus(.running) marks connected, clears any error, and stamps lastPingTime")
    @MainActor
    func runningMarksConnected() {
        let service = ZoteroService()
        service.isConnected = false
        service.connectionError = "stale error"
        service.lastPingTime = nil

        service.applyProbedStatus(.running)

        #expect(service.isConnected)
        #expect(service.connectionError == nil)
        #expect(service.lastPingTime != nil)
    }

    @Test(
        "applyProbedStatus(failure status) marks disconnected with a non-empty connectionError",
        arguments: failureStatuses
    )
    @MainActor
    func failureStatusMarksDisconnected(status: ZoteroStatus) {
        let service = ZoteroService()
        service.isConnected = true
        service.connectionError = nil

        service.applyProbedStatus(status)

        #expect(!service.isConnected)
        #expect(!(service.connectionError ?? "").isEmpty)
    }

    @Test("Regression: a stale isConnected == true flips to false after applying .notRunning")
    @MainActor
    func staleConnectedFlipsFalseOnNotRunning() {
        let service = ZoteroService()
        // Simulate a stale "connected" left over from an earlier successful ping -- exactly
        // the shape this fix targets: app-wide cached state that never got told Zotero
        // disappeared.
        service.isConnected = true
        service.connectionError = nil
        service.lastPingTime = Date(timeIntervalSinceNow: -600)

        service.applyProbedStatus(.notRunning)

        #expect(!service.isConnected)
        #expect(service.connectionError != nil)
    }
}
