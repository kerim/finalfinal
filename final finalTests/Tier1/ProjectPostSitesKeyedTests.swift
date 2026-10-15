//
//  ProjectPostSitesKeyedTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C8a (slice-3a-1b-everyday.md section 5.5, "A22 exit check"): every place that POSTS
//  `.projectDidOpen`, `.projectDidCreate` or `.projectDidClose` carries the lifecycle token key
//  (`LifecycleEntry.keyedUserInfo()`), so ContentView's old handlers stand down when a managed tail does the job.
//  An unkeyed post would make the old handler flush, back up and reconfigure a second time.
//
//  This is a source scan (the `RawFontSizeLiteralTests` pattern): it walks `final final/**/*.swift`, finds every call
//  of `post(` whose arguments name one of the three notifications, and requires `keyedUserInfo` in the call. Round
//  C8b removed the Repair allowance (Repair and Open Anyway now post from `ProjectCommands`, keyed) and replaced the
//  last exemption by an explicit marker:
//
//    - `ProjectCommands.swift`: the Getting Started close posts `.projectDidClose` with
//      `LifecycleEntry.gettingStartedCloseUserInfo` ON PURPOSE. It runs no lifecycle (nothing to save), so there is no
//      token, and `LifecycleEntry.keyedUserInfo()` could even return a DIFFERENT running lifecycle's id and make the
//      old handler skip the close. Exactly one such marked post is allowed, and nothing else may be unkeyed.
//
//  The second test pins obligation 18 / E4: neither the Finder-open handler nor Save As flushes the editor itself any
//  more (the save sequence does it, through the ordered write queue).
//

import Foundation
import Testing

// MARK: - Scanner

struct ProjectPostSite: CustomStringConvertible {
    let relativePath: String
    let lineNumber: Int
    /// The whole call, from `post(` to its matching `)`, comments removed.
    let call: String

    var isKeyed: Bool { call.contains("keyedUserInfo") }

    /// The Getting Started close's explicit marker (round C8b): not keyed, but not an anonymous unkeyed post either.
    var isGettingStartedCloseMarker: Bool { call.contains("gettingStartedCloseUserInfo") }

    var description: String { "\(relativePath):\(lineNumber): \(call.replacingOccurrences(of: "\n", with: " "))" }
}

enum ProjectPostSiteScanner {
    static let notificationNames = [".projectDidOpen", ".projectDidCreate", ".projectDidClose"]

    /// Removes `//` comments (line and doc comments) so a comment that merely mentions a post is not a post.
    static func strippingComments(_ source: String) -> String {
        source.components(separatedBy: "\n").map { line -> String in
            guard let range = line.range(of: "//") else { return line }
            return String(line[line.startIndex..<range.lowerBound])
        }.joined(separator: "\n")
    }

    /// Every `post(...)` call in `source` whose argument list names one of the project notifications.
    static func postSites(in source: String, relativePath: String) -> [ProjectPostSite] {
        let text = strippingComments(source)
        // Cheap pre-check: almost every file never names a project notification, and the scan below is per character.
        guard notificationNames.contains(where: { text.contains($0) }) else { return [] }
        let chars = Array(text)
        var sites: [ProjectPostSite] = []
        var searchStart = 0
        let needle = Array("post(")
        while searchStart + needle.count <= chars.count {
            guard Array(chars[searchStart..<(searchStart + needle.count)]) == needle else {
                searchStart += 1
                continue
            }
            let openIndex = searchStart + needle.count - 1
            var depth = 0
            var closeIndex = openIndex
            for index in openIndex..<min(chars.count, openIndex + 800) {
                if chars[index] == "(" { depth += 1 }
                if chars[index] == ")" {
                    depth -= 1
                    if depth == 0 { closeIndex = index; break }
                }
            }
            let call = String(chars[openIndex...closeIndex])
            if notificationNames.contains(where: { mentions($0, in: call) }) {
                let lineNumber = chars[0..<searchStart].filter { $0 == "\n" }.count + 1
                sites.append(ProjectPostSite(relativePath: relativePath, lineNumber: lineNumber, call: call))
            }
            searchStart = closeIndex + 1
        }
        return sites
    }

    /// True when `name` appears in `call` and is not the prefix of a longer identifier.
    private static func mentions(_ name: String, in call: String) -> Bool {
        var remainder = call[...]
        while let range = remainder.range(of: name) {
            guard let next = remainder[range.upperBound...].first else { return true }
            if !(next.isLetter || next.isNumber || next == "_") { return true }
            remainder = remainder[range.upperBound...]
        }
        return false
    }

