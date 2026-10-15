//
//  CitationPrefillSchedulerTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  `CitationPrefillScheduler` decides WHEN the standby Rich Text page works the document's citations out ahead of time. The
//  scheduler takes everything outside it as closures, so these tests run it with a controllable clock and a stand-in for the fill:
//  no web view, no real waiting, every step in order.
//
//  1. The change detector (`CitationGroupSignature`): it moves when the set of citation brackets moves and at no other time.
//  2. When a fill runs: after the standby page is ready, after a typing pause, after a library or style change, on a replacement
//     page, for another project's text.
//  3. When it does not: no page, no text, nothing changed since the last fill (prose-only typing), a failed page.
//  4. The keystroke path: nothing but storing the text; one waiting task however long the burst; never two fills at once.
//  5. A claim during a fill, a trigger during a fill, the one retry of a page that had no editor yet.
//

import Foundation
import Testing
@testable import final_final

// MARK: - The change detector

@Suite("Citation group signature")
struct CitationGroupSignatureTests {

    private func sig(_ text: String) -> Int { CitationGroupSignature.of(text) }

    private let base = "# Title\n\nSome prose. As shown [@lee2010, p. 12] and by [@kim2015; @park2018]."

    @Test("prose typed around the citations does not move the signature")
    func proseDoesNotMoveIt() {
        let edited = "# A new title\n\nQuite different prose, longer now, 中文 included. As shown [@lee2010, p. 12] and by [@kim2015; @park2018]. More."
        #expect(sig(base) == sig(edited))
        #expect(sig("") == sig("no brackets at all"))
        #expect(sig("a [link](https://example.org) and a footnote[^1] and [plain text]") == sig(""))
    }

    @Test("a citation added, removed or edited moves it")
    func citationEditsMoveIt() {
        #expect(sig(base) != sig(base + " Also [@new2020]."))
        #expect(sig(base) != sig(base.replacingOccurrences(of: "[@kim2015; @park2018]", with: "[@kim2015]")))
        #expect(sig(base) != sig(base.replacingOccurrences(of: "p. 12", with: "p. 13")))
        #expect(sig(base) != sig(base.replacingOccurrences(of: "[@lee2010, p. 12]", with: "[-@lee2010, p. 12]")))
    }

    @Test("the same bracket twice, or the brackets in another order, is the same signature")
    func setNotSequence() {
        #expect(sig(base) == sig(base + " Again [@lee2010, p. 12]."))
        let reordered = "Intro. [@kim2015; @park2018] then [@lee2010, p. 12]."
        let original = "Intro. [@lee2010, p. 12] then [@kim2015; @park2018]."
        #expect(sig(reordered) == sig(original))
    }

    @Test("it agrees with the shared span regex about which texts have the same brackets")
    func agreesWithTheRegex() {
        let corpus = [
            "", "plain", "[@a]", "[@a] [@a]", "[@a] and [@b]", "[@b] and [@a]", "[see [@a] and @b]", "[@a", "[@a] [@b", "] [@a] ]",
            "[x](u) [@a]", "[me@example.com]", "[^1] [@a]", "中文 [@a, 第3页] 中文", "[@a]\n[@b]", "[[@a]]", "[@a]]", "[]", "[@]",
            "[@a, p. 1]", "[@a, p. 2]", "text [without] at"
        ]
        func oracle(_ text: String) -> Set<String> {
            let nsText = text as NSString
            let spans = ExportCitationRegex.span.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            return Set(spans.map { nsText.substring(with: $0.range) }.filter { $0.contains("@") })
        }
        for first in corpus {
            for second in corpus {
                let sameSpans = oracle(first) == oracle(second)
                #expect((sig(first) == sig(second)) == sameSpans, "texts: \(first.debugDescription) / \(second.debugDescription)")
            }
        }
    }
}

// MARK: - The scheduler

