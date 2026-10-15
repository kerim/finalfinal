//
//  CitationPrefillTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  "Work the document's citations out ahead of time" (plan-citations-ahead-of-time.md, Stage A) drives a hidden web page, so
//  what can be checked without one is checked here:
//
//  1. The guard that stops a fill the moment its spare is claimed or replaced -- including BEFORE the page's `begin` call,
//     which parses the whole document (a late `begin` would run inside the page the user is loading).
//  2. Reading the page's two answers: anything but the agreed shape is "stop", never a guess.
//  3. The step loop's own stop rules (done, no progress, step cap).
//  4. The JavaScript sent to the page: a page without the functions answers `missing` instead of throwing, the document and
//     the budget reach the function untouched, and the library push is the one call the mount makes.
//  5. The UI-test switch parsing: unset or outside a UI test, nothing is on.
//

import Foundation
import JavaScriptCore
import Testing
@testable import final_final

@Suite("Citation prefill")
@MainActor
struct CitationPrefillTests {

    // MARK: - The generation-and-claim guard

    @Test("a fill goes on while its spare is the current, ready one")
    func guardLetsTheFillContinue() {
        #expect(CitationPrefillGuard.stopReason(expectedGeneration: 4, currentGeneration: 4, claimedGeneration: 3, spareIsReady: true) == nil)
        #expect(CitationPrefillGuard.stopReason(expectedGeneration: 1, currentGeneration: 1, claimedGeneration: nil, spareIsReady: true) == nil)
    }

    @Test("a claimed spare stops the fill, whatever generation the replacement has")
    func guardStopsOnClaim() {
        // The claim bumps the generation and the replacement bumps it again: current is 6, the fill started on 4, the claim recorded 4.
        #expect(CitationPrefillGuard.stopReason(expectedGeneration: 4, currentGeneration: 6, claimedGeneration: 4, spareIsReady: false) == .claimed)
        #expect(CitationPrefillGuard.stopReason(expectedGeneration: 4, currentGeneration: 6, claimedGeneration: 4, spareIsReady: true) == .claimed)
    }

    @Test("a replaced spare stops the fill")
    func guardStopsOnReplacement() {
        #expect(CitationPrefillGuard.stopReason(expectedGeneration: 4, currentGeneration: 6, claimedGeneration: 5, spareIsReady: true) == .replaced)
        #expect(CitationPrefillGuard.stopReason(expectedGeneration: 2, currentGeneration: 3, claimedGeneration: nil, spareIsReady: true) == .replaced)
    }

    @Test("a spare that is no longer ready stops the fill even when nothing was claimed")
    func guardStopsWhenTheSpareIsNotReady() {
        let reason = CitationPrefillGuard.stopReason(expectedGeneration: 4, currentGeneration: 4, claimedGeneration: nil, spareIsReady: false)
        #expect(reason == .spareNotReady)
    }

    // MARK: - Reading the page's answers

    @Test("begin: the agreed shape is read, with and without the statistics")
    func beginReplyAgreedShape() {
        let full = CitationPrefillBeginReply.parse(
            ["status": "ok", "groups": 408, "distinct": 256, "pending": 400, "unresolved": 8, "parseMs": 181.5] as [String: Any])
        #expect(full == CitationPrefillBeginReply(status: .accepted, groups: 408, distinct: 256, pending: 400, unresolved: 8, parseMs: 181.5))
        let minimal = CitationPrefillBeginReply.parse(["status": "ok", "pending": 0] as [String: Any])
        #expect(minimal == CitationPrefillBeginReply(status: .accepted, groups: nil, distinct: nil, pending: 0, unresolved: nil, parseMs: nil))
        #expect(CitationPrefillBeginReply.parse(["status": "notReady"] as [String: Any])?.status == .notReady)
        #expect(CitationPrefillBeginReply.parse(["status": "parseFailed"] as [String: Any])?.status == .parseFailed)
    }

    @Test("begin: anything else is not a reply")
    func beginReplyUnexpectedShapes() {
        #expect(CitationPrefillBeginReply.parse(nil) == nil)
        #expect(CitationPrefillBeginReply.parse("ok") == nil)
        #expect(CitationPrefillBeginReply.parse([Any]()) == nil)
        #expect(CitationPrefillBeginReply.parse([String: Any]()) == nil)
        #expect(CitationPrefillBeginReply.parse(["status": 1, "pending": 3] as [String: Any]) == nil)
        #expect(CitationPrefillBeginReply.parse(["status": "later", "pending": 3] as [String: Any]) == nil)
        // `ok` without a queue size cannot be trusted to mean "nothing to do".
        #expect(CitationPrefillBeginReply.parse(["status": "ok", "groups": 5] as [String: Any]) == nil)
        #expect(CitationPrefillBeginReply.parse(["status": "ok", "pending": "many"] as [String: Any]) == nil)
    }

