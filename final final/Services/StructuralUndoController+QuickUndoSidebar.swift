//
//  StructuralUndoController+QuickUndoSidebar.swift
//  final final
//
//  t-94369a83 Phase 4b, slice 2b (addendum A16): the sidebar side of a quick undo. The restored leaders leave the pending-removal
//  filter and are shown again: inserted into `sections`, and kept in an overlay (with the document anchor they go after,
//  `SidebarRestoreOverlay`) that the outline results merge in until the reinsert has put their rows back
//  (`EditorViewState.pendingRestoreSections`). Their rows come from the payload holder when the delete job has applied; otherwise (the
//  delete job has not run yet) the database still holds them, and they are read from there.
//
//  WHEN. The editor already shows the section when the restore reply arrives; the sidebar update (the section list, the parent
//  relationships, the outline refresh) is a main-thread stretch of 110-240 ms on a long book that gates WebKit's next frame, so it
//  waits for that frame (the page's next animation frame plus a task, at most 300 ms) and the editor paints the restored section
//  first (VM measurement, 12-chapter book: key to painted 218 ms median before, 63 ms after). With no web view attached (a unit test)
//  there is nothing to paint and the update runs at once.
//
//  WHAT KEEPS IT CONSISTENT while the update is waiting:
//    * the leaders stay in `pendingRemovalIds`, so an outline tick that lands in the window still shows the post-delete list (valid);
//    * `EditorViewState.pendingSidebarRestoreCount` is up for the whole window (and `pendingReinsertCount` until the reinsert's job
//      resolves), so hierarchy enforcement does not run on the list (`ContentView.hierarchyEnforcementWaitsForQuickUndo`);
//    * the reinsert's task awaits the update before its settle runs, so the unsettled marker of the reinsert (close, quit, project
//      switch, zoom, mode switch, Save Version, export and every flush wait for it) covers the window, and the settle (which clears
//      the overlay) can never run before the update that would set it;
//    * the update is dropped when the entry's epoch has moved (a quick redo or a later undo took the entry) or the project changed;
//    * the overlay is set only while the reinsert's job future is unresolved, so an entry that has already settled never gets an
//      overlay nobody would clear.
//

import Foundation
import GRDB
import WebKit

/// What the sidebar needs to show a quick-undone section again.
struct RestoredSidebarSections {
    let opId: UUID
    /// The section's leaders in document order (the payload holder's, or read from the database).
    let leaders: [Block]
    let anchor: RestoreAnchor?
    /// Ids that leave the pending-removal filter: the restored leaders and the click's own leaders.
    let releasedIds: Set<String>
}

extension StructuralUndoController {

