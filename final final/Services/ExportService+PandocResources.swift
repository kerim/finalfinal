//
//  ExportService+PandocResources.swift
//  final final
//

import Foundation

// MARK: - Bundle Resource Helpers

extension ExportService {

    /// Check if bundled export resources are available
    static func bundledResourcesAvailable() -> Bool {
        let luaPath = Bundle.main.url(forResource: "zotero", withExtension: "lua", subdirectory: "Export")
        let refPath = Bundle.main.url(forResource: "reference", withExtension: "docx", subdirectory: "Export")
        return luaPath != nil && refPath != nil
    }

    /// Get path to bundled Lua script
    static var bundledLuaScriptPath: String? {
        Bundle.main.url(forResource: "zotero", withExtension: "lua", subdirectory: "Export")?.path
    }

    /// Get path to the bundled PDF-only figure-placement Lua filter (pins captioned figures
    /// to `[H]` so they no longer float past following text at page breaks).
    static var bundledFigurePlacementLuaPath: String? {
        Bundle.main.url(forResource: "figure-placement", withExtension: "lua", subdirectory: "Export")?.path
    }

    /// Get path to the bundled `\usepackage{float}` header snippet required for the
    /// `[H]` placement specifier applied by figure-placement.lua to compile.
    static var bundledFloatPackageTexPath: String? {
        Bundle.main.url(forResource: "float-package", withExtension: "tex", subdirectory: "Export")?.path
    }

    /// Get path to the bundled URL-line-breaking header snippet. Reproduces the `xurl` LaTeX
    /// package's URL-breaking behavior (extending `url.sty`'s `\UrlBreaks`) without bundling
    /// `xurl.sty` itself, which isn't part of this app's TinyTeX distribution -- see
    /// xurl-workaround.tex for the full rationale.
    static var bundledXurlWorkaroundTexPath: String? {
        Bundle.main.url(forResource: "xurl-workaround", withExtension: "tex", subdirectory: "Export")?.path
    }

    /// Get path to the bundled document-wide linkify-urls Lua filter (see linkify-urls.lua).
    /// Converts any bare URL-shaped `Str` inline anywhere in the document into a real `Link`,
    /// so it gets the `\UrlBreaks` wrap protection from xurl-workaround.tex, which only applies
    /// to real `\url{}`/`\href{}` content, never to plain text -- fixes the page-margin overflow
    /// for citation-field URLs (e.g. Zotero's "archive" field) and bare URLs typed in body text.
    static var bundledLinkifyUrlsLuaPath: String? {
        Bundle.main.url(forResource: "linkify-urls", withExtension: "lua", subdirectory: "Export")?.path
    }

    /// Get path to the bundled PDF-only filter that flattens bare (unbracketed) `@citekey`
    /// citations back to literal text, so they match DOCX/ODT rather than rendering as a
    /// broken `\textbf{key?}` marker under --citeproc. See the file's own header comment.
    static var bundledBareCitationsLuaPath: String? {
        Bundle.main.url(forResource: "bare-citations-literal", withExtension: "lua", subdirectory: "Export")?.path
    }

    /// Get path to the bundled PDF-only filter that escapes the TeX-special characters `&`,
    /// `#`, and `%` inside math spans, so they don't crash xelatex (or, for `%`, silently
    /// truncate the rest of the line) when they appear unescaped in inline/display math. See
    /// the file's own header comment for the confirmed failure modes and the alignment-
    /// environment exemption.
    static var bundledMathSpecialCharsLuaPath: String? {
        Bundle.main.url(forResource: "math-special-chars", withExtension: "lua", subdirectory: "Export")?.path
    }

    /// Get path to bundled reference document
    static var bundledReferenceDocPath: String? {
        Bundle.main.url(forResource: "reference", withExtension: "docx", subdirectory: "Export")?.path
    }

    /// Get path to bundled CSL citation style
    static var bundledCSLStylePath: String? {
        Bundle.main.url(forResource: "chicago-author-date", withExtension: "csl", subdirectory: "Export")?.path
    }

    /// Get path to bundled TinyTeX xelatex binary (direct path, may fail if app path has spaces)
    static var bundledXelatexPath: String? {
        // xelatex is a symlink to xetex in TinyTeX
        Bundle.main.url(forResource: "xelatex", withExtension: nil, subdirectory: "TinyTeX/bin/universal-darwin")?.path
    }

    /// Get URL to bundled TinyTeX directory
    static var bundledTinyTeXURL: URL? {
        Bundle.main.url(forResource: "TinyTeX", withExtension: nil, subdirectory: nil)
    }
}

// MARK: - TinyTeX Symlink Preparation

extension ExportService {

    /// Prepare bundled TinyTeX for use via symlink and XeTeX's -output-driver option.
    /// This avoids issues when the app bundle path contains spaces (e.g., "final final.app").
    ///
    /// The problem: xelatex internally calls xdvipdfmx via shell without quoting the path.
    /// If the path contains spaces, the shell command breaks.
    ///
    /// The solution: XeTeX's documented `-output-driver` option specifies the command
    /// used to convert XDV to PDF. We create an xdvipdfmx wrapper at a space-free path
    /// and tell xelatex to use it via this option.
    ///
    /// Reference: https://mirrors.mit.edu/CTAN/info/xetexref/xetex-reference.pdf
    ///
    /// - Returns: Tuple of (xelatex path, output-driver argument), or nil if unavailable
    func prepareBundledTinyTeX() throws -> (xelatexPath: String, outputDriverArg: String)? {
        guard let bundledTinyTeXURL = ExportService.bundledTinyTeXURL else {
            return nil
        }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory

        // Per-export unique suffix. These paths used to be fixed/shared across every PDF
        // export, so two overlapping exports would remove and recreate each other's symlink
        // and wrapper mid-flight — a real, demonstrated bug (concurrent exports crashing).
        // A unique suffix per call gives every export its own private symlink and wrapper,
        // eliminating the shared mutable state instead of trying to lock around it.
        let uniqueSuffix = UUID().uuidString

        // Create symlink to TinyTeX in temp directory (no spaces in path)
        let symlinkURL = tempDir.appendingPathComponent("TinyTeX-\(uniqueSuffix)")
        try? fm.removeItem(at: symlinkURL)
        try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: bundledTinyTeXURL)

        // Paths via symlink (no spaces)
        let tinyTeXBin = symlinkURL.appendingPathComponent("bin/universal-darwin").path

        // Create xdvipdfmx wrapper that properly calls the real binary
        // This wrapper is at a space-free path, so xelatex can invoke it safely
        let xdvipdfmxWrapperURL = tempDir.appendingPathComponent("xdvipdfmx-wrapper-\(uniqueSuffix)")
        let xdvipdfmxWrapper = """
            #!/bin/bash
            exec "\(tinyTeXBin)/xdvipdfmx" "$@"
            """
        try? fm.removeItem(at: xdvipdfmxWrapperURL)
        try xdvipdfmxWrapper.write(to: xdvipdfmxWrapperURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xdvipdfmxWrapperURL.path)

        // Return xelatex path via symlink (for package resolution) and output-driver argument
        let xelatexPath = tinyTeXBin + "/xelatex"
        let outputDriverArg = "-output-driver=\(xdvipdfmxWrapperURL.path)"

        return (xelatexPath, outputDriverArg)
    }
}
