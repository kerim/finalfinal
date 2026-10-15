//
//  ContentView+VersionHistory.swift
//  final final
//
//  Save Version handling and the content-flush helpers project switch/close and Save Version
//  share. Split out of ContentView+ProjectLifecycle.swift to keep that file under SwiftLint's
//  file_length limit. Mechanical move only -- no behavior change.
//

import SwiftUI

extension ContentView {
    // MARK: - Version History Handlers

    /// Handle save version command (Cmd+Shift+S)
    func handleSaveVersion() async {
        guard let db = documentManager.projectDatabase,
              let pid = documentManager.projectId else {
            DebugLog.log(.lifecycle, "[ContentView] Cannot save version: no project open")
            return
        }

        // Flush the freshest possible WebView content into the block table before the
        // snapshot reads it -- the same staleness gap fixed for export (incremental
        // block-sync diff alone can silently drop a pure block move). See
        // EditorViewState+Zoom.swift's flushLiveContentToDatabase(currentContent:).
        await editorState.flushLiveContentToDatabase {
            await editorState.blockSyncService?.fetchContentFromWebView()
        }

        // Ensure sections are synced before snapshot (debounce may not have fired yet).
        // fromEditorChange: true — by the time this fires the content is definitionally the
        // user's real, settled state (not a pre-round-trip programmatic sync), so a real edit
        // immediately followed by Save Version must still reach Getting Started edit-detection.
        await sectionSyncService.syncNow(editorState.content, fromEditorChange: true)

        let name = saveVersionName.isEmpty ? nil : saveVersionName
        let service = SnapshotService(database: db, projectId: pid)

        do {
            if let versionName = name {
                let snapshot = try service.createManualSnapshot(name: versionName)
                DebugLog.log(.lifecycle, "[ContentView] Created manual snapshot: \(snapshot.displayName)")
                // §4.1.2 names this string verbatim as one of only two canonical toast examples.
                withAnimation {
                    ToastCenter.shared.show(ToastFactory.versionSaved())
                }
            } else {
                if let snapshot = try service.createAutoSnapshot() {
                    DebugLog.log(.lifecycle, "[ContentView] Created auto snapshot: \(snapshot.id)")
                    withAnimation {
                        ToastCenter.shared.show(ToastFactory.versionSaved())
                    }
                } else {
                    DebugLog.log(.lifecycle, "[ContentView] Auto snapshot skipped: content unchanged")
                }
            }
        } catch {
            DebugLog.log(.lifecycle, "[ContentView] Failed to create snapshot: \(error)")
            // §4.1: a failure the user would care about must be visible, not just logged.
            withAnimation {
                ToastCenter.shared.show(ToastFactory.versionSaveFailed())
            }
        }

        saveVersionName = ""
    }
}
