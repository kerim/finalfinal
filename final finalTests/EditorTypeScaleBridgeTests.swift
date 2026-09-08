//
//  EditorTypeScaleBridgeTests.swift
//  final finalTests
//
//  Contract D14 lock test: "the type scale crosses the bridge like colours do" — sizes
//  and line heights are declared once, in Swift (`Theme/EditorTypeScale.swift`), and reach
//  the Milkdown/CodeMirror editors as CSS custom properties through the same
//  `AppColorScheme.cssVariables` -> `window.FinalFinal.setTheme()` channel colours already
//  use. Guards against the numbers drifting back into `web/shared/typography.css` or
//  silently diverging from the values the web layer actually renders with.
//
//  Five checks:
//  1a. Every theme's `cssVariables` actually carries the document type scale, computed
//      from `EditorTypeScale` — never retyped as literals here.
//  1b. No `.css` file under `web/` re-declares any of the bridged custom properties —
//      that redeclaration is exactly the drift this task closes.
//  1c. Every `var(--font-size-*|--line-height-*|--weight-*, <fallback>)` belt-and-braces
//      default anywhere under `web/` still matches `EditorTypeScale`'s current numbers, so
//      a future change in Swift can't silently leave a stale fallback behind.
//  1e. Every `var(--font-size-*|--line-height-*|--weight-*)` USAGE anywhere under `web/`
//      has a fallback at all (1c can only validate fallbacks that already exist — it
//      can't catch "no fallback at all", which is the actual first-paint bug: before
//      Swift's async `setTheme()` round-trip completes, an unfallen-back custom property
//      is "guaranteed invalid" and the declaration using it is ignored entirely, so e.g.
//      an un-fallback-ed `font-size: var(--font-size-h1)` doesn't render at *some* size —
//      it inherits, collapsing the heading to the parent's font size).
//  1d. Sanity guard: the scan actually walked a realistic number of real CSS files.
//

import Foundation
import Testing
@testable import final_final

// MARK: - Scanner

enum EditorTypeScaleBridgeScanner {

    // MARK: Declaration guard (1b)

    /// Matches a *declaration* line of one of the bridged custom properties, e.g.
    /// `  --font-size-h1: 31px;` — never a `var(--font-size-h1)` *usage*, which never
    /// starts the line with `--`.
    static let declarationPattern =
        #"^\s*--(font-size|line-height|weight)-[A-Za-z0-9-]+\s*:"#
    private static let declarationRegex = try! NSRegularExpression(pattern: declarationPattern)

    static func isDeclaration(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return declarationRegex.firstMatch(in: line, options: [], range: range) != nil
    }

    // MARK: Usage-with-fallback guard (1c)

    /// One `var(--font-size-body, 18px)`-style usage: the reconstructed variable name and
    /// the fallback text exactly as written (trimmed of surrounding whitespace).
    struct UsageMatch {
        let variableName: String
        let fallbackText: String
    }

    /// Matches `var(--font-size-body, 18px)`-style usages, capturing the category
    /// (`font-size`/`line-height`/`weight`), the rest of the variable name, and the
    /// fallback text up to the closing paren.
    static let usagePattern =
        #"var\(\s*--(font-size|line-height|weight)-([A-Za-z0-9-]+)\s*,\s*([^)]+)\)"#
    private static let usageRegex = try! NSRegularExpression(pattern: usagePattern)

    static func usageMatches(in line: String) -> [UsageMatch] {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        let matches = usageRegex.matches(in: line, options: [], range: range)
        return matches.compactMap { match -> UsageMatch? in
            guard let categoryRange = Range(match.range(at: 1), in: line),
                  let restRange = Range(match.range(at: 2), in: line),
                  let fallbackRange = Range(match.range(at: 3), in: line) else { return nil }
            let name = "--\(line[categoryRange])-\(line[restRange])"
            let fallback = line[fallbackRange].trimmingCharacters(in: .whitespaces)
            return UsageMatch(variableName: name, fallbackText: fallback)
        }
    }

    // MARK: No-fallback usage guard (1e)

    /// Matches a `var(--font-size-h1)`-style usage with NO fallback argument at all — no
    /// comma before the closing paren. This is what 1c structurally cannot catch: 1c's
    /// `usagePattern` requires a comma to match in the first place, so a usage missing a
    /// fallback entirely never shows up as a "stale fallback" — it just doesn't match
    /// anything. Deliberately anchored the same way `usagePattern` is (matches inside a
    /// `calc(...)` too, e.g. `calc(var(--font-size-body) * 0.85)`) so the two patterns
    /// agree on what counts as a "usage".
    static let noFallbackUsagePattern =
        #"var\(\s*--(font-size|line-height|weight)-([A-Za-z0-9-]+)\s*\)"#
    private static let noFallbackUsageRegex = try! NSRegularExpression(pattern: noFallbackUsagePattern)