/// A clock the test moves by hand. `sleep` suspends until `advance` reaches its wake time; time passes in order, so a task that
/// wakes and sleeps again inside one `advance` is woken again if its new wake time is still inside it.
@MainActor
private final class ManualClock {
    private(set) var current: TimeInterval = 0
    private var sleepers: [(wake: TimeInterval, continuation: CheckedContinuation<Void, Never>)] = []

    var pendingSleepers: Int { sleepers.count }

    func now() -> TimeInterval { current }

    func sleep(_ seconds: TimeInterval) async {
        await withCheckedContinuation { sleepers.append((current + seconds, $0)) }
    }

    func advance(by seconds: TimeInterval) async {
        let target = current + seconds
        await settle()
        while let next = sleepers.filter({ $0.wake <= target }).min(by: { $0.wake < $1.wake }) {
            current = max(current, next.wake)
            if let index = sleepers.firstIndex(where: { $0.wake == next.wake }) {
                sleepers.remove(at: index).continuation.resume()
            }
            await settle()
        }
        current = target
        await settle()
    }

    /// Lets every task that can run on the main actor run until it waits for something only the test can give.
    func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }
}

/// The scheduler wired to a manual clock and a stand-in fill that records what it was asked for.
@MainActor
private final class Harness {
    struct Fill: Equatable {
        var generation: Int
        var text: String
        var pushLibrary: Bool
    }

    let clock = ManualClock()
    var scheduler: CitationPrefillScheduler!

    // What the app would answer.
    var readyGeneration: Int? = 1
    var libraryRevision = 0
    /// Whether a library exists to push (the real fill pushes nothing when the cached library is `[]`).
    var libraryAvailable = true
    /// How the next fills end; once empty every fill completes.
    var nextStops: [CitationPrefillStop] = []
    /// While true a fill does not return until `releaseFill()`.
    var holdFills = false

    // What the scheduler did.
    private(set) var fills: [Fill] = []
    private(set) var signatureCalls = 0
    private(set) var maxFillsInFlight = 0
    private var fillsInFlight = 0
    private var gate: CheckedContinuation<Void, Never>?

    init() {
        let environment = CitationPrefillScheduler.Environment(
            readySpareGeneration: { [unowned self] in self.readyGeneration },
            libraryRevision: { [unowned self] in self.libraryRevision },
            signature: { [unowned self] text in
                self.signatureCalls += 1
                return CitationGroupSignature.of(text)
            },
            fill: { [unowned self] generation, text, pushLibrary in
                self.fills.append(Fill(generation: generation, text: text, pushLibrary: pushLibrary))
                self.fillsInFlight += 1
                self.maxFillsInFlight = max(self.maxFillsInFlight, self.fillsInFlight)
                if self.holdFills { await withCheckedContinuation { self.gate = $0 } }
                self.fillsInFlight -= 1
                var outcome = CitationPrefillOutcome(generation: generation, documentChars: text.utf16.count)
                outcome.stop = self.nextStops.isEmpty ? .completed : self.nextStops.removeFirst()
                outcome.libraryPushed = pushLibrary && self.libraryAvailable
                return outcome
            },
            now: { [unowned self] in self.clock.now() },
            sleep: { [unowned self] seconds in await self.clock.sleep(seconds) })
        scheduler = CitationPrefillScheduler(environment: environment)
    }

    func advance(_ seconds: TimeInterval) async { await clock.advance(by: seconds) }

    func releaseFill() async {
        holdFills = false
        gate?.resume()
        gate = nil
        await clock.settle()
    }

    /// The standby page is ready, the document is open, and the first fill has run.
    func startWithFirstFill(_ text: String = Doc.cited) async {
        scheduler.documentChanged(text)
        await advance(2.1)
    }
}

private enum Doc {
    static let prose = "# Title\n\nSome prose without any citation."
    static let cited = prose + " As shown [@lee2010, p. 12]."
    static let moreCited = cited + " And [@kim2015] too."
    static let otherProject = "# Other book\n\nAnother project entirely [@mori1999]."
}

