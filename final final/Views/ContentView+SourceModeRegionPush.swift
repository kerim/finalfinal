//
//  ContentView+SourceModeRegionPush.swift
//  final final
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), round 4, O28/O29/O30: the ContentView side of
//    - the REGION-SCOPED push of the Notes and Bibliography into the Markdown editor (the three rebuild handlers call
//      `markdownRegionRead()` on the line where they stamp their read and `pushRebuildToMarkdownEditor` instead of the whole-text
//      assignment and `updateSourceContentIfNeeded()`), and
//    - the OWED PULL of the page's live text (`runOwedMarkdownPull`, run at the next idle and after the 150 ms grace).
//  The decisions live in `MarkdownManagedRegions`, `MarkdownManagedRegionPusher` and `MarkdownOwedPull` (unit-tested); this file only
//  wires them to the page and the editor state. The handlers keep their Rich Text code byte for byte.
//

import SwiftUI
import WebKit

extension ContentView {

    // MARK: - The page

    /// The pusher wired to this window: JavaScript through the active (CodeMirror) web view, adoption through the one adopter.
    @MainActor
    func markdownRegionPusher() -> MarkdownManagedRegionPusher {
        let findBarState = findBarState
        let editorState = editorState
        return MarkdownManagedRegionPusher(
            evaluate: { script in
                guard let webView = findBarState.activeWebView, let answer = try? await webView.evaluateJavaScript(script) else {
                    return nil
                }
                return answer as? String
            },
            adopt: { raw in editorState.adoptMarkdownPageText(raw) })
    }

    // MARK: - O28: the region push

    /// What the editor holds in its Notes and Bibliography right now, from the content record: the `expectedOld` of a rebuild that is
    /// about to read the rows. Call it on the line right after `stampRebuildRead()` (no `await` between). nil outside non-zoomed Markdown
    /// mode: the rebuild then takes its existing path.
    @MainActor
    func markdownRegionRead() -> MarkdownRegionSnapshot? {
        guard editorState.editorMode == .source, editorState.zoomedSectionId == nil, editorState.markdownWriter.isEnabled,
              let pid = documentManager.projectId else { return nil }
        return MarkdownManagedRegions.snapshot(
            markdown: editorState.content, projectId: pid, notesTitle: notesHeadingTitle(projectId: pid))
    }

    @MainActor
    private func notesHeadingTitle(projectId: String) -> String? {
        guard let database = documentManager.projectDatabase else { return nil }
        return try? database.fetchNotesHeadingTitle(projectId: projectId)
    }

    /// The Markdown replacement for a rebuild's `content = result.markdown; updateSourceContentIfNeeded()` plus its Milkdown push.
    /// Pushes each of `regions` as a region replace (`expectedOld` from `read`, `newText` from the text the rebuild assembled from the
    /// rows), adopts the page's reply (O30), and never assigns the rows' text to the content record.
    ///   - the stamp went stale (a click or a job is unapplied): nothing is pushed, `noteStalePushSkipped` raises the re-push owed;
    ///   - `.stale` / `.failed`: nothing was written, `managedRegionsNeedRepush` is raised;
    ///   - the region does not exist yet in the editor's text (the first footnote or citation): the existing whole-text path runs, but
    ///     only while the stamp is still current (a stale stamp reports `staleSkipped` instead, review F1, so a Delete's unapplied
    ///     job is never overwritten by the rows' text).
    ///     KNOWN LIMIT: that one push still replaces the whole document (typing made in the rebuild's window can be lost, as before).
    @MainActor
    func pushRebuildToMarkdownEditor(
        _ regions: [MarkdownManagedRegion],
        result: BlockFetchResult,
        read: MarkdownRegionSnapshot,
        stamp: RebuildReadStamp,
        kind: String
    ) async {
        guard let pid = documentManager.projectId else { return }
        let fresh = MarkdownManagedRegions.snapshot(
            markdown: result.markdown, projectId: pid, notesTitle: notesHeadingTitle(projectId: pid))
        let report = await markdownRegionPusher().pushRebuild(
            regions: regions, read: read, fresh: fresh, stillWanted: { editorState.rebuildPushStillWanted(stamp) })
        if report.staleSkipped {
            editorState.noteStalePushSkipped(stamp, kind: kind)
        }
        if report.repushOwed {
            DebugLog.log(.lifecycle, "[MdRegionPush] \(kind): a region push was not applied; re-push owed")
            editorState.managedRegionsNeedRepush = true
        }
        if report.wholeTextFallback, !report.staleSkipped {
            // The editor has no such region yet: only the whole-text path can create it (plan D-8). KNOWN LIMIT, see the pusher.
            DebugLog.log(.lifecycle, "[MdRegionPush] \(kind): no region in the editor yet; whole-text push")
            editorState.content = result.markdown
            updateSourceContentIfNeeded()
        }
    }

    // MARK: - O29: the owed pull

    /// Pulls the page's live text into the content record and re-arms the re-parse, if a pull is owed and the editor state allows it
    /// (`MarkdownOwedPull`). Run at every idle transition and after the 150 ms grace of a dropped `contentChanged`.
    @MainActor
    func runOwedMarkdownPull() async {
        let editorState = editorState
        let projectId = editorState.currentProjectId
        let pusher = markdownRegionPusher()
        _ = await MarkdownOwedPull.runIfOwed(
            writer: editorState.markdownWriter,
            gate: {
                // A lifecycle, a project change, leaving Markdown mode and zoom are not drops of typing: they save the live text
                // themselves, and a pull after teardown would act on a dead editor.
                guard editorState.markdownWriter.isEnabled, editorState.editorMode == .source, editorState.zoomedSectionId == nil,
                      editorState.activeLifecycle == nil, editorState.currentProjectId == projectId else { return .abandon }
                return editorState.contentState == .idle && !editorState.isResettingContent ? .proceed : .retryAtIdle
            },
            readLive: { await pusher.evaluate("window.FinalFinal.getContentRaw()") },
            adopt: { editorState.adoptMarkdownPageText($0) },
            arm: {
                editorState.lifecycleHost?.scheduleSourceModeReparse(editorState.content)
                editorState.markdownWriter.requestRefire()
            })
    }

    /// A `contentChanged` was dropped: the writer owes a pull. When the content state is idle already (the 150 ms grace dropped it), no
    /// idle transition follows, so the pull runs after the grace; a busy state runs it at its next idle (`handleContentStateChange`).
    @MainActor
    func noteMarkdownContentPushDropped() {
        editorState.markdownWriter.notePullOwed("a page contentChanged was dropped")
        guard editorState.contentState == .idle, !editorState.isResettingContent else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            await runOwedMarkdownPull()
        }
    }
}
