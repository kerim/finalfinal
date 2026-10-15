//
//  CitationPrefillScheduler.swift
//  final final
//
//  WHEN the standby Rich Text page works the document's citations out ahead of time
//  (plan: .claude/superdev/write-queue-phase3b/plan-citations-ahead-of-time.md, step S1; the work itself is
//  `EditorPreloader.prefillCitations`, see EditorPreloader+CitationPrefill.swift).
//
//  A fill is only worth doing when something it depends on has changed since the last one for the same standby page, so the
//  scheduler remembers what the last fill was done for -- the spare page, the document's set of citation brackets, the library of
//  cited items and the citation style -- and runs another only when one of the four differs:
//
//    * document change  -> 2 s after the last change (a typing pause); the citation-bracket signature is worked out OFF the main
//                          thread, and a pause in which no citation was touched ends there (no page work at all);
//    * library change   -> 2 s after the last one (the Zotero service reports each write to its cache);
//    * style change     -> 2 s after the last one;
//    * spare ready      -> 1.5 s after the standby page finished loading (its style push is already queued in the page).
//
//  What the keystroke path costs: `documentChanged` stores the text (a reference, no copy), bumps a counter and moves a due time.
//  It starts nothing heavier than one task per burst of changes; the scan and the page work happen later, off that path.
//
//  Everything outside the scheduler is injected (`Environment`), so the unit tests run it without a web view or a clock.
//

import Foundation

/// A change detector for "did the document's citations change?": the set of distinct `[...]` spans that contain an `@`, as 64-bit
/// hashes combined in sorted order. A superset of the real citation groups is fine (a link text with an `@` is in it); it is never
/// used to decide what a citation says, only to decide that a fill might have something new to do. Same span rule as
/// `ExportCitationRegex.span` (`\[[^\]]*\]`: a `[`, everything up to the next `]`, nested `[` included), without the regex.
enum CitationGroupSignature {
    private static let fnvOffset: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let fnvPrime: UInt64 = 0x0000_0100_0000_01b3

    /// One linear pass over the UTF-8 bytes; nothing is allocated per character. Safe to call from any thread.
    nonisolated static func of(_ markdown: String) -> Int {
        var text = markdown
        return text.withUTF8 { combinedHash(ofSpansIn: $0) }
    }

    private nonisolated static func combinedHash(ofSpansIn bytes: UnsafeBufferPointer<UInt8>) -> Int {
        let open = UInt8(ascii: "["), close = UInt8(ascii: "]"), marker = UInt8(ascii: "@")
        var spans = Set<UInt64>()
        var index = 0
        while index < bytes.count {
            guard bytes[index] == open else {
                index += 1
                continue
            }
            var hash = fnvOffset
            var hasMarker = false
            var end = index
            while end < bytes.count {
                let byte = bytes[end]
                hash = (hash ^ UInt64(byte)) &* fnvPrime
                if byte == marker { hasMarker = true }
                if byte == close && end > index { break }
                end += 1
            }
            // An unclosed `[` has no later span either (the next `[` would also run to the end without a `]`).
            guard end < bytes.count else { break }
            if hasMarker { spans.insert(hash) }
            index = end + 1
        }
        var combined = fnvOffset
        for span in spans.sorted() {
            var value = span
            for _ in 0..<8 {
                combined = (combined ^ (value & 0xff)) &* fnvPrime
                value >>= 8
            }
        }
        combined = (combined ^ UInt64(spans.count)) &* fnvPrime
        return Int(truncatingIfNeeded: combined)
    }
}

@MainActor
final class CitationPrefillScheduler {

    /// The pauses before a fill. The defaults are the plan's; the unit tests use the same numbers against a controllable clock.
    struct Delays: Equatable {
        /// After the last document, library or style change.
        var afterChange: TimeInterval = 2
        /// After the standby page finished loading.
        var afterSpareReady: TimeInterval = 1.5
        /// Before the one retry of a fill whose page had no editor yet.
        var beforeNotReadyRetry: TimeInterval = 1
    }

    /// Everything the last fill was done for. A new fill runs only when the next one's key differs.
    struct Key: Equatable {
        var generation: Int
        var signature: Int
        var libraryRevision: Int
        var styleRevision: Int
    }

