//
//  MarkdownParseCache.swift
//  final final
//
//  t-2fbe4c9b Phase 4c job 3 (the three Markdown section commands on a book-length text), plan v2 section 3(A)/(B) with amendments
//  A1 and A6: the writer's PARSE MEMO. Owned by `MarkdownBlockWriter` (`parseCache`). The writer's synchronous step (`prepare`) parses
//  the whole editor text on the main thread every time it runs (0.15 to 0.3 s at 700,000 characters, three to four times per
//  Delete, drag or Duplicate). That parse is a pure calculation, so it can be done AHEAD OF TIME in the background and looked up
//  when the writer needs it. This type is only the memo and the background job; it decides nothing about what is written.
//
//  WHAT IS KEPT. For one text: the `[Block]` that `BlockParser.parse` returned and the `endsOpen` answer of
//  `BlockParser.endsInsideOpenFenceOrMath` (the open-fence guard's new-text side). At most `capacity` (3) entries, least recently
//  used out. Both values are what `prepare` computed itself before this type existed; a hit gives it the same values.
//
//  THE KEY is everything the parse reads: the text, `projectId`, the Notes heading title (`fetchNotesHeadingTitle`, a database read)
//  and the bibliography header name and grace list (`ExportSettings`, read ONCE by the caller and passed to the parse explicitly, so
//  the entry is keyed by exactly the inputs it was parsed with). Every part is compared BYTE FOR BYTE (UTF-8, both texts made
//  contiguous first, lengths compared first, then `memcmp`): never Swift `String ==` and never `hashValue`, because Swift treats
//  canonically equivalent texts ("caf\u{E9}" and "cafe\u{301}") as equal, and the parse does not give the same blocks for them. A text
//  that is not byte-identical is a MISS. That is what makes it safe for `MarkdownBlockWriter.noteLoaded` NOT to empty the cache:
//  a stale entry can never match a new key.
//
//  WHY A HIT IS SAFE. `BlockParser.parse` is a static, nonisolated function of its arguments. The block ids it mints are never used
//  by the diff (`MarkdownBlockDiff` mints temp ids for inserts and reads ids only from the baseline). `Block` is a struct, so a
//  stored result cannot be changed by whoever uses it.
//
//  NO SUSPENSION IS ADDED ANYWHERE. `lookup` and `store` are synchronous. `prewarm` returns at once; the work is a detached task whose
//  result comes back to the main actor and is stored only if `generation` is unchanged (`reset()` bumps it, so a result prepared for
//  a project that was closed or a writer that was reset is dropped). A caller never awaits the background work; if the entry is not
//  ready when `prepare` looks, `prepare` parses on the main thread exactly as before and stores that result (trigger iv).
//
//  AN UNDELAYED REQUEST STARTS INSIDE `prewarm` (round C4). Right after a click the main actor is busy for 0.3 to 0.5 s; a request that
//  had to wait for it before its work could start (a `Task` on the main actor that then spawned the detached work) started the parse
//  after step 8 had looked. So an undelayed request (a load, the text after a click) makes its two small reads (the Notes title and
//  the bibliography names) synchronously, inside the call, and spawns the detached task there; only the STORING of the result waits for
//  the main actor. A delayed request (a typing pause) stays lazy: O(1) per keystroke, and a request replaced before its delay ends
//  costs nothing.
//
//  `prewarm` takes the text as the page or the editor state holds it ("raw"): the background task first applies
//  `MarkdownLeaderMap.recordText` (the section anchors and the bibliography opening marker removed: the "content record" text
//  `prepare` is handed), so the key's text is the record text. At most ONE prewarm runs at a time; a newer request REPLACES a waiting
//  one (latest wins; a request waiting out its `after:` delay is cancelled and the newer one's delay counts), and the newest request
//  always runs eventually (a request made while one is running waits for it, then runs). Typing therefore costs at most one
//  background core.
//
//  NO TEXT IS PARSED TWICE. Triggers (ii) and (iii) often ask for the same text (a command's post-click text, then the content change
//  its adopt causes). When a request STARTS, the background task strips its text, builds the full key (the text, the project, the Notes
//  title and the bibliography names, all read when the request started) and compares it, byte for byte, with the keys of the entries
//  already stored; an identical key means the parse already exists, so nothing is parsed and that entry becomes the newest. A request
//  made while another runs is compared when it starts, which is after the running one has stored its entry, so it covers the running
//  request too; a pending request is replaced, never parsed. The comparison is made in the background task, not in `prewarm`.
//  (A result made before a `reset()` is normally dropped; it is kept when the request made after the reset asks for exactly the same
//  entry, so the Rich Text -> Markdown switch parses the book once.)
//
//  THE SCANS COME FIRST. The one background task works in two stages. Stage 1 strips the text, builds the key and runs the two handler
//  scans (citation keys and footnote references: about 60 ms); it hands them to the main actor in a hop nobody waits for, which stores
//  them in `scans` (MarkdownScanMemo.swift) as soon as the main actor is free, if the cache was not reset meanwhile. Stage 2, the parse
//  (about 200 ms), follows at once in the same task, without waiting for that hop, and is skipped when the full key is already stored.
//
//  THE DEBOUNCE FIRE MAY WAIT (round C8). The typing-pause request (trigger ii) needs the main actor to START (after its 300 ms) and to
//  STORE its result, and the settle can keep the main actor busy for half a second, so the fire (1 s after the same content change) could
//  look the memo up just before the parse arrived. `ensure` (below, with its bound of 0.8 s) lets the fire's Task wait for the request
//  for its own text BEFORE its existing waits and re-checks, starting a request that is still pending at once. It never starts a parse of
//  a text nobody asked for, and on timeout the fire parses on the main thread as before.
//
//  THE TEST-ONLY SWITCH (round C9). The UI-test flag `FF_UI_TESTING_NO_PARSE_MEMO=1` (`TestMode.isUITestingNoParseMemo`, which needs
//  `FF_UI_TESTING` too, so it cannot be on for a user) makes `MarkdownBlockWriter` build this cache with `isDisabled`, read once: the same
//  build then behaves as it did before job 3, so a UI test can compare the two arms on one host, back to back. `lookup` finds nothing
//  and `store` keeps nothing (every `prepare` parses on the main thread and says `cache=miss`), `prewarm` returns at once (so the
//  `prewarmParse` calls, the typing-pause request and the load request all do nothing, and `scans` is never filled: the handlers run
//  their own scans), and `ensure` returns `none` at once. The cost when the flag is off is one `Bool` test per call.
//
//  TESTS read `entries`, `scans`, `generation` and `isRunning`; under DEBUG also the counters `hitCount`, `missCount`, `parseCount`,
//  `skipCount` and `startedCount`, `settled()` and three seams: `testAfterScan` runs when the scans reach the main actor (before they are
//  stored), `testBeforeStore` when the job's result does (before it is stored; `isRunning` is still true) and `testBackgroundStarted`
//  on the background thread when the job's detached task begins.
//

