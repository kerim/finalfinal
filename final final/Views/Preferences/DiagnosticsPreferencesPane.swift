//
//  DiagnosticsPreferencesPane.swift
//  final final
//
//  Preferences pane for the persistent diagnostic log toggle and the
//  Generate Diagnostic Report action.
//

import SwiftUI
import AppKit

struct DiagnosticsPreferencesPane: View {
    @State private var settings = DiagnosticsSettings.shared
    @State private var isGeneratingReport = false
    @State private var reportOutcome: ReportOutcome?

    private enum ReportOutcome: Identifiable {
        case success(URL)
        case failure(String)

        var id: String {
            switch self {
            case .success(let url): return "success:\(url.path)"
            case .failure(let message): return "failure:\(message)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Diagnostic Logging") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Enable diagnostic logging", isOn: $settings.loggingEnabled)
                    Text("Writes a rolling local log covering editor sync, export, and app-lifecycle "
                       + "activity — off by default. Helps track down rare issues that are hard to "
                       + "reproduce on demand. Log entries may include short snippets of your document "
                       + "text (e.g. heading previews); review before sharing a report.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            GroupBox("Diagnostic Report") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bundles the diagnostic log, a system-info snapshot, and your most recent "
                       + "export captures (if any) into a folder you choose. Works even if logging "
                       + "above is off — the report just won't have a log file in that case.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(isGeneratingReport ? "Generating…" : "Generate Diagnostic Report…") {
                        generateReport()
                    }
                    .disabled(isGeneratingReport)
                    if let lastReportGeneratedAt = settings.lastReportGeneratedAt {
                        Text("Last generated: \(lastReportGeneratedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }

            Spacer()
        }
        .padding()
        .alert(
            reportAlertTitle,
            isPresented: Binding(
                get: { reportOutcome != nil },
                set: { if !$0 { reportOutcome = nil } }
            ),
            presenting: reportOutcome
        ) { _ in
            Button("OK") { reportOutcome = nil }
        } message: { outcome in
            Text(reportAlertMessage(for: outcome))
        }
    }

    private var reportAlertTitle: String {
        if case .failure = reportOutcome { return "Report Generation Failed" }
        return "Diagnostic Report Saved"
    }

    private func reportAlertMessage(for outcome: ReportOutcome) -> String {
        switch outcome {
        case .success(let url):
            return "Saved to: \(url.path)"
        case .failure(let message):
            return message
        }
    }

    /// Enabled and works regardless of the logging toggle's state. System info and recent
    /// export-diagnostic captures are useful on their own (the export-reorder bug's data is
    /// captured unconditionally today, independent of this toggle); blocking report generation
    /// when logging is off would make the button confusing and would prevent using it for the
    /// export bug when a user never turned logging on. When the toggle was off, the generated
    /// `logs/` folder is simply empty with an explanatory README.txt instead of a log file.
    private func generateReport() {
        let panel = NSSavePanel()
        panel.title = "Save Diagnostic Report"
        panel.message = "Choose a location to save the diagnostic report folder."
        panel.nameFieldStringValue = "final-final-diagnostics-\(isoStamp())"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        isGeneratingReport = true
        Task {
            let result = await DiagnosticReportGenerator.generateReport(to: destinationURL)
            isGeneratingReport = false
            switch result {
            case .success(let url):
                settings.lastReportGeneratedAt = Date()
                reportOutcome = .success(url)
            case .failure(let error):
                reportOutcome = .failure(error.localizedDescription)
            }
        }
    }

    /// Same ":" -> "-" idiom as ExportService's diagnostic-dump timestamps, so the default
    /// filename is filesystem-safe.
    private func isoStamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
}

#Preview {
    DiagnosticsPreferencesPane()
        .frame(width: 500, height: 400)
}
