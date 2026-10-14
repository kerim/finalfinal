//
//  ComplexDocumentFixture+SwitchInputs.swift
//  final finalTests
//
//  The part of the shared complex-document fixture that needs the app (ComplexDocumentFixture.swift itself is
//  Foundation-only): the rows the database would hold for the document, the editor text assembled from them, and
//  the section list with the character offsets that a Rich Text -> Markdown switch computes before it injects the
//  section anchors (`handleEditorModeToggle`, ViewNotificationModifiers.swift: sort by sortOrder with headings
//  first, drop empty fragments, offset += fragment length + 2 per block). Used by ModeSwitchTextRoundTripTests and
//  SectionAnchorInjectionTests.
//

import Foundation
@testable import final_final

extension ComplexDocumentFixture {

    static let projectId = "complex-document-fixture"

    /// `BlockParser.parse` with the names it would otherwise read from the shared export settings passed in, so a test never depends on
    /// (or races with) the process-wide settings store: the shipped default bibliography heading, no grace names, the default Notes heading.
    static func parse(_ markdown: String) -> [Block] {
        BlockParser.parse(
            markdown: markdown, projectId: projectId, bibliographyHeaderName: "Bibliography", graceNames: [], notesHeaderName: "Notes")
    }

    struct SwitchInputs {
        /// The rows the database holds for the document once the app has generated its bibliography.
        let storedBlocks: [Block]
        /// `editorState.content` in Rich Text mode: the stored rows assembled for the editor (end marker included).
        let content: String
        /// Every outline block (heading or section break) as a section, as `editorState.sections` holds them: no offsets yet.
        let sectionsToInject: [SectionViewModel]
        /// The same sections with `startOffset` set to the character offset of their block in `content`, in outline order.
        let adjustedSections: [SectionViewModel]
    }

    /// The inputs of a Rich Text -> Markdown switch for `document`, built the way `handleEditorModeToggle` builds them.
    @MainActor
    static func switchInputs(for document: Document) -> SwitchInputs {
        switchInputs(storedBlocks: parse(document.editorMarkdown))
    }

    /// The inputs of a Rich Text -> Markdown switch for rows the database holds NOW (any rows, for example after earlier switches
    /// rewrote some of them), built the way `handleEditorModeToggle` builds them. `for document:` above is this with the rows the
    /// fixture's own text parses to.
    @MainActor
    static func switchInputs(storedBlocks stored: [Block]) -> SwitchInputs {
        let content = BlockParser.assembleMarkdownForEditor(from: stored)
        let outline = stored
            .filter { $0.blockType == .heading || $0.isPseudoSection }
            .sorted { ($0.isBibliography ? 1 : 0, $0.sortOrder) < ($1.isBibliography ? 1 : 0, $1.sortOrder) }
        let sectionsToInject = outline.map { SectionViewModel(from: $0) }

        // The offsets, exactly as the toggle computes them from the fetched rows.
        let sorted = stored.sorted { first, second in
            let firstKey = (first.sortOrder, first.blockType == .heading ? 0 : 1)
            let secondKey = (second.sortOrder, second.blockType == .heading ? 0 : 1)
            return firstKey < secondKey
        }
        let nonEmpty = sorted.filter { !BlockParser.isEmptyFragment($0.markdownFragment) }
        var blockOffset: [String: Int] = [:]
        var offset = 0
        for (index, block) in nonEmpty.enumerated() {
            if index > 0 { offset += 2 }
            blockOffset[block.id] = offset
            offset += block.markdownFragment.count
        }
        var adjusted: [SectionViewModel] = []
        for section in sectionsToInject.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            if let startOffset = blockOffset[section.id] {
                adjusted.append(section.withUpdates(startOffset: startOffset))
            }
        }
        return SwitchInputs(storedBlocks: stored, content: content, sectionsToInject: sectionsToInject, adjustedSections: adjusted)
    }
}