import Foundation

@MainActor
final class MarkdownParseCache {

    // MARK: - Key and entry

    /// Everything `BlockParser.parse` reads. The text is held as contiguous UTF-8.
    struct Key: Sendable {
        let text: String
        let projectId: String
        let notesTitle: String?
        let bibliographyHeaderName: String
        let graceNames: [String]

        init(text: String, projectId: String, notesTitle: String?, bibliographyHeaderName: String, graceNames: [String]) {
            var contiguous = text
            contiguous.makeContiguousUTF8()
            self.text = contiguous
            self.projectId = projectId
            self.notesTitle = notesTitle
            self.bibliographyHeaderName = bibliographyHeaderName
            self.graceNames = graceNames
        }

        /// Byte-exact equality of every part. The short parts first, the text last.
        func matches(_ other: Key) -> Bool {
            guard Self.sameBytes(projectId, other.projectId), Self.sameBytes(bibliographyHeaderName, other.bibliographyHeaderName),
                  graceNames.count == other.graceNames.count,
                  zip(graceNames, other.graceNames).allSatisfy({ Self.sameBytes($0, $1) }) else { return false }
            switch (notesTitle, other.notesTitle) {
            case (nil, nil): break
            case let (left?, right?): guard Self.sameBytes(left, right) else { return false }
            default: return false
            }
            return Self.sameBytes(text, other.text)
        }

