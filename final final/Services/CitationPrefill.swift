//
//  CitationPrefill.swift
//  final final
//
//  The pure pieces of "work the document's citations out ahead of time" (plan: .claude/superdev/write-queue-phase3b/
//  plan-citations-ahead-of-time.md). `EditorPreloader.prefillCitations` is the one production function that drives
//  the spare Rich Text page; everything it decides without touching a web view lives here so unit tests can reach it:
//
//    * `CitationPrefillGuard`      -- is the spare still the one this fill started on (not claimed, not replaced)?
//    * `CitationPrefillBeginReply` -- what `window.FinalFinal.prefillCitationsBegin` answered, or nil if the shape is not the agreed one
//    * `CitationPrefillStepReply`  -- the same for `prefillCitationsStep`
//    * `CitationPrefillProgress`   -- the steps taken so far and when to give up on a page that is not making progress
//    * `CitationPrefillOutcome`    -- everything one fill did, for the log line and the caller
//    * `CitationPrefillPageCalls`  -- the JavaScript bodies sent to the page (an absent page function is a stop, never a throw)
//
//  Nothing here runs unless `EditorPreloader.prefillCitations` is called; its one caller is `CitationPrefillScheduler`
//  (CitationPrefillScheduler.swift), which decides when.
//

import Foundation

/// Why a fill ended. `completed` is the only success; every other case means the memo may be only partly filled, which is
/// harmless (a group missing from the page's memo is formatted at the switch exactly as today).
enum CitationPrefillStop: Equatable {
    case completed
    /// The spare was handed to an editor (claimed) while the fill was running or before it began.
    case claimed
    /// The spare was replaced by a newer one (its generation is no longer the one this fill started on).
    case replaced
    /// The generation is unchanged but the spare is not in the ready state any more (its page failed).
    case spareNotReady
    /// The page has no editor yet (`prefillCitationsBegin` answered `notReady`).
    case notReady
    case parseFailed
    /// `window.FinalFinal` has no `prefillCitationsBegin` / `prefillCitationsStep` (a page built without the web side).
    case pageFunctionMissing
    /// Three steps in a row formatted nothing without finishing: the page is not making progress.
    case noProgress
    case stepLimit
    /// The page call itself threw (the text is the error).
    case pageError(String)
    /// The reply was not the agreed shape (the text says which call).
    case unexpectedReply(String)
    /// There was no document text to send (the scheduler never asks for a fill without text, so this is a guard, not a flow).
    case noDocument

    /// Short stable text for the log line.
    var logText: String {
        switch self {
        case .completed: return "completed"
        case .claimed: return "claimed"
        case .replaced: return "replaced"
        case .spareNotReady: return "spareNotReady"
        case .notReady: return "notReady"
        case .parseFailed: return "parseFailed"
        case .pageFunctionMissing: return "pageFunctionMissing"
        case .noProgress: return "noProgress"
        case .stepLimit: return "stepLimit"
        case .pageError(let text): return "pageError: \(text)"
        case .unexpectedReply(let text): return "unexpectedReply: \(text)"
        case .noDocument: return "noDocument"
        }
    }
}

/// The generation-and-claim check made before the library push, before `begin` and before every `step`.
enum CitationPrefillGuard {
    /// nil means "go on". `claimedGeneration` is the generation of the spare most recently handed out by `claimMilkdownView()`;
    /// `spareIsReady` is whether the preloader's Rich Text spare is in its ready (loaded, unclaimed) state right now.
    static func stopReason(
        expectedGeneration: Int, currentGeneration: Int, claimedGeneration: Int?, spareIsReady: Bool
    ) -> CitationPrefillStop? {
        if expectedGeneration == claimedGeneration { return .claimed }
        if expectedGeneration != currentGeneration { return .replaced }
        if !spareIsReady { return .spareNotReady }
        return nil
    }
}

/// `window.FinalFinal.prefillCitationsBegin(markdown)`'s answer, agreed in the plan (W2):
/// `{ status: 'ok' | 'notReady' | 'parseFailed', groups, distinct, pending, unresolved, parseMs }`. Only `status` (and, for `ok`,
/// `pending`) are required; the statistics are carried when present.
struct CitationPrefillBeginReply: Equatable {
    enum Status: String {
        /// The page's `ok`: the groups are queued.
        case accepted = "ok"
        case notReady, parseFailed
    }

    var status: Status
    var groups: Int?
    var distinct: Int?
    var pending: Int
    var unresolved: Int?
    var parseMs: Double?

