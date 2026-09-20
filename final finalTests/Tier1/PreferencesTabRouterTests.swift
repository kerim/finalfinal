//
//  PreferencesTabRouterTests.swift
//  final finalTests
//
//  Tier 1: a request for a specific Settings tab ("Export Preferences...", the toast's
//  "Open Diagnostics") is STORED, so it lands on the requested tab whether the Settings
//  window is created by the request (cold launch) or already open -- and a plain open of
//  Settings afterwards shows Export.
//

import Testing
import Foundation
import Observation
@testable import final_final

/// Records that an Observation `onChange` fired. A class because the `onChange` closure is
/// `@Sendable` and cannot mutate a captured local.
private final class ObservationFlag: @unchecked Sendable {
    var fired = false
}

@Suite
struct PreferencesTabRouterTests {

    @Test("With nothing requested, a plain open of Settings shows Export")
    @MainActor
    func plainOpenShowsExport() {
        let router = PreferencesTabRouter()
        #expect(router.pendingTab == nil)
        #expect(router.initialTab == .export)
        #expect(router.consumePendingTab() == nil)
        #expect(PreferencesTabRouter.defaultTab == .export)
    }

    // The cold-launch route: the request is made BEFORE the Settings view exists (it is what
    // opens the window), so the view can only find it by reading the stored value.
    @Test("A request made before the view exists is what a new view starts on, then clears")
    @MainActor
    func requestBeforeViewExistsLandsThenClears() {
        // A tab other than the default (Export), so a request that failed to clear could not be
        // mistaken for the default below.
        let router = PreferencesTabRouter()
        router.request(.appearance)

        // The new view's initial tab. Reading it must not clear the request: SwiftUI may build
        // the view value more than once before it appears.
        #expect(router.initialTab == .appearance)
        #expect(router.initialTab == .appearance)

        // On appear the view consumes the request, applying it exactly once...
        #expect(router.consumePendingTab() == .appearance)
        #expect(router.pendingTab == nil)

        // ...so a later plain open of Settings (Cmd-,) is not redirected and shows Export.
        #expect(router.initialTab == .export)
        #expect(router.consumePendingTab() == nil)
    }

    @Test("The Diagnostics request routes the same way")
    @MainActor
    func diagnosticsRequestRoutesTheSameWay() {
        let router = PreferencesTabRouter()
        router.request(.diagnostics)
        #expect(router.initialTab == .diagnostics)
        #expect(router.consumePendingTab() == .diagnostics)
        #expect(router.initialTab == .export)
    }

    @Test("When two requests arrive before the view applies one, the latest wins")
    @MainActor
    func latestRequestWins() {
        let router = PreferencesTabRouter()
        router.request(.export)
        router.request(.diagnostics)
        #expect(router.consumePendingTab() == .diagnostics)
        #expect(router.consumePendingTab() == nil)
    }

    // The already-open route: the live view learns of the request by observing the stored
    // value change (its `onChange(of: router.pendingTab)`), so that change must be observable.
    @Test("A request is observable, so an already-open Settings view can react to it")
    @MainActor
    func requestIsObservable() {
        let router = PreferencesTabRouter()
        let flag = ObservationFlag()
        withObservationTracking {
            _ = router.pendingTab
        } onChange: {
            flag.fired = true
        }
        router.request(.export)
        #expect(flag.fired)
    }
}
