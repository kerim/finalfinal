//
//  CitationErrorPresenterCopyTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Pins CitationErrorPresenter.Kind's title/message strings. A silently wrong or
//  missing error message leaves the user with no idea why a citation action failed --
//  see .claude/rules/ux-contract.md §4.4, "one error class, one presenter". Kind is a
//  pure value type (no actor isolation, no AppKit), so these are plain string
//  assertions, following the house pattern set by DestructiveConfirmationCopyTests.
//

import Testing
@testable import final_final

@Suite("Citation Error Presenter — Tier 1: Silent Killers")
struct CitationErrorPresenterCopyTests {

    private static let zoteroNotRunningMessage = "Zotero is not running. Please open Zotero and try again."

    @Test("Not Running: title and message")
    func notRunningCopy() {
        let kind = CitationErrorPresenter.Kind.notRunning

        #expect(kind.title == "Zotero Not Running")
        #expect(kind.message == Self.zoteroNotRunningMessage)
    }

    @Test("Connection Lost: title and message")
    func connectionLostCopy() {
        let kind = CitationErrorPresenter.Kind.connectionLost

        #expect(kind.title == "Zotero Connection Lost")
        #expect(kind.message == Self.zoteroNotRunningMessage)
    }

    @Test("Failed: title is generic, message is the passed description verbatim")
    func failedCopy() {
        let kind = CitationErrorPresenter.Kind.failed("Some underlying CAYW error")

        #expect(kind.title == "Citation Error")
        #expect(kind.message == "Some underlying CAYW error")
    }

    @Test("Not Running and Connection Lost share the same message")
    func notRunningAndConnectionLostShareMessage() {
        #expect(CitationErrorPresenter.Kind.notRunning.message == CitationErrorPresenter.Kind.connectionLost.message)
    }
}
