//
//  TestDefaultsSuiteTests.swift
//  final finalTests
//
//  Proves `TestDefaultsSuite` (Helpers/TestDefaultsSuite.swift) keeps a test's throwaway defaults
//  suite off the user's Preferences folder, and takes it off the Mac when the test ends. A test run
//  used to leave one listed `defaults domains` entry per suite per run (46,000 by 2026-11-19, board
//  t-dd2a58d1): a suite named like a bundle identifier is a file in ~/Library/Preferences, and
//  neither emptying it nor deleting that file afterwards removed it for good. What a user would see
//  is that list, so these tests assert on the files themselves -- the thing `defaults domains` reads
//  -- rather than on the helper's inner calls.
//

import Testing
import Foundation

@Suite(.serialized)
struct TestDefaultsSuiteTests {

    private var preferencesFolder: String { NSHomeDirectory() + "/Library/Preferences" }

    /// The UUID at the end of a `TestDefaultsSuite.uniqueName` result.
    private func uuid(of suiteName: String) -> String { String(suiteName.suffix(36)) }

    /// Every file in ~/Library/Preferences whose name mentions `token`.
    private func preferencesFiles(mentioning token: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: preferencesFolder)) ?? []).filter { $0.contains(token) }
    }

    /// Polls `condition` for at most three seconds (bounded) and returns whether it held.
    private func eventually(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    /// Makes a throwaway suite, writes one value into it, and waits until its file exists, which is
    /// the state every real test leaves behind.
    private func makeWrittenSuite() throws -> (suiteName: String, suite: UserDefaults) {
        let suiteName = TestDefaultsSuite.uniqueName("selfCheck")
        let suite = try #require(UserDefaults(suiteName: suiteName))
        suite.set("probe", forKey: "probeKey")
        let plist = suiteName + ".plist"
        try #require(
            eventually { FileManager.default.fileExists(atPath: plist) },
            "a suite that was written to never got its plist file at \(plist)"
        )
        return (suiteName, suite)
    }

    @Test("a throwaway suite is written inside the helper's own folder and never into ~/Library/Preferences")
    func throwawaySuiteStaysOutOfThePreferencesFolder() throws {
        let (suiteName, suite) = try makeWrittenSuite()
        let plist = suiteName + ".plist"
        defer { TestDefaultsSuite.remove(suiteName) }

        #expect(plist.hasPrefix(TestDefaultsSuite.rootPath + "/"))
        // The preferences daemon writes on its own schedule, so give a stray write time to land.
        Thread.sleep(forTimeInterval: 0.3)
        #expect(
            preferencesFiles(mentioning: uuid(of: suiteName)).isEmpty,
            "a plist for the throwaway suite appeared in ~/Library/Preferences -- `defaults domains` would list it"
        )
        withExtendedLifetime(suite) {}
    }

    @Test("remove() deletes the suite's file and nothing brings it back or puts one in ~/Library/Preferences")
    func removeDeletesTheSuiteFileForGood() throws {
        let (suiteName, suite) = try makeWrittenSuite()
        let plist = suiteName + ".plist"

        // Called once, here: the assertions below follow it, and none of them stops the test early.
        TestDefaultsSuite.remove(suiteName)
        #expect(!FileManager.default.fileExists(atPath: plist), "remove() left the suite's file behind at \(plist)")
        #expect((UserDefaults.standard.persistentDomain(forName: suiteName) ?? [:]).isEmpty)

        Thread.sleep(forTimeInterval: 0.5)
        #expect(!FileManager.default.fileExists(atPath: plist), "the suite's file came back after remove()")
        #expect(
            preferencesFiles(mentioning: uuid(of: suiteName)).isEmpty,
            "removing the suite left a plist in ~/Library/Preferences -- `defaults domains` would list it"
        )
        withExtendedLifetime(suite) {}
    }

    @Test("remove() on a suite that never wrote anything leaves no file")
    func removeOnAnUnwrittenSuiteLeavesNoFile() throws {
        let suiteName = TestDefaultsSuite.uniqueName("selfCheckUnwritten")
        let suite = try #require(UserDefaults(suiteName: suiteName))

        TestDefaultsSuite.remove(suiteName)
        Thread.sleep(forTimeInterval: 0.3)

        #expect(!FileManager.default.fileExists(atPath: suiteName + ".plist"))
        withExtendedLifetime(suite) {}
    }

    @Test("every name from uniqueName is a distinct single file inside the helper's folder")
    func uniqueNamesAreDistinctFilesInsideTheFolder() {
        let first = TestDefaultsSuite.uniqueName("a")
        let second = TestDefaultsSuite.uniqueName("a")
        #expect(first != second)
        #expect(TestDefaultsSuite.isThrowawayName(first))
        #expect(TestDefaultsSuite.isThrowawayName(second))
        #expect(TestDefaultsSuite.isThrowawayName(TestDefaultsSuite.uniqueName()))
    }

    @Test("the guard refuses anything that is not a single file in the helper's folder, real defaults files included")
    func guardRefusesEverythingElse() {
        let root = TestDefaultsSuite.rootPath
        let refused = [
            "",
            "com.kerim.final-final",
            "com.kerim.final-final.testhost",
            "com.kerim.final-final.tests.\(UUID().uuidString)",
            NSHomeDirectory() + "/Library/Preferences/com.kerim.final-final",
            root,
            root + "/",
            root + "/sub/name",
            root + "/../name",
            root + "/.hidden"
        ]
        for name in refused {
            #expect(!TestDefaultsSuite.isThrowawayName(name), "the guard accepted '\(name)'")
        }
    }
}
