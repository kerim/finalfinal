//
//  RawFontSizeLiteralTests.swift
//  final finalTests
//
//  Guards the app's UX-contract rule (§7): "Raw `.system(size:)` literals are
//  forbidden everywhere." — every main-window chrome text/glyph size must come
//  from `Theme/Typography.swift`'s `TypeScale` table, not a hardcoded number.
//
//  Scans every `.swift` file under `final final/` for a raw numeric literal
//  immediately following `.system(size:`, `systemFont(ofSize:`,
//  `monospacedSystemFont(ofSize:`, or `monospacedDigitSystemFont(ofSize:`,
//  outside the token table itself and three stated, non-chrome exemptions:
//
//  - `QuickLook Extension/**` — separate target rendering Finder previews, not
//    main-window chrome.
//  - `final final/App/DevBuildBadge.swift` — draws into an NSImage app-icon
//    overlay, not UI text.
//  - `final final/Commands/PrintCommands.swift`'s single
//    `monospacedSystemFont(ofSize: 11)` line — page-rendering print output,
//    not screen chrome. The exemption is keyed by that line's content, not
//    its line number, so it still applies if the line moves and a future raw
//    literal added anywhere else in PrintCommands.swift still fails this
//    guard.
//

import Foundation
import Testing
@testable import final_final

// MARK: - Scanner

/// One raw font-size-literal violation: the file and line it was found on,
/// plus the offending line's trimmed text for a readable failure message.
struct RawFontSizeViolation: CustomStringConvertible {
    let relativePath: String
    let lineNumber: Int
    let lineText: String

    var description: String {
        "\(relativePath):\(lineNumber): \(lineText)"
    }
}

/// Walks `final final/**/*.swift` looking for raw numeric font-size literals.
/// See the file header above for the exact rule and the stated exemptions.
enum RawFontSizeScanner {
    /// Matches a raw numeric literal immediately (modulo whitespace) after the
    /// `size:`/`ofSize:` label of any of the four font-construction APIs this
    /// task's migration table covers. A token reference such as
    /// `TypeScale.chromeMicro` or `h1` starts with a letter, never a digit, so
    /// it never matches — see `patternDiscriminatesRawLiteralFromTokenReference`
    /// below for the guard confirming exactly that.
    static let pattern =
        #"(\.system\(size:|systemFont\(ofSize:|monospacedSystemFont\(ofSize:|monospacedDigitSystemFont\(ofSize:)\s*[0-9]"#

    private static let regex = try! NSRegularExpression(pattern: pattern)

    /// Returns whether a single line (or any standalone string) contains a raw
    /// font-size literal per `pattern`. Exposed standalone so the
    /// pattern-discrimination self-test can exercise it directly.
    static func matches(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.firstMatch(in: line, options: [], range: range) != nil
    }

    /// The token table itself: every raw literal here IS a token definition,
    /// not a violation.
    static let tokenTableFile = "final final/Theme/Typography.swift"

    /// Whole-file/whole-directory exemptions: every raw-size hit anywhere
    /// under these paths (relative to the repo root) is allowed. Also the
    /// canonical list the exemption-liveness guard checks for existence.
    static let exemptFilePrefixes: [String] = [
        "QuickLook Extension/",
        "final final/App/DevBuildBadge.swift",
    ]

    /// Single-line exemption, keyed by file path plus the exact expected line
    /// content — not by line number. A line number would silently break in two
    /// ways: an edit above it shifts the real exempted literal to a different
    /// line (so the scanner then flags it with a confusing message), and any
    /// unrelated new literal that happens to land on that same line number
    /// would be silently exempted too. Keying by content means the exemption
    /// only ever matches the exact literal it was written for, wherever it
    /// ends up in the file.
    static let exemptFileLineContents: [String: String] = [
        "final final/Commands/PrintCommands.swift": "monospacedSystemFont(ofSize: 11"
    ]

    /// Every path the exemption-liveness guard checks for existence: the two
    /// whole-file/directory exemptions above, plus the file (not just the
    /// line) carrying the single-line exemption.
    static let allExemptedPaths: [String] = [
        "QuickLook Extension",
        "final final/App/DevBuildBadge.swift",
        "final final/Commands/PrintCommands.swift",
    ]

    static func isExempt(relativePath: String, lineText: String) -> Bool {
        if relativePath == tokenTableFile { return true }
        if exemptFilePrefixes.contains(where: { relativePath.hasPrefix($0) }) { return true }
        if let expectedContent = exemptFileLineContents[relativePath], lineText.contains(expectedContent) {
            return true
        }
        return false
    }

    /// The directory this test scans, relative to the repo root — matches the
    /// task's scope: main-window chrome lives under `final final/`, not the
    /// QuickLook Extension target (a sibling directory, never visited here —
    /// its exemption entry above exists for `allExemptedPaths`'s liveness
    /// check, and as a defensive statement in case the scan root ever widens).
    static let scanRootComponent = "final final"

