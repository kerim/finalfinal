//
//  MarkdownOnlyExportFilenameTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Coverage for `FileOperations.markdownExportURL(for:)` -- the pure filename-fixup helper
//  behind "Markdown Only" export's save panel. Before this helper existed, the inline fixup
//  only appended ".md" when the extension wasn't already "md", so a panel URL that already
//  carried some OTHER extension kept it: `savePanel.allowedContentTypes = [.plainText]` makes
//  NSSavePanel itself auto-append ".txt" (plain text's preferred extension) to a name typed
//  without an extension, so a document named "Notes" resolved to `savePanel.url` "Notes.txt"
//  before the fixup ever ran, and the export landed as "Notes.txt.md" instead of "Notes.md".
//  This function is pure and side-effect-free -- no `NSSavePanel` (a real, modal, screen-taking
//  window that must never run inside a headless unit test) -- so the panel's URL can be
//  simulated directly with a plain `URL` value.

import Testing
import Foundation
@testable import final_final

@Suite("Markdown Only export filename fixup — Tier 1: Silent Killers")
@MainActor
struct MarkdownOnlyExportFilenameTests {

    @Test("A panel URL carrying the .txt extension NSSavePanel auto-appends becomes <name>.md, not <name>.txt.md")
    func txtExtensionReplacedNotStacked() {
        let panelURL = URL(fileURLWithPath: "/tmp/Notes.txt")
        let fixed = FileOperations.markdownExportURL(for: panelURL)
        #expect(fixed.lastPathComponent == "Notes.md")
    }

    @Test("A project whose original filename carries an extension like .txt exports as <name>.md, not <name>.txt.md")
    func projectNameWithExtensionDoesNotDoubleExtend() {
        // Simulates a save panel default name derived from an original document called
        // "filename.txt" -- the exported file must be "filename.md", never "filename.txt.md".
        let panelURL = URL(fileURLWithPath: "/tmp/filename.txt")
        let fixed = FileOperations.markdownExportURL(for: panelURL)
        #expect(fixed.lastPathComponent == "filename.md")
        #expect(fixed.pathExtension == "md")
    }

    @Test("A user-typed .MD extension is recognized case-insensitively and left alone")
    func uppercaseMDExtensionRecognized() {
        let panelURL = URL(fileURLWithPath: "/tmp/Notes.MD")
        let fixed = FileOperations.markdownExportURL(for: panelURL)
        #expect(fixed.lastPathComponent == "Notes.MD")
    }

    @Test("A name with no extension at all gets .md appended")
    func noExtensionGetsMDAppended() {
        let panelURL = URL(fileURLWithPath: "/tmp/Untitled")
        let fixed = FileOperations.markdownExportURL(for: panelURL)
        #expect(fixed.lastPathComponent == "Untitled.md")
    }

    @Test("An already-correct .md extension is left untouched")
    func alreadyMDLeftUntouched() {
        let panelURL = URL(fileURLWithPath: "/tmp/Notes.md")
        let fixed = FileOperations.markdownExportURL(for: panelURL)
        #expect(fixed.lastPathComponent == "Notes.md")
    }
}
