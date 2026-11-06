//
//  WriteQueuePhase5BeforeNumbersE2ETests.swift
//  final finalUITests
//
// swiftlint:disable file_length
// (Phase 5 job A8: its methods were asked for in this class, not a new file; the class's parts are kept together, one MARK per job.)
//
//  PHASE 5, JOB A1 (docs/architecture/write-queue-plan/phase5/a1-before-numbers.md). TESTS ONLY: nothing here changes how the app behaves
//  (the app gained one log line, `[ZoomClick] performUserZoomIn tail complete in <s>s`, the zoom-in twin of the zoom-out line).
//
//  TWO THINGS ARE DONE HERE, on today's code, so the Phase 5 jobs A7 to A10 can be compared with them (same build run with and without the
//  change, same VM speed state):
//   1. BEFORE-NUMBERS. How long do four actions take: switch to Markdown, switch to Rich Text, zoom in (Outline double-click on the size's
//      middle chapter), zoom out (the status bar's exit glyph)? Three repetitions of the whole cycle per launch, on the three generated
//      documents of `Phase4bDelSize` (article, book6, book12), with the editor preloader off (the UI-testing default) and on
//      (`FF_UI_TESTING_ENABLE_PRELOADER=1`, which also leaves 4.5 s between two switches, like Phase 3b's published figures). REPORT ONLY:
//      no timing is asserted anywhere.
//   2. A LOSS REPRODUCER (board t-b371d77a). One unique marker word is typed at a requested delay (0, 250, 500, 750, 1000, 1500 ms) after the
//      trigger of each of the four actions, and the database says whether it survived exactly once. The test ASSERTS that every marker
//      survived exactly once, so it FAILS on today's code if any is lost. It prints every row either way. If today's code loses nothing, the
//      table says so: that is a finding, not a failure of the job.
//
//  THE METHODS (one timing method per vmtest run; the sandbox is off; never more than two runs at once)
//    testBeforeNumbers_article / _book6 / _book12                  preloader off
//    testBeforeNumbersPreloader_article / _book6 / _book12         preloader on, 4.5 s or more between two switches
//    testLossWindow_article / testLossWindow_book12                the loss reproducer (24 markers: 4 actions x 6 delays)
//    testPhase5Helpers_handWorkedExample                           no app: the pure judge, parser and marker names on canned input
//    testMarkdownDeleteRightAfterSwitchIsHeldThenFast_book12       job A5 (board t-633df056): Delete Section pressed the moment the badge says
//                                                                  Markdown, before the page is there, is HELD and then takes the fast route
//                                                                  (an app-side check with an assertion; see its own MARK at the end)
//  Example: scripts/vmtest/vmtest run --detach --timeout 2400 \
//             --scope "final finalUITests/WriteQueuePhase5BeforeNumbersE2ETests/testBeforeNumbers_article"
//
//  WHAT EACH TIMING IS (every one is a figure from the TEST VM, never from the user's own Mac):
//    zero      switches: the app's own `[TYPING-TRACE] key ... code=44` line for the Cmd-/ press (the stamp of the key event as the app saw it);
//              zoom in and zoom out: the test process's clock just before the click is issued (the app logs nothing at the click). That
//              figure includes the driver's event delivery (tens of milliseconds, the same before and after any change). The app's own
//              `<s>s` figure on the end line (time since `performUserZoomIn` / `performUserZoomOut` began) is printed next to it.
//    end       to Markdown: `[CodeMirrorEditor] batchInitialize: setting lastPushedContent`. It is written just before the text is handed to
//              the page, so it means "page loaded, handover begins", NOT "text in place".
//              to Rich Text: the first `[BlockSyncService] Set content with N block IDs atomically` after the trigger.
//              zoom in: `[ZoomClick] performUserZoomIn tail complete in`. Zoom out: `[ZoomClick] zoomOut() settled in` (the figure), and the
//              later `[ZoomClick] performUserZoomOut tail complete in` (printed as tailMs).
//    Every action is waited out and followed by a log that has been quiet for 3 s before the next one starts.
//
//  THE VALIDITY PROBES. Three fixed things the changes of Phase 5 never touch are timed before and after the reps of every test: (a) a SHA-256
//  over a fixed 32 MB buffer, (b) writing and reading 16 MB in NSTemporaryDirectory(), (c) the median of 9 accessibility reads of the label of
//  `status-bar-editor-mode`. A run is INVALID when the median of the three ratios (probe divided by its reference) is above 1.5 or any ratio is
//  above 3.0 (`Phase5Limits`). The references are NOT known yet: until they are set, in the constants below, from the quietest valid runs
//  (with the run ids in a comment, as `MdSpeedLimits.references` does), every run is a "reference-setting run" and no gate applies. An INVALID
//  run ends with XCTSkip; a skip is neither a pass nor a reason to retry blind.
//
//  THE DOCUMENTS are the generated stand-ins of `Phase4bDelGenerator` (the guest has no mount of the user's real test books), so every figure
//  is comparable with the Phase 3b to 4c figures taken on them. The loss tests add 18 plain lines `LossNN line of the fixture document.` after
//  Anchor14 and 6 plain lines `ZoneNN line of the fixture document.` right under the zoom target's heading, one fresh line per repetition, so
//  every caret placement is the proven exact-line recipe (`placeCaretAtAnchorEnd(paragraph:exactLine:)`).
//
//  THE DRIVER CANNOT TYPE before about 0.65 s after a command (it waits for the app to be idle), so a requested delay is not the arrival
//  time. The real arrival of each marker key is read from the app's `[TYPING-TRACE] key` lines and printed beside the request.
//

import CryptoKit
import XCTest

// MARK: - The constants block

/// Every number the tests compare with or are driven by. A change of a number touches this block only.
enum Phase5Limits {
    /// The validity references in milliseconds. NIL UNTIL A QUIET VALID RUN SETS THEM; the run ids that set them go in a comment here.
    static let referenceShaMs: Double? = nil
    static let referenceDiskMs: Double? = nil
    static let referenceAxMs: Double? = nil
    /// INVALID when the median of the three ratios is above this.
    static let validityMedianLimit = 1.5
    /// INVALID when any one ratio is above this.
    static let validitySingleLimit = 3.0
    /// Repetitions of the whole four-action cycle in a before-numbers test.
    static let repetitions = 3
    /// The least time between two switches when the preloader is on (Phase 3b's 4 s claim gap plus a 0.5 s margin).
    static let claimGapSeconds: TimeInterval = 4.5
    /// The app's log must have been quiet this long before the next action.
    static let quietSeconds: TimeInterval = 3
    /// The requested delays after the trigger at which the loss test types its marker.
    static let lossDelaysMs = [0, 250, 500, 750, 1_000, 1_500]
    /// How long the database is polled for a marker before it is called lost.
    static let markerPollSeconds: TimeInterval = 8
    /// The probes: buffer sizes, runs per median.
    static let probeShaBytes = 32 << 20
    static let probeDiskBytes = 16 << 20
    static let probeRuns = 5
    static let probeAxReads = 9
    /// The key code of "/" (Cmd-/ switches the editor).
    static let slashKeyCode = 44
    /// Arrow keys (123 to 126) are never marker keys.
    static let arrowKeyCodes = 123...126
    /// Job A5: how long the app's UI-test seam `FF_UI_TESTING_MD_PAGE_READY_HOLD_MS` keeps the first Markdown page from being mounted, so
    /// the Delete pressed right after the switch lands inside the window for certain (the real window is about 1 s idle, 2.5 s busy on the
    /// twelve-chapter book, VM figures; the driver's trigger reaches the app a few hundred milliseconds after the badge flips).
    static let pageReadyHoldMs = 3_000
}

// MARK: - The four actions

enum Phase5Action: CaseIterable {
    case toMarkdown
    case toRichText
    case zoomIn
    case zoomOut

    var title: String {
        switch self {
        case .toMarkdown: return "switch to Markdown"
        case .toRichText: return "switch to Rich Text"
        case .zoomIn: return "zoom in"
        case .zoomOut: return "zoom out"
        }
    }

    /// One letter that makes the marker word of this action different from the others'.
    var letter: String {
        switch self {
        case .toMarkdown: return "m"
        case .toRichText: return "r"
        case .zoomIn: return "i"
        case .zoomOut: return "o"
        }
    }

    var isSwitch: Bool { self == .toMarkdown || self == .toRichText }

    /// The mode the badge reads once a switch is done.
    var wantedMode: String? {
        switch self {
        case .toMarkdown: return "Markdown"
        case .toRichText: return "Rich Text"
        default: return nil
        }
    }

    /// The marker word of repetition `cycle` (1-based): five characters, a different one for each action and cycle, none inside another.
    func marker(cycle: Int) -> String { "p5" + letter + String(format: "%02d", cycle) }
}

// MARK: - The pure judging

struct Phase5Probes: Equatable {
    let shaMs: Double
    let diskMs: Double
    let axMs: Double
}

struct Phase5References {
    let shaMs: Double?
    let diskMs: Double?
    let axMs: Double?

    /// The committed references: all nil until a quiet valid run sets them (see the constants block).
    static let committed = Phase5References(
        shaMs: Phase5Limits.referenceShaMs, diskMs: Phase5Limits.referenceDiskMs, axMs: Phase5Limits.referenceAxMs)
}

enum Phase5Verdict: Equatable {
    case referenceSetting
    case valid(median: Double)
    case invalid(String)

    var isInvalid: Bool {
        if case .invalid = self { return true }
        return false
    }

    var text: String {
        switch self {
        case .referenceSetting: return "REFERENCE-SETTING RUN (no references yet, no gate applied)"
        case .valid(let median): return "VALID (median ratio \(String(format: "%.2f", median)))"
        case .invalid(let why): return "INVALID (\(why))"
        }
    }
}

