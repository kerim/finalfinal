//
//  TestMode.swift
//  final final
//

import Foundation

enum TestMode {
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting")
    }

    static var testFixturePath: String? {
        guard let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--test-fixture-path"),
              index + 1 < ProcessInfo.processInfo.arguments.count else { return nil }
        return ProcessInfo.processInfo.arguments[index + 1]
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
