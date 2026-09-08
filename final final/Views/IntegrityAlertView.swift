//
//  IntegrityAlertView.swift
//  final final
//
//  Shows integrity issues and repair options to the user.
//

import SwiftUI

/// View model for integrity alert
struct IntegrityAlertModel {
    let report: IntegrityReport

    /// `true` (the default, so existing call sites/previews keep compiling unchanged) when
    /// this alert is blocking an open that hasn't happened yet. `false` for §4.3's "Project
    /// integrity drift detected" case -- the project already opened successfully and this is
    /// reporting non-critical drift found along the way, so the wording and buttons below adapt
    /// (no "could not be opened", no "Open Anyway" -- there's nothing left to open).
    // `var`, not `let`: a `let` stored property with an inline default is excluded from
    // Swift's synthesized memberwise init entirely (SE-0242's default-value synthesis only
    // applies to `var`) -- callers that need to pass `blockedOpen: false` (ProjectOpenErrorHost)
    // require it to actually appear as a settable init parameter.
    var blockedOpen: Bool = true

    var title: String {
        guard blockedOpen else { return "Project Has Issues" }
        if report.hasCriticalIssues {
            return "Project Cannot Be Opened"
        } else if report.hasErrors {
            return "Project Has Issues"
        } else {
            return "Project Warning"
        }
    }

    var message: String {
        // Name the file explicitly: with one always-mounted host (rather than a
        // sheet scoped to the editor) this can appear over an unrelated open
        // project -- e.g. a broken Finder-open URL surfacing over the project
        // that was restored on launch -- so the generic sentence alone would
        // leave the user unable to tell which document is being complained about.
        let quotedFile = "\u{201C}\(report.packageURL.lastPathComponent)\u{201D}"
        guard blockedOpen else {
            return quotedFile + " opened normally. Some issues were found — they don't affect your work right now."
        }
        let namedFile = quotedFile + " could not be opened. "
        if report.hasCriticalIssues {
            return namedFile + "Critical issues were found that prevent this project from opening."
        } else if report.hasErrors {
            return namedFile + "Some issues were found that may affect your project."
        } else {
            return namedFile + "Minor issues were detected in this project."
        }
    }

    /// SF Symbol + semantic color + text per issue, in place of a prepended emoji character --
    /// this alert is native chrome (see `.claude/rules/ux-contract.md` §7 "Icons: SF Symbols
    /// only in native chrome"), and raw emoji glyphs aren't SF Symbols.
    var issueDescriptions: [(icon: String, color: Color, description: String)] {
        report.issues.map { issue in
            let color: Color = switch issue.severity {
            case .critical: .red
            case .error, .warning: .orange
            }
            return (icon: "exclamationmark.circle.fill", color: color, description: issue.description)
        }
    }

    var canRepair: Bool {
        report.canAutoRepair
    }
}

/// Alert view for displaying integrity issues
struct IntegrityAlertView: View {
    let model: IntegrityAlertModel
    let onRepair: () -> Void
    let onOpenAnyway: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: model.report.hasCriticalIssues ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(model.report.hasCriticalIssues ? .red : .orange)
                    .font(.title)
                Text(model.title)
                    .font(.headline)
            }

            // Message
            // This alert is native chrome, not themed document content (see
            // `.claude/rules/ux-contract.md` §7a) -- use the system secondary color, not a
            // document/editor-theme token.
            Text(model.message)
                .foregroundStyle(.secondary)

            // Issues list
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(model.issueDescriptions.enumerated()), id: \.offset) { _, issue in
                    HStack(spacing: 6) {
                        Image(systemName: issue.icon)
                            .foregroundStyle(issue.color)
                        Text(issue.description)
                            .font(.callout)
                    }
                }
            }
            .padding(.vertical, 8)

            Divider()

            // Action buttons
            HStack {
                // Once the project is already open (blockedOpen == false) there's nothing to
                // cancel -- a plain OK just dismisses the notice. Escape dismisses it the same
                // way Cancel would, but not via a button keyboard shortcut: this sheet is
                // presented with `.sheet(item:)` (ProjectOpenErrorHost.swift), and macOS's
                // native sheet-presentation behavior dismisses on Escape on its own, routing
                // back through the item binding's setter -- which calls the identical
                // `ProjectOpenErrorState.shared.clear()` the OK button's `onCancel()` calls.
                if model.blockedOpen {
                    Button("Cancel", role: .cancel) {
                        onCancel()
                    }
                    .keyboardShortcut(.escape)

                    Spacer()

                    // Open Anyway (if not critical) -- only meaningful while the open is
                    // actually blocked; once the project already opened there's nothing left to
                    // "open anyway".
                    if !model.report.hasCriticalIssues {
                        Button("Open Anyway (Unsafe)") {
                            onOpenAnyway()
                        }
                        .foregroundStyle(.orange)
                    }

                    // Repair (if possible) -- only while the open is still blocked. Once the
                    // project is already open (blockedOpen == false), Repair has no safe exit
                    // path: it either silently no-ops (openProject skips an already-open project)
                    // or does a mid-session close/reopen that discards unflushed edits
                    // (forceOpenProject has no already-open guard). Show only OK/Continue instead.
                    if model.canRepair {
                        Button("Repair") {
                            onRepair()
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return)
                    }
                } else {
                    // The drift alert is purely informational -- the project already opened.
                    // OK is the sole action, so it carries the Return default: Repair's exit
                    // paths (openProject's already-open no-op, forceOpenProject's mid-session
                    // close/reopen) are both broken for an already-open project, so Repair is
                    // never offered here at all. Standard macOS places the default action
                    // bottom-right, hence the Spacer first.
                    //
                    // No `.keyboardShortcut(.cancelAction)` here: SwiftUI's `keyboardShortcut`
                    // modifier is not additive -- stacking a second one on the same button
                    // overwrites the first rather than making the button respond to both keys.
                    // It isn't needed anyway: this sheet is presented with `.sheet(item:)`
                    // (ProjectOpenErrorHost.swift), and macOS dismisses a sheet on Escape natively,
                    // independent of any button's own shortcut, routing through the item
                    // binding's setter -- which calls the same `ProjectOpenErrorState.shared
                    // .clear()` this button's `onCancel()` calls.
                    Spacer()

                    Button("OK") {
                        onCancel()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                }
            }
        }
        .padding()
        .frame(minWidth: 400, maxWidth: 500)
    }
}

#Preview {
    IntegrityAlertView(
        model: IntegrityAlertModel(
            report: IntegrityReport(
                issues: [
                    .missingProjectRecord,
                    .orphanedSections(count: 3)
                ],
                packageURL: URL(fileURLWithPath: "/test/demo.ff")
            )
        ),
        onRepair: {},
        onOpenAnyway: {},
        onCancel: {}
    )
}
