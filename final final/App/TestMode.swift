//
//  TestMode.swift
//  final final
//

import Foundation

enum TestMode {
    static var isUITesting: Bool {
        ProcessInfo.processInfo.environment["FF_UI_TESTING"] == "1"
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
        defaults.removeObject(forKey: "hasSeenSubtreeDragHint")
    }
}