    /// Everything outside the scheduler. Each closure is called on the main actor.
    struct Environment {
        /// The generation of the standby Rich Text page if it is loaded and unclaimed right now, else nil.
        var readySpareGeneration: @MainActor () -> Int?
        /// Counts the writes to the Zotero service's cached items (a bump with identical contents is expected and harmless).
        var libraryRevision: @MainActor () -> Int
        /// `CitationGroupSignature.of`, worked out off the main thread.
        var signature: @MainActor (String) async -> Int
        /// One fill on the standby page of `generation` (`EditorPreloader.prefillCitations`). `pushLibrary` says whether the page
        /// must be given the cached library first; the closure may still skip the push if there is no library.
        var fill: @MainActor (_ generation: Int, _ markdown: String, _ pushLibrary: Bool) async -> CitationPrefillOutcome
        /// Seconds on a monotonic clock.
        var now: @MainActor () -> TimeInterval
        var sleep: @MainActor (TimeInterval) async -> Void
    }

    private let environment: Environment
    private let delays: Delays

    /// The latest document text and how many times it changed; `documentChanged` writes only these and `deadline`.
    private var latestText = ""
    private var textSerial = 0
    /// When the next evaluation is due (nil: nothing armed). Later triggers move it later, never earlier.
    private var deadline: TimeInterval?
    /// Exists while something is armed or an evaluation (and its fill) is running: at most one fill is ever in flight.
    private var runner: Task<Void, Never>?
    /// Counts `styleChanged()` calls. A style notification that changes nothing (the page compares what it is pushed with what it
    /// already runs) costs one fill that finds every citation in the memo already.
    private var styleRevision = 0
    private var lastFinished: Key?
    /// The spare and library revision of the last library push the scheduler asked for.
    private var pushedLibrary: (generation: Int, revision: Int)?
    /// The key of a fill whose page had no editor yet, retried once.
    private var notReadyRetryKey: Key?

    init(environment: Environment, delays: Delays = Delays()) {
        self.environment = environment
        self.delays = delays
    }

    // MARK: - Triggers

    /// The document text changed (both editors, project open). The keystroke path: nothing here but storing the text.
    func documentChanged(_ text: String) {
        latestText = text
        textSerial &+= 1
        arm(after: delays.afterChange)
    }

    /// The Zotero service's cached items were written.
    func libraryChanged() {
        arm(after: delays.afterChange)
    }

    /// The citation style changed (the preloader has already passed it to the standby page).
    func styleChanged() {
        styleRevision += 1
        arm(after: delays.afterChange)
    }

    /// The standby page finished loading and was given its style.
    func spareBecameReady() {
        arm(after: delays.afterSpareReady)
    }

    /// The standby page was handed to an editor. Whatever was armed was meant for it; the replacement page announces itself with
    /// `spareBecameReady`. A fill still running on the claimed page stops by itself at its next generation check, and its answer is
    /// ignored (the page's generation is no longer the ready one).
    func spareClaimed() {
        deadline = nil
    }

    // MARK: - Running

    private func arm(after delay: TimeInterval) {
        let due = environment.now() + delay
        deadline = max(deadline ?? due, due)
        if runner == nil {
            runner = Task { await self.run() }
        }
    }

    private func run() async {
        while true {
            while let due = deadline {
                let remaining = due - environment.now()
                if remaining <= 0 { break }
                await environment.sleep(remaining)
            }
            guard deadline != nil else { break }
            deadline = nil
            await evaluate()
            // Triggers that arrived during the evaluation armed a new deadline: go round once more, after its pause.
            if deadline == nil { break }
        }
        runner = nil
    }

    /// One look at whether a fill is due, and the fill if so.
    private func evaluate() async {
        guard let generation = environment.readySpareGeneration() else { return }
        let text = latestText
        guard !text.isEmpty else { return }
        let serial = textSerial
        let signature = await environment.signature(text)
        // A change during the scan armed its own evaluation; a spare change makes this evaluation about a page that is gone.
        guard serial == textSerial, environment.readySpareGeneration() == generation else { return }

        // Read after the scan, right before the fill, which pushes the library in its first synchronous step.
        let key = Key(
            generation: generation, signature: signature,
            libraryRevision: environment.libraryRevision(), styleRevision: styleRevision)
        if key == lastFinished { return }

        let pushLibrary = pushedLibrary?.generation != generation || pushedLibrary?.revision != key.libraryRevision
        DebugLog.log(
            .zotero, "[CitationPrefill] fill starting: generation \(generation), \(text.utf16.count) chars, pushLibrary \(pushLibrary)")
        let outcome = await environment.fill(generation, text, pushLibrary)

        // A claim or replacement during the fill: the page the answer is about is gone, so nothing is remembered.
        guard environment.readySpareGeneration() == generation else { return }
        if outcome.libraryPushed { pushedLibrary = (generation, key.libraryRevision) }
        switch outcome.stop {
        case .claimed, .replaced, .noDocument:
            return
        case .notReady where notReadyRetryKey != key:
            notReadyRetryKey = key
            arm(after: delays.beforeNotReadyRetry)
            return
        default:
            break
        }
        notReadyRetryKey = nil
        lastFinished = key
    }
}