    static func noFallbackUsageMatches(in line: String) -> [String] {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        let matches = noFallbackUsageRegex.matches(in: line, options: [], range: range)
        return matches.compactMap { match -> String? in
            guard let categoryRange = Range(match.range(at: 1), in: line),
                  let restRange = Range(match.range(at: 2), in: line) else { return nil }
            return "--\(line[categoryRange])-\(line[restRange])"
        }
    }

    // MARK: Comment stripping

    /// Strips `/* ... */` block comments (which may span multiple lines) before scanning,
    /// so a commented-out declaration or usage never counts as a real hit. Line breaks
    /// inside a stripped comment are preserved as blank lines so line numbers reported
    /// afterward still point at the right place in the original file.
    static func stripBlockComments(_ contents: String) -> String {
        var result = ""
        var remaining = Substring(contents)
        while let start = remaining.range(of: "/*") {
            result += remaining[remaining.startIndex..<start.lowerBound]
            let afterStart = remaining[start.upperBound...]
            guard let end = afterStart.range(of: "*/") else {
                // Unterminated comment: drop the rest of the file rather than misparse it.
                remaining = Substring("")
                break
            }
            let commentBody = afterStart[afterStart.startIndex..<end.lowerBound]
            result += String(repeating: "\n", count: commentBody.filter { $0 == "\n" }.count)
            remaining = afterStart[end.upperBound...]
        }
        result += remaining
        return result
    }

    // MARK: File walking

    /// Directories never descended into: dependency and build output. No CSS lives in
    /// either under `web/` today, but this keeps the guard honest if that ever changes.
    static let excludedDirNames: Set<String> = ["node_modules", "dist", "build"]

    /// Every file under `root` whose extension is in `extensions`, skipping the excluded
    /// directories above entirely (never descending into them).
    static func relevantFiles(under root: URL, extensions: Set<String>) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                if excludedDirNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard extensions.contains(url.pathExtension) else { continue }
            files.append(url)
        }
        return files
    }

    /// Locates the repo root by walking up from this test file's own on-disk path until a
    /// directory containing `project.yml` is found (falling back to two
    /// `deletingLastPathComponent()` hops — same convention as
    /// `RawFontSizeLiteralTests.swift`/`FixtureGeneratorTests.swift` — if that search ever
    /// comes up empty).
    static func repoRoot(from testFilePath: String = #filePath) -> URL {
        var dir = URL(fileURLWithPath: testFilePath).deletingLastPathComponent()
        let fm = FileManager.default
        while dir.pathComponents.count > 1 {
            if fm.fileExists(atPath: dir.appendingPathComponent("project.yml").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: testFilePath)
            .deletingLastPathComponent()  // final finalTests/
            .deletingLastPathComponent()  // repo root
    }

    /// `fileURL`'s path relative to `repoRoot`, e.g. `web/shared/typography.css`.
    static func relativePath(of fileURL: URL, repoRoot: URL) -> String {
        let full = fileURL.standardizedFileURL.path
        let rootPath = repoRoot.standardizedFileURL.path
        guard full.hasPrefix(rootPath) else { return full }
        var stripped = String(full.dropFirst(rootPath.count))
        if stripped.hasPrefix("/") { stripped.removeFirst() }
        return stripped
    }
}

// MARK: - Tests

@Suite("Editor type-scale CSS bridge — UX contract D14")
struct EditorTypeScaleBridgeTests {