@Suite("Citation prefill scheduler")
@MainActor
struct CitationPrefillSchedulerTests {

    // MARK: - When a fill runs

    @Test("with no standby page nothing happens, however long the document is edited")
    func noSpareNoFill() async {
        let harness = Harness()
        harness.readyGeneration = nil
        harness.scheduler.documentChanged(Doc.cited)
        harness.scheduler.libraryChanged()
        await harness.advance(10)
        #expect(harness.fills.isEmpty)
        #expect(harness.signatureCalls == 0)
    }

    @Test("a standby page that becomes ready gets its fill 1.5 s later, not before")
    func fillsAfterSpareReady() async {
        let harness = Harness()
        harness.readyGeneration = nil
        harness.scheduler.documentChanged(Doc.cited)
        await harness.advance(2.1)   // the typing pause passes with no page: nothing
        #expect(harness.fills.isEmpty)

        harness.readyGeneration = 1
        harness.scheduler.spareBecameReady()
        await harness.advance(1.4)
        #expect(harness.fills.isEmpty)
        await harness.advance(0.2)
        #expect(harness.fills == [Harness.Fill(generation: 1, text: Doc.cited, pushLibrary: true)])
    }

    @Test("a burst of document changes inside the pause gives one fill, 2 s after the last change")
    func burstGivesOneFill() async {
        let harness = Harness()
        harness.scheduler.documentChanged(Doc.prose)
        await harness.advance(1)
        harness.scheduler.documentChanged(Doc.cited)
        await harness.advance(1.9)
        harness.scheduler.documentChanged(Doc.moreCited)
        await harness.advance(1.9)   // 3.8 s after the first change, 1.9 s after the last: not yet
        #expect(harness.fills.isEmpty)
        await harness.advance(0.2)
        #expect(harness.fills == [Harness.Fill(generation: 1, text: Doc.moreCited, pushLibrary: true)])
    }

    @Test("a citation added after the first fill gives one more fill, with no library push at the same revision")
    func changedCitationsFillAgain() async {
        let harness = Harness()
        await harness.startWithFirstFill()
        harness.scheduler.documentChanged(Doc.moreCited)
        await harness.advance(2.1)
        #expect(harness.fills.count == 2)
        #expect(harness.fills.last == Harness.Fill(generation: 1, text: Doc.moreCited, pushLibrary: false))
    }

    @Test("a library revision change pushes the library again and fills")
    func libraryChangePushesAndFills() async {
        let harness = Harness()
        await harness.startWithFirstFill()
        harness.libraryRevision = 1
        harness.scheduler.libraryChanged()
        await harness.advance(2.1)
        #expect(harness.fills.count == 2)
        #expect(harness.fills.last == Harness.Fill(generation: 1, text: Doc.cited, pushLibrary: true))
    }

    @Test("a revision bump with identical contents costs one more fill and nothing after it")
    func identicalLibraryCostsOneFill() async {
        let harness = Harness()
        await harness.startWithFirstFill()
        // The same items written again: the revision moves, the contents do not (the page keeps its memo; see citeproc-memo.test.ts).
        harness.libraryRevision = 1
        harness.scheduler.libraryChanged()
        await harness.advance(2.1)
        #expect(harness.fills.count == 2)
        // Typing prose afterwards, and triggers with no new revision, add nothing.
        harness.scheduler.documentChanged(Doc.cited + " prose")
        harness.scheduler.libraryChanged()
        await harness.advance(10)
        #expect(harness.fills.count == 2)
    }

    @Test("a style change fills again, without pushing the library")
    func styleChangeFills() async {
        let harness = Harness()
        await harness.startWithFirstFill()
        harness.scheduler.styleChanged()
        await harness.advance(2.1)
        #expect(harness.fills.count == 2)
        #expect(harness.fills.last == Harness.Fill(generation: 1, text: Doc.cited, pushLibrary: false))
        await harness.advance(10)
        #expect(harness.fills.count == 2)
    }