    @Test("step: the agreed shape is read, and a boolean from JavaScript is a boolean")
    func stepReply() {
        let reply = CitationPrefillStepReply.parse(["done": NSNumber(value: false), "formatted": 42, "remaining": 100, "ms": 101.2] as [String: Any])
        #expect(reply == CitationPrefillStepReply(done: false, formatted: 42, remaining: 100, pageMs: 101.2))
        let finished = CitationPrefillStepReply.parse(["done": NSNumber(value: true), "remaining": 0] as [String: Any])
        #expect(finished == CitationPrefillStepReply(done: true, formatted: 0, remaining: 0, pageMs: 0))
        #expect(CitationPrefillStepReply.parse(nil) == nil)
        #expect(CitationPrefillStepReply.parse(["formatted": 3, "remaining": 1] as [String: Any]) == nil)
        #expect(CitationPrefillStepReply.parse(["done": true, "formatted": 3] as [String: Any]) == nil)
        #expect(CitationPrefillStepReply.parse(["done": "yes", "remaining": 1] as [String: Any]) == nil)
    }

    // MARK: - The step loop's stop rules

    private func step(done: Bool = false, formatted: Int, remaining: Int = 10) -> CitationPrefillStepReply {
        CitationPrefillStepReply(done: done, formatted: formatted, remaining: remaining, pageMs: 100)
    }

    @Test("progress: counts add up and the page's done ends the loop")
    func progressCompletes() {
        var progress = CitationPrefillProgress()
        #expect(progress.record(step(formatted: 30)) == nil)
        #expect(progress.record(step(formatted: 25)) == nil)
        #expect(progress.record(step(done: true, formatted: 5, remaining: 0)) == .completed)
        #expect(progress.steps == 3)
        #expect(progress.formatted == 60)
        #expect(progress.formatMs == 300)
    }

    @Test("progress: three steps in a row that format nothing end the loop, a step that formats resets the count")
    func progressNeedsProgress() {
        var progress = CitationPrefillProgress()
        #expect(progress.record(step(formatted: 0)) == nil)
        #expect(progress.record(step(formatted: 0)) == nil)
        #expect(progress.record(step(formatted: 4)) == nil)
        #expect(progress.record(step(formatted: 0)) == nil)
        #expect(progress.record(step(formatted: 0)) == nil)
        #expect(progress.record(step(formatted: 0)) == .noProgress)
    }

    @Test("progress: a page that never finishes is cut off at the step cap")
    func progressStepCap() {
        var progress = CitationPrefillProgress()
        var stop: CitationPrefillStop?
        for _ in 0..<CitationPrefillProgress.maxSteps where stop == nil { stop = progress.record(step(formatted: 1)) }
        #expect(stop == .stepLimit)
        #expect(progress.steps == CitationPrefillProgress.maxSteps)
    }

    // MARK: - The JavaScript sent to the page

    /// Evaluates an async-function body the way `callAsyncJavaScript` does (named arguments in scope) against a stub page.
    private func evaluate(_ body: String, argumentName: String, argument: Any, stubPage: String) -> Any? {
        guard let context = JSContext() else {
            Issue.record("JavaScriptCore could not create a context")
            return nil
        }
        var thrown: String?
        context.exceptionHandler = { _, exception in thrown = exception?.toString() }
        context.evaluateScript("var window = \(stubPage);")
        context.setObject(argument, forKeyedSubscript: argumentName as NSString)
        let result = context.evaluateScript("(function (\(argumentName)) { \(body) })(\(argumentName))")
        if let thrown { Issue.record("The page call threw: \(thrown)") }
        return result?.toObject()
    }

    @Test("a page without the fill functions answers missing, and the answer is recognised")
    func absentPageFunctionIsAStopNotAThrow() {
        for stub in ["{}", "{ FinalFinal: {} }", "{ FinalFinal: { prefillCitationsBegin: 3 } }"] {
            let begin = evaluate(CitationPrefillPageCalls.beginBody, argumentName: "markdown", argument: "a [@k] b", stubPage: stub)
            #expect(CitationPrefillPageCalls.isMissing(begin))
            #expect(CitationPrefillBeginReply.parse(begin) == nil)
        }
        let step = evaluate(CitationPrefillPageCalls.stepBody, argumentName: "budgetMs", argument: 100, stubPage: "{ FinalFinal: {} }")
        #expect(CitationPrefillPageCalls.isMissing(step))
        #expect(CitationPrefillStepReply.parse(step) == nil)
    }