    /// The fallback values every belt-and-braces `var(..., fallback)` usage under `web/`
    /// must match. Built entirely from `EditorTypeScale` — via its own `pxString`/
    /// `decimalString` formatters, not reimplemented here, so a future formatting change
    /// (e.g. rounding) can't silently diverge between production code and this test — a
    /// stale literal here would be as much a bug as a stale one in the web files this
    /// checks.
    static func expectedFallbackValues() -> [String: String] {
        [
            "--font-size-body": EditorTypeScale.pxString(EditorTypeScale.body),
            "--font-size-h1": EditorTypeScale.pxString(EditorTypeScale.h1),
            "--font-size-h2": EditorTypeScale.pxString(EditorTypeScale.h2),
            "--font-size-h3": EditorTypeScale.pxString(EditorTypeScale.h3),
            "--font-size-h4": EditorTypeScale.pxString(EditorTypeScale.h4),
            "--font-size-h5": EditorTypeScale.pxString(EditorTypeScale.h5),
            "--font-size-h6": EditorTypeScale.pxString(EditorTypeScale.h6),
            "--line-height-body": EditorTypeScale.decimalString(EditorTypeScale.lineHeightBody),
            "--line-height-heading": EditorTypeScale.decimalString(EditorTypeScale.lineHeightHeading),
            // The belt-and-braces fallbacks in web/ are the light-theme weights: the base
            // stylesheet has no notion of the current theme, unlike AppColorScheme's
            // per-theme `typographyCssVariables`.
            "--weight-heading": "\(EditorTypeScale.weightHeadingLight)",
            "--weight-body": "\(EditorTypeScale.weightBodyLight)",
        ]
    }

    // MARK: - 1a. Swift -> CSS variable bridge

