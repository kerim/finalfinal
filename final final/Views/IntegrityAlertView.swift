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

    var title: String {
        if report.hasCriticalIssues {
            return "Project Cannot Be Opened"
        } else if report.hasErrors {
            return "Project Has Issues"
        } else {
            return "Project Warning"
        }
    }

    var message: String {
        if report.hasCriticalIssues {
            return "Critical issues were found that prevent this project from opening."
        } else if report.hasErrors {
            return "Some issues were found that may affect your project."
        } else {
            return "Minor issues were detected in this project."
        }
    }

    var issueDescriptions: [String] {
        report.issues.map { issue in
            let severity = switch issue.severity {
            case .critical: "🔴"
            case .error: "🟠"
            case .warning: "🟡"
            }
            return "\(severity) \(issue.description)"
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

    @Environment(ThemeManager.self) private var themeManager

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
            Text(model.message)
                .foregroundStyle(themeManager.currentTheme.editorTextSecondary)

            // Issues list
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.issueDescriptions, id: \.self) { description in
                    Text(description)
                        .font(.callout)
                }
            }
            .padding(.vertical, 8)

            Divider()

            // Action buttons
            HStack {
                // Cancel is always available
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.escape)

                Spacer()

                // Open Anyway (if not critical)
                if !model.report.hasCriticalIssues {
                    Button("Open Anyway (Unsafe)") {
                        onOpenAnyway()
                    }
                    .foregroundStyle(.orange)
                }

                // Repair (if possible)
                if model.canRepair {
                    Button("Repair") {
                        onRepair()
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

/// Wrapper to make IntegrityReport identifiable for sheet presentation
struct IntegrityReportWrapper: Identifiable {
    let report: IntegrityReport
    var id: String { report.packageURL.path }
}

extension View {
    /// Present an integrity alert sheet
    @ViewBuilder
    func integrityAlert(
        report: Binding<IntegrityReport?>,
        onRepair: @escaping (IntegrityReport) -> Void,
        onOpenAnyway: @escaping (IntegrityReport) -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        self.sheet(
            isPresented: Binding(
                get: { report.wrappedValue != nil },
                set: { if !$0 { report.wrappedValue = nil } }
            )
        ) {
            if let currentReport = report.wrappedValue {
                IntegrityAlertView(
                    model: IntegrityAlertModel(report: currentReport),
                    onRepair: {
                        onRepair(currentReport)
                        report.wrappedValue = nil
                    },
                    onOpenAnyway: {
                        onOpenAnyway(currentReport)
                        report.wrappedValue = nil
                    },
                    onCancel: {
                        onCancel()
                        report.wrappedValue = nil
                    }
                )
            }
        }
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
