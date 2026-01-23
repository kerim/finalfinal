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