    @Test("a replacement standby page gets its own library push and fill, whatever the first page had")
    func replacementSpareGetsItsOwnFill() async {
        let harness = Harness()
        await harness.startWithFirstFill()
        harness.scheduler.spareClaimed()
        harness.readyGeneration = nil
        await harness.advance(5)
        #expect(harness.fills.count == 1)

        harness.readyGeneration = 3
        harness.scheduler.spareBecameReady()
        await harness.advance(1.6)
        #expect(harness.fills.count == 2)
        #expect(harness.fills.last == Harness.Fill(generation: 3, text: Doc.cited, pushLibrary: true))
    }

    @Test("opening another project fills against the same standby page, with the library pushed again")
    func projectSwitchFillsAgain() async {
        let harness = Harness()
        await harness.startWithFirstFill()
        // Close empties the text and the library cache; open loads the other project's items and text.
        harness.scheduler.documentChanged("")
        harness.libraryRevision = 1
        harness.scheduler.libraryChanged()
        harness.libraryRevision = 2
        harness.scheduler.libraryChanged()
        harness.scheduler.documentChanged(Doc.otherProject)
        await harness.advance(2.1)
        #expect(harness.fills.count == 2)
        #expect(harness.fills.last == Harness.Fill(generation: 1, text: Doc.otherProject, pushLibrary: true))
    }

    // MARK: - When it does not

    @Test("an empty document (project closed) does nothing")
    func emptyTextDoesNothing() async {
        let harness = Harness()
        harness.scheduler.documentChanged("")
        await harness.advance(10)
        #expect(harness.fills.isEmpty)
        #expect(harness.signatureCalls == 0)
    }

    @Test("prose typed without touching a citation causes no fill after the first, only a scan per pause")
    func proseOnlyTypingCausesNoFill() async {
        let harness = Harness()
        await harness.startWithFirstFill()
        #expect(harness.fills.count == 1)
        for index in 1...6 {
            harness.scheduler.documentChanged(Doc.cited + String(repeating: " more prose", count: index))
            await harness.advance(2.1)
        }
        #expect(harness.fills.count == 1)
        #expect(harness.signatureCalls == 7)   // the first fill's scan plus one per pause
    }

    @Test("a page that failed is not asked again at every pause")
    func failedFillIsNotRetriedAtEveryPause() async {
        let harness = Harness()
        harness.nextStops = [.pageError("boom")]
        await harness.startWithFirstFill()
        harness.scheduler.documentChanged(Doc.cited + " prose")
        await harness.advance(10)
        #expect(harness.fills.count == 1)
        // A real change is tried again.
        harness.scheduler.documentChanged(Doc.moreCited)
        await harness.advance(2.1)
        #expect(harness.fills.count == 2)
    }

    // MARK: - The keystroke path

    @Test("typing starts no scan and no fill, and leaves one waiting task however many keystrokes")
    func keystrokesStartNothing() async {
        let harness = Harness()
        for index in 0..<40 {
            harness.scheduler.documentChanged(Doc.cited + String(repeating: "x", count: index))
            await harness.advance(0.05)
            #expect(harness.clock.pendingSleepers <= 1)
        }
        #expect(harness.signatureCalls == 0)
        #expect(harness.fills.isEmpty)
        await harness.advance(2)   // the pause arrives
        #expect(harness.signatureCalls == 1)
        #expect(harness.fills.count == 1)
    }

    @Test("never more than one fill is in flight, however many triggers arrive meanwhile")
    func neverTwoFillsAtOnce() async {
        let harness = Harness()
        harness.holdFills = true
        await harness.startWithFirstFill()
        #expect(harness.fills.count == 1)
        for revision in 1...3 {
            harness.libraryRevision = revision
            harness.scheduler.libraryChanged()
            harness.scheduler.documentChanged(Doc.moreCited + String(repeating: "!", count: revision))
            await harness.advance(3)
        }
        #expect(harness.fills.count == 1)
        await harness.releaseFill()
        await harness.advance(2.1)
        #expect(harness.fills.count == 2)   // one follow-up for everything that arrived meanwhile
        #expect(harness.maxFillsInFlight == 1)
    }