    /// Every post site in every `.swift` file under `<repoRoot>/final final/`, plus how many files were walked.
    static func scan(repoRoot: URL) -> (sites: [ProjectPostSite], filesWalked: Int) {
        let root = repoRoot.appendingPathComponent("final final")
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return ([], 0) }
        var sites: [ProjectPostSite] = []
        var filesWalked = 0
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            filesWalked += 1
            sites += postSites(in: contents, relativePath: relativePath(of: fileURL, repoRoot: repoRoot))
        }
        return (sites, filesWalked)
    }

    static func relativePath(of fileURL: URL, repoRoot: URL) -> String {
        let full = fileURL.standardizedFileURL.path
        let rootPath = repoRoot.standardizedFileURL.path
        guard full.hasPrefix(rootPath) else { return full }
        var stripped = String(full.dropFirst(rootPath.count))
        if stripped.hasPrefix("/") { stripped.removeFirst() }
        return stripped
    }

    /// `<repoRoot>/final finalTests/Tier1/<this file>`: three `deletingLastPathComponent()` calls reach the repo root.
    static func repoRoot(from testFilePath: String = #filePath) -> URL {
        URL(fileURLWithPath: testFilePath)
            .deletingLastPathComponent()  // Tier1/
            .deletingLastPathComponent()  // final finalTests/
            .deletingLastPathComponent()  // repo root
    }

    /// The unkeyed sites that are NOT covered by the one stated exemption (see the file header): after round C8b that
    /// is nothing but the single marked Getting Started close in `ProjectCommands.swift`.
    static func unexemptedUnkeyedSites(_ sites: [ProjectPostSite]) -> [ProjectPostSite] {
        var unkeyed = sites.filter { !$0.isKeyed }
        var gettingStartedAllowance = 1
        unkeyed.removeAll { site in
            if site.relativePath.hasSuffix("Commands/ProjectCommands.swift"),
               site.call.contains(".projectDidClose"), site.isGettingStartedCloseMarker, gettingStartedAllowance > 0 {
                gettingStartedAllowance -= 1
                return true
            }
            return false
        }
        return unkeyed
    }
}

// MARK: - Tests

@Suite("Project lifecycle post sites carry the token key (t-94369a83 3a-1b C8a, A22)")
struct ProjectPostSitesKeyedTests {

    @Test("""
        A22: no .projectDidOpen / .projectDidCreate / .projectDidClose post is left unkeyed, except the one marked \
        Getting Started close (round C8b: Repair and Open Anyway are keyed now)
        """)
    func everyPostSiteIsKeyed() {
        let (sites, _) = ProjectPostSiteScanner.scan(repoRoot: ProjectPostSiteScanner.repoRoot())
        let unkeyed = ProjectPostSiteScanner.unexemptedUnkeyedSites(sites)
        #expect(
            unkeyed.isEmpty,
            """
            These posts do not carry LifecycleEntry.keyedUserInfo(); a managed tail would be run a second time by the old \
            ContentView handler:
            \(unkeyed.map(\.description).joined(separator: "\n"))
            """
        )
    }

    @Test("Vacuous-pass guard: the scan walks real files and finds the lifecycle's own post sites")
    func scanFindsTheKnownPostSites() {
        let (sites, filesWalked) = ProjectPostSiteScanner.scan(repoRoot: ProjectPostSiteScanner.repoRoot())
        #expect(filesWalked > 20, "the scan root is probably wrong: \(ProjectPostSiteScanner.repoRoot().path)")
        let keyed = sites.filter(\.isKeyed)
        #expect(
            keyed.count >= 6,
            "expected the six keyed command sites (close, open/Finder, Save As, New, Import, Repair/Open Anyway); got \(keyed.map(\.description))")
        #expect(
            sites.contains { $0.relativePath.hasSuffix("Commands/ProjectCommands.swift") && $0.isGettingStartedCloseMarker },
            "the one marked Getting Started close is scanned (and is the only exemption)")
        #expect(
            !sites.contains { $0.relativePath.hasSuffix("Views/ProjectOpenErrorHost.swift") },
            "Repair and Open Anyway no longer post from the sheet: ProjectCommands does it, keyed")
    }

    @Test("The scanner tells keyed from unkeyed, multi-line calls included, and ignores comments")
    func scannerDiscriminates() {
        let source = """
            // NotificationCenter.default.post(name: .projectDidOpen, object: nil)
            NotificationCenter.default.post(name: .projectDidOpen, object: nil)
            env.post(.projectDidClose, LifecycleEntry.keyedUserInfo())
            NotificationCenter.default.post(
                name: .projectDidCreate,
                object: nil,
                userInfo: LifecycleEntry.keyedUserInfo(adding: ["content": content])
            )
            NotificationCenter.default.post(
                name: .projectDidCreate,
                object: nil,
                userInfo: ["content": content]
            )
            NotificationCenter.default.post(name: .projectDidOpenSomethingElse, object: nil)
            NotificationCenter.default.post(name: .saveProject, object: nil)
            env.post(.projectDidClose, LifecycleEntry.gettingStartedCloseUserInfo)
            """
        let sites = ProjectPostSiteScanner.postSites(in: source, relativePath: "x.swift")
        #expect(sites.count == 5, "the comment, the longer name and the unrelated post are not sites; got \(sites.map(\.description))")
        #expect(sites.map(\.isKeyed) == [false, true, true, false, false])
        #expect(sites.map(\.isGettingStartedCloseMarker) == [false, false, false, false, true])
    }

    @Test("Obligation 18 / E4: neither the Finder-open handler nor Save As flushes the editor itself any more")
    func noDirectFlushInFinderOpenOrSaveAs() throws {
        let root = ProjectPostSiteScanner.repoRoot().appendingPathComponent("final final")
        for relative in ["App/AppDelegate.swift", "Commands/FileCommands.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            let code = ProjectPostSiteScanner.strippingComments(source)
            #expect(
                !code.contains("flushContentToDatabase"),
                "\(relative) still calls flushContentToDatabase(): the lifecycle's save sequence does that now")
        }
    }
}
