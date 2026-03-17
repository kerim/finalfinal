//
//  TestMode.swift
//  final final
//

import Foundation

enum TestMode {
    static var isUITesting: Bool {
        ProcessInfo.processInfo.environment["FF_UI_TESTING"] == "1"
    }

    /// True when running unit tests (test bundle injected into app process).
    /// Uses XCTestConfigurationFilePath — set by Xcode's test runner before
    /// any test bundle code runs. This is undocumented but has been the
    /// canonical detection approach since Xcode 8.
    static var isUnitTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// True when running any kind of test (unit or UI)
    static var isTesting: Bool {
        isUITesting || isUnitTesting
    }

    static var testFixturePath: String? {
        ProcessInfo.processInfo.environment["FF_TEST_FIXTURE_PATH"]
    }

    /// Clears UserDefaults keys that could interfere with test isolation
    static func clearTestState() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "com.kerim.final-final.lastProjectBookmark")
        defaults.removeObject(forKey: "com.kerim.final-final.recentProjects")
        defaults.removeObject(forKey: "com.kerim.final-final.lastSeenVersion")
        defaults.removeObject(forKey: "focusModeEnabled")
        defaults.removeObject(forKey: "com.kerim.final-final.focusModeSettings")
        defaults.removeObject(forKey: "hasSeenSubtreeDragHint")
    }
}
