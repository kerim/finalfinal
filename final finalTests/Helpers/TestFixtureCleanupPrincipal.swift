//
//  TestFixtureCleanupPrincipal.swift
//  final finalTests
//
//  Registered as this test bundle's NSPrincipalClass (INFOPLIST_KEY_NSPrincipalClass
//  in project.yml) -- Apple's documented mechanism for a test bundle to run its own
//  setup before any test executes. XCTest instantiates exactly one instance of this
//  class, on the main thread, as part of loading the bundle -- strictly before test
//  discovery or any test body runs, in either XCTest or Swift Testing, and regardless
//  of whether a filtered (`-only-testing`) run contains any XCTestCase at all.
//
//  That unconditional, main-thread-before-anything-else guarantee is why this
//  replaced registering the observer from inside `TestFixtureCleanup.bootstrap`,
//  which only ran lazily -- from whichever test happened to call
//  `TestFixtureCleanup.register(_:)` first, on whatever thread that was. See
//  TestFixtureCleanup.swift's header comment for the crash that caused and the full
//  history.
//

import Foundation
import XCTest

/// See the file header above. `init` runs exactly once, automatically, when XCTest
/// instantiates this bundle's principal class -- there is no call site for this type
/// anywhere else in the target.
@objc(TestFixtureCleanupPrincipal)
final class TestFixtureCleanupPrincipal: NSObject {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(TestFixtureCleanupObserver())
    }
}