    @Test("begin and step hand the document and the budget to the page function unchanged")
    func pageCallsForwardTheirArguments() {
        let document = "Text `with` backticks, a \\ backslash and ${dollar} \u{201C}quotes\u{201D} \u{4E2D}\u{6587} [@lee2010, p. 12]"
        let stub = """
            { FinalFinal: {
                prefillCitationsBegin: function (md) { return { status: 'ok', pending: md.length, echo: md }; },
                prefillCitationsStep: function (ms) { return { done: ms === 100, formatted: 1, remaining: 0, ms: ms }; }
            } }
            """
        let begin = evaluate(CitationPrefillPageCalls.beginBody, argumentName: "markdown", argument: document, stubPage: stub) as? [String: Any]
        #expect(begin?["echo"] as? String == document)
        #expect(CitationPrefillBeginReply.parse(begin)?.pending == (document as NSString).length)
        let step = evaluate(CitationPrefillPageCalls.stepBody, argumentName: "budgetMs", argument: 100, stubPage: stub)
        #expect(CitationPrefillStepReply.parse(step) == CitationPrefillStepReply(done: true, formatted: 1, remaining: 0, pageMs: 100))
    }

    @Test("the library push into the standby page is the call the mount makes, whatever the items contain")
    func libraryScriptRoundTrip() {
        guard let context = JSContext() else {
            Issue.record("JavaScriptCore could not create a context")
            return
        }
        context.evaluateScript("var received = null; var window = { FinalFinal: { setCitationLibrary: function (items) { received = items; } } };")
        let json = #"[{"id":"a`b","title":"back\\slash ${x} `tick`"},{"id":"plain","title":"Plain"}]"#
        context.evaluateScript(MilkdownEditor.Coordinator.setCitationLibraryScript(json))
        let received = context.evaluateScript("received")?.toObject() as? [[String: Any]]
        #expect(received?.count == 2)
        #expect(received?.first?["id"] as? String == "a`b")
        #expect(received?.first?["title"] as? String == "back\\slash ${x} `tick`")
    }

    @Test("the memo-off switch calls the page's switch when there is one and does nothing when there is not")
    func memoOffScript() {
        func run(_ stub: String) -> (returned: Bool?, calls: [Any]?) {
            guard let context = JSContext() else { return (nil, nil) }
            var thrown = false
            context.exceptionHandler = { _, _ in thrown = true }
            context.evaluateScript("var calls = []; var window = \(stub);")
            let returned = context.evaluateScript(CitationPrefillTestScripts.memoOff)?.toBool()
            #expect(!thrown)
            return (returned, context.evaluateScript("calls")?.toArray())
        }
        let present = run("{ FinalFinal: { setCitationMemoEnabled: function (on) { calls.push(on); } } }")
        #expect(present.returned == true)
        #expect(present.calls?.count == 1)
        #expect((present.calls?.first as? NSNumber)?.boolValue == false)
        #expect(run("{ FinalFinal: {} }").returned == false)
        #expect(run("{}").returned == false)
    }

    // MARK: - The UI-test switch

    @Test("the prefill switch is honoured only in a UI test and only for its three values")
    func prefillModeParsing() {
        func mode(_ value: String?, uiTesting: Bool = true) -> TestMode.UITestingCitationPrefillMode? {
            TestMode.citationPrefillMode(environment: value.map { ["FF_UI_TESTING_CITATION_PREFILL": $0] } ?? [:], isUITesting: uiTesting)
        }
        #expect(mode(nil) == nil)
        #expect(mode("off") == .off)
        #expect(mode("memoOff") == .memoOff)
        #expect(mode("trigger") == .trigger)
        #expect(mode("on") == nil)
        #expect(mode("") == nil)
        #expect(mode("trigger", uiTesting: false) == nil)
        #expect(mode("memoOff", uiTesting: false) == nil)
    }

    @Test("with no UI-test flag set the scheduler is on and the memo is not turned off")
    func noFlagMeansTheAppAsTheUserHasIt() {
        // The unit-test process is not a UI test, so the read-once switch is nil whatever the environment says.
        #expect(TestMode.uiTestingCitationPrefillMode == nil)
        #expect(!TestMode.isUITestingCitationMemoOff)
        #expect(TestMode.isCitationPrefillSchedulerEnabled)
    }

    @Test("the scheduler is on unless a UI test asked for off or memoOff; trigger means the same as unset")
    func schedulerSwitch() {
        #expect(TestMode.citationPrefillSchedulerEnabled(for: nil))
        #expect(TestMode.citationPrefillSchedulerEnabled(for: .trigger))
        #expect(!TestMode.citationPrefillSchedulerEnabled(for: .off))
        #expect(!TestMode.citationPrefillSchedulerEnabled(for: .memoOff))
    }
}