    /// nil for any shape other than the agreed one. `missing` (the page has no such function) is not a reply: the caller's page call
    /// body answers `{ status: 'missing' }` and `CitationPrefillPageCalls.isMissing` recognises it first.
    static func parse(_ raw: Any?) -> CitationPrefillBeginReply? {
        guard let dictionary = raw as? [String: Any],
              let statusText = dictionary["status"] as? String,
              let status = Status(rawValue: statusText) else { return nil }
        let pending = number(dictionary["pending"]).map { Int($0) }
        if status == .accepted, pending == nil { return nil }
        return CitationPrefillBeginReply(
            status: status, groups: number(dictionary["groups"]).map { Int($0) }, distinct: number(dictionary["distinct"]).map { Int($0) },
            pending: pending ?? 0, unresolved: number(dictionary["unresolved"]).map { Int($0) }, parseMs: number(dictionary["parseMs"]))
    }
}

/// `window.FinalFinal.prefillCitationsStep(budgetMs)`'s answer: `{ done, formatted, remaining, ms }`. `done` and `remaining` are required.
struct CitationPrefillStepReply: Equatable {
    var done: Bool
    var formatted: Int
    var remaining: Int
    /// Milliseconds the page spent formatting in this step.
    var pageMs: Double

    static func parse(_ raw: Any?) -> CitationPrefillStepReply? {
        guard let dictionary = raw as? [String: Any],
              let done = (dictionary["done"] as? NSNumber)?.boolValue,
              let remaining = number(dictionary["remaining"]) else { return nil }
        return CitationPrefillStepReply(
            done: done, formatted: number(dictionary["formatted"]).map { Int($0) } ?? 0, remaining: Int(remaining),
            pageMs: number(dictionary["ms"]) ?? 0)
    }
}

private func number(_ any: Any?) -> Double? {
    (any as? NSNumber)?.doubleValue
}

/// The steps taken so far. `record` says whether the loop must stop.
struct CitationPrefillProgress {
    static let maxStalledSteps = 3
    /// 100 ms of page work per step: 5000 steps is more than eight minutes, far beyond any document.
    static let maxSteps = 5000

    var steps = 0
    var formatted = 0
    var formatMs = 0.0
    private(set) var stalledSteps = 0

    /// Adds one step's answer. Returns `.completed` when the page says it is done, `.noProgress` after three steps in a row that
    /// formatted nothing, `.stepLimit` at the step cap, nil to go on.
    mutating func record(_ reply: CitationPrefillStepReply) -> CitationPrefillStop? {
        steps += 1
        formatted += reply.formatted
        formatMs += reply.pageMs
        if reply.done { return .completed }
        stalledSteps = reply.formatted == 0 ? stalledSteps + 1 : 0
        if stalledSteps >= Self.maxStalledSteps { return .noProgress }
        if steps >= Self.maxSteps { return .stepLimit }
        return nil
    }
}

/// What one fill did. Filled in by `EditorPreloader.prefillCitations` and returned to the caller.
struct CitationPrefillOutcome {
    var generation: Int
    var documentChars: Int
    var stop: CitationPrefillStop = .noDocument
    var begin: CitationPrefillBeginReply?
    var steps = 0
    var formatted = 0
    var libraryPushed = false
    var totalMs = 0.0

    var completed: Bool { stop == .completed }
}

/// The JavaScript sent to the page. Each is the body of an async function (`callAsyncJavaScript`), with the named argument in scope.
enum CitationPrefillPageCalls {
    static let beginBody = """
        var ff = window.FinalFinal;
        if (!ff || typeof ff.prefillCitationsBegin !== 'function') { return { status: 'missing' }; }
        return ff.prefillCitationsBegin(markdown);
        """

    static let stepBody = """
        var ff = window.FinalFinal;
        if (!ff || typeof ff.prefillCitationsStep !== 'function') { return { status: 'missing' }; }
        return ff.prefillCitationsStep(budgetMs);
        """

    /// True for the answer the bodies above give when the page function does not exist.
    static func isMissing(_ raw: Any?) -> Bool {
        ((raw as? [String: Any])?["status"] as? String) == "missing"
    }
}

/// UI-test-only page switches (`TestMode.uiTestingCitationPrefillMode`).
enum CitationPrefillTestScripts {
    /// Turns the page's citation memo off if the page has the switch; answers whether it did.
    static let memoOff = """
        (function () {
          var ff = window.FinalFinal;
          if (ff && typeof ff.setCitationMemoEnabled === 'function') { ff.setCitationMemoEnabled(false); return true; }
          return false;
        })()
        """
}