    // MARK: - During a fill

    @Test("a claim during a fill stops the follow-up for that page; the replacement gets its own fill")
    func claimDuringFill() async {
        let harness = Harness()
        harness.holdFills = true
        await harness.startWithFirstFill()
        #expect(harness.fills.count == 1)

        harness.scheduler.spareClaimed()
        harness.readyGeneration = nil
        harness.nextStops = [.claimed]
        await harness.releaseFill()   // the fill ends "claimed", late
        await harness.advance(10)
        #expect(harness.fills.count == 1)

        harness.readyGeneration = 3
        harness.scheduler.spareBecameReady()
        await harness.advance(1.6)
        #expect(harness.fills.map(\.generation) == [1, 3])
    }

    @Test("a fill that ends normally after the claim is ignored, not remembered")
    func lateCompletedResultIsIgnored() async {
        let harness = Harness()
        harness.holdFills = true
        await harness.startWithFirstFill()
        harness.scheduler.spareClaimed()
        harness.readyGeneration = nil
        await harness.releaseFill()   // completes, but for a page that is gone
        harness.readyGeneration = 3
        harness.scheduler.spareBecameReady()
        await harness.advance(1.6)
        #expect(harness.fills.map(\.generation) == [1, 3])
        #expect(harness.fills.last?.pushLibrary == true)
    }

    @Test("a citation change during a fill gives exactly one follow-up fill once it ends")
    func citationChangeDuringFillGivesOneFollowUp() async {
        let harness = Harness()
        harness.holdFills = true
        await harness.startWithFirstFill()
        harness.scheduler.documentChanged(Doc.moreCited)
        await harness.advance(2.1)   // the pause passes while the fill is still running
        #expect(harness.fills.count == 1)
        await harness.releaseFill()
        await harness.advance(2.1)
        #expect(harness.fills.count == 2)
        #expect(harness.fills.last?.text == Doc.moreCited)
        await harness.advance(10)
        #expect(harness.fills.count == 2)
    }

    @Test("prose typed during a fill gives no follow-up fill")
    func proseDuringFillGivesNoFollowUp() async {
        let harness = Harness()
        harness.holdFills = true
        await harness.startWithFirstFill()
        harness.scheduler.documentChanged(Doc.cited + " typed while the page was busy")
        await harness.advance(2.1)
        await harness.releaseFill()
        await harness.advance(10)
        #expect(harness.fills.count == 1)
    }

    // MARK: - A page with no editor yet

    @Test("a page that had no editor yet is tried once more after a second, and no third time")
    func notReadyRetriedOnce() async {
        let harness = Harness()
        harness.nextStops = [.notReady, .notReady]
        await harness.startWithFirstFill()
        #expect(harness.fills.count == 1)
        await harness.advance(0.8)   // the fill ran at 2.0 s; the retry is due at 3.0 s
        #expect(harness.fills.count == 1)
        await harness.advance(0.3)
        #expect(harness.fills.count == 2)
        await harness.advance(10)
        #expect(harness.fills.count == 2)
        // A real change starts afresh.
        harness.scheduler.documentChanged(Doc.moreCited)
        await harness.advance(2.1)
        #expect(harness.fills.count == 3)
    }

    @Test("a retry that succeeds is the end of it")
    func notReadyThenOk() async {
        let harness = Harness()
        harness.nextStops = [.notReady]
        await harness.startWithFirstFill()
        await harness.advance(1.1)
        #expect(harness.fills.count == 2)
        await harness.advance(10)
        #expect(harness.fills.count == 2)
    }
}
