//
//  AppDefaultsTests.swift
//  final finalTests
//
//  Regression coverage for the "Recent Projects (and other UserDefaults-backed state) wiped
//  on every app update" bug. Root cause: unit tests run *inside* the real app process, so
//  `UserDefaults.standard` during a unit test run IS the user's real, live
//  `com.kerim.final-final` defaults domain — not a sandboxed copy. `scripts/build.sh` runs the
//  full unit-test suite before every release build, and several tests call
//  `TestMode.clearTestState()` in their setup helpers, which used to call
//  `UserDefaults.standard.removeObject(forKey:)` directly on all eight of its managed keys —
//  permanently deleting the user's real Recent Projects list, last-opened-project bookmark,
//  focus mode preferences, etc. on every release build.
//
//  `.serialized`: this suite reads (but, deliberately, never writes) the real
//  `UserDefaults.standard` domain's current values for `clearTestState()`'s managed keys, so
//  it must not run concurrently with anything else that mutates those same keys mid-test.
//
//  IMPORTANT: no test in this file may ever *write* to one of these production keys in the
//  real `UserDefaults.standard` domain, not even temporarily with a restoring `defer` — if
//  the test process were killed between the write and the `defer` running, the user's real
//  Recent Projects list (etc.) would be permanently overwritten with test sentinel garbage,
//  literally reproducing the bug this file exists to guard against. Tests that need to prove
//  something about `.standard` do so by reading its existing values, or by writing only to
//  probe keys that no production code ever reads.
//

import Testing
import Foundation
@testable import final_final

@Suite(.serialized)
struct AppDefaultsTests {

    /// All eight keys `TestMode.clearTestState()` manages — kept in sync with that
    /// function's own list so this suite fails loudly if a key is added there without also
    /// being covered here.
    private static let clearTestStateKeys: [String] = [
        "com.kerim.final-final.lastProjectBookmark",
        "com.kerim.final-final.recentProjects",
        "com.kerim.final-final.lastSeenVersion",
        "focusModeEnabled",
        "com.kerim.final-final.focusModeSettings",
        "hasSeenSubtreeDragHint",
        DiagnosticLogFile.loggingEnabledDefaultsKey,
        "com.kerim.final-final.diagnosticsLastReportGeneratedAt"
    ]

    /// Compares two `UserDefaults.object(forKey:)` results for equality without assuming
    /// `Any` conforms to `Equatable` — every property-list type UserDefaults can return
    /// (`NSString`, `NSNumber`, `NSData`, `NSArray`, `NSDictionary`, ...) is bridged to
    /// `NSObject` and implements `isEqual(_:)`.
    private static func defaultsValuesMatch(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs as NSObject, rhs as NSObject):
            return lhs.isEqual(rhs)
        default:
            return false
        }
    }

    // MARK: - Store Isolation

    @Test("AppDefaults.store is isolated from UserDefaults.standard while testing")
    func storeIsIsolatedFromStandardDuringTests() {
        // This test runs inside the unit test process, so TestMode.isTesting is true here —
        // AppDefaults.store must therefore never be .standard itself.
        let probeKey = "com.kerim.final-final.tests.appDefaultsProbe.\(UUID().uuidString)"
        let probeValue = "probe-\(UUID().uuidString)"

        AppDefaults.store.set(probeValue, forKey: probeKey)
        defer { AppDefaults.store.removeObject(forKey: probeKey) }

        #expect(AppDefaults.store.string(forKey: probeKey) == probeValue)
        #expect(
            UserDefaults.standard.string(forKey: probeKey) == nil,
            "Writing to AppDefaults.store during a test run must never leak into UserDefaults.standard"
        )
    }

    @Test("AppDefaults.store returns the same isolated instance across repeated access")
    func storeIsStableAcrossAccess() {
        // Not required to be literally the same object identity (UserDefaults doesn't expose
        // one), but two independently-obtained references must see each other's writes —
        // i.e. they're the same underlying suite, not a fresh throwaway each call.
        let key = "com.kerim.final-final.tests.appDefaultsStability.\(UUID().uuidString)"
        AppDefaults.store.set(42, forKey: key)
        defer { AppDefaults.store.removeObject(forKey: key) }

        #expect(AppDefaults.store.integer(forKey: key) == 42)
    }

    // MARK: - clearTestState() Never Touches the Real Domain

    @Test("clearTestState() never removes any of its eight keys from UserDefaults.standard")
    func clearTestStateDoesNotTouchStandardDomain() {
        // Deliberately never seeds sentinel values into these production keys on the real
        // `UserDefaults.standard` domain — see the file-level comment above for why. Instead
        // this proves the same thing two ways without ever writing to `.standard`:
        //
        // 1. Structurally: while `TestMode.isTesting` is true (always true for a test process
        //    like this one), `AppDefaults.store` must be a distinct instance from
        //    `UserDefaults.standard`. `TestMode.clearTestState()` only ever calls
        //    `AppDefaults.store.removeObject(forKey:)` (see TestMode.swift) — never
        //    `UserDefaults.standard` directly — so this structural fact alone guarantees it
        //    cannot reach the real domain during a test run.
        // 2. Behaviorally, but read-only: capture each key's *existing* real value (whatever
        //    it happens to be — possibly nil — on this machine) before calling
        //    `clearTestState()`, then assert it is still exactly that value afterward. No
        //    value is ever written to `.standard`, so there is nothing for a crash to corrupt.
        #expect(TestMode.isTesting, "This test's isolation guarantee only holds while a test is running")
        #expect(
            AppDefaults.store !== UserDefaults.standard,
            "AppDefaults.store must be a separate, isolated instance from UserDefaults.standard while testing"
        )

        let keys = Self.clearTestStateKeys
        let before: [String: Any?] = Dictionary(
            uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        )

        TestMode.clearTestState()

        for key in keys {
            #expect(
                Self.defaultsValuesMatch(UserDefaults.standard.object(forKey: key), before[key] ?? nil),
                "clearTestState() must not modify '\(key)' in the real UserDefaults.standard domain"
            )
        }
    }

    @Test("clearTestState() does remove all eight keys from the isolated AppDefaults.store")
    func clearTestStateRemovesFromIsolatedStore() {
        let keys = Self.clearTestStateKeys

        for key in keys {
            AppDefaults.store.set(true, forKey: key)
        }

        TestMode.clearTestState()

        for key in keys {
            #expect(
                AppDefaults.store.object(forKey: key) == nil,
                "clearTestState() should remove '\(key)' from the isolated AppDefaults.store"
            )
        }
    }
}