    /// Walks every `.swift` file under `<repoRoot>/final final/` and returns
    /// every raw-size violation found outside the exemptions, plus the total
    /// count of `.swift` files walked (for the vacuous-pass guard).
    static func scan(repoRoot: URL) -> (violations: [RawFontSizeViolation], filesWalked: Int) {
        let root = repoRoot.appendingPathComponent(scanRootComponent)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], 0)
        }

        var violations: [RawFontSizeViolation] = []
        var filesWalked = 0

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }

            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            filesWalked += 1
            let relative = relativePath(of: fileURL, repoRoot: repoRoot)

            let lines = contents.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let lineNumber = index + 1
                guard matches(line) else { continue }
                guard !isExempt(relativePath: relative, lineText: line) else { continue }
                violations.append(
                    RawFontSizeViolation(
                        relativePath: relative,
                        lineNumber: lineNumber,
                        lineText: line.trimmingCharacters(in: .whitespaces)
                    )
                )
            }
        }

        return (violations, filesWalked)
    }

    /// `fileURL`'s path relative to `repoRoot`, e.g. `final final/Views/StatusBar.swift`.
    static func relativePath(of fileURL: URL, repoRoot: URL) -> String {
        let full = fileURL.standardizedFileURL.path
        let rootPath = repoRoot.standardizedFileURL.path
        guard full.hasPrefix(rootPath) else { return full }
        var stripped = String(full.dropFirst(rootPath.count))
        if stripped.hasPrefix("/") { stripped.removeFirst() }
        return stripped
    }

    /// Locates the repo root from this test file's own on-disk path:
    /// `<repoRoot>/final finalTests/RawFontSizeLiteralTests.swift` — one
    /// `deletingLastPathComponent()` removes the filename, a second removes
    /// `final finalTests/`, leaving the repo root. Same convention as
    /// `FixtureGeneratorTests.swift`.
    static func repoRoot(from testFilePath: String = #filePath) -> URL {
        URL(fileURLWithPath: testFilePath)
            .deletingLastPathComponent()  // final finalTests/
            .deletingLastPathComponent()  // repo root
    }
}

// MARK: - Tests

@Suite("Raw font-size literal guard — UX contract §7")
struct RawFontSizeLiteralTests {

    /// The guard itself: fails, listing every offender, if any main-window
    /// chrome file still has a raw `.system(size:)`/`…ofSize:` numeric literal
    /// outside `Theme/Typography.swift` and the stated exemptions.
    @Test("No raw font-size literals outside Theme/Typography.swift and the stated exemptions")
    func noRawFontSizeLiteralsOutsideTypography() {
        let repoRoot = RawFontSizeScanner.repoRoot()
        let (violations, _) = RawFontSizeScanner.scan(repoRoot: repoRoot)
        #expect(
            violations.isEmpty,
            """
            Raw font-size literal(s) found outside Theme/Typography.swift and the exemption list. \
            Reference a TypeScale constant instead, or add a stated exemption to the plan/scanner if this is a genuine new case:
            \(violations.map(\.description).joined(separator: "\n"))
            """
        )
    }

    /// Vacuous-pass guard: an empty violation list is only meaningful if the
    /// scanner actually walked real files. Catches a broken repo-root
    /// computation or an empty/wrong scan root silently "passing" by finding
    /// nothing to check.
    @Test("Scanner walks a realistic number of .swift files under final final/")
    func scannerWalksARealisticFileCount() {
        let repoRoot = RawFontSizeScanner.repoRoot()
        let (_, filesWalked) = RawFontSizeScanner.scan(repoRoot: repoRoot)
        #expect(
            filesWalked > 20,
            """
            Scanner only walked \(filesWalked) .swift file(s) under final final/ — expected well over 20 \
            (204 at the time this guard was written). The scan root is likely wrong: \(repoRoot.path)
            """
        )
    }

    /// Pattern-discrimination guard: the regex must flag a known raw literal
    /// and must NOT flag the token-reference form call sites migrate to —
    /// otherwise every migrated call site in this task would itself trip the
    /// guard it's meant to satisfy.
    @Test("Pattern matches a raw literal and does not match a token reference")
    func patternDiscriminatesRawLiteralFromTokenReference() {
        #expect(RawFontSizeScanner.matches(".font(.system(size: 9))"))
        #expect(RawFontSizeScanner.matches("textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)"))
        #expect(!RawFontSizeScanner.matches(".font(.system(size: TypeScale.body))"))
        #expect(!RawFontSizeScanner.matches(".font(.system(size: TypeScale.chromeMicro, weight: .medium))"))
    }

    /// Exemption-liveness guard: every path the exemption list names must
    /// still exist on disk, so a rename or deletion of an exempted file
    /// doesn't silently narrow (or widen) what the scanner actually excludes.
    @Test("Every exempted path still exists on disk")
    func everyExemptedPathStillExists() {
        let repoRoot = RawFontSizeScanner.repoRoot()
        let fm = FileManager.default
        for relativePath in RawFontSizeScanner.allExemptedPaths {
            let url = repoRoot.appendingPathComponent(relativePath)
            #expect(fm.fileExists(atPath: url.path), "Exempted path no longer exists on disk: \(relativePath)")
        }
    }
}