enum Phase5Judge {
    static func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// The rule: INVALID when the median of the three ratios is above `validityMedianLimit` or any ratio is above `validitySingleLimit`.
    static func verdict(_ probes: Phase5Probes, references: Phase5References = .committed) -> Phase5Verdict {
        guard let sha = references.shaMs, let disk = references.diskMs, let axis = references.axMs else { return .referenceSetting }
        let ratios = [probes.shaMs / sha, probes.diskMs / disk, probes.axMs / axis]
        let middle = median(ratios) ?? 0
        let worst = ratios.max() ?? 0
        let shown = ratios.map { String(format: "%.2f", $0) }.joined(separator: ", ")
        if middle > Phase5Limits.validityMedianLimit {
            let found = String(format: "%.2f", middle)
            return .invalid("median ratio \(found) is above \(Phase5Limits.validityMedianLimit); ratios sha, disk, ax: \(shown)")
        }
        if worst > Phase5Limits.validitySingleLimit {
            let found = String(format: "%.2f", worst)
            return .invalid("a ratio of \(found) is above \(Phase5Limits.validitySingleLimit); ratios sha, disk, ax: \(shown)")
        }
        return .valid(median: middle)
    }

    /// How a marker fared, from the number of times the database holds it.
    static func classify(occurrences: Int) -> String {
        switch occurrences {
        case 1: return "survived"
        case 2...: return "duplicated"
        case 0: return "lost"
        default: return "unreadable"
        }
    }
}

enum Phase5Parse {
    /// The number that follows `marker` in `text` ("in 0.321s" gives 0.321), or nil.
    static func seconds(after marker: String, in text: String) -> Double? {
        guard let range = text.range(of: marker) else { return nil }
        return Double(text[range.upperBound...].prefix(while: { $0.isASCII && ($0.isNumber || $0 == ".") }))
    }

    static func millis(_ seconds: Double?) -> Int? { seconds.map { Int(($0 * 1_000).rounded()) } }

    static func ms(from start: Date, to end: Date) -> Int { Int((end.timeIntervalSince(start) * 1_000).rounded()) }
}

// MARK: - What a repetition records

/// What the marker typing of one repetition did.
struct Phase5Typing {
    let requestedDelayMs: Int
    /// The test process's clock: when the typing call began, counted from the test's zero.
    let typeStartMs: Int
    let typingCallMs: Int
    /// The arrival of each typed key in the app's log, counted from the repetition's zero.
    let keyMs: [Int]
    /// How many of those keys the app said went to the editor (`editor=true`).
    let keysInEditor: Int
}

/// One performed action.
struct Phase5Performed {
    let action: Phase5Action
    let zeroStamp: String
    let zeroBasis: String
    let elapsedMs: Int
    /// Zoom out only: the trigger to `performUserZoomOut tail complete`.
    let tailMs: Int?
    /// The app's own `<s>s` figure on the end line.
    let appSelfMs: Int?
    /// Switches: the gap since the previous switch trigger returned.
    let gapMs: Int?
    let typing: Phase5Typing?
}

/// One marker of the loss test.
struct Phase5LossRow {
    let action: Phase5Action
    let word: String
    let done: Phase5Performed
    let occurrences: Int
    let location: String
    var finalOccurrences = -1

    var result: String { Phase5Judge.classify(occurrences: occurrences) }
    var finalResult: String { Phase5Judge.classify(occurrences: finalOccurrences) }
}

// MARK: - The test class

final class WriteQueuePhase5BeforeNumbersE2ETests: Phase4bDelHarness {
    var preloaderOn = false
    var reps: [(number: Int, done: Phase5Performed)] = []
    var lossRows: [Phase5LossRow] = []
    var probeSets: [(label: String, probes: Phase5Probes)] = []
    var lastSwitchReturned: Date?
    var reportLines: [String] = []
    /// Keeps the probes' results alive so the optimizer cannot drop the work.
    var probeSink = 0