    @Test("Every theme's cssVariables carries the document type scale, sourced from EditorTypeScale")
    func everyThemeCarriesTheEditorTypeScale() {
        for theme in AppColorScheme.all {
            let css = theme.cssVariables
            let weightHeading = theme.isDarkTheme ? EditorTypeScale.weightHeadingDark : EditorTypeScale.weightHeadingLight
            let weightBody = theme.isDarkTheme ? EditorTypeScale.weightBodyDark : EditorTypeScale.weightBodyLight

            let expectedDeclarations: [String] = [
                "--font-size-body: \(EditorTypeScale.pxString(EditorTypeScale.body));",
                "--font-size-h1: \(EditorTypeScale.pxString(EditorTypeScale.h1));",
                "--font-size-h2: \(EditorTypeScale.pxString(EditorTypeScale.h2));",
                "--font-size-h3: \(EditorTypeScale.pxString(EditorTypeScale.h3));",
                "--font-size-h4: \(EditorTypeScale.pxString(EditorTypeScale.h4));",
                "--font-size-h5: \(EditorTypeScale.pxString(EditorTypeScale.h5));",
                "--font-size-h6: \(EditorTypeScale.pxString(EditorTypeScale.h6));",
                "--line-height-body: \(EditorTypeScale.decimalString(EditorTypeScale.lineHeightBody));",
                "--line-height-heading: \(EditorTypeScale.decimalString(EditorTypeScale.lineHeightHeading));",
                "--weight-heading: \(weightHeading);",
                "--weight-body: \(weightBody);",
            ]

            for expectation in expectedDeclarations {
                #expect(
                    css.contains(expectation),
                    "Theme \"\(theme.id)\": expected cssVariables to contain \"\(expectation)\", got:\n\(css)"
                )
            }
        }
    }

    // MARK: - 1b. No redeclaration in web/

    @Test("No CSS file under web/ re-declares a bridged type-scale variable")
    func noCssFileRedeclaresTheTypeScale() {
        let repoRoot = EditorTypeScaleBridgeScanner.repoRoot()
        let webRoot = repoRoot.appendingPathComponent("web")
        let cssFiles = EditorTypeScaleBridgeScanner.relevantFiles(under: webRoot, extensions: ["css"])

        var violations: [String] = []
        for file in cssFiles {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let stripped = EditorTypeScaleBridgeScanner.stripBlockComments(contents)
            let relative = EditorTypeScaleBridgeScanner.relativePath(of: file, repoRoot: repoRoot)
            let lines = stripped.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                guard EditorTypeScaleBridgeScanner.isDeclaration(line) else { continue }
                violations.append("\(relative):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        #expect(
            violations.isEmpty,
            """
            Found a CSS declaration of a bridged type-scale variable under web/. These are injected \
            at runtime from Theme/EditorTypeScale.swift (ux-contract D14) and must not be redeclared \
            in the stylesheet:
            \(violations.joined(separator: "\n"))
            """
        )
    }

    // MARK: - 1c. Belt-and-braces fallbacks stay in sync

    @Test("Every var(..., fallback) belt-and-braces default under web/ matches EditorTypeScale")
    func everyCssFallbackMatchesEditorTypeScale() {
        let repoRoot = EditorTypeScaleBridgeScanner.repoRoot()
        let webRoot = repoRoot.appendingPathComponent("web")
        let files = EditorTypeScaleBridgeScanner.relevantFiles(under: webRoot, extensions: ["css", "ts"])
        let expected = Self.expectedFallbackValues()

        var violations: [String] = []
        var fallbackUsagesFound = 0

        for file in files {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let scanned = file.pathExtension == "css"
                ? EditorTypeScaleBridgeScanner.stripBlockComments(contents)
                : contents
            let relative = EditorTypeScaleBridgeScanner.relativePath(of: file, repoRoot: repoRoot)
            let lines = scanned.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                for match in EditorTypeScaleBridgeScanner.usageMatches(in: line) {
                    fallbackUsagesFound += 1
                    guard let expectedValue = expected[match.variableName] else {
                        violations.append(
                            "\(relative):\(index + 1): var(\(match.variableName), ...) is not a variable " +
                            "EditorTypeScale (or this test's expected-value map) knows about"
                        )
                        continue
                    }
                    if match.fallbackText != expectedValue {
                        violations.append(
                            "\(relative):\(index + 1): var(\(match.variableName), \(match.fallbackText)) fallback " +
                            "is stale — EditorTypeScale currently says \(expectedValue)"
                        )
                    }
                }
            }
        }

        #expect(
            fallbackUsagesFound >= 5,
            """
            Scanner found only \(fallbackUsagesFound) var(..., fallback) usage(s) under web/ — expected \
            the ~15 known belt-and-braces defaults. The scan is likely broken: \(webRoot.path)
            """
        )
        #expect(
            violations.isEmpty,
            "Stale or unrecognized CSS variable fallback(s) found under web/:\n\(violations.joined(separator: "\n"))"
        )
    }

    // MARK: - 1e. Every bridged var() usage has a fallback at all

    /// Usages allowed to skip a fallback, as `"path/relative/to/repo:lineNumber"`. Empty
    /// today — every bridged usage under `web/` has a belt-and-braces default, because
    /// `setTheme()` is an async round-trip after page load and an un-fallback-ed custom
    /// property is CSS "guaranteed-invalid": the whole declaration is dropped and the
    /// property inherits, not "renders at some size". If a genuinely fallback-free usage
    /// is ever added, list it here with a comment explaining why it's safe (e.g. a
    /// property only ever read after `setTheme()` has definitely already run).
    static let noFallbackAllowlist: Set<String> = []

    @Test("Every var(--font-size-*|--line-height-*|--weight-*) usage under web/ has a fallback")
    func everyBridgedVarUsageHasAFallback() {
        let repoRoot = EditorTypeScaleBridgeScanner.repoRoot()
        let webRoot = repoRoot.appendingPathComponent("web")
        let files = EditorTypeScaleBridgeScanner.relevantFiles(under: webRoot, extensions: ["css", "ts"])

        var violations: [String] = []

        for file in files {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let scanned = file.pathExtension == "css"
                ? EditorTypeScaleBridgeScanner.stripBlockComments(contents)
                : contents
            let relative = EditorTypeScaleBridgeScanner.relativePath(of: file, repoRoot: repoRoot)
            let lines = scanned.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let lineNumber = index + 1
                let key = "\(relative):\(lineNumber)"
                guard !Self.noFallbackAllowlist.contains(key) else { continue }
                for variableName in EditorTypeScaleBridgeScanner.noFallbackUsageMatches(in: line) {
                    violations.append("\(key): var(\(variableName)) has no fallback argument")
                }
            }
        }

        #expect(
            violations.isEmpty,
            """
            Found a bridged type-scale var() usage under web/ with no fallback at all. Until \
            Swift's setTheme() round-trip completes after page load, an un-fallen-back custom \
            property is CSS "guaranteed-invalid" -- the whole declaration is dropped and the \
            property inherits instead of rendering at any particular size. Add a literal fallback \
            matching EditorTypeScale (e.g. var(--font-size-h1, 31px)), or add the exact \
            "path:line" to noFallbackAllowlist with a comment saying why it's safe:
            \(violations.joined(separator: "\n"))
            """
        )
    }

    // MARK: - 1d. Vacuous-pass guard

    @Test("Scanner walks a realistic number of CSS files under web/")
    func scannerWalksARealisticCssFileCount() {
        let repoRoot = EditorTypeScaleBridgeScanner.repoRoot()
        let webRoot = repoRoot.appendingPathComponent("web")
        let cssFiles = EditorTypeScaleBridgeScanner.relevantFiles(under: webRoot, extensions: ["css"])
        #expect(
            cssFiles.count >= 5,
            """
            Scanner only found \(cssFiles.count) CSS file(s) under web/ — expected at least 5. \
            The scan root is likely wrong: \(webRoot.path)
            """
        )
    }
}