    /// Shows the restored section in the sidebar: once the editor has painted it (see the header), or at once when there is no web
    /// view. `reinsertKey` and `epoch` are the quick undo's own. Returns the task that will run the update (nil when it ran already);
    /// the reinsert's task awaits it before its settle.
    @discardableResult
    func showRestoredSections( // swiftlint:disable:this function_parameter_count
        opId: UUID, reinsertKey: UUID, epoch: Int, holder: SectionDeletePayloadHolder,
        restoredLeaderIds: Set<String>, database db: ProjectDatabase
    ) -> Task<Void, Never>? {
        guard let editorState else { return nil }
        let state = holder.snapshot()
        var leaders = state.leaders
        if leaders.isEmpty, !restoredLeaderIds.isEmpty {
            leaders = (try? db.read { try Block.filter(keys: Array(restoredLeaderIds)).fetchAll($0) }) ?? []
        }
        let update = RestoredSidebarSections(
            opId: opId, leaders: leaders,
            anchor: SidebarRestoreOverlay.anchor(for: leaders, inPreDeleteRows: state.preDeleteRows),
            releasedIds: restoredLeaderIds.union(state.clickLeaderIds))
        guard sidebarUpdateWaitsForPaint else {
            applyRestoredSections(update, includeOverlay: true)
            return nil
        }
        StructuralTrace.log("quick-undo lap: sidebar update waits for the editor's next paint")
        editorState.pendingSidebarRestoreCount += 1
        return Task { @MainActor [weak self, weak editorState] in
            defer { editorState?.pendingSidebarRestoreCount -= 1 }
            await self?.awaitNextPaint()
            guard let self, let editorState else { return }
            guard (self.efOpEpoch[opId] ?? epoch) == epoch else {
                StructuralTrace.log("quick-undo lap: sidebar update dropped (the entry's epoch moved)")
                return
            }
            guard update.leaders.first.map({ $0.projectId == editorState.currentProjectId }) ?? true else {
                StructuralTrace.log("quick-undo lap: sidebar update dropped (the project changed)")
                return
            }
            // t-d2061b27 (review F14): decided from the pending-reinsert count (raised in the quick undo's first stretch, lowered when the
            // reinsert's future resolves), NOT from the registry record: typing put back on top of the undo ends the redo branch, whose
            // discard forgets the entry's job keys (and their records) at once, and a missing record used to read as "resolved", so the
            // overlay was never set and the restored section's Outline card was missing until the reinsert's settle. (A count that is
            // up for ANOTHER reinsert only sets the overlay one settle early; the reinsert's settle, which waits for this update, lifts it.)
            let reinsertPending = editorState.pendingReinsertCount > 0
            StructuralTrace.log("quick-undo lap: sidebar update starts (painted, reinsertPending=\(reinsertPending))")
            self.applyRestoredSections(update, includeOverlay: reinsertPending)
        }
    }

    /// The update itself. `includeOverlay` is false only for an update that finds the reinsert already resolved: its settle has not
    /// run yet (it waits for this update) and will find nothing to clear, and the rows are in the database.
    private func applyRestoredSections(_ update: RestoredSidebarSections, includeOverlay: Bool) {
        guard let editorState else { return }
        editorState.pendingRemovalIds.subtract(update.releasedIds)
        guard !update.leaders.isEmpty else {
            editorState.refreshSections()
            return
        }
        if includeOverlay {
            editorState.pendingRestoreSections[update.opId] = update.leaders
            editorState.pendingRestoreAnchors[update.opId] = update.anchor
        }
        StructuralTrace.log("quick-undo lap: sidebar overlay set")
        let restored = PendingRestore(leaders: update.leaders.map { SectionViewModel(from: $0) }, anchor: update.anchor)
        editorState.sections = SidebarRestoreOverlay.merging([restored], into: editorState.sections)
        StructuralTrace.log("quick-undo lap: sidebar sections assigned")
        editorState.recalculateParentRelationships()
        StructuralTrace.log("quick-undo lap: sidebar parent relationships recalculated")
        editorState.refreshSections()
        StructuralTrace.log("quick-undo lap: sidebar outline refresh requested")
    }

    // MARK: - Waiting for the editor's paint

    /// Whether there is an editor to wait for: a web view is attached (or, in a debug build, a test stands in for the frame).
    private var sidebarUpdateWaitsForPaint: Bool {
        #if DEBUG
        if testNextPaintWait != nil { return true }
        #endif
        return activeWebView != nil
    }

    /// Returns after the page's next animation frame (a task after it, the same mapping the editor's own `restore painted` marker
    /// uses), or after 300 ms, whichever comes first.
    private func awaitNextPaint(timeout: Duration = .milliseconds(300)) async {
        #if DEBUG
        if let stand = testNextPaintWait {
            await stand()
            return
        }
        #endif
        guard let webView = activeWebView else { return }
        let signal = EFReservationSignal()
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(
                "await new Promise(resolve => requestAnimationFrame(() => setTimeout(resolve, 0))); return true;",
                arguments: [:], in: nil, contentWorld: .page)
            signal.fire()
        }
        Task { @MainActor in
            try? await Task.sleep(for: timeout)
            signal.fire()
        }
        await signal.wait()
    }
}