        /// UTF-8 byte equality: the lengths first, then the bytes. Not `String ==` (canonical equivalence). A bridged (Foundation-backed)
        /// string has no contiguous UTF-8 and an O(n) byte count, so it is made contiguous ONCE here, as `init` does for the key's text,
        /// instead of being compared byte by byte; a native string is not touched.
        static func sameBytes(_ lhs: String, _ rhs: String) -> Bool {
            var left = lhs
            var right = rhs
            return left.withUTF8 { leftBytes in
                right.withUTF8 { rightBytes in
                    leftBytes.count == rightBytes.count
                        && (leftBytes.isEmpty || memcmp(leftBytes.baseAddress, rightBytes.baseAddress, leftBytes.count) == 0)
                }
            }
        }
    }

    /// One memo entry: the parse of `key.text` and the open-fence answer for it.
    struct Entry: Sendable {
        let key: Key
        let blocks: [Block]
        let endsOpen: Bool
    }

    /// How many texts are kept (a book's text, the text after a click, and one spare for the idle re-parse).
    static let capacity = 3

    // MARK: - State

    /// Least recently used first.
    private(set) var entries: [Entry] = []
    /// Bumped by `reset()`. A prewarm stores its result only if this is unchanged since it was asked for.
    private(set) var generation = 0
    /// True while a background job is in progress.
    private(set) var isRunning = false
    /// The handler scan memo (MarkdownScanMemo.swift): the stripped text, citation keys and footnote references of the newest texts, made by
    /// the same background task, published as soon as they are ready (before the parse), and emptied by `reset()` like the entries.
    let scans = MarkdownScanMemo()
    /// True under the UI-test switch `FF_UI_TESTING_NO_PARSE_MEMO` (`TestMode.isUITestingNoParseMemo`, read once when the writer is made):
    /// the memo is OFF, which is how the writer behaved before job 3. `lookup` finds nothing, `store` keeps nothing, `prewarm` starts
    /// nothing (so no background work, and `scans` is never filled: every handler scan runs itself), `ensure` returns at once.
    let isDisabled: Bool

    init(isDisabled: Bool = TestMode.isUITestingNoParseMemo) {
        self.isDisabled = isDisabled
    }
    #if DEBUG
    /// Test-only counters: lookups that hit and missed; background parses run to completion; started requests that found their text already
    /// stored and parsed nothing; background jobs started (a started job may still be skipped as already stored, or dropped after a reset).
    private(set) var hitCount = 0
    private(set) var missCount = 0
    private(set) var parseCount = 0
    private(set) var skipCount = 0
    private(set) var startedCount = 0
    /// Test seams. `testAfterScan` runs on the main actor when the background scans reach it, before they are stored and `generation`
    /// is checked; `testBeforeStore` when the background job's result reaches the main actor, before `isRunning` goes down and before
    /// the entry is stored and `generation` is checked (a request made here arrives "while the job runs"); `testBackgroundStarted` runs
    /// ON THE BACKGROUND THREAD as soon as the job's detached task begins (a test can look for it while the main actor is blocked).
    var testAfterScan: (@MainActor () -> Void)?
    var testBeforeStore: (@MainActor () -> Void)?
    var testBackgroundStarted: (@Sendable () -> Void)?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    #endif

    private var pending: Request?
    private var waiter: Task<Void, Never>?
    private var requestCounter = 0
    /// The request whose background job is in progress (nil when none is), and the callers of `ensure` (below) waiting for a job to end.
    private var running: Request?
    fileprivate var ensureWaiters: [Int: EnsureWaiter] = [:]
    fileprivate var ensureWaiterCounter = 0

    // MARK: - Lookup and store (synchronous)

    /// The entry for `key`, byte-exact, or nil. A hit becomes the most recently used entry.
    func lookup(_ key: Key) -> Entry? {
        guard !isDisabled, let index = entries.firstIndex(where: { $0.key.matches(key) }) else {
            #if DEBUG
            missCount += 1
            #endif
            return nil
        }
        #if DEBUG
        hitCount += 1
        #endif
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry
    }

