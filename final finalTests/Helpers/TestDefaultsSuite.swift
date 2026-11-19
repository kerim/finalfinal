//
//  TestDefaultsSuite.swift
//  final finalTests
//
//  Throwaway `UserDefaults` suites for unit tests, kept OUT of the user's Preferences folder
//  (t-dd2a58d1). A test that must not touch the real `com.kerim.final-final` defaults domain
//  makes its own suite; this helper names those suites and takes them away again.
//
//  THE PROBLEM: a suite named like a bundle identifier (`com.kerim.final-final.tests.<UUID>`) is a
//  defaults DOMAIN that the preferences daemon (cfprefsd) backs with a file,
//  `~/Library/Preferences/<name>.plist`, and `defaults domains` lists it for as long as that file
//  exists. Test runs piled up one listed domain per suite per run -- 46,000 by 2026-11-19. Cleaning
//  up in the test did not work either (measured 2026-11-19, small scratch programs against the real
//  daemon):
//    - `removePersistentDomain(forName:)`, on the suite instance or on `UserDefaults.standard`,
//      only EMPTIES the domain. The file stays as a 42-byte empty-dictionary plist.
//    - Deleting that file afterwards does not hold. The daemon writes a domain out on its own
//      schedule, so after most variants the file reappeared by itself between a few seconds and
//      about a minute after the delete: removal on `UserDefaults.standard`, with or without a
//      synchronize in between, and even removal on the suite instance followed by a synchronize
//      and the delete. A second removal call recreated it within half a second.
//
//  THE FIX: give the suite an ABSOLUTE PATH as its name. CFPreferences treats a name that starts
//  with `/` as the location of the plist file itself, so the file is written there and nothing is
//  written into ~/Library/Preferences, which means nothing is listed by `defaults domains`. What
//  the same scratch programs measured:
//    - `UserDefaults(suiteName: "/some/dir/name")` works and creates exactly `/some/dir/name.plist`.
//    - `UserDefaults.standard.persistentDomain(forName: "/some/dir/name")` reads that suite.
//    - Emptying the domain and deleting that file leaves the directory empty, and nothing came back
//      during a six-second watch, nor after the probe process exited.
//    - ~/Library/Preferences gained no file at all while those suites were written and removed.
//
//  Use `uniqueName(_:)` for the name and end the test with `defer { TestDefaultsSuite.remove(name) }`.
//
//  THE GUARD: `remove(_:)` deletes a file, so it refuses (crashes with a plain message) anything that
//  is not a single file directly inside this helper's own folder. A real defaults file -- the app's,
//  the test host's, anything in ~/Library/Preferences -- can never match.
//
//  NOT COVERED, ON PURPOSE: `AppDefaults` keeps ONE fixed suite, `com.kerim.final-final.testing`,
//  for the whole test process (production code, created once, never grows), so it is not a
//  per-test leftover and this helper does not touch it.
//

import Foundation

enum TestDefaultsSuite {

    /// The one folder every throwaway suite file lives in, under the user's temporary directory.
    /// A leftover file here (a crashed test run) is harmless: it is never read by anything and the
    /// system clears the temporary directory itself.
    static let rootPath: String = {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("final-final-test-suites").path
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()

    /// A fresh suite name for `UserDefaults(suiteName:)`: an absolute path inside `rootPath`.
    /// `tag` is only a human-readable hint in the file name.
    static func uniqueName(_ tag: String = "suite") -> String {
        "\(rootPath)/\(tag).\(UUID().uuidString)"
    }

    /// Whether `suiteName` is a single file directly inside `rootPath` (the guard in `remove(_:)`).
    static func isThrowawayName(_ suiteName: String) -> Bool {
        guard suiteName.hasPrefix(rootPath + "/") else { return false }
        let tail = suiteName.dropFirst(rootPath.count + 1)
        return !tail.isEmpty && !tail.contains("/") && !tail.hasPrefix(".")
    }

    /// Empties the suite and deletes its file. Call it from a `defer` right after creating the
    /// suite, exactly once; the suite's file is then gone from the Mac.
    static func remove(_ suiteName: String) {
        precondition(
            isThrowawayName(suiteName),
            "TestDefaultsSuite.remove refuses '\(suiteName)': a throwaway suite must come from " +
            "TestDefaultsSuite.uniqueName so this helper can never delete a real defaults file."
        )
        // Clear anything the process still holds for this domain, so a suite instance that is still
        // alive cannot write it back, then drop the file.
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        CFPreferencesAppSynchronize(suiteName as CFString)
        try? FileManager.default.removeItem(atPath: suiteName + ".plist")
    }
}
