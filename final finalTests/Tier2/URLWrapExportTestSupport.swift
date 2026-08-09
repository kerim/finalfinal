//
//  URLWrapExportTestSupport.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//
//  Shared fixture paths and executable-discovery helpers for the URL-wrap-export test suite
//  (the URLWrap*Tests.swift files) -- factored out so each concern's test file doesn't
//  duplicate this lookup logic. See URLWrapExportTests.swift for the full feature background
//  comment shared by every file in this suite.
//
//  Resources are located relative to THIS source file (repo root), the same #filePath pattern
//  ImageCaptionExportTests.swift and FixtureGeneratorTests.swift use, since Bundle.main in a
//  unit-test host is the XCTest runner's own bundle, not the app's.
//

import Foundation

enum URLWrapExportFixtures {

    static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tier2/
            .deletingLastPathComponent()  // final finalTests/
            .deletingLastPathComponent()  // repo root
    }

    static var xurlWorkaroundTexPath: String {
        repoRoot().appendingPathComponent("final final/Resources/Export/xurl-workaround.tex").path
    }

    static var bundledTinyTeXURL: URL {
        repoRoot().appendingPathComponent("final final/Resources/TinyTeX")
    }

    static var bundledXelatexPath: String {
        bundledTinyTeXURL.appendingPathComponent("bin/universal-darwin/xelatex").path
    }

    static var linkifyUrlsLuaPath: String {
        repoRoot().appendingPathComponent("final final/Resources/Export/linkify-urls.lua").path
    }

    static var cslPath: String {
        repoRoot().appendingPathComponent("final final/Resources/Export/chicago-author-date.csl").path
    }

    static func findExecutable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func findPandocPath() -> String? {
        findExecutable(["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc", "/usr/bin/pandoc"])
    }

    static func findPdftotextPath() -> String? {
        findExecutable(["/opt/homebrew/bin/pdftotext", "/usr/local/bin/pdftotext", "/usr/bin/pdftotext"])
    }

    // Long, unbroken alphanumeric-only tail (no slashes/hyphens) -- the shape that overflowed
    // the margin in the reported bug.
    static let longURL = "https://example.com/articles/" +
        "aVeryLongUnbrokenAlphanumericTrackingParameterSegmentThatKeepsGoingAndGoing" +
        "WithNoNaturalBreakPointsWhatsoeverABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
}
