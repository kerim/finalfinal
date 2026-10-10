//
//  UnitOutputFile.swift
//  final finalTests
//
//  The measurement tests of the book-length switch plan (ModeSwitchTextRoundTripTests, BlockParserScalingTests,
//  SectionAnchorInjectionTests) print their tables with `print`, but the unit-test tool returns only a summary, so
//  the printed lines were unreachable. This helper prints each line AND writes the same lines to a plain-text file
//  under the worktree, located from `#filePath` the way the golden rows and the committed fixture are:
//
//      <worktree>/.claude/scratch/unit-out/<name>.txt
//
//  (`roundtrip.txt`, `scaling.txt`, `anchors.txt`.) That directory is git-ignored here (`.claude/scratch/` is in the
//  repository's local exclude file; `.claude/unit-out/` is NOT ignored, which is why it is not used). The files are
//  run output: never commit them.
//
//  Per run the file is overwritten: the first call for a name in a test process starts the file with a header line
//  carrying the date and time of the run, later calls (other tests of the same run) add to it. Writes are serialised,
//  because Swift Testing runs tests of one suite in parallel unless the suite is `.serialized`. A failure to write
//  never fails a test: it is printed as a single `[UNIT-OUT]` line and nothing else.
//

import Foundation

enum UnitOutputFile {

    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var linesByName: [String: [String]] = [:]
    }

    private static let store = Store()

    /// `<worktree>/.claude/scratch/unit-out`, found by walking up from the CALLING test file (`filePath` defaults to the caller's
    /// `#filePath`) to the `final finalTests` directory and one level above it. Nil when the path has no such directory.
    private static func directory(from filePath: String) -> URL? {
        var url = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        while url.lastPathComponent != "final finalTests" {
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return url.deletingLastPathComponent()
            .appendingPathComponent(".claude/scratch/unit-out", isDirectory: true)
    }

    /// Prints every line and records it in `<name>.txt` (see the file header). Safe to call from parallel tests.
    static func emit(_ name: String, _ lines: [String], filePath: String = #filePath) {
        for line in lines { print(line) }
        store.lock.lock()
        defer { store.lock.unlock() }
        if store.linesByName[name] == nil {
            let stamp = ISO8601DateFormatter().string(from: Date())
            store.linesByName[name] = ["# \(stamp) -- output of the \(name) tests of this unit-test run (overwritten each run; never commit)"]
        }
        store.linesByName[name, default: []] += lines
        guard let directory = directory(from: filePath) else {
            print("[UNIT-OUT] could not write \(name).txt: no 'final finalTests' directory above \(filePath)")
            return
        }
        let url = directory.appendingPathComponent("\(name).txt")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try (store.linesByName[name, default: []].joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("[UNIT-OUT] could not write \(url.path): \(error)")
        }
    }
}
