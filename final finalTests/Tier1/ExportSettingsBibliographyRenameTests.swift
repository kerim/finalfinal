//
//  ExportSettingsBibliographyRenameTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Regression coverage for `ExportSettingsManager.setBibliographyHeaderName`'s own
//  validation/write logic -- previously exercised only incidentally by
//  `BibliographyRenameGraceNameTests`/`ExportSettingsResetNotificationTests`, never directly.
//
//  Two feedback-round fixes this file locks in:
//
//  1. An empty/whitespace-only submission now RESETS to the shipped default
//     ("Bibliography") through the exact same atomic grace-list-append path as any other
//     rename, instead of being rejected with "Name cannot be empty." -- see
//     `setBibliographyHeaderName`'s doc comment in ExportSettings.swift.
//
//  2. Manually typing the literal default name "Bibliography" over a DIFFERENT current
//     name was reported as silently blocked with no error message (unlike "Notes", which
//     is rejected WITH a visible error). Investigation found no explicit rejection rule for
//     "Bibliography" anywhere in `setBibliographyHeaderName` -- the diagnostic test below
//     (`typingLiteralDefaultNameOverADifferentCurrentNameSucceeds`) proves the settings-manager
//     layer accepts it exactly like any other rename. If this test ever starts failing, the
//     regression is in this method's validation, not (as originally suspected) the
//     `ExportPreferencesPane` UI layer.
//
//  Isolation: same seam as `ExportSettingsResetNotificationTests.swift` -- see that file's
//  doc comment for the full rationale. `ExportSettingsManager.shared` is a process-wide
//  singleton; `ExportSettings.userDefaults` is a process-wide static. Both are swapped to a
//  throwaway per-test store and restored via `defer`, guarded by the cross-suite
//  `exportSettingsTestLock` (see `ExportSettingsTestLock.swift`) shared with the other suites
//  that touch the same statics.
//

import Testing
import Foundation
@testable import final_final

@MainActor
@Suite(.serialized)
struct ExportSettingsBibliographyRenameTests {

    /// Points `ExportSettings.userDefaults` at a fresh, per-call isolated suite, force-syncs
    /// `ExportSettingsManager.shared`'s in-memory cache to a known-default starting point, runs
    /// `body`, then restores both the manager's cache and the previous store to exactly what
    /// they held before this call. Mirrors `ExportSettingsResetNotificationTests`' inline setup.
    private func withIsolatedManager(_ body: (ExportSettingsManager) -> Void) {
        let manager = ExportSettingsManager.shared
        let previousManagerSettings = manager.settings

        let suiteName = "com.kerim.final-final.tests.exportSettingsManagerBibRename.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        exportSettingsTestLock.lock()
        let previousStore = ExportSettings.userDefaults
        ExportSettings.userDefaults = testDefaults
        defer {
            manager.update { $0 = previousManagerSettings }
            ExportSettings.userDefaults = previousStore
            testDefaults.removePersistentDomain(forName: suiteName)
            exportSettingsTestLock.unlock()
        }

        // Force-sync the singleton's in-memory cache to a known, default starting point in
        // the isolated store -- ExportSettingsManager.shared caches settings once at first
        // access and does not re-read ExportSettings.userDefaults on its own.
        manager.update { $0 = ExportSettings.default }

        body(manager)
    }

    // MARK: - Item 2a: empty/whitespace resolves to the shipped default

    @Test("An empty submission resets to the shipped default via the same atomic rename path")
    func emptySubmissionResetsToDefault() {
        withIsolatedManager { manager in
            manager.setBibliographyHeaderName("Works Cited")
            #expect(manager.effectiveBibliographyHeaderName == "Works Cited")

            var received: [String: String]?
            let observer = NotificationCenter.default.addObserver(
                forName: .bibliographyHeaderNameChanged, object: nil, queue: .main
            ) { note in
                if let old = note.userInfo?["oldName"] as? String, let new = note.userInfo?["newName"] as? String {
                    received = ["oldName": old, "newName": new]
                }
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            let result = manager.setBibliographyHeaderName("")
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

            #expect(result == nil, "an empty submission must succeed, not be rejected")
            #expect(manager.effectiveBibliographyHeaderName == "Bibliography")
            #expect(manager.bibliographyHeaderName == "Bibliography")
            #expect(
                manager.previousBibliographyHeaderNames.contains("Works Cited"),
                """
                the outgoing custom name must land in the grace list -- the reset must go through the same \
                atomic append as any other rename, not a bypass
                """
            )
            #expect(received?["oldName"] == "Works Cited")
            #expect(received?["newName"] == "Bibliography")
        }
    }

    @Test("A whitespace-only submission also resets to the shipped default")
    func whitespaceOnlySubmissionResetsToDefault() {
        withIsolatedManager { manager in
            manager.setBibliographyHeaderName("Sources")
            #expect(manager.effectiveBibliographyHeaderName == "Sources")

            let result = manager.setBibliographyHeaderName("   \n\t  ")

            #expect(result == nil)
            #expect(manager.effectiveBibliographyHeaderName == "Bibliography")
            #expect(manager.previousBibliographyHeaderNames.contains("Sources"))
        }
    }