    /// Remembers the parse of `key.text` (trigger iv: the writer's own main-thread parse). An entry with the same key is replaced.
    func store(_ key: Key, blocks: [Block], endsOpen: Bool) {
        guard !isDisabled else { return }
        store(Entry(key: key, blocks: blocks, endsOpen: endsOpen))
    }

    private func store(_ entry: Entry) {
        entries.removeAll { $0.key.matches(entry.key) }
        entries.append(entry)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    /// The editor state is reset (project switch or close, mode change, zoom start): drop everything, forget a waiting prewarm, and make
    /// the result of a running one unwanted.
    func reset() {
        generation += 1
        entries.removeAll()
        scans.reset()
        pending = nil
        waiter?.cancel()
        waiter = nil
        endEnsureWaiters(forRequest: nil, as: .ended)   // a fire never waits on a job that no longer matters
        noteIdleIfSettled()
    }

    // MARK: - Prewarm (background)

    /// Asks for the parse of `raw` (as the page or the editor state holds it) to be prepared in the background. Returns at once.
    ///
    /// TWO KINDS OF REQUEST.
    ///
    /// DELAYED (`delay` given: trigger (ii), a typing pause). This call costs O(1) on the main thread: it stores the request (the text is
    /// a reference, not a copy), cancels the waiting one and starts a sleeping task; trigger (ii) calls it on every content change while
    /// typing. The two reads the parse needs, the Notes heading title (one database read) and the bibliography names (`names`, by
    /// default `ExportSettings.load()` through `BlockParser.bibliographyNames`), are made later, on the main actor, when the request is
    /// about to START, so a request that is replaced before its delay ends costs nothing.
    ///
    /// UNDELAYED (triggers i and iii: a load, the text after a click). The work STARTS INSIDE THIS CALL, without waiting for a free main
    /// actor: right after a click the main actor is busy for 0.3 to 0.5 s (content handlers, SwiftUI), and a request that had to wait for
    /// it started its work after the next step of the command had already looked for the result (the Outline drag, round C4: step 8 at
    /// +643 ms, the parse started at +556 ms). So the two reads are made here, synchronously (one indexed read and a small decode,
    /// about a millisecond; the `parseCache.request` span), and the background task is spawned here.
    ///
    /// Either way the background task strips `raw` to the record text, makes it contiguous, runs the two handler scans, parses with the
    /// names passed explicitly, scans for an open fence, and the result is stored on the main actor if `generation` is unchanged.
    ///
    /// Latest wins: a request that has not started is replaced by this one (the text, not the start: a delayed request that replaces an
    /// UNDELAYED pending one keeps its immediate start, so a click's post-click text does not wait for a typing-pause delay). At most one
    /// background job runs: a request made while one runs becomes the pending one and starts the moment the running one's result has been
    /// stored (on the main actor, so that moment can itself wait for a free main actor).
    func prewarm(
        raw: String,
        projectId: String,
        database: ProjectDatabase,
        names: (headerName: String, graceNames: [String])? = nil,
        after delay: Duration? = nil
    ) {
        guard !isDisabled else { return }
        requestCounter += 1
        let keepsImmediateStart = pending != nil && pending?.startAt == nil
        let request = Request(
            id: requestCounter, raw: raw, projectId: projectId, database: database, names: names, generation: generation,
            startAt: keepsImmediateStart ? nil : delay.map { ContinuousClock.now + $0 })
        if let replaced = pending { endEnsureWaiters(forRequest: replaced.id, as: .ended) }   // its text is no longer the wanted one
        pending = request
        guard !isRunning else { return }   // `finish` starts the newest request when the running job's result has been stored
        waiter?.cancel()
        waiter = nil
        if let startAt = request.startAt { schedule(request, startAt: startAt) } else { start(request) }
    }

    #if DEBUG
    /// Waits until nothing is waiting or running. For tests only; nothing in the app waits on the background work.
    func settled() async {
        if isSettled { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }
    #endif

    /// A request as `prewarm` stored it. `names` nil: read `ExportSettings` when the request starts.
    private struct Request {
        let id: Int
        let raw: String
        let projectId: String
        let database: ProjectDatabase
        let names: (headerName: String, graceNames: [String])?
        let generation: Int
        let startAt: ContinuousClock.Instant?
    }

    /// What the background task needs: the request with its two reads made, and what is already stored (a text found among the stored keys
    /// is not parsed again; one found among the scan entries is not scanned again).
    private struct Job: Sendable {
        let raw: String
        let projectId: String
        let notesTitle: String?
        let headerName: String
        let graceNames: [String]
        let storedKeys: [Key]
        let scanEntries: [MarkdownScanMemo.Entry]
    }

    /// What the first background stage found: the full key, the scans (nil when the scan memo already holds this text), and whether the
    /// parse is still needed (false when the request's full key equals a stored entry's).
    private struct Scanned: Sendable {
        let key: Key
        let scanEntry: MarkdownScanMemo.Entry?
        let needsParse: Bool
    }

    /// What the whole background job found: the key, the scans (nil when already stored), and the parsed entry (nil when already stored).
    private struct Finished: Sendable {
        let key: Key
        let scanEntry: MarkdownScanMemo.Entry?
        let parsed: Entry?
    }

    /// Wakes the tests' `settled()` waiters once nothing is waiting or running. Nothing in the app waits, so it does nothing in a release build.
    private func noteIdleIfSettled() {
        #if DEBUG
        guard pending == nil, !isRunning, waiter == nil else { return }
        let waiting = idleWaiters
        idleWaiters = []
        for continuation in waiting { continuation.resume() }
        #endif
    }

    #if DEBUG
    private var isSettled: Bool { pending == nil && !isRunning && waiter == nil }
    #endif

    /// Starts `request`, a DELAYED one (only delayed requests are ever scheduled), when `startAt` arrives.
    private func schedule(_ request: Request, startAt: ContinuousClock.Instant) {
        waiter = Task { [weak self] in
            do { try await Task.sleep(until: startAt, clock: .continuous) } catch { return }   // replaced or reset
            self?.run(request)
        }
    }

    /// A delayed request whose delay is over (the sleeping task of `schedule`).
    private func run(_ request: Request) {
        guard pending?.id == request.id else { return }   // replaced since this task was started: the newer one has its own task
        start(request)   // `reset()` clears `pending`, so a request made before a reset never gets here
    }

    /// Starts the background job for `request` NOW: the two reads on the main actor (no suspension), then a DETACHED task, which does not
    /// need the main actor to begin. The detached task runs both stages in a row, scans first and parse straight after (the parse does not
    /// wait for the main actor to store the scans); the scans are handed to the main actor in a hop nobody waits for, so they are stored
    /// as soon as the main actor is free, normally long before the parse is done. The result comes back through `finish`.
    private func start(_ request: Request) {
        let requestSpan = MdSpeed.span("parseCache.request")   // the synchronous part of a request: the two reads and the spawn
        pending = nil
        waiter = nil
        isRunning = true
        running = request
        #if DEBUG
        startedCount += 1
        #endif
        let names = request.names ?? BlockParser.bibliographyNames(from: ExportSettings.load())
        let job = Job(
            raw: request.raw, projectId: request.projectId,
            notesTitle: try? request.database.fetchNotesHeadingTitle(projectId: request.projectId),
            headerName: names.headerName, graceNames: names.graceNames, storedKeys: entries.map(\.key), scanEntries: scans.entries)
        let requestGeneration = request.generation
        #if DEBUG
        let backgroundStarted = testBackgroundStarted
        #endif
        let work = Task.detached(priority: .userInitiated) { [weak self] () -> Finished in
            #if DEBUG
            backgroundStarted?()
            #endif
            let scanned = Self.scan(job)
            if let scanEntry = scanned.scanEntry {
                Task { @MainActor in self?.publishScans(scanEntry, generation: requestGeneration) }   // not awaited
            }
            let parsed = scanned.needsParse ? Self.parse(scanned.key) : nil
            return Finished(key: scanned.key, scanEntry: scanned.scanEntry, parsed: parsed)
        }
        // The awaiter has an explicit priority: awaiting from a high-priority context must not raise the parse above `.userInitiated`.
        Task(priority: .userInitiated) { [weak self] in
            let finished = await work.value
            self?.finish(request, finished)
        }
        requestSpan.end()
    }

    /// The scans of a started job, on the main actor (stored unless the cache was reset since the request was made).
    private func publishScans(_ scanEntry: MarkdownScanMemo.Entry, generation requestGeneration: Int) {
        #if DEBUG
        testAfterScan?()
        #endif
        if requestGeneration == generation { scans.store(scanEntry) }
    }

    /// The job's result, on the main actor. Starts the pending request, if one was made meanwhile, once this result is stored.
    private func finish(_ request: Request, _ finished: Finished) {
        #if DEBUG
        testBeforeStore?()
        #endif
        isRunning = false
        running = nil
        // A `reset()` while the job ran makes its result unwanted (a memory policy: the project may be gone) UNLESS the request made after
        // that reset asks for exactly this entry (same project, text, Notes title and names): then the result is kept and that request
        // dropped, so the book is parsed once, not twice (the Rich Text -> Markdown switch: the ready callback, then the reset, then the
        // onChange's re-request).
        let supersededByIdentical = request.generation != generation && pendingAsksForSameEntry(as: request, finished.key)
        let droppedPendingId = supersededByIdentical ? pending?.id : nil
        if supersededByIdentical { pending = nil }
        let wanted = request.generation == generation || supersededByIdentical
        if wanted {
            if let scanEntry = finished.scanEntry {
                scans.store(scanEntry)   // normally stored by `publishScans` long ago
            } else {
                scans.touch(stripped: finished.key.text, projectId: finished.key.projectId)   // a skipped text is the live one: newest
            }
        }
        if let parsed = finished.parsed {
            #if DEBUG
            parseCount += 1
            #endif
            if wanted { store(parsed) }
        } else {
            #if DEBUG
            skipCount += 1
            #endif
            if wanted { touch(finished.key) }
        }
        endEnsureWaiters(forRequest: request.id, as: .waited)   // the entry (if wanted) is stored: the caller's lookup finds it
        if let droppedPendingId { endEnsureWaiters(forRequest: droppedPendingId, as: .waited) }
        if let next = pending {
            if let startAt = next.startAt, startAt > ContinuousClock.now { schedule(next, startAt: startAt) } else { start(next) }
        }
        noteIdleIfSettled()
    }

    /// Whether the pending request would produce `key` exactly: the same project, the same raw text (byte for byte) and, as they are read
    /// now, the same Notes title and bibliography names. Only asked of a stale result, so the two small reads cost nothing in the common case.
    private func pendingAsksForSameEntry(as request: Request, _ key: Key) -> Bool {
        guard let next = pending, Key.sameBytes(next.projectId, request.projectId), Key.sameBytes(next.raw, request.raw) else { return false }
        let names = next.names ?? BlockParser.bibliographyNames(from: ExportSettings.load())
        let wanted = Key(
            text: key.text, projectId: next.projectId, notesTitle: try? next.database.fetchNotesHeadingTitle(projectId: next.projectId),
            bibliographyHeaderName: names.headerName, graceNames: names.graceNames)
        return wanted.matches(key)
    }

    /// Makes the stored entry for `key` the most recently used one, without counting a hit.
    private func touch(_ key: Key) {
        guard let index = entries.firstIndex(where: { $0.key.matches(key) }) else { return }
        entries.append(entries.remove(at: index))
    }

    /// The first background stage. Pure: nothing here touches the main actor, the database or the settings.
    private nonisolated static func scan(_ job: Job) -> Scanned {
        let span = MdSpeed.span("parseCache.scan")
        let key = Key(
            text: MarkdownLeaderMap.recordText(fromRaw: job.raw), projectId: job.projectId,
            notesTitle: job.notesTitle, bibliographyHeaderName: job.headerName, graceNames: job.graceNames)
        let known = MarkdownScanMemo.contains(job.scanEntries, stripped: key.text, projectId: job.projectId)
        let scanEntry = known ? nil : MarkdownScanMemo.makeEntry(raw: job.raw, stripped: key.text, projectId: job.projectId)
        let needsParse = !job.storedKeys.contains { $0.matches(key) }
        span.end("scanned=\(!known) parseNeeded=\(needsParse)")
        return Scanned(key: key, scanEntry: scanEntry, needsParse: needsParse)
    }

    /// The second background stage: the parse and the open-fence scan of the key's text.
    private nonisolated static func parse(_ key: Key) -> Entry {
        let span = MdSpeed.span("parseCache.prewarm")
        defer { span.end() }
        let blocks = BlockParser.parse(
            markdown: key.text, projectId: key.projectId, bibliographyHeaderName: key.bibliographyHeaderName,
            graceNames: key.graceNames, notesHeaderName: key.notesTitle)
        return Entry(key: key, blocks: blocks, endsOpen: BlockParser.endsInsideOpenFenceOrMath(key.text))
    }
}

// MARK: - Waiting for a request's job (the debounce fire, round C8)

extension MarkdownParseCache {

    /// How long the debounce fire waits, at most, for the parse of its own text (judge ruling, round C8).
    nonisolated static let ensureBound: Duration = .milliseconds(800)

    /// How `ensure` ended. `hit`: the memo already held the key. `waited`: a request for the text was (made to be) in its job and the job
    /// ended. `timeout`: the bound ran out. `none`: nobody had asked for this text. `ended`: the caller's task was cancelled, or the cache
    /// was reset or the request replaced while it waited.
    enum EnsureOutcome: String, Sendable {
        case hit, waited, timeout, none, ended
    }

    fileprivate struct EnsureWaiter {
        let requestId: Int
        let continuation: CheckedContinuation<EnsureOutcome, Never>
        let timer: Task<Void, Never>
    }

    /// Waits until the memo can answer for `raw`, if a request for exactly that text and project exists; never starts a parse of its own.
    ///
    /// The debounce fire (1 s after a content change) looks the memo up in its synchronous step. The typing-pause request for the same
    /// text (trigger ii) is meant to be ready by then, but it needs the main actor twice, to START after its 300 ms and to STORE its
    /// result, and right after a command the main actor can be busy for half a second (the settle): the request then starts late or is
    /// still running when the fire looks (the drag, round C8: the fire found nothing at +3051 ms and parsed on the main thread for 231 ms
    /// as the background parse ended). So, called by the fire's Task BEFORE it waits for the write in flight and re-checks its
    /// generation, this:
    ///  (a) returns at once (`hit`) when the memo already holds the exact key (text, project, Notes title, bibliography names);
    ///  (b) else, when a RUNNING or PENDING request has the same project and the same raw text (byte for byte), waits for that request's
    ///      job to end; a request still pending is started NOW (made undelayed: a delayed one stops waiting for its turn, one queued
    ///      behind a running job starts the moment that job's result is stored);
    ///  (c) else returns at once (`none`): the text changed, or nothing was asked.
    /// The wait is bounded by `timeout` (`ensureBound`, 0.8 s); on `timeout` the caller goes on exactly as before (its lookup misses and
    /// parses on the main thread) and one trace line `ensure timeout` is written. It ends at once when the calling Task is cancelled
    /// (a newer keystroke) and when `reset()` runs; every waiter is resumed exactly once, by `finish`, the timer, the cancellation or
    /// `reset()`. It adds no state the sync model sees: the fire's synchronous step and everything after the waits is unchanged.
    @discardableResult
    func ensure(
        raw: String, projectId: String, database: ProjectDatabase, timeout: Duration = MarkdownParseCache.ensureBound
    ) async -> EnsureOutcome {
        if isDisabled { return .none }
        let span = MdSpeed.span("parseCache.ensure")
        let notesTitle = try? database.fetchNotesHeadingTitle(projectId: projectId)
        let names = BlockParser.bibliographyNames(from: ExportSettings.load())
        let key = Key(
            text: raw, projectId: projectId, notesTitle: notesTitle,
            bibliographyHeaderName: names.headerName, graceNames: names.graceNames)
        var outcome = EnsureOutcome.hit
        if !entries.contains(where: { $0.key.matches(key) }) {
            if let requestId = requestToWaitFor(text: key.text, projectId: projectId) {
                outcome = await waitForEnd(of: requestId, timeout: timeout)
            } else {
                outcome = .none
            }
        }
        span.end("outcome=\(outcome.rawValue)")
        if outcome == .timeout { MdSpeed.mark("ensure timeout") }
        return outcome
    }

    /// The id of the request whose job will produce `text` for `projectId`, after making sure it will start now; nil when there is none.
    private func requestToWaitFor(text: String, projectId: String) -> Int? {
        func asksFor(_ request: Request) -> Bool {
            request.generation == generation && Key.sameBytes(request.projectId, projectId) && Key.sameBytes(request.raw, text)
        }
        if let running, asksFor(running) { return running.id }
        guard let next = pending, asksFor(next) else { return nil }
        let now = Request(
            id: next.id, raw: next.raw, projectId: next.projectId, database: next.database, names: next.names,
            generation: next.generation, startAt: nil)
        pending = now
        if !isRunning {
            waiter?.cancel()
            waiter = nil
            start(now)
        }   // else `finish` starts it, undelayed, the moment the running job's result is stored
        return now.id
    }

    /// Suspends until `finish` ends the job of `requestId`, the timer runs out, the Task is cancelled, or `reset()` runs.
    private func waitForEnd(of requestId: Int, timeout: Duration) async -> EnsureOutcome {
        ensureWaiterCounter += 1
        let waiterId = ensureWaiterCounter
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<EnsureOutcome, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .ended)
                    return
                }
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.endEnsureWaiter(waiterId, as: .timeout)
                }
                ensureWaiters[waiterId] = EnsureWaiter(requestId: requestId, continuation: continuation, timer: timer)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.endEnsureWaiter(waiterId, as: .ended) }
        }
    }

    /// Resumes one waiter, once (a second call finds nothing).
    private func endEnsureWaiter(_ waiterId: Int, as outcome: EnsureOutcome) {
        guard let waiter = ensureWaiters.removeValue(forKey: waiterId) else { return }
        waiter.timer.cancel()
        waiter.continuation.resume(returning: outcome)
    }

    /// Resumes the waiters of one request (all of them when `requestId` is nil).
    fileprivate func endEnsureWaiters(forRequest requestId: Int?, as outcome: EnsureOutcome) {
        for (waiterId, waiter) in ensureWaiters where requestId == nil || waiter.requestId == requestId {
            endEnsureWaiter(waiterId, as: outcome)
        }
    }

    /// How many callers of `ensure` are suspended (tests: none may be left behind).
    var ensureWaiterCount: Int { ensureWaiters.count }
}

