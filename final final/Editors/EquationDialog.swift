//
//  EquationDialog.swift
//  final final
//
//  Shared equation-insert dialog used by both editor coordinators.
//  Shows an NSAlert with an inline/display toggle. Inline uses a single-line
//  LaTeX text field; Display swaps in a scrollable multi-line text view so
//  multi-line constructs (e.g. \begin{aligned}...\end{aligned}) can be typed
//  at insert time. On Insert, calls window.FinalFinal.insertEquation(latex, isDisplay)
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

        let accessoryWidth: CGFloat = 380
        let inlineHeight: CGFloat = 100
        let displayHeight: CGFloat = 260
        let inlineInformativeText = "Enter LaTeX for your equation."
        let displayInformativeText = "Enter multi-line LaTeX for your equation."

        // --- Build the accessory view ---
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: accessoryWidth, height: inlineHeight))

        // Inline / Display segmented control
        let segmentControl = NSSegmentedControl(
            labels: ["Inline  $...$", "Display  $$...$$"],
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        segmentControl.selectedSegment = 0

        // LaTeX label
        let label = NSTextField(labelWithString: "LaTeX:")

        // Monospace text field for single-line (Inline) LaTeX input
        let textField = NSTextField(frame: .zero)
        textField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textField.placeholderString = "e.g. x^2 + y^2 = r^2"

        // Scrollable monospace text view for multi-line (Display) LaTeX input
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = true
        scrollView.isHidden = true
        // scrollableTextView() always backs its scroll view with an NSTextView.
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isRichText = false
        // Explicit identifier so XCUITest can address this text view
        // unambiguously instead of relying on an unscoped `.firstMatch`
        // query, which is ambiguous if any other element in the app exposes
        // the same accessibility element type. No effect on real usage.
        textView.setAccessibilityIdentifier("equation-dialog-display-textview")

        // Placeholder overlay for the multi-line field (NSTextView has no native placeholder).
        // Built via init(frame:) + manual label-style config rather than NSTextField(labelWithString:)
        // so the click-through subclass below doesn't depend on convenience-initializer inheritance.
        let placeholderField = ClickThroughLabel(frame: .zero)
        placeholderField.stringValue = "e.g. \\begin{aligned}\n  x &= y \\\\\n  z &= w\n\\end{aligned}"
        placeholderField.isEditable = false
        placeholderField.isSelectable = false
        placeholderField.isBezeled = false
        placeholderField.drawsBackground = false
        placeholderField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        placeholderField.textColor = .placeholderTextColor
        placeholderField.cell?.wraps = true
        placeholderField.cell?.usesSingleLineMode = false
        placeholderField.isHidden = true

        accessory.addSubview(segmentControl)
        accessory.addSubview(label)
        accessory.addSubview(textField)
        accessory.addSubview(scrollView)
        accessory.addSubview(placeholderField)

        // Drives the Inline/Display layout swap; kept alive by the sheet's
        // completion closure below (NSControl.target and NSTextView.delegate are weak).
        let coordinator = EquationDialogCoordinator(
            accessory: accessory,
            segmentControl: segmentControl,
            label: label,
            textField: textField,
            scrollView: scrollView,
            textView: textView,
            placeholderField: placeholderField,
            accessoryWidth: accessoryWidth,
            inlineHeight: inlineHeight,
            displayHeight: displayHeight,
            inlineInformativeText: inlineInformativeText,
            displayInformativeText: displayInformativeText
        )
        textView.delegate = coordinator
        segmentControl.target = coordinator
        segmentControl.action = #selector(EquationDialogCoordinator.segmentChanged(_:))
        coordinator.applyLayout(isDisplay: false)

        // --- Build the alert ---
        let alert = NSAlert()
        alert.messageText = "Insert Equation"
        alert.informativeText = inlineInformativeText
        let insertButton = alert.addButton(withTitle: "Insert")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = accessory
        coordinator.alert = alert
        coordinator.insertButton = insertButton

        // Focus the text field when the sheet appears
        alert.window.initialFirstResponder = textField

        alert.beginSheetModal(for: window) { [weak webView, coordinator] response in
            // `coordinator` is captured strongly only to keep it alive for the
            // sheet's lifetime (NSControl.target/NSTextView.delegate hold it
            // weakly) -- it's never otherwise referenced in this closure.
            _ = coordinator
            guard response == .alertFirstButtonReturn else { return }
            let isDisplay = segmentControl.selectedSegment == 1
            let raw = isDisplay ? textView.string : textField.stringValue
            let latex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !latex.isEmpty else { return }

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

/// Drives the equation dialog's Inline/Display layout swap and the multi-line
/// field's placeholder visibility.
@MainActor
private final class EquationDialogCoordinator: NSObject, NSTextViewDelegate {
    private let accessory: NSView
    private let segmentControl: NSSegmentedControl
    private let label: NSTextField
    private let textField: NSTextField
    private let scrollView: NSScrollView
    private let textView: NSTextView
    private let placeholderField: NSTextField
    private let accessoryWidth: CGFloat
    private let inlineHeight: CGFloat
    private let displayHeight: CGFloat
    private let inlineInformativeText: String
    private let displayInformativeText: String
    weak var alert: NSAlert?
    weak var insertButton: NSButton?

    init(
        accessory: NSView,
        segmentControl: NSSegmentedControl,
        label: NSTextField,
        textField: NSTextField,
        scrollView: NSScrollView,
        textView: NSTextView,
        placeholderField: NSTextField,
        accessoryWidth: CGFloat,
        inlineHeight: CGFloat,
        displayHeight: CGFloat,
        inlineInformativeText: String,
        displayInformativeText: String
    ) {
        self.accessory = accessory
        self.segmentControl = segmentControl
        self.label = label
        self.textField = textField
        self.scrollView = scrollView
        self.textView = textView
        self.placeholderField = placeholderField
        self.accessoryWidth = accessoryWidth
        self.inlineHeight = inlineHeight
        self.displayHeight = displayHeight
        self.inlineInformativeText = inlineInformativeText
        self.displayInformativeText = displayInformativeText
        super.init()
    }

    @objc func segmentChanged(_ sender: NSSegmentedControl) {
        applyLayout(isDisplay: sender.selectedSegment == 1)
    }

    /// Lays out the accessory view for the given mode, growing the dialog for
    /// Display (multi-line) and carrying over any text already typed.
    func applyLayout(isDisplay: Bool) {
        let height = isDisplay ? displayHeight : inlineHeight
        accessory.setFrameSize(NSSize(width: accessoryWidth, height: height))
        segmentControl.frame = NSRect(x: 0, y: height - 30, width: accessoryWidth, height: 24)
        label.frame = NSRect(x: 0, y: height - 52, width: 60, height: 18)

        if isDisplay {
            if textView.string.isEmpty, !textField.stringValue.isEmpty {
                textView.string = textField.stringValue
            }
            textField.isHidden = true
            scrollView.isHidden = false
            let boxHeight = height - 68
            scrollView.frame = NSRect(x: 64, y: 8, width: accessoryWidth - 64, height: boxHeight)
            let placeholderHeight = min(76, boxHeight - 8)
            placeholderField.frame = NSRect(
                x: 68,
                y: scrollView.frame.maxY - placeholderHeight - 4,
                width: accessoryWidth - 72,
                height: placeholderHeight
            )
            placeholderField.isHidden = !textView.string.isEmpty
        } else {
            if textField.stringValue.isEmpty, !textView.string.isEmpty {
                textField.stringValue = textView.string.components(separatedBy: .newlines).first ?? textView.string
            }
            scrollView.isHidden = true
            placeholderField.isHidden = true
            textField.isHidden = false
            textField.frame = NSRect(x: 64, y: height - 54, width: accessoryWidth - 64, height: 22)
        }

        alert?.informativeText = isDisplay ? displayInformativeText : inlineInformativeText

        // Confirmed root cause (file-based diagnostic logging during
        // investigation, since removed): NSAlert commits its accessory
        // container's size at assignment time and does not keep tracking a
        // later frame change on its own -- reassigning `accessoryView`
        // again, to the SAME view now at its new size, forces it to
        // recompute the container. Verified via a real driven test: without
        // this, the dialog never visibly resized and typed/pasted text
        // never reached the text view.
        alert?.accessoryView = accessory
        alert?.layout()

        // NSAlert wires its first button's keyEquivalent to Return ("\r") so
        // Return submits the dialog -- checked via performKeyEquivalent(_:),
        // which AppKit runs over the view hierarchy BEFORE a plain keyDown
        // ever reaches the first responder's own keyDown:/insertNewline:
        // handling. That means a focused multi-line NSTextView never gets a
        // chance to consume Return as a newline while the button still
        // claims it: the dialog submits early (frequently with the LaTeX
        // still incomplete), closes, and further typing reaches whatever is
        // behind it. Clearing the keyEquivalent while Display is active lets
        // Return reach the text view instead; restoring it for Inline keeps
        // that mode's original submit-on-Return behavior.
        insertButton?.keyEquivalent = isDisplay ? "" : "\r"
        // Belt-and-suspenders: NSWindow's own defaultButtonCell fallback is a
        // separate mechanism from a button's keyEquivalent and can trigger
        // the default button for an unconsumed Return independently of it.
        accessory.window?.defaultButtonCell = isDisplay ? nil : insertButton?.cell as? NSButtonCell

        let responder: NSResponder = isDisplay ? textView : textField
        let becameFirstResponder = accessory.window?.makeFirstResponder(responder) ?? false
        if !becameFirstResponder {
            // makeFirstResponder can silently fail (return false, previously
            // ignored here) when called in the same pass as unhiding/resizing
            // the view it targets. Retrying once on the next run-loop turn,
            // after layout has settled, is a standard, safe defensive
            // pattern for this.
            DispatchQueue.main.async { [weak accessory] in
                accessory?.window?.makeFirstResponder(responder)
            }
        }
    }

    func textDidChange(_ notification: Notification) {
        placeholderField.isHidden = !textView.string.isEmpty
    }
}

/// A label that never intercepts mouse events, so it can float on top of the
/// multi-line text view as placeholder text without blocking clicks into it.
@MainActor
private final class ClickThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
