//
//  ExportActivity.swift
//  final final
//
//  Tracks "is a long export/print operation running right now" for the whole app (UX contract
//  §4.2 / D7): a progress toast the moment the operation starts, replaced by the operation's
//  own result toast (or an error alert) when it ends, and every export/print command in
//  FileCommands.swift disabled while `isRunning` is true so none of them can be started twice.
//
//  A singleton (`.shared`), like `ToastCenter`, because the call sites that need to flip
//  `isRunning` -- `ExportViewModel.export`, `PrintOperations`, `FileCommands+Export`'s three
//  markdown exporters -- all fire from outside any one view's own state tree, and the menu
//  items that read `isRunning` live in `FileCommands`, a `Commands` struct with no view
//  hierarchy of its own to share state through.
//
//  Depth-counted rather than a plain Bool: most call sites wire exactly one `begin`/`end` (or
//  `run(...)`) pair per user-visible command, but `PrintCommands.handlePrintFormatted()`
//  deliberately nests two -- an outer pair covering its own preflight (content load, Pandoc
//  probe) plus `ExportViewModel.export()`'s inner `run(...)` around the pandoc invocation itself
//  (see that method's own doc comment) -- and the counter is what makes that, and any future
//  nested call, harmless by construction instead of relying on every call site remembering not
//  to nest.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class ExportActivity {
    static let shared = ExportActivity()

    /// Whether ANY export/print operation is currently running -- read directly by
    /// `FileCommands.swift`'s `.disabled(...)` modifiers.
    private(set) var isRunning = false

    private var depth = 0
    private var toastID: UUID?
    private let toastCenter: ToastCenter

    /// Not `private` -- `.shared` is the one production entry point, but tests construct their
    /// own isolated instances (paired with their own isolated `ToastCenter`) rather than
    /// mutating the shared singleton and racing other parallel tests.
    ///
    /// `toastCenter` defaults to `nil` (resolved to `ToastCenter.shared` in the body) rather
    /// than `= .shared` directly in the parameter list: a default parameter VALUE expression is
    /// evaluated in the caller's isolation context, not the callee's, so referencing the
    /// main-actor-isolated `ToastCenter.shared` there is flagged even though this whole
    /// initializer is itself `@MainActor` (inherited from the class) -- resolving it inside the
    /// body instead reads `.shared` from code that's unambiguously on the main actor.
    init(toastCenter: ToastCenter? = nil) {
        self.toastCenter = toastCenter ?? .shared
    }

    /// Marks one operation as started. Safe to call while another is already running -- only
    /// the outermost `begin`/`end` pair actually flips `isRunning` or shows/dismisses a toast;
    /// an inner pair is a no-op past incrementing/decrementing `depth`. Pass `nil` for an
    /// operation too fast for a spinner to mean anything (see `handlePrintRawMarkdown()`) --
    /// `isRunning`/`disabled(...)` still applies, but no toast is shown.
    func begin(message: String?) {
        depth += 1
        guard depth == 1 else { return }
        isRunning = true
        if let message {
            let toast = ToastFactory.exportInProgress(message: message)
            toastID = toast.id
            withAnimation {
                toastCenter.show(toast)
            }
        }
    }

    /// Marks one operation as ended. Only the matching outermost `end()` actually clears
    /// `isRunning` and dismisses this activity's progress toast (via `ToastCenter.dismiss(id:)`
    /// -- never `dismissCurrent()`, which would tear down whatever toast is showing regardless
    /// of whether it's this one).
    func end() {
        depth = max(0, depth - 1)
        guard depth == 0 else { return }
        isRunning = false
        if let id = toastID {
            toastID = nil
            withAnimation {
                toastCenter.dismiss(id: id)
            }
        }
    }

    /// Runs `operation` wrapped in a `begin`/`end` pair, `defer`-clearing state even if
    /// `operation` throws -- the standard shape every export/print call site uses instead of
    /// hand-pairing `begin()`/`end()` around its own body.
    func run<T>(_ message: String?, operation: () async throws -> T) async rethrows -> T {
        begin(message: message)
        defer { end() }
        return try await operation()
    }
}