    func testBeforeNumbers_article() throws { try runBeforeNumbers(method: #function, size: .article, preloader: false) }
    func testBeforeNumbers_book6() throws { try runBeforeNumbers(method: #function, size: .book6, preloader: false) }
    func testBeforeNumbers_book12() throws { try runBeforeNumbers(method: #function, size: .book12, preloader: false) }
    func testBeforeNumbersPreloader_article() throws { try runBeforeNumbers(method: #function, size: .article, preloader: true) }
    func testBeforeNumbersPreloader_book6() throws { try runBeforeNumbers(method: #function, size: .book6, preloader: true) }
    func testBeforeNumbersPreloader_book12() throws { try runBeforeNumbers(method: #function, size: .book12, preloader: true) }
    func testLossWindow_article() throws { try runLossWindow(method: #function, size: .article) }
    func testLossWindow_book12() throws { try runLossWindow(method: #function, size: .book12) }

    /// No app: the pure judge, the parser and the marker names on canned input worked out by hand.
    func testPhase5Helpers_handWorkedExample() {
        let references = Phase5References(shaMs: 20, diskMs: 40, axMs: 10)
        // Ratios 1.0, 1.0, 1.0: valid with median 1.0.
        XCTAssertEqual(Phase5Judge.verdict(Phase5Probes(shaMs: 20, diskMs: 40, axMs: 10), references: references), .valid(median: 1.0))
        // Ratios 2.0, 2.0, 1.0: median 2.0 is above 1.5.
        XCTAssertTrue(Phase5Judge.verdict(Phase5Probes(shaMs: 40, diskMs: 80, axMs: 10), references: references).isInvalid)
        // Ratios 1.0, 1.0, 3.5: median 1.0 is fine, one ratio is above 3.0.
        XCTAssertTrue(Phase5Judge.verdict(Phase5Probes(shaMs: 20, diskMs: 40, axMs: 35), references: references).isInvalid)
        // Ratios 3.0, 1.0, 1.0: exactly 3.0 is not above 3.0, and the median 1.0 is fine.
        XCTAssertEqual(Phase5Judge.verdict(Phase5Probes(shaMs: 60, diskMs: 40, axMs: 10), references: references), .valid(median: 1.0))
        // No references: a reference-setting run, never invalid.
        let unset = Phase5References(shaMs: nil, diskMs: 1, axMs: 1)
        XCTAssertEqual(Phase5Judge.verdict(Phase5Probes(shaMs: 999, diskMs: 999, axMs: 999), references: unset), .referenceSetting)
        XCTAssertEqual(Phase5Judge.median([3, 1, 2]), 2)
        XCTAssertEqual(Phase5Judge.median([4, 1, 3, 2]), 2.5)
        XCTAssertNil(Phase5Judge.median([]))
        XCTAssertEqual(Phase5Judge.classify(occurrences: 0), "lost")
        XCTAssertEqual(Phase5Judge.classify(occurrences: 1), "survived")
        XCTAssertEqual(Phase5Judge.classify(occurrences: 2), "duplicated")
        XCTAssertEqual(Phase5Judge.classify(occurrences: -1), "unreadable")
        let line = "2026-11-02T10:00:00.123Z [ZoomClick] zoomOut() settled in 0.321s"
        XCTAssertEqual(Phase5Parse.seconds(after: "settled in ", in: line), 0.321)
        XCTAssertEqual(Phase5Parse.millis(0.321), 321)
        XCTAssertNil(Phase5Parse.seconds(after: "tail complete in ", in: line))
        // 24 markers: all different, all five characters, none inside another.
        let words = Phase5Limits.lossDelaysMs.indices.flatMap { cycle in Phase5Action.allCases.map { $0.marker(cycle: cycle + 1) } }
        XCTAssertEqual(words.count, 24)
        XCTAssertEqual(Set(words).count, 24)
        XCTAssertTrue(words.allSatisfy { $0.count == 5 })
        XCTAssertEqual(Phase5Action.zoomIn.marker(cycle: 3), "p5i03")
        let seeded = Self.withLossLines(Phase4bDelGenerator.make(chapters: 1), headingMarks: "## ", title: Phase4bDelSize.article.deleteTitle)
        XCTAssertNotNil(seeded)
        let text = seeded?.markdown ?? ""
        XCTAssertEqual(text.components(separatedBy: " line of the fixture document.").count - 1, 14 + Self.lossLineCount + Self.zoneLineCount)
        XCTAssertTrue(text.contains("## 1.3 Prices at the Market\n\n" + Self.zoneLine(1) + "\n\n" + Self.zoneLine(2)))
        XCTAssertTrue(text.contains("Anchor14 line of the fixture document.\n\n" + Self.lossLine(1) + "\n\n" + Self.lossLine(2)))
    }

    override func tearDownWithError() throws {
        if !methodName.isEmpty {
            let header = [
                "PHASE 5 A1 report of \(methodName): size \(size.identifier), preloader \(preloaderOn ? "ON" : "OFF").",
                "All figures are TEST VM figures, not the user's own Mac. The documents are the generated stand-ins of Phase4bDelSize.",
                "The build commit is not readable from the test process: take it from the vmtest result's source_commit.", ""
            ]
            attachText("phase5-report-\(methodName).txt", (header + reportLines).joined(separator: "\n"))
        }
        try super.tearDownWithError()
    }

    /// A line for the report: printed with the fixture tag in the test log and kept for the attached report.
    func emit(_ line: String) {
        reportLines.append(line)
        result(line)
    }
}

// MARK: - Starting a scenario

extension WriteQueuePhase5BeforeNumbersE2ETests {
    static let lossLineCount = 18
    static let zoneLineCount = 6
    static func lossLine(_ number: Int) -> String { String(format: "Loss%02d line of the fixture document.", number) }
    static func zoneLine(_ number: Int) -> String { String(format: "Zone%02d line of the fixture document.", number) }

    /// The document with the loss test's fresh lines: `lossLineCount` after Anchor14, `zoneLineCount` right under the zoom target's heading
    /// (`headingMarks` + `title`). Nil when either place is missing or ambiguous.
    static func withLossLines(_ generated: Phase4bDoc, headingMarks: String, title: String) -> Phase4bDoc? {
        let anchor14 = "Anchor14 line of the fixture document."
        let heading = "\n\n\(headingMarks)\(title)\n\n"
        guard generated.markdown.components(separatedBy: anchor14).count == 2, generated.markdown.components(separatedBy: heading).count == 2 else {
            return nil
        }
        let losses = (1...lossLineCount).map(lossLine).joined(separator: "\n\n")
        let zones = (1...zoneLineCount).map(zoneLine).joined(separator: "\n\n")
        var text = generated.markdown.replacingOccurrences(of: heading, with: heading + zones + "\n\n")
        text = text.replacingOccurrences(of: anchor14, with: anchor14 + "\n\n" + losses)
        return Phase4bDoc(markdown: text, cslJSON: generated.cslJSON, counts: Phase4bGenerator.count(text))
    }

    /// Begins the method, seeds (with the loss test's lines when asked), sets the preloader, launches and waits for the load to settle.
    func startScenario(method: String, size: Phase4bDelSize, preloader: Bool, lossLines: Bool, caretParagraph: Bool = false) -> Bool {
        begin(method: method, size: size)
        preloaderOn = preloader
        if lossLines {
            guard let generated = doc,
                  var seeded = Self.withLossLines(generated, headingMarks: size == .article ? "## " : "# ", title: size.deleteTitle) else {
                fail("TEST-SETUP: the loss lines could not be put into the document (Anchor14 or the heading \"\(size.deleteTitle)\" missing)")
                return false
            }
            if caretParagraph {
                let last = Self.lossLine(Self.lossLineCount)
                let text = seeded.markdown.replacingOccurrences(of: last, with: last + "\n\n" + Self.caretParagraphText)
                seeded = Phase4bDoc(markdown: text, cslJSON: seeded.cslJSON, counts: Phase4bGenerator.count(text))
                note("SEED: the caret paragraph after \(String(last.prefix(6))): \(Self.caretParagraphText)")
            }
            doc = seeded
            note("SEED: \(Self.lossLineCount) loss lines after Anchor14, \(Self.zoneLineCount) zone lines under \"\(size.deleteTitle)\"; "
                + seeded.counts.reportLine)
        } else {
            note("SEED: the generated document, unchanged")
        }
        if preloader {
            app.launchEnvironment["FF_UI_TESTING_ENABLE_PRELOADER"] = "1"
            note("SEAM FF_UI_TESTING_ENABLE_PRELOADER=1")
        }
        emit("ENVIRONMENT size=\(size.identifier) preloader=\(preloader ? "on" : "off") documents=generated stand-ins (TEST VM figures)")
        guard launchScenario(), requireSectionRows() != nil else { return false }
        tail.poll()
        evidenceLogStart = tail.lines.count
        return true
    }
}

// MARK: - Performing one action

/// What `prepare` settled before the trigger: the Outline card to double-click (zoom in) and the gap left since the previous switch.
struct Phase5Prepared {
    var card: XCUIElement?
    var gapMs: Int?
}

/// When and how long the marker typing of one repetition took, on the test process's clock.
struct Phase5TypingFacts {
    let requestedDelayMs: Int
    let startMs: Int
    let callMs: Int
}

extension WriteQueuePhase5BeforeNumbersE2ETests {
    /// Types straight into whatever has the keyboard focus. One `typeText` call: the marker is typed at a measured moment, not retyped.
    func typeNow(_ text: String) {
        // e2e-lint: allow raw-typetext -- typeText IS the measured input here (one marker at a measured delay); a verified retype would wait.
        app.typeText(text)
    }

    /// With the preloader on, leaves at least `claimGapSeconds` since the previous switch trigger returned, so the spare of the previous claim
    /// is ready. Returns the gap actually left (nil before the first switch).
    func waitForClaimGap() -> Int? {
        guard let last = lastSwitchReturned else { return nil }
        if preloaderOn {
            while Date().timeIntervalSince(last) < Phase5Limits.claimGapSeconds { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)) }
        }
        return Phase5Parse.ms(from: last, to: Date())
    }

    /// As `waitForLogQuiet`, but the high-volume polling categories (`noisyLogCategories`) do not count as activity: in Rich Text the app's
    /// block poll writes a line every 2 s for as long as the editor is open, so the plain wait ran to its 60 s cap after every action (first
    /// article run, run-1793601843-4229). Returns false when `cap` ran out first.
    func waitForQuietLog(quiet: TimeInterval, cap: TimeInterval) -> Bool {
        let noisyTags = Self.noisyLogCategories.map { " [\($0)] " }
        let deadline = Date(timeIntervalSinceNow: cap)
        tail.poll()
        var seen = tail.lines.count
        var lastActivity = Date()
        repeat {
            tail.poll()
            if tail.lines.count > seen {
                if tail.lines[seen...].contains(where: { line in !noisyTags.contains(where: { line.text.contains($0) }) }) { lastActivity = Date() }
                seen = tail.lines.count
            }
            if Date().timeIntervalSince(lastActivity) >= quiet { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return false
    }

    func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if element.exists, element.isEnabled { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        } while Date() < deadline
        return false
    }

    /// The needle of the line that ends `action` (see the file header).
    static func endNeedle(_ action: Phase5Action) -> String {
        switch action {
        case .toMarkdown: return markdownPageReadyLogLine
        case .toRichText: return "block IDs atomically"
        case .zoomIn: return "[ZoomClick] performUserZoomIn tail complete in"
        case .zoomOut: return "[ZoomClick] zoomOut() settled in"
        }
    }

    /// The state checks before a trigger. Nil after a reported failure.
    func prepare(_ action: Phase5Action) -> Phase5Prepared? {
        let modeButton = app.buttons["status-bar-editor-mode"]
        let exitButton = app.buttons["status-bar-zoom-exit"]
        switch action {
        case .toMarkdown, .toRichText:
            guard modeButton.waitForExistence(timeout: 10) else { fail("the editor-mode button never appeared"); return nil }
            if modeButton.label == action.wantedMode {
                fail("TEST-SETUP: the editor already reads \(action.wantedMode ?? "?") before the \(action.title)")
                return nil
            }
            return Phase5Prepared(card: nil, gapMs: waitForClaimGap())
        case .zoomIn:
            if exitButton.exists { fail("TEST-SETUP: the editor is already zoomed before the zoom in"); return nil }
            guard let card = bringZoomCardIntoView() else { return nil }
            return Phase5Prepared(card: card, gapMs: nil)
        case .zoomOut:
            guard exitButton.waitForExistence(timeout: 10), waitUntilEnabled(exitButton, timeout: 20) else {
                fail("TEST-SETUP: the zoom exit glyph is missing or disabled before the zoom out")
                return nil
            }
            return Phase5Prepared(card: nil, gapMs: nil)
        }
    }

    /// The Outline card of the chapter the zoom-in goes to, found by the END of its title. In the loss test a marker typed right after a
    /// zoom-in lands at the start of the zoomed chapter's heading (the very bug being reproduced), so the next cycle's card reads
    /// "p5i01.3 Prices at the Market" and an exact title match (`bringSidebarCardIntoView`) can no longer find it.
    func bringZoomCardIntoView() -> XCUIElement? {
        let title = size.deleteTitle
        let scroll = app.groups["outline-sidebar"].scrollViews.firstMatch
        guard scroll.waitForExistence(timeout: capped(30)) else { fail("the outline sidebar's scroll view never appeared"); return nil }
        let card = scroll.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label ENDSWITH %@ OR value ENDSWITH %@", title, title)).firstMatch
        var direction: CGFloat = 1
        for attempt in 1...size.sidebarScrollAttempts {
            let band = scroll.frame
            guard card.exists else {
                scroll.scroll(byDeltaX: 0, deltaY: -500 * direction)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8))
                continue
            }
            let frame = card.frame
            if band.insetBy(dx: 0, dy: 20).contains(frame) {
                note("SIDEBAR zoom card ending \"\(title)\" in view after \(attempt - 1) scroll(s)")
                return card
            }
            let wanted = max(-1200, min(1200, frame.midY - band.midY))
            scroll.scroll(byDeltaX: 0, deltaY: -wanted * direction)
            app.waitForStableFrame(card)
            if card.exists, (card.frame.midY - frame.midY) * (-wanted) < 0 { direction = -direction }
        }
        fail("the sidebar card ending \"\(title)\" could not be scrolled into view (scroll view \(scroll.frame), card exists: \(card.exists))")
        return nil
    }

    /// Fires the trigger of `action`: Cmd-/, the double-click on the Outline card, or the click on the status bar's exit glyph.
    func fire(_ action: Phase5Action, card: XCUIElement?) {
        let middle = CGVector(dx: 0.5, dy: 0.5)
        switch action {
        case .toMarkdown, .toRichText: app.typeKey("/", modifierFlags: .command)
        case .zoomIn: card?.coordinate(withNormalizedOffset: middle).doubleClick()
        case .zoomOut: app.buttons["status-bar-zoom-exit"].coordinate(withNormalizedOffset: middle).click()
        }
    }

    /// Types `word` once `delayMs` have passed since the trigger call returned (`returned`).
    func typeMarker(_ word: String, delayMs: Int, after returned: Date, zero: Date) -> Phase5TypingFacts {
        while Date().timeIntervalSince(returned) * 1_000 < Double(delayMs) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
        }
        let started = Date()
        typeNow(word)
        return Phase5TypingFacts(
            requestedDelayMs: delayMs, startMs: Phase5Parse.ms(from: zero, to: started), callMs: Phase5Parse.ms(from: started, to: Date()))
    }

    /// Does one action: the trigger, optionally one marker typed `delayMs` after the trigger returned, then waits for the end line, the
    /// state cross-check and a quiet log. Nil after a reported failure.
    func perform(_ action: Phase5Action, marker: (word: String, delayMs: Int)? = nil) -> Phase5Performed? {
        guard let prepared = prepare(action) else { return nil }
        app.activateAndWaitForForeground()
        tail.poll()
        let from = tail.lines.count
        if firstTriggerIndex == nil { firstTriggerIndex = from }
        let testZero = Date()
        fire(action, card: prepared.card)
        let returned = Date()
        if action.isSwitch { lastSwitchReturned = returned }
        let facts = marker.map { typeMarker($0.word, delayMs: $0.delayMs, after: returned, zero: testZero) }
        return finish(action, from: from, testZero: testZero, gapMs: prepared.gapMs, typedFacts: facts)
    }

    /// The zero of a repetition: the app's own Cmd-/ key line for a switch, else the test clock before the click.
    private func zeroPoint(_ action: Phase5Action, from: Int, through endIndex: Int, testZero: Date) -> (date: Date, basis: String) {
        if action.isSwitch,
           let keyLine = tail.lines[from...endIndex].first(where: { Phase4bDelTypingParser.key($0.text)?.code == Phase5Limits.slashKeyCode }),
           let keyDate = keyLine.date {
            return (keyDate, "app log: the Cmd-/ key line")
        }
        return (testZero, "test clock before the click")
    }

    /// The app's own `<s>s` figure on the end line, and (zoom out) the time from the zero to the later `tail complete` line.
    private func selfMeasured(_ action: Phase5Action, endText: String, from: Int, zero: Date) -> (appSelfMs: Int?, tailMs: Int?) {
        switch action {
        case .zoomIn:
            return (Phase5Parse.millis(Phase5Parse.seconds(after: "tail complete in ", in: endText)), nil)
        case .zoomOut:
            let own = Phase5Parse.millis(Phase5Parse.seconds(after: "settled in ", in: endText))
            let tailNeedle = "[ZoomClick] performUserZoomOut tail complete in"
            guard waitForLog(containing: tailNeedle, from: from, timeout: 30),
                  let index = tail.indexOfFirstLine(containing: tailNeedle, from: from), let date = tail.lines[index].date else { return (own, nil) }
            return (own, Phase5Parse.ms(from: zero, to: date))
        default:
            return (nil, nil)
        }
    }

    /// The state cross-check after an action: the badge, or the exit glyph.
    private func verifyEnded(_ action: Phase5Action) {
        switch action {
        case .toMarkdown, .toRichText:
            let wanted = action.wantedMode ?? ""
            let reads = app.buttons["status-bar-editor-mode"].waitForLabel("== '\(wanted)'", timeout: 10)
            assertCheck(reads, "after the \(action.title) the badge reads \(wanted)")
        case .zoomIn:
            let there = app.buttons["status-bar-zoom-exit"].waitForExistence(timeout: 10)
            assertCheck(there, "after the zoom in the exit glyph is there (the editor is zoomed)")
        case .zoomOut:
            // 30 s, not 10: the app's own end line has already come, but on the twelve-chapter book a zoom out can take 13 s on a loaded VM.
            let gone = app.buttons["status-bar-zoom-exit"].waitForDisappearance(timeout: 30)
            assertCheck(gone, "after the zoom out the exit glyph is gone (the editor is not zoomed)")
        }
    }

    /// The part of `perform` after the trigger (and the typing): the waits, the figures, the cross-check.
    private func finish(_ action: Phase5Action, from: Int, testZero: Date, gapMs: Int?, typedFacts: Phase5TypingFacts?) -> Phase5Performed? {
        let needle = Self.endNeedle(action)
        let timeout = size.operationTimeout * 2
        guard waitForLog(containing: needle, from: from, timeout: timeout), let endIndex = tail.indexOfFirstLine(containing: needle, from: from),
              let endDate = tail.lines[endIndex].date else {
            fail("no \"\(needle)\" line (with a readable stamp) within \(Int(timeout)) s of the \(action.title)")
            return nil
        }
        let zero = zeroPoint(action, from: from, through: endIndex, testZero: testZero)
        let own = selfMeasured(action, endText: tail.lines[endIndex].text, from: from, zero: zero.date)
        verifyEnded(action)
        _ = waitForQuietLog(quiet: Phase5Limits.quietSeconds, cap: 60)
        return Phase5Performed(
            action: action, zeroStamp: WriteQueuePhase4bTraceE2ETests.stamp(zero.date), zeroBasis: zero.basis,
            elapsedMs: Phase5Parse.ms(from: zero.date, to: endDate), tailMs: own.tailMs, appSelfMs: own.appSelfMs, gapMs: gapMs,
            typing: typedFacts.map { typing($0, from: from, zero: zero.date) })
    }

    /// The keys the marker typed, as the app's log says they arrived (the Cmd-/ key and arrow keys left out).
    private func typing(_ facts: Phase5TypingFacts, from: Int, zero: Date) -> Phase5Typing {
        tail.poll()
        var arrivals: [Int] = []
        var inEditor = 0
        for line in tail.lines[min(from, tail.lines.count)...] {
            guard let key = Phase4bDelTypingParser.key(line.text), key.code != Phase5Limits.slashKeyCode,
                  !Phase5Limits.arrowKeyCodes.contains(key.code), let date = line.date else { continue }
            arrivals.append(Phase5Parse.ms(from: zero, to: date))
            if key.inEditor { inEditor += 1 }
        }
        return Phase5Typing(
            requestedDelayMs: facts.requestedDelayMs, typeStartMs: facts.startMs, typingCallMs: facts.callMs, keyMs: arrivals,
            keysInEditor: inEditor)
    }
}

// MARK: - The validity probes

extension WriteQueuePhase5BeforeNumbersE2ETests {
    private func timeMs(_ work: () -> Void) -> Double {
        let began = DispatchTime.now().uptimeNanoseconds
        work()
        return Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
    }

    /// The three fixed probes of the file header, each the median of its runs. Printed with the verdict against the committed references.
    func measureProbes(label: String) -> Phase5Probes {
        let shaBuffer = Data(repeating: 0x5A, count: Phase5Limits.probeShaBytes)
        let shaTimes = (0..<Phase5Limits.probeRuns).map { _ in
            timeMs { probeSink &+= Int(Array(SHA256.hash(data: shaBuffer)).first ?? 0) }
        }
        let payload = Data(repeating: 0x33, count: Phase5Limits.probeDiskBytes)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ff-p5-probe-\(UUID().uuidString).bin")
        let diskTimes = (0..<Phase5Limits.probeRuns).map { _ in
            timeMs {
                do {
                    try payload.write(to: url, options: .atomic)
                    probeSink &+= try Data(contentsOf: url, options: .uncached).count
                } catch {
                    note("PROBE disk error: \(error)")
                }
            }
        }
        try? FileManager.default.removeItem(at: url)
        let modeButton = app.buttons["status-bar-editor-mode"]
        let axTimes = (0..<Phase5Limits.probeAxReads).map { _ in timeMs { probeSink &+= modeButton.label.count } }
        let probes = Phase5Probes(
            shaMs: Phase5Judge.median(shaTimes) ?? -1, diskMs: Phase5Judge.median(diskTimes) ?? -1, axMs: Phase5Judge.median(axTimes) ?? -1)
        probeSets.append((label, probes))
        emit("PHASE5-PROBES \(label): shaMs=\(String(format: "%.1f", probes.shaMs)) diskMs=\(String(format: "%.1f", probes.diskMs)) "
            + "axMs=\(String(format: "%.1f", probes.axMs)) verdict=\(Phase5Judge.verdict(probes).text)")
        return probes
    }

    /// Ends the run with XCTSkip when a probe set was INVALID. Nothing happens while the references are not set.
    func skipIfInvalid() throws {
        let invalid = probeSets.filter { Phase5Judge.verdict($0.probes).isInvalid }
        guard let first = invalid.first else { return }
        let why = Phase5Judge.verdict(first.probes).text
        emit("PHASE5-VALIDITY INVALID RUN: the \(first.label) probes: \(why)")
        throw XCTSkip("INVALID RUN - host too loaded, rerun: the \(first.label) probes: \(why)")
    }
}

// MARK: - The before-numbers

extension WriteQueuePhase5BeforeNumbersE2ETests {
    func runBeforeNumbers(method: String, size: Phase4bDelSize, preloader: Bool) throws {
        guard startScenario(method: method, size: size, preloader: preloader, lossLines: false) else { return }
        _ = measureProbes(label: "before")
        for number in 1...Phase5Limits.repetitions {
            for action in Phase5Action.allCases {
                guard let done = perform(action) else { return }
                reps.append((number, done))
                emitRep(number, done)
            }
        }
        _ = measureProbes(label: "after")
        emitSummary()
        try skipIfInvalid()
    }

    func emitRep(_ number: Int, _ done: Phase5Performed) {
        emit("PHASE5-BEFORE size=\(size.identifier) preloader=\(preloaderOn ? "on" : "off") rep=\(number) "
            + "action=\"\(done.action.title)\" ms=\(done.elapsedMs) tailMs=\(done.tailMs.map(String.init) ?? "-") "
            + "appSelfMs=\(done.appSelfMs.map(String.init) ?? "-") "
            + "gapMs=\(done.gapMs.map(String.init) ?? "-") zero=\"\(done.zeroBasis)\" triggerAt=\(done.zeroStamp)")
    }

    /// The median and range of the repetitions of each action.
    func emitSummary() {
        for action in Phase5Action.allCases {
            let rows = reps.filter { $0.done.action == action }.map { $0.done }
            let values = rows.map { Double($0.elapsedMs) }
            guard let middle = Phase5Judge.median(values), let low = values.min(), let high = values.max() else { continue }
            let own = Phase5Judge.median(rows.compactMap { $0.appSelfMs.map(Double.init) })
            emit("PHASE5-BEFORE SUMMARY size=\(size.identifier) preloader=\(preloaderOn ? "on" : "off") action=\"\(action.title)\" "
                + "medianMs=\(Int(middle)) rangeMs=\(Int(low))-\(Int(high)) reps=\(rows.count) appSelfMedianMs=\(own.map { String(Int($0)) } ?? "-")")
        }
    }
}

// MARK: - The loss window

extension WriteQueuePhase5BeforeNumbersE2ETests {
    func markerOccurrences(_ word: String) -> Int {
        let needle = FixtureDatabase.escape(word)
        let removed = "length(replace(markdownFragment, '\(needle)', ''))"
        return dbInt("SELECT COALESCE(SUM((length(markdownFragment) - \(removed)) / length('\(needle)')), 0) FROM block;") ?? -1
    }

    /// Where the first row holding `word` is: its type and its first characters.
    func markerLocation(_ word: String) -> String {
        let needle = FixtureDatabase.escape(word)
        let row = dbText("SELECT blockType || ': ' || substr(markdownFragment, 1, 50) FROM block "
            + "WHERE instr(markdownFragment, '\(needle)') > 0 ORDER BY sortOrder LIMIT 1;")
        return row.replacingOccurrences(of: "\n", with: " ")
    }

    /// Polls the block table until `word` is there (and one more half second for a late duplicate), at most `markerPollSeconds`.
    func waitForMarker(_ word: String) -> Int {
        let deadline = Date(timeIntervalSinceNow: Phase5Limits.markerPollSeconds)
        var count = markerOccurrences(word)
        while count < 1, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            count = markerOccurrences(word)
        }
        if count >= 1 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            count = markerOccurrences(word)
        }
        return count
    }

    func runLossWindow(method: String, size: Phase4bDelSize) throws {
        guard startScenario(method: method, size: size, preloader: false, lossLines: true) else { return }
        _ = measureProbes(label: "before")
        var lossNumber = 0
        for (index, delay) in Phase5Limits.lossDelaysMs.enumerated() {
            for action in Phase5Action.allCases {
                if Date().timeIntervalSince(startedAt) > size.budgetSeconds {
                    emit("PHASE5-LOSS BUDGET REACHED before the \(action.title) at \(delay) ms: "
                        + "\(lossRows.count) of \(Phase5Limits.lossDelaysMs.count * 4) markers typed")
                    return try finishLoss(incomplete: true)
                }
                let cycle = index + 1
                let word = action.marker(cycle: cycle)
                let prefix: String
                let line: String
                if action == .zoomOut {
                    prefix = String(format: "Zone%02d", cycle)
                    line = Self.zoneLine(cycle)
                } else {
                    lossNumber += 1
                    prefix = String(format: "Loss%02d", lossNumber)
                    line = Self.lossLine(lossNumber)
                }
                guard placeCaretAtAnchorEnd(paragraph: prefix, exactLine: line), let done = perform(action, marker: (word, delay)) else { return }
                let count = waitForMarker(word)
                let row = Phase5LossRow(action: action, word: word, done: done, occurrences: count, location: count > 0 ? markerLocation(word) : "-")
                lossRows.append(row)
                emitLossRow(row)
            }
        }
        try finishLoss(incomplete: false)
    }

    func emitLossRow(_ row: Phase5LossRow) {
        let typing = row.done.typing
        let keys = typing?.keyMs.map(String.init).joined(separator: ",") ?? "-"
        emit("PHASE5-LOSS action=\"\(row.action.title)\" marker=\(row.word) requestedDelayMs=\(typing?.requestedDelayMs ?? -1) "
            + "typeStartMs=\(typing?.typeStartMs ?? -1) typingCallMs=\(typing?.typingCallMs ?? -1) keyArrivalsMs=[\(keys)] "
            + "keysInEditor=\(typing?.keysInEditor ?? -1)/\(typing?.keyMs.count ?? -1) actionEndMs=\(row.done.elapsedMs) result=\(row.result) "
            + "where=\"\(row.location)\" zero=\"\(row.done.zeroBasis)\"")
    }

    /// The final audit (every marker counted again after the last action), the table and the assertion.
    private func finishLoss(incomplete: Bool) throws {
        _ = waitForQuietLog(quiet: Phase5Limits.quietSeconds, cap: 60)
        _ = waitForBlocksToSettle()
        _ = measureProbes(label: "after")
        var failures: [String] = []
        for index in lossRows.indices {
            lossRows[index].finalOccurrences = markerOccurrences(lossRows[index].word)
            let row = lossRows[index]
            let facts = "\(row.word) (\(row.action.title), requested \(row.done.typing?.requestedDelayMs ?? -1) ms, first key at "
                + "\(row.done.typing?.keyMs.first.map(String.init) ?? "n/a") ms, \(row.done.typing?.keysInEditor ?? -1) of "
                + "\(row.done.typing?.keyMs.count ?? -1) keys reached the editor, the action ended at \(row.done.elapsedMs) ms)"
            if row.result != "survived" { failures.append("\(facts) is \(row.result) right after the action") }
            if row.finalResult != "survived" { failures.append("\(facts) is \(row.finalResult) in the final audit") }
            emit("PHASE5-LOSS AUDIT marker=\(row.word) afterAction=\(row.result) final=\(row.finalResult)")
        }
        for action in Phase5Action.allCases {
            let rows = lossRows.filter { $0.action == action }
            let lost = rows.filter { $0.result == "lost" }.map(\.word)
            emit("PHASE5-LOSS SUMMARY action=\"\(action.title)\" typed=\(rows.count) survived=\(rows.filter { $0.result == "survived" }.count) "
                + "lost=\(lost.count) lostMarkers=[\(lost.joined(separator: ","))] duplicated=\(rows.filter { $0.result == "duplicated" }.count)")
        }
        let clean = failures.isEmpty && !incomplete
        let incompleteNote = incomplete ? ", run incomplete" : ""
        emit("PHASE5-LOSS VERDICT " + (clean ? "NOTHING LOST in this run" : "\(failures.count) marker problem(s)\(incompleteNote)"))
        let problems = failures.joined(separator: " | ")
        assertCheck(clean, "LOSS WINDOW: every marker survived exactly once; problems: \(problems)")
        if clean { try skipIfInvalid() }
    }
}

// MARK: - Job A5: a Delete pressed before the Markdown page is ready is held, then fast (board t-633df056)

extension WriteQueuePhase5BeforeNumbersE2ETests {
    /// The app's log lines this test reads. The first three are written by StructuralUndoController+MarkdownPageWait.swift (the third also
    /// by the old route's own fallback line); the hold marker by `TestMode.holdMarkdownPageReady`; the trigger line by
    /// UITestingDeleteTrigger; the fast-route mark by the editor-first Delete (`MdSpeed.mark("entered")`); the notice lines by ToastCenter.
    static let pageWaitHeldLine = "the Markdown page is still loading -- held until it is ready"
    static let pageWaitReadyLine = "the Markdown page is ready after"
    static let oldPathLine = "old path for this press"
    static let pageReadyHoldLine = "[MD-PAGE-READY-HOLD]"
    static let deleteTriggerLine = "deleteSection received title="
    static let fastRouteLine = "md-speed delete entered"
    static let noticeShownLine = "[toast] show style=progress message=Finishing the last change"
    static let noticeDismissedLine = "[toast] dismiss message=Finishing the last change"

    /// Board t-633df056. The twelve-chapter book opens in Rich Text; Cmd-/; and Delete Section is pressed the moment the badge says
    /// Markdown, BEFORE the Markdown page is mounted (the app's UI-test seam holds the mount for `Phase5Limits.pageReadyHoldMs`, so the
    /// press lands inside the window for certain; the real window is about 1 s idle and 2.5 s busy on this book). The app must HOLD the
    /// Delete until the page is ready (UX contract 4.2: held, never refused), show "Finishing the last change…" after a second, and then
    /// take the editor-first (fast) route, never the old whole-document body it quietly took in that window before job A5; and the delete
    /// must work (the heading is gone from the block table). FAILS on the code before A5: there the Delete asked the Rich Text page, got
    /// no answer and logged "the page refused or failed (no answer) -- old path for this press" (the diagnosis of run-1793546972-92411).
    func testMarkdownDeleteRightAfterSwitchIsHeldThenFast_book12() {
        app.launchEnvironment["FF_UI_TESTING_MD_PAGE_READY_HOLD_MS"] = String(Phase5Limits.pageReadyHoldMs)
        note("SEAM FF_UI_TESTING_MD_PAGE_READY_HOLD_MS=\(Phase5Limits.pageReadyHoldMs)")
        guard startScenario(method: #function, size: .book12, preloader: false, lossLines: false) else { return }
        let title = size.deleteTitle
        let mode = app.buttons["status-bar-editor-mode"]
        guard mode.waitForExistence(timeout: 10) else { fail("the editor-mode button never appeared"); return }
        app.activateAndWaitForForeground()
        tail.poll()
        let switchFrom = tail.lines.count
        firstTriggerIndex = switchFrom
        let pressedAt = Date()
        app.typeKey("/", modifierFlags: .command)
        guard mode.waitForLabel("== 'Markdown'", timeout: size.operationTimeout * 2) else {
            fail("the editor-mode button never reported Markdown after the toggle keystroke (it reads \(mode.label))")
            return
        }
        let badgeAt = Date()
        // The press, AT ONCE: the app's UI-testing Delete trigger (UITestingDeleteTrigger.swift), the same entry point the sidebar's Delete
        // Section runs. Not a menu click: the driver's own accessibility queries behind one take seconds on a book and would miss the window.
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.kerim.final-final.uitest.deleteSection"), object: nil, userInfo: ["title": title], deliverImmediately: true)
        let triggerAt = Date()
        emit("A5 DRIVER: Cmd-/ to badge \(Phase5Parse.ms(from: pressedAt, to: badgeAt)) ms; badge to Delete trigger "
            + "\(Phase5Parse.ms(from: badgeAt, to: triggerAt)) ms (test clock)")

        // What the app did, read from its log. Every wait is bounded; the verdicts come after them all, so one failure cannot hide the rest.
        let held = waitForLog(containing: Self.pageWaitHeldLine, from: switchFrom, timeout: 20)
        guard waitForMarkdownPageReady(from: switchFrom) else { return }
        let wentOn = waitForLog(containing: Self.pageWaitReadyLine, from: switchFrom, timeout: 20)
        let fast = waitForLog(containing: Self.fastRouteLine, from: switchFrom, timeout: 20)
        let rowsAfter = waitForHeadingRows(title, equalTo: 0, timeout: capped(size.operationTimeout * 2))
        _ = waitForQuietLog(quiet: Phase5Limits.quietSeconds, cap: 60)
        tail.poll()
        let window = Array(tail.lines[min(switchFrom, tail.lines.count)...])
        func stamp(_ needle: String) -> Date? { window.first { $0.text.contains(needle) }?.date }
        let oldPath = window.filter { $0.text.contains(Self.oldPathLine) }.map { String($0.text.suffix(140)) }
        let holdBegan = window.contains { $0.text.contains(Self.pageReadyHoldLine) }
        let noticeShown = window.contains { $0.text.contains(Self.noticeShownLine) }
        let noticeDismissed = window.contains { $0.text.contains(Self.noticeDismissedLine) }
        let placed: String
        if let triggerStamp = stamp(Self.deleteTriggerLine), let readyStamp = stamp(Self.markdownPageReadyLogLine) {
            let gap = Phase5Parse.ms(from: triggerStamp, to: readyStamp)
            placed = gap > 0
                ? "the Delete reached the app \(gap) ms BEFORE the page was ready"
                : "the Delete reached the app \(-gap) ms AFTER the page was ready (TEST-SETUP: the hold was too short for this host)"
        } else {
            placed = "the trigger line or the page-ready line is missing from the log, so the press cannot be placed against the page"
        }
        let heldMs = stamp(Self.pageWaitHeldLine).flatMap { began in stamp(Self.pageWaitReadyLine).map { Phase5Parse.ms(from: began, to: $0) } }
        emit("A5 APP: \(placed); held for \(heldMs.map(String.init) ?? "-") ms; notice shown \(Self.yesNo(noticeShown)), "
            + "taken down \(Self.yesNo(noticeDismissed)); heading rows after the delete: \(rowsAfter) (TEST VM figures)")

        assertCheck(holdBegan, "TEST-SETUP: the page-ready hold began (a \(Self.pageReadyHoldLine) line is in the log)")
        assertCheck(held, "the Delete pressed before the Markdown page was ready was HELD for the page (\"\(Self.pageWaitHeldLine)\"); \(placed)")
        assertCheck(wentOn, "the held Delete went on once the page was ready (\"\(Self.pageWaitReadyLine)\")")
        assertCheck(
            fast && oldPath.isEmpty,
            "the Delete took the editor-first (fast) route: its `\(Self.fastRouteLine)` line is there (\(Self.yesNo(fast))) and no "
                + "`\(Self.oldPathLine)` line is; old-path lines: \(oldPath)")
        assertCheck(rowsAfter == 0, "the delete worked: the heading \"\(title)\" is gone from the block table (rows: \(rowsAfter))")
        assertCheck(
            noticeShown && noticeDismissed,
            "the held Delete showed \"Finishing the last change…\" after a second and took it down when done (UX contract 4.2)")
    }
}

// MARK: - Job A7: typing inside a Rich Text zoom's window is carried across (design a7-a10-design.md, sections 1, 6 and 7)

/// What one zoom with a marker typed inside its held window showed in the app's log.
struct Phase5ZoomTyping { let holdSeen: Bool; let swapped: Bool; let keysInEditor: Int }

extension WriteQueuePhase5BeforeNumbersE2ETests {
    /// The app's seam (`FF_UI_TESTING_TRANS_HOLD_MS`) widens the window of the first two transitions (the zoom in, then the zoom out). New
    /// path: after the barrier, the page holding and recording. Legacy path: after the cached-copy flush, before the push.
    static let transHoldMs = 3_000
    static let transSwappedLine = "[TRANS] swapped kind="
    /// Typed in chapter 1 during the zoom INTO chapter 6 (outside the range); typed in chapter 6 during the zoom OUT (inside the window).
    static let outsideMarker = "p7out"
    static let insideMarker = "p7zin"
    /// Job A7, the new path: both markers survive exactly once, each in its own line (`Loss01` in chapter 1, `Zone01` in chapter 6).
    func testZoomTypingInsideHeldWindow_book12() throws { try runZoomTypingInsideHeldWindow(method: #function, legacy: false) }
    /// The must-fail twin on today's path (`FF_UI_TESTING_LEGACY_TRANSITION=zoom`): EXPECTED TO FAIL, the push overwrites the typing.
    func testZoomTypingInsideHeldWindowLegacy_book12() throws { try runZoomTypingInsideHeldWindow(method: #function, legacy: true) }
    func testBeforeNumbersLegacyZoom_article() throws { try runLegacyZoomBeforeNumbers(method: #function, size: .article) }
    func testBeforeNumbersLegacyZoom_book6() throws { try runLegacyZoomBeforeNumbers(method: #function, size: .book6) }
    func testBeforeNumbersLegacyZoom_book12() throws { try runLegacyZoomBeforeNumbers(method: #function, size: .book12) }
    func runLegacyZoomBeforeNumbers(method: String, size: Phase4bDelSize) throws {
        app.launchEnvironment["FF_UI_TESTING_LEGACY_TRANSITION"] = "zoom"
        emit("A7 PATH legacy zoom (today's path), SEAM FF_UI_TESTING_LEGACY_TRANSITION=zoom")
        try runBeforeNumbers(method: method, size: size, preloader: false)
    }
    /// Caret at the end of `line`, the zoom triggered, the marker typed as soon as the app logs that the hold began, the zoom waited out.
    private func zoomTypingInsideHold(_ action: Phase5Action, caretPrefix: String, line: String, marker: String) -> Phase5ZoomTyping? {
        guard placeCaretAtAnchorEnd(paragraph: caretPrefix, exactLine: line), let prepared = prepare(action) else { return nil }
        app.activateAndWaitForForeground()
        tail.poll()
        let from = tail.lines.count
        if firstTriggerIndex == nil { firstTriggerIndex = from }
        fire(action, card: prepared.card)
        let holdSeen = waitForLog(containing: "[TRANS-HOLD]", from: from, timeout: size.operationTimeout)
        typeNow(marker)
        let end = Self.endNeedle(action)
        guard waitForLog(containing: end, from: from, timeout: size.operationTimeout * 2) else { fail("no \"\(end)\" line"); return nil }
        _ = waitForQuietLog(quiet: Phase5Limits.quietSeconds, cap: 60)
        tail.poll()
        let window = tail.lines[min(from, tail.lines.count)...]
        return Phase5ZoomTyping(
            holdSeen: holdSeen, swapped: window.contains { $0.text.contains(Self.transSwappedLine) },
            keysInEditor: window.compactMap { Phase4bDelTypingParser.key($0.text) }.filter(\.inEditor).count)
    }
    private func audit(_ marker: String, _ label: String, _ zoom: Phase5ZoomTyping) -> (count: Int, row: String) {
        let count = waitForMarker(marker)
        let row = count > 0 ? markerLocation(marker) : "-"
        emit("A7 \(label): hold seen \(Self.yesNo(zoom.holdSeen)), swapped \(Self.yesNo(zoom.swapped)), keys in the editor "
            + "\(zoom.keysInEditor); \(marker) in the rows \(count) time(s), at \"\(row)\"")
        return (count, row)
    }
    func runZoomTypingInsideHeldWindow(method: String, legacy: Bool) throws {
        app.launchEnvironment["FF_UI_TESTING_TRANS_HOLD_MS"] = String(Self.transHoldMs)
        app.launchEnvironment["FF_UI_TESTING_TRANS_HOLD_FIRST_N"] = "2"
        if legacy { app.launchEnvironment["FF_UI_TESTING_LEGACY_TRANSITION"] = "zoom" }
        note("SEAM FF_UI_TESTING_TRANS_HOLD_MS=\(Self.transHoldMs) FIRST_N=2" + (legacy ? " LEGACY_TRANSITION=zoom (EXPECTED TO FAIL)" : ""))
        guard startScenario(method: method, size: .book12, preloader: false, lossLines: true) else { return }
        emit("A7 PATH \(legacy ? "legacy zoom (today's path)" : "carried zoom (the new path)")")
        let zoomIn = zoomTypingInsideHold(.zoomIn, caretPrefix: "Loss01", line: Self.lossLine(1), marker: Self.outsideMarker)
        guard let zoomIn else { return }
        let outside = audit(Self.outsideMarker, "ZOOM IN", zoomIn)
        let zoomOut = zoomTypingInsideHold(.zoomOut, caretPrefix: "Zone01", line: Self.zoneLine(1), marker: Self.insideMarker)
        guard let zoomOut else { return }
        let inside = audit(Self.insideMarker, "ZOOM OUT", zoomOut)
        _ = waitForBlocksToSettle()
        let outsideFinal = markerOccurrences(Self.outsideMarker)
        let insideFinal = markerOccurrences(Self.insideMarker)
        emit("A7 AUDIT final: \(Self.outsideMarker)=\(outsideFinal), \(Self.insideMarker)=\(insideFinal)")
        assertCheck(zoomIn.holdSeen && zoomOut.holdSeen, "TEST-SETUP: both zooms logged [TRANS-HOLD] (the window was widened)")
        assertCheck(zoomIn.keysInEditor >= 5 && zoomOut.keysInEditor >= 5,
                    "TEST-SETUP: the marker keys reached the editor (zoom in \(zoomIn.keysInEditor), zoom out \(zoomOut.keysInEditor))")
        if !legacy { assertCheck(zoomIn.swapped && zoomOut.swapped, "both zooms took the carried path (a \(Self.transSwappedLine) line)") }
        assertCheck(outside.count == 1 && outsideFinal == 1 && outside.row.contains("Loss01"),
                    "chapter-1 typing during the zoom into chapter 6 saved once, in its line (\(outside.count), final \(outsideFinal))")
        assertCheck(inside.count == 1 && insideFinal == 1 && inside.row.contains("Zone01"),
                    "chapter-6 typing during the zoom out saved once, in its line (\(inside.count), final \(insideFinal))")
    }
}

// MARK: - Job A8: typing inside a Markdown zoom's window is carried across (design a7-a10-design.md, sections 2, 6 and 7)

extension WriteQueuePhase5BeforeNumbersE2ETests {
    /// Job A8, the new path, typing INSIDE the zoomed chapter in both windows: the zoom into chapter 6 with the caret in chapter 6 (`Zone01`),
    /// then the zoom out with the caret on `Zone02`. Both markers survive exactly once, each in its own line.
    func testMarkdownZoomTypingInside_book12() throws { try runMarkdownZoomTyping(method: #function, legacy: false, outside: false) }
    /// The must-fail twin on today's path (`FF_UI_TESTING_LEGACY_TRANSITION=zoom`): EXPECTED TO FAIL, the push overwrites the typing.
    func testMarkdownZoomTypingInsideLegacy_book12() throws { try runMarkdownZoomTyping(method: #function, legacy: true, outside: false) }
    /// Job A8, typing OUTSIDE the zoomed span: the zoom into chapter 6 with the caret in chapter 1 (`Loss01`); then the zoom out, inside.
    func testMarkdownZoomTypingOutside_book12() throws { try runMarkdownZoomTyping(method: #function, legacy: false, outside: true) }
    /// Its must-fail twin on today's path: EXPECTED TO FAIL (the zoom out's push overwrites the typing done in its window).
    func testMarkdownZoomTypingOutsideLegacy_book12() throws { try runMarkdownZoomTyping(method: #function, legacy: true, outside: true) }
    /// The A/B timing of the zooms in Markdown, the same build with and without the change (`legacy`).
    func testMarkdownZoomNumbers_article() throws { try runMarkdownZoomNumbers(method: #function, size: .article, legacy: false) }
    func testMarkdownZoomNumbers_book6() throws { try runMarkdownZoomNumbers(method: #function, size: .book6, legacy: false) }
    func testMarkdownZoomNumbers_book12() throws { try runMarkdownZoomNumbers(method: #function, size: .book12, legacy: false) }
    func testMarkdownZoomNumbersLegacy_article() throws { try runMarkdownZoomNumbers(method: #function, size: .article, legacy: true) }
    func testMarkdownZoomNumbersLegacy_book6() throws { try runMarkdownZoomNumbers(method: #function, size: .book6, legacy: true) }
    func testMarkdownZoomNumbersLegacy_book12() throws { try runMarkdownZoomNumbers(method: #function, size: .book12, legacy: true) }

    /// The Markdown page draws only the lines in view: a single click on the zoom chapter's Outline card scrolls it there (UX contract 2).
    private func showZoomChapter() -> Bool {
        guard let card = bringZoomCardIntoView() else { return false }
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click() // as `fire` does: the card's text is not hittable
        _ = waitForQuietLog(quiet: Phase5Limits.quietSeconds, cap: 30)
        return true
    }

    /// Starts the scenario and switches to Markdown (waited out like every action).
    private func startInMarkdown(method: String, size: Phase4bDelSize, lossLines: Bool, legacy: Bool) -> Bool {
        if legacy { app.launchEnvironment["FF_UI_TESTING_LEGACY_TRANSITION"] = "zoom" }
        guard startScenario(method: method, size: size, preloader: false, lossLines: lossLines), perform(.toMarkdown) != nil else { return false }
        let path = legacy ? "legacy zoom (today's path), SEAM FF_UI_TESTING_LEGACY_TRANSITION=zoom" : "carried zoom (the new path)"
        emit("A8 PATH \(path) in Markdown")
        return true
    }

    func runMarkdownZoomNumbers(method: String, size: Phase4bDelSize, legacy: Bool) throws {
        guard startInMarkdown(method: method, size: size, lossLines: false, legacy: legacy) else { return }
        _ = measureProbes(label: "before")
        for number in 1...Phase5Limits.repetitions {
            for action in [Phase5Action.zoomIn, .zoomOut] {
                guard let done = perform(action) else { return }
                reps.append((number, done))
                emitRep(number, done)
            }
        }
        _ = measureProbes(label: "after")
        emitSummary()
        try skipIfInvalid()
    }

    func runMarkdownZoomTyping(method: String, legacy: Bool, outside: Bool) throws {
        app.launchEnvironment["FF_UI_TESTING_TRANS_HOLD_MS"] = String(Self.transHoldMs)
        // Three: the carried switch to Markdown that starts the scenario takes the first hold (A9's seam sits in the switch too;
        // run-1793952798-94205 logged no hold for the zoom out with two), then the zoom in and the zoom out.
        app.launchEnvironment["FF_UI_TESTING_TRANS_HOLD_FIRST_N"] = "3"
        note("SEAM FF_UI_TESTING_TRANS_HOLD_MS=\(Self.transHoldMs) FIRST_N=3" + (legacy ? " LEGACY_TRANSITION=zoom (EXPECTED TO FAIL)" : ""))
        guard startInMarkdown(method: method, size: .book12, lossLines: true, legacy: legacy) else { return }
        let firstMarker = outside ? "m8out" : "m8zin"
        let (firstPrefix, firstLine) = outside ? ("Loss01", Self.lossLine(1)) : ("Zone01", Self.zoneLine(1))
        if !outside { guard showZoomChapter() else { return } }
        guard let zoomIn = zoomTypingInsideHold(.zoomIn, caretPrefix: firstPrefix, line: firstLine, marker: firstMarker) else { return }
        let first = audit(firstMarker, "MARKDOWN ZOOM IN", zoomIn)
        // After the zoom in the chapter's top was out of view (run-1793900955-66664: the push is the same `setContent` on both paths); the
        // person clicks the chapter's card to get there.
        guard showZoomChapter(),
              let zoomOut = zoomTypingInsideHold(.zoomOut, caretPrefix: "Zone02", line: Self.zoneLine(2), marker: "m8zot") else { return }
        let second = audit("m8zot", "MARKDOWN ZOOM OUT", zoomOut)
        _ = waitForBlocksToSettle()
        let firstFinal = markerOccurrences(firstMarker)
        let secondFinal = markerOccurrences("m8zot")
        emit("A8 AUDIT final: \(firstMarker)=\(firstFinal), m8zot=\(secondFinal)")
        assertCheck(zoomIn.holdSeen && zoomOut.holdSeen, "TEST-SETUP: both zooms logged [TRANS-HOLD] (the window was widened)")
        assertCheck(zoomIn.keysInEditor >= 5 && zoomOut.keysInEditor >= 5,
                    "TEST-SETUP: the marker keys reached the editor (zoom in \(zoomIn.keysInEditor), zoom out \(zoomOut.keysInEditor))")
        if !legacy { assertCheck(zoomIn.swapped && zoomOut.swapped, "both zooms took the carried path (a \(Self.transSwappedLine) line)") }
        assertCheck(first.count == 1 && firstFinal == 1 && first.row.contains(firstPrefix),
                    "typing during the zoom in saved once, in its line \(firstPrefix) (\(first.count), final \(firstFinal))")
        assertCheck(second.count == 1 && secondFinal == 1 && second.row.contains("Zone02"),
                    "typing during the zoom out saved once, in its line Zone02 (\(second.count), final \(secondFinal))")
    }
}

// MARK: - Jobs A9 and A10: typing inside the Rich Text / Markdown switch is carried across (design a7-a10-design.md, sections 3, 4, 6, 7)

extension WriteQueuePhase5BeforeNumbersE2ETests {
    /// Job A9 then A10, the new path: the caret on `Loss01` in Rich Text, Cmd-/ (to Markdown), a marker typed as soon as the app logs that the
    /// switch's window was widened (`FF_UI_TESTING_TRANS_HOLD_MS`: the incoming page is ready, the outgoing page still on screen); then Cmd-/
    /// back (to Rich Text) with a second marker typed the same way at the caret, which is still in that line. Both survive exactly once, in
    /// the `Loss01` row.
    func testSwitchTypingInsideHeldWindow_article() throws { try runSwitchTypingInsideHeldWindow(method: #function, legacy: false) }
    /// The must-fail twin on today's path (`FF_UI_TESTING_LEGACY_TRANSITION=switch`; the same hold sits between the flip and the new page's
    /// text): EXPECTED TO FAIL, the keys reach no editor or are overwritten when the new page gets its text.
    func testSwitchTypingInsideHeldWindowLegacy_article() throws { try runSwitchTypingInsideHeldWindow(method: #function, legacy: true) }
    /// The A/B timing of both switches on today's path (`FF_UI_TESTING_LEGACY_TRANSITION=switch`), the same steps as `testBeforeNumbers_*`
    /// and `testBeforeNumbersPreloader_*`.
    func testBeforeNumbersLegacySwitch_article() throws { try runLegacySwitchBeforeNumbers(method: #function, size: .article, preloader: false) }
    func testBeforeNumbersLegacySwitch_book6() throws { try runLegacySwitchBeforeNumbers(method: #function, size: .book6, preloader: false) }
    func testBeforeNumbersLegacySwitch_book12() throws { try runLegacySwitchBeforeNumbers(method: #function, size: .book12, preloader: false) }
    func testBeforeNumbersPreloaderLegacySwitch_article() throws {
        try runLegacySwitchBeforeNumbers(method: #function, size: .article, preloader: true)
    }
    func testBeforeNumbersPreloaderLegacySwitch_book6() throws {
        try runLegacySwitchBeforeNumbers(method: #function, size: .book6, preloader: true)
    }
    func testBeforeNumbersPreloaderLegacySwitch_book12() throws {
        try runLegacySwitchBeforeNumbers(method: #function, size: .book12, preloader: true)
    }

    /// Diagnosis (a9-notes.md, 04:45 entry): the loss window with today's switch and the carried zooms, to tell whether the zoom-in typing
    /// that becomes a delete plus an insert comes from the carried switch's prepared page or from the carried zoom itself.
    func testLossWindowLegacySwitch_book12() throws {
        app.launchEnvironment["FF_UI_TESTING_LEGACY_TRANSITION"] = "switch"
        emit("A9/A10 PATH legacy switch (today's path), carried zooms, SEAM FF_UI_TESTING_LEGACY_TRANSITION=switch")
        try runLossWindow(method: #function, size: .book12)
    }

    func runLegacySwitchBeforeNumbers(method: String, size: Phase4bDelSize, preloader: Bool) throws {
        app.launchEnvironment["FF_UI_TESTING_LEGACY_TRANSITION"] = "switch"
        emit("A9/A10 PATH legacy switch (today's path), SEAM FF_UI_TESTING_LEGACY_TRANSITION=switch")
        try runBeforeNumbers(method: method, size: size, preloader: preloader)
    }

    /// One switch with a marker typed inside its held window, at the caret wherever it is. Nil after a reported failure.
    private func switchTypingInsideHold(_ action: Phase5Action, marker: String) -> Phase5ZoomTyping? {
        guard let prepared = prepare(action) else { return nil }
        app.activateAndWaitForForeground()
        tail.poll()
        let from = tail.lines.count
        if firstTriggerIndex == nil { firstTriggerIndex = from }
        fire(action, card: prepared.card)
        let holdSeen = waitForLog(containing: "[TRANS-HOLD]", from: from, timeout: size.operationTimeout)
        typeNow(marker)
        let end = Self.endNeedle(action)
        guard waitForLog(containing: end, from: from, timeout: size.operationTimeout * 2) else { fail("no \"\(end)\" line"); return nil }
        let wanted = action.wantedMode ?? ""
        let reads = app.buttons["status-bar-editor-mode"].waitForLabel("== '\(wanted)'", timeout: 10)
        assertCheck(reads, "after the \(action.title) the badge reads \(wanted)")
        _ = waitForQuietLog(quiet: Phase5Limits.quietSeconds, cap: 60)
        tail.poll()
        let window = tail.lines[min(from, tail.lines.count)...]
        return Phase5ZoomTyping(
            holdSeen: holdSeen, swapped: window.contains { $0.text.contains("[TRANS] swapped kind=switch") },
            keysInEditor: window.compactMap { Phase4bDelTypingParser.key($0.text) }.filter(\.inEditor).count)
    }

    func runSwitchTypingInsideHeldWindow(method: String, legacy: Bool) throws {
        app.launchEnvironment["FF_UI_TESTING_TRANS_HOLD_MS"] = String(Self.transHoldMs)
        app.launchEnvironment["FF_UI_TESTING_TRANS_HOLD_FIRST_N"] = "2"
        if legacy { app.launchEnvironment["FF_UI_TESTING_LEGACY_TRANSITION"] = "switch" }
        note("SEAM FF_UI_TESTING_TRANS_HOLD_MS=\(Self.transHoldMs) FIRST_N=2" + (legacy ? " LEGACY_TRANSITION=switch (EXPECTED TO FAIL)" : ""))
        guard startScenario(method: method, size: .article, preloader: false, lossLines: true) else { return }
        emit("A9/A10 PATH \(legacy ? "legacy switch (today's path)" : "carried switch (the new path)")")
        guard placeCaretAtAnchorEnd(paragraph: "Loss01", exactLine: Self.lossLine(1)),
              let toMarkdown = switchTypingInsideHold(.toMarkdown, marker: "s9md") else { return }
        let first = audit("s9md", "SWITCH TO MARKDOWN", toMarkdown)
        guard let toRichText = switchTypingInsideHold(.toRichText, marker: "s10rt") else { return }
        let second = audit("s10rt", "SWITCH TO RICH TEXT", toRichText)
        _ = waitForBlocksToSettle()
        let firstFinal = markerOccurrences("s9md")
        let secondFinal = markerOccurrences("s10rt")
        emit("A9/A10 AUDIT final: s9md=\(firstFinal), s10rt=\(secondFinal)")
        assertCheck(toMarkdown.holdSeen && toRichText.holdSeen, "TEST-SETUP: both switches logged [TRANS-HOLD] (the window was widened)")
        if !legacy { assertCheck(toMarkdown.swapped && toRichText.swapped, "both switches took the carried path (a [TRANS] swapped line)") }
        assertCheck(first.count == 1 && firstFinal == 1 && first.row.contains("Loss01"),
                    "typing during the switch to Markdown saved once, in its line (\(first.count), final \(firstFinal))")
        assertCheck(second.count == 1 && secondFinal == 1 && second.row.contains("Loss01"),
                    "typing during the switch to Rich Text saved once, in its line (\(second.count), final \(secondFinal))")
    }
}

// MARK: - Hand test 2026-11-06: the caret across the switch, with citations before it (a9-notes.md, "Cursor fix and switch notice")

/// One switch of `testSwitchCaretFollowsTyping_article`: whether it ended, what the log said, and the paragraph's row afterwards.
struct Phase5CaretSwitch { let ended: Bool; let note: String; let row: String }

extension WriteQueuePhase5BeforeNumbersE2ETests {
    /// A body paragraph with three citations before its end (one Rich Text atom each, many characters in Markdown), seeded after the loss
    /// lines. Short enough to sit on one line, so Cmd-Right after the click is the paragraph's end.
    static var caretParagraphText: String {
        let keys = Phase4bGenerator.citekeys
        return "Caret01 ledger [@\(keys[0]), {p. 12}; @\(keys[1]), {p. 40}] harbour [@\(keys[2])] closes."
    }

    /// The owner's hand test of 2026-11-06, made exact: the caret at the END of a paragraph with citations before it, a few letters typed,
    /// Cmd-/, and the rest of a long string typed straight on (in two-letter pieces, so the flip falls in the middle of it: some keys reach
    /// the outgoing page, the rest the incoming one), then a closing word once the switch is over. The paragraph must end with the whole
    /// string, contiguous, followed by the closing word: the caret ended where the typing went on. Then the same back to Rich Text.
    /// Before the fix the keys typed on the new Markdown page landed in the middle of the paragraph: the caret came over at a column
    /// computed with each citation counted as one character.
    func testSwitchCaretFollowsTyping_article() throws {
        guard startScenario(method: #function, size: .article, preloader: false, lossLines: true, caretParagraph: true),
              placeCaretInCaretParagraph(wordsBack: 0) else { return }
        let first = switchWhileTyping(.toMarkdown, head: " the qu", tail: "ick brown fox jumps over the lazy dog", closing: " zq9one")
        let firstText = " the quick brown fox jumps over the lazy dog zq9one"
        let second = switchWhileTyping(.toRichText, head: " pack my", tail: " box with five dozen liquor jugs", closing: " zq9two")
        let secondText = " pack my box with five dozen liquor jugs zq9two"
        _ = waitForBlocksToSettle()
        let after = caretRow()
        emit("CARET-SWITCH final row: \"\(after)\"")
        assertCheck(first.ended && second.ended, "TEST-SETUP: both switches ended (to Markdown \(first.note); to Rich Text \(second.note))")
        assertCheck(first.row.hasSuffix("closes." + firstText),
                    "after the switch to Markdown the paragraph ends with the typing, contiguous, then the closing word: \"\(first.row)\"")
        assertCheck(after.hasSuffix("closes." + firstText + secondText),
                    "after the switch back to Rich Text the paragraph ends with both typings, contiguous: \"\(after)\"")
    }

    /// The same in the middle of the paragraph, after the two citations of its first line: Option-Down then Option-Left after the click leave
    /// the caret right before "harbour" in the test VM's window (run-1793949042-67803). The typing, all of it after Cmd-/, starts with the
    /// letter that follows the caret ("hot" before "harbour"): the text difference then finds the carried keys one letter later than they
    /// were typed, and keys typed on the new page went BEFORE them (run-1793947506-54633, run-1793948299-61623). The check does not depend
    /// on where the caret landed: each typing must be in the row whole and in order, the second right after the first.
    func testSwitchCaretFollowsTypingMidParagraph_article() throws {
        guard startScenario(method: #function, size: .article, preloader: false, lossLines: true, caretParagraph: true),
              placeCaretInCaretParagraph(wordsBack: 1) else { return }
        let first = switchWhileTyping(.toMarkdown, head: "", tail: "hot dark night falls ", closing: "zq9one ")
        let second = switchWhileTyping(.toRichText, head: "", tail: "hazy morning air comes ", closing: "zq9two ")
        _ = waitForBlocksToSettle()
        let after = caretRow()
        emit("CARET-SWITCH final row: \"\(after)\"")
        assertCheck(first.ended && second.ended, "TEST-SETUP: both switches ended (to Markdown \(first.note); to Rich Text \(second.note))")
        assertCheck(first.row.contains("hot dark night falls zq9one "),
                    "after the switch to Markdown the typing is in the row whole and in order: \"\(first.row)\"")
        assertCheck(after.contains("hot dark night falls zq9one hazy morning air comes zq9two "),
                    "after the switch back to Rich Text both typings are whole, in order, one after the other: \"\(after)\"")
    }

    /// The caret in the Caret01 paragraph: its end (`wordsBack` 0; the paragraph wraps in the test window, so Cmd-Right after the click
    /// stops at the end of its first line), or the middle (Option-Down, then `wordsBack` words back with Option-Left). Checks the row.
    private func placeCaretInCaretParagraph(wordsBack: Int) -> Bool {
        let placed = app.placeCaretByClicking(paragraphStartingWith: "Caret01", atEnd: true, runProbe: false, findTimeout: capped(90))
        note("CARET in the Caret01 paragraph: \(placed.attempts)")
        guard !placed.attempts.isEmpty else { fail("the Caret01 paragraph could not be clicked (probe \(placed.probe))"); return false }
        if wordsBack == 0 {
            // The end: the paragraph is two lines in the test VM's window; Down then Cmd-Right is the end of its second line.
            app.typeKey(.downArrow, modifierFlags: [])
            app.typeKey(.rightArrow, modifierFlags: .command)
        } else {
            // run-1793949466-70869: this leaves the caret right before "harbour" in the test VM's window.
            app.typeKey(.downArrow, modifierFlags: .option)
            for _ in 0..<wordsBack { app.typeKey(.leftArrow, modifierFlags: .option) }
        }
        let before = caretRow()
        guard before.hasPrefix("Caret01"), before.hasSuffix("closes.") else {
            fail("TEST-SETUP: the Caret01 row reads \"\(before)\"")
            return false
        }
        return true
    }

    /// The Caret01 row's text from the database (one line).
    private func caretRow() -> String {
        dbText("SELECT markdownFragment FROM block WHERE markdownFragment LIKE 'Caret01%' ORDER BY sortOrder LIMIT 1;")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// `head`, the switch key, `typed` in two-letter pieces straight on, the switch waited out, then `closing`; the row once it settled.
    private func switchWhileTyping(_ action: Phase5Action, head: String, tail typed: String, closing: String)
        -> Phase5CaretSwitch {
        guard prepare(action) != nil else { return Phase5CaretSwitch(ended: false, note: "not prepared", row: caretRow()) }
        tail.poll()
        let from = tail.lines.count
        if firstTriggerIndex == nil { firstTriggerIndex = from }
        if !head.isEmpty { typeNow(head) }
        let pressed = Date()
        fire(action, card: nil)
        var rest = Substring(typed)
        while !rest.isEmpty {
            typeNow(String(rest.prefix(2)))
            rest = rest.dropFirst(2)
        }
        let typedMs = Phase5Parse.ms(from: pressed, to: Date())
        let end = Self.endNeedle(action)
        let ended = waitForLog(containing: end, from: from, timeout: size.operationTimeout * 2)
        let reads = app.buttons["status-bar-editor-mode"].waitForLabel("== '\(action.wantedMode ?? "")'", timeout: 10)
        _ = waitForQuietLog(quiet: Phase5Limits.quietSeconds, cap: 60)
        typeNow(closing)
        _ = waitForQuietLog(quiet: Phase5Limits.quietSeconds, cap: 60)
        _ = waitForBlocksToSettle()
        tail.poll()
        let flip = tail.lines[min(from, tail.lines.count)...].first { $0.text.contains("[TRANS] swapped kind=switch") }
        let flipMs = flip?.date.map { Phase5Parse.ms(from: pressed, to: $0) }
        let row = caretRow()
        let summary = "ended \(Self.yesNo(ended)), badge \(Self.yesNo(reads)), flip at \(flipMs.map(String.init) ?? "-") ms, "
            + "typing ended at \(typedMs) ms (test clock)"
        emit("CARET-SWITCH \(action.title): \(summary); row \"\(row)\"")
        return Phase5CaretSwitch(ended: ended && reads, note: summary, row: row)
    }
}
