//
//  DestructiveConfirmationCopyTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//  Confirmation copy for delete-preset, clear-recents, and pane-reset actions
//  follows .claude/rules/ux-contract.md §3's dialog-wording rule: the confirm
//  title is a verb phrase naming the object (never a bare "OK", "Yes",
//  "Confirm", or a bare, objectless verb), the message names the object, and
//  says the action cannot be undone.
//

import Testing
import AppKit
@testable import final_final

@Suite("Destructive Confirmation Copy — Tier 2: Visible Breakage")
struct DestructiveConfirmationCopyTests {

    // MARK: - Helpers

    /// A confirm title must be a multi-word verb phrase naming the object, never a bare
    /// generic word ("OK", "Yes", "Confirm") or a single unqualified verb ("Delete", "Reset").
    private func assertNotBare(_ confirmTitle: String, sourceLabel: String) {
        let normalized = confirmTitle.trimmingCharacters(in: .whitespaces).lowercased()
        let forbiddenBareWords: Set<String> = ["ok", "yes", "confirm", "delete", "clear", "reset", "remove"]
        #expect(
            !forbiddenBareWords.contains(normalized),
            "\(sourceLabel): confirmTitle '\(confirmTitle)' must not be a bare verb or generic word"
        )
        #expect(
            confirmTitle.split(separator: " ").count >= 2,
            "\(sourceLabel): confirmTitle '\(confirmTitle)' should be a verb phrase naming the object, not a single word"
        )
    }

    // MARK: - Delete Preset

    @Test("Delete Preset: confirm title names the object, message names the preset and says it cannot be undone")
    func deletePresetCopy() {
        let copy = DestructiveConfirmationCopy.deletePreset(named: "My Preset")

        assertNotBare(copy.confirmTitle, sourceLabel: "deletePreset")
        #expect(copy.title == "Delete Preset")
        #expect(copy.message.contains("My Preset"))
        #expect(copy.message.localizedCaseInsensitiveContains("undone"))
    }

    // MARK: - Clear Recent Projects

    @Test("Clear Recent Projects: confirm title names the object, message names it and says it cannot be undone")
    func clearRecentProjectsCopy() {
        let copy = DestructiveConfirmationCopy.clearRecentProjects

        assertNotBare(copy.confirmTitle, sourceLabel: "clearRecentProjects")
        #expect(copy.title == "Clear Recent Projects")
        #expect(copy.message.localizedCaseInsensitiveContains("recent projects"))
        #expect(copy.message.localizedCaseInsensitiveContains("undone"))
    }

    // MARK: - Reset Pane

    @Test(
        "Reset pane: confirm title and message name the pane and say it cannot be undone",
        arguments: PreferencesTab.allCases
    )
    func resetPaneCopy(tab: PreferencesTab) {
        let copy = DestructiveConfirmationCopy.resetPane(tab)

        assertNotBare(copy.confirmTitle, sourceLabel: "resetPane(\(tab.title))")
        #expect(copy.title.contains(tab.title), "resetPane(\(tab.title)) title must name the pane")
        #expect(copy.confirmTitle.contains(tab.title), "resetPane(\(tab.title)) confirmTitle must name the pane")

        if tab == .appearance {
            // Appearance's message names the current theme rather than the literal
            // pane name, and conveys non-reversibility without the exact phrase
            // "cannot be undone" -- a saved preset can still be reapplied, so a
            // blanket "cannot be undone" overstates it (see
            // DestructiveConfirmationCopy.message's .resetPane(.appearance) case).
            #expect(
                copy.message.localizedCaseInsensitiveContains("theme"),
                "resetPane(appearance) message must name the current theme"
            )
            #expect(
                copy.message.localizedCaseInsensitiveContains("lost"),
                "resetPane(appearance) message must convey that unsaved style changes will be lost"
            )
        } else {
            #expect(copy.message.contains(tab.title), "resetPane(\(tab.title)) message must name the pane")
            #expect(copy.message.localizedCaseInsensitiveContains("undone"))
        }
    }

    // MARK: - Cross-cutting

    @Test("No confirm title across any case is a bare OK/Yes/Confirm")
    func noGenericConfirmTitles() {
        let allCopies: [DestructiveConfirmationCopy] =
            [.deletePreset(named: "Preset"), .clearRecentProjects] + PreferencesTab.allCases.map { .resetPane($0) }

        for copy in allCopies {
            let normalized = copy.confirmTitle.trimmingCharacters(in: .whitespaces).lowercased()
            #expect(!["ok", "yes", "confirm"].contains(normalized), "'\(copy.confirmTitle)' must not be a generic confirm word")
        }
    }

    // MARK: - Clear Recent Projects NSAlert (review round: standard button order --
    // action rightmost/first, Cancel second -- Cancel is still the Return default, the
    // destructive button never is, and Escape still resolves to Cancel)

    @Test("Clear Recent Projects alert: shared copy, standard button order, Cancel is Return default, destructive button never is")
    @MainActor
    func clearRecentProjectsAlertOrderAndKeyEquivalents() {
        let alert = FileOperations.makeClearRecentProjectsAlert()
        let copy = DestructiveConfirmationCopy.clearRecentProjects

        // The alert's text comes from DestructiveConfirmationCopy, not an inline restatement.
        #expect(alert.messageText == copy.title)
        #expect(alert.informativeText == copy.message)

        // Force NSAlert's real layout pass -- this asserts on ACTUAL runtime state after a
        // public AppKit lifecycle call, not a readback of what this function just wrote two
        // lines earlier.
        alert.layout()

        // Standard macOS order: the action button is added first (renders rightmost).
        #expect(alert.buttons.count == 2)
        #expect(alert.buttons[0].title == copy.confirmTitle)
        #expect(alert.buttons[1].title == "Cancel")

        // Cancel -- never the destructive button -- is the Return default.
        #expect(alert.buttons[0].keyEquivalent != "\r")
        #expect(alert.buttons[1].keyEquivalent == "\r")
        #expect(alert.buttons[0].hasDestructiveAction)

        // Escape must still resolve to Cancel's own response, not be silently dropped: some
        // button (the invisible accessory-view relay) carries the Escape key equivalent and
        // shares Cancel's target/action, so triggering it invokes the same handler.
        let allButtons = (alert.accessoryView?.subviews ?? []).compactMap { $0 as? NSButton } + alert.buttons
        guard let escapeButton = allButtons.first(where: { $0.keyEquivalent == "\u{1b}" }) else {
            Issue.record("No button in the alert carries the Escape key equivalent")
            return
        }
        #expect(escapeButton !== alert.buttons[1])
        #expect(escapeButton.action == alert.buttons[1].action)
        #expect(escapeButton.target === alert.buttons[1].target)
    }
}
