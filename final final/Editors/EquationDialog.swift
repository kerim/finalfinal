//
//  EquationDialog.swift
//  final final
//
//  Shared equation-insert dialog used by both editor coordinators.
//  Shows an NSAlert with an inline/display toggle + LaTeX text field;
//  on Insert, calls window.FinalFinal.insertEquation(latex, isDisplay)
//  in the given web view (Milkdown inserts a math node, CodeMirror raw $…$ text).
//

import AppKit
import WebKit

@MainActor
enum EquationDialog {
    /// Present the equation sheet over the web view's window.
    /// - Parameters:
    ///   - webView: the editor web view that receives the insertEquation(...) call
    ///   - logLabel: editor name used in DebugLog messages (e.g. "MilkdownEditor")
    static func present(for webView: WKWebView?, logLabel: String) {
        let window = webView?.window ?? NSApp.keyWindow
        guard let window else { return }

        // --- Build the accessory view ---
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 100))

        // Inline / Display segmented control
        let segmentControl = NSSegmentedControl(
            labels: ["Inline  $...$", "Display  $$...$$"],
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        segmentControl.frame = NSRect(x: 0, y: 70, width: 380, height: 24)
        segmentControl.selectedSegment = 0

        // LaTeX label
        let label = NSTextField(labelWithString: "LaTeX:")
        label.frame = NSRect(x: 0, y: 48, width: 60, height: 18)

        // Monospace text field for LaTeX input
        let textField = NSTextField(frame: NSRect(x: 64, y: 46, width: 316, height: 22))
        textField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textField.placeholderString = "e.g. x^2 + y^2 = r^2"

        accessory.addSubview(segmentControl)
        accessory.addSubview(label)
        accessory.addSubview(textField)

        // --- Build the alert ---
        let alert = NSAlert()
        alert.messageText = "Insert Equation"
        alert.informativeText = "Enter LaTeX for your equation."
        alert.addButton(withTitle: "Insert")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = accessory

        // Focus the text field when the sheet appears
        alert.window.initialFirstResponder = textField

        alert.beginSheetModal(for: window) { [weak webView] response in
            guard response == .alertFirstButtonReturn else { return }
            let latex = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !latex.isEmpty else { return }
            let isDisplay = segmentControl.selectedSegment == 1

            // JSON-encode the latex string (JSONEncoder handles bare strings; JSONSerialization cannot)
            guard let jsonData = try? JSONEncoder().encode(latex),
                  let jsonString = String(data: jsonData, encoding: .utf8) else { return }

            let js = "window.FinalFinal.insertEquation(\(jsonString), \(isDisplay ? "true" : "false"))"
            webView?.evaluateJavaScript(js) { _, error in
                if let error {
                    DebugLog.log(.editor, "[\(logLabel)] insertEquation JS error: \(error)")
                }
            }
        }
    }
}