    /// Part 2 fix: a no-op resubmission (here, an empty submission that resolves to the name
    /// already in effect) must NOT write settings or touch the grace list -- but, unlike the
    /// old "no write, no notify" contract, it DOES still post `.bibliographyHeaderNameChanged`
    /// flagged `isReconciliationOnly: true`, so `ContentView.performBibliographyHeaderNameChange`
    /// gets a chance to retitle a document that might still be stuck on an old name after an
    /// earlier collision-guard refusal. Without this, resubmitting the same (already-committed)
    /// name is a PERMANENT dead end with no way to ever retry from the UI -- see
    /// `ExportSettings.swift`'s `setBibliographyHeaderName` doc comment for the full incident.
    @Test("An empty submission at the default does not write settings, but still posts a reconciliation-only notification")
    func emptySubmissionNoOpWhenAlreadyAtDefault() {
        withIsolatedManager { manager in
            #expect(manager.effectiveBibliographyHeaderName == "Bibliography")

            var received: [String: Any]?
            let observer = NotificationCenter.default.addObserver(
                forName: .bibliographyHeaderNameChanged, object: nil, queue: .main
            ) { note in received = note.userInfo as? [String: Any] }
            defer { NotificationCenter.default.removeObserver(observer) }

            let result = manager.setBibliographyHeaderName("")
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

            #expect(result == nil)
            #expect(manager.previousBibliographyHeaderNames.isEmpty, "a true no-op must not touch the grace list")
            #expect(manager.effectiveBibliographyHeaderName == "Bibliography", "a true no-op must not rewrite the name")
            #expect(received?["oldName"] as? String == "Bibliography")
            #expect(received?["newName"] as? String == "Bibliography")
            #expect(
                received?["isReconciliationOnly"] as? Bool == true,
                "must be flagged reconciliation-only so a benign zero-candidate outcome downstream stays silent"
            )
        }
    }

    // MARK: - Item 2b: manually typing "Bibliography" over a different current name

    /// The diagnostic test the feedback explicitly asked for: current name is something other
    /// than "Bibliography"; call `setBibliographyHeaderName("Bibliography")` directly (bypassing
    /// the UI layer entirely); assert it succeeds and the name is now "Bibliography". This
    /// passes cleanly, confirming the reported "silently blocked, no error" behavior is not
    /// caused by this method's validation -- there is no explicit rejection rule for
    /// "Bibliography" anywhere in it, unlike the explicit "Notes" rule proven distinct below.
    @Test("Typing the literal default name \"Bibliography\" over a different current name succeeds, unlike \"Notes\"")
    func typingLiteralDefaultNameOverADifferentCurrentNameSucceeds() {
        withIsolatedManager { manager in
            manager.setBibliographyHeaderName("Works Cited")
            #expect(manager.effectiveBibliographyHeaderName == "Works Cited")

            var received: [String: String]?
            let observer = NotificationCenter.default.addObserver(
                forName: .bibliographyHeaderNameChanged, object: nil, queue: .main
            ) { note in
                if let old = note.userInfo?["oldName"] as? String, let new = note.userInfo?["newName"] as? String {
                    received = ["oldName": old, "newName": new]
                }
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            let result = manager.setBibliographyHeaderName("Bibliography")
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

            #expect(result == nil, "no rejection message -- \"Bibliography\" is not a reserved name")
            #expect(manager.effectiveBibliographyHeaderName == "Bibliography")
            #expect(manager.bibliographyHeaderName == "Bibliography")
            #expect(manager.previousBibliographyHeaderNames.contains("Works Cited"))
            #expect(received?["oldName"] == "Works Cited")
            #expect(received?["newName"] == "Bibliography")

            // Contrast: "Notes" IS explicitly reserved and must still be rejected WITH a
            // visible error message, unlike the "Bibliography" case just proven above.
            let notesResult = manager.setBibliographyHeaderName("Notes")
            #expect(notesResult == "\"Notes\" is reserved for the footnotes section.")
            #expect(manager.effectiveBibliographyHeaderName == "Bibliography", "the rejected \"Notes\" attempt must not have written anything")
        }
    }

    // MARK: - Retained validation rules (must not be weakened by the above)

    @Test("Newline is still rejected")
    func newlineStillRejected() {
        withIsolatedManager { manager in
            let result = manager.setBibliographyHeaderName("Works\nCited")
            #expect(result == "Name cannot contain a line break.")
        }
    }

    @Test("A leading \"#\" is still rejected")
    func hashPrefixStillRejected() {
        withIsolatedManager { manager in
            let result = manager.setBibliographyHeaderName("#Bibliography")
            #expect(result == "Name cannot start with \"#\".")
        }
    }

    @Test("HTML comment markers are still rejected")
    func commentMarkersStillRejected() {
        withIsolatedManager { manager in
            let result = manager.setBibliographyHeaderName("<!-- sneaky -->")
            #expect(result == "Name cannot contain \"<!--\" or \"-->\".")
        }
    }

    @Test("\"Notes\", case-insensitively, is still rejected")
    func notesStillRejectedCaseInsensitively() {
        withIsolatedManager { manager in
            #expect(manager.setBibliographyHeaderName("Notes") == "\"Notes\" is reserved for the footnotes section.")
            #expect(manager.setBibliographyHeaderName("NOTES") == "\"Notes\" is reserved for the footnotes section.")
            #expect(manager.setBibliographyHeaderName("notes") == "\"Notes\" is reserved for the footnotes section.")
        }
    }

    @Test("Over-100-character names are still rejected")
    func overLongNameStillRejected() {
        withIsolatedManager { manager in
            let tooLong = String(repeating: "x", count: 101)
            let result = manager.setBibliographyHeaderName(tooLong)
            #expect(result == "Name must be 100 characters or fewer.")
        }
    }
}
