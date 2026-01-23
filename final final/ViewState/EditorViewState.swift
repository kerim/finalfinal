//
//  EditorViewState.swift
//  final final
//

import SwiftUI

enum EditorMode: String, CaseIterable {
    case wysiwyg = "WYSIWYG"
    case source = "Source"
}

@MainActor
@Observable
class EditorViewState {
    var editorMode: EditorMode = .wysiwyg
    var focusModeEnabled: Bool = false
    var zoomedSectionId: String? = nil
    var wordCount: Int = 0
    var characterCount: Int = 0
    var currentSectionName: String = ""

    // MARK: - Content
    var content: String = ""

    // MARK: - Scroll Request
    var scrollToOffset: Int? = nil

    // MARK: - Stats Update
    func updateStats(words: Int, characters: Int) {
        wordCount = words
        characterCount = characters
    }

    func scrollTo(offset: Int) {
        scrollToOffset = offset
    }

    func clearScrollRequest() {
        scrollToOffset = nil
    }

    func toggleEditorMode() {
        editorMode = editorMode == .wysiwyg ? .source : .wysiwyg
    }

    func toggleFocusMode() {
        focusModeEnabled.toggle()
    }

    func zoomToSection(_ sectionId: String) {
        zoomedSectionId = sectionId
    }

    func zoomOut() {
        zoomedSectionId = nil
    }
}