// MARK: - What the writer's callers use

extension MarkdownBlockWriter {

    /// How long the content must be unchanged before the debounce-arm trigger (ii) starts the parse: the page posts its text 50 ms after
    /// a change, the parse takes up to about 0.3 s on a book, and the re-parse fires 1 s after the last change, so the entry is ready.
    static let parseMemoTypingPause: Duration = .milliseconds(300)

    /// The triggers' one call (i: a load, iii: the text after a click): asks the parse memo to prepare `raw`, in the background, now.
    /// Synchronous and never awaited, but NOT O(1): this is an undelayed request, so the call itself makes one indexed database read (the
    /// Notes title) and one settings decode (about a millisecond) and spawns the job; only the delayed request below is O(1). A no-op under
    /// the UI-test flag that turns the per-block writer off.
    func prewarmParse(raw: String, projectId: String, database: ProjectDatabase) {
        guard isEnabled else { return }
        parseCache.prewarm(raw: raw, projectId: projectId, database: database)
    }

    /// Trigger (ii), called on EVERY content change while typing (from `scheduleFullDocumentReparse`): like `prewarmParse`, but the parse
    /// starts only after `parseMemoTypingPause`, and each newer call replaces the waiting one, so a burst of typing starts one parse.
    func prewarmParseAfterTypingPause(raw: String, projectId: String, database: ProjectDatabase) {
        guard isEnabled else { return }
        parseCache.prewarm(raw: raw, projectId: projectId, database: database, after: Self.parseMemoTypingPause)
    }
}
