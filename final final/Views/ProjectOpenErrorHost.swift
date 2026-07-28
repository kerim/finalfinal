//
//  ProjectOpenErrorHost.swift
//  final final
//
//  Always-mounted host for ProjectOpenErrorState.shared.pending. Mounted once,
//  above the appViewState switch in FinalFinalApp.body, so a project-open failure
//  is visible no matter which screen (loading / picker / editor / gettingStarted)
//  is on screen when it happens. Replaces ContentView's old .integrityAlert sheet,
//  which only existed while ContentView was mounted (.editor / .gettingStarted) and
//  so silently dropped failures raised from the picker or the launch-time splash.
//

import SwiftUI

extension View {
    /// Presents ProjectOpenErrorState.shared.pending as a sheet.
    @MainActor
    func projectOpenErrorHost() -> some View {
        // Read as a plain local, NOT inside the Binding's `get` closure below.
        // SwiftUI's Observation only registers a dependency for reads that happen
        // lexically during a view's body evaluation. `Binding(get: {
        // ProjectOpenErrorState.shared.pending })` would defer the actual read to
        // whenever SwiftUI later calls the binding's getter -- outside tracked body
        // evaluation -- so report() firing later would never invalidate this view.
        // (Previously this meant the sheet only ever appeared by coincidence: the
        // launch-time case happened to work because determineInitialState() also
        // changes appViewState right after reporting, forcing an unrelated
        // re-render, but the headline case -- app already running, an open fails --
        // had nothing to force that re-render and the sheet simply never appeared.)
        let pending = ProjectOpenErrorState.shared.pending
        return self.sheet(item: Binding(
            get: { pending },
            set: { newValue in
                if newValue == nil { ProjectOpenErrorState.shared.clear() }  // covers Escape / any SwiftUI-initiated dismiss
            }
        )) { failure in
            ProjectOpenErrorSheetContent(failure: failure)
                // Injected directly on the presented content, not relied on via
                // modifier-chain ordering in FinalFinalApp.body: a sheet's content
                // only inherits environment values injected ABOVE the presentation
                // modifier, so anchoring the injection here holds regardless of how
                // FinalFinalApp.body's modifier chain is reordered later.
                .environment(ThemeManager.shared)
        }
    }
}

/// The sheet's content. Takes the ProjectOpenFailure `.sheet(item:)` hands it
/// rather than re-reading ProjectOpenErrorState.shared itself, so it updates in
/// place whenever the presenting view re-renders with a fresh value sharing the
/// same `id` (see ProjectOpenFailure.id) -- e.g. a Repair pass revealing a new,
/// still-broken report for the same file.
private struct ProjectOpenErrorSheetContent: View {
    let failure: ProjectOpenFailure

    var body: some View {
        switch failure {
        case .integrity(let report, let url):
            IntegrityAlertView(
                model: IntegrityAlertModel(report: report),
                onRepair: {
                    Task { await handleRepair(report: report, url: url) }
                },
                onOpenAnyway: {
                    handleOpenAnyway(url: url)
                },
                onCancel: {
                    ProjectOpenErrorState.shared.clear()
                }
            )
            .accessibilityIdentifier("project-open-error-sheet")
        case .other(let message, let url):
            ProjectOpenErrorView(message: message, url: url) {
                ProjectOpenErrorState.shared.clear()
            }
            .accessibilityIdentifier("project-open-error-sheet")
        }
    }

    /// `onRepair` runs an unstructured Task (IntegrityAlertView's onRepair is
    /// synchronous, so the await has to be wrapped somewhere), which means the user
    /// could Cancel -- or an unrelated new failure could arrive -- while this is in
    /// flight. `expectedId` is captured before the await so any write-back below
    /// only applies if the sheet is still showing the same failure this repair was
    /// launched against; a real side effect (the project actually opening) still
    /// gets reported regardless, since that already happened and is not undoable.
    private func handleRepair(report: IntegrityReport, url: URL) async {
        let expectedId = ProjectOpenFailure.integrity(report: report, url: url).id
        switch await IntegrityResolution.repair(report: report, url: url) {
        case .opened:
            if ProjectOpenErrorState.shared.pending?.id == expectedId {
                ProjectOpenErrorState.shared.clear()
            }
            NotificationCenter.default.post(name: .projectDidOpen, object: nil)
        case .stillBroken(let newReport):
            if ProjectOpenErrorState.shared.pending?.id == expectedId {
                ProjectOpenErrorState.shared.pending = .integrity(report: newReport, url: url)
            }
        case .failed(let error):
            // Surface the failure instead of discarding it silently (the old
            // behavior left the button looking like it did nothing). Reuses the
            // .other view rather than adding an error slot to IntegrityAlertView;
            // the trade-off is the user can no longer retry Repair from here --
            // they can still Cancel/OK and reopen the file to try again.
            if ProjectOpenErrorState.shared.pending?.id == expectedId {
                ProjectOpenErrorState.shared.pending = .other(message: error.localizedDescription, url: url)
            }
        }
    }

    /// Synchronous end-to-end (no await), so unlike handleRepair there's no window
    /// for a concurrent Cancel/new-failure to race this -- no staleness guard needed.
    private func handleOpenAnyway(url: URL) {
        switch IntegrityResolution.openAnyway(url: url) {
        case .opened:
            ProjectOpenErrorState.shared.clear()
            NotificationCenter.default.post(name: .projectDidOpen, object: nil)
        case .failed(let error):
            ProjectOpenErrorState.shared.pending = .other(message: error.localizedDescription, url: url)
        case .stillBroken:
            break  // openAnyway() never actually returns this -- force-open either succeeds or throws
        }
    }
}

/// Shown for non-integrity project-open failures (stale bookmark, unreadable
/// package, security-scoped access denied, etc.) -- the `.other` case of
/// ProjectOpenFailure. Names the failing file for the same reason
/// IntegrityAlertModel.message does: with one always-mounted host, this sheet can
/// appear over an unrelated open project, so the generic message alone wouldn't
/// tell the user which file it's complaining about.
struct ProjectOpenErrorView: View {
    let message: String
    let url: URL
    let onOK: () -> Void

    private var namedMessage: String {
        "\u{201C}\(url.lastPathComponent)\u{201D} could not be opened. " + message
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.title)
                Text("Could Not Open Project")
                    .font(.headline)
            }

            Text(namedMessage)

            Divider()

            HStack {
                Spacer()
                Button("OK") {
                    onOK()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 400, maxWidth: 500)
    }
}

#Preview {
    ProjectOpenErrorView(
        message: "The file couldn't be opened because it may have been moved or deleted.",
        url: URL(fileURLWithPath: "/test/demo.ff"),
        onOK: {}
    )
}
