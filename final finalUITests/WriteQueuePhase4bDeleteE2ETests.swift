//
//  WriteQueuePhase4bDeleteE2ETests.swift
//  final finalUITests
//
//  PHASE 4b PART 2, SLICE 0 (bt task t-94369a83): MEASURE ONLY. How long do Delete Section, Cmd-Z and Cmd-Shift-Z take TODAY, on the app's
//  own clock, on three synthetic documents, so the next builds can be timed old-versus-new in one session? The numbers come from the
//  `[STRUCT-TRACE]` and `[TYPING-TRACE]` lines of final final/Services/StructuralTrace.swift (formats: docs/architecture/unified-undo.md,
//  "Timing trace for the editor-first delete work"). THIS CLASS ASSERTS NO TIME LIMIT ANYWHERE. Its assertions are functional only: the
//  operation finished (the app's own `performed` line), the heading went from / came back to the block table, no `routing-refused` line, and
//  the click that was timed was a MOUSE event.
//
//  THE THREE DOCUMENTS (invented text; the recipe of ComplexDocumentFixture in final finalTests/Support, ported through the primitives of
//  `Phase4bGenerator` in WriteQueuePhase4bTraceE2ETests.swift: same random generator, same seeds, same paragraph plan):
//    article  x1 chapters:  58,764 characters, 68 citation groups, 9 footnote marks, 18 headings   (the fixture of the committed Phase 4b tests)
//    book6    x6 chapters: 349,810 characters, 408 citation groups, 54 footnote marks, 103 headings
//    book12   x12 chapters: 699,139 characters, 816 citation groups, 108 footnote marks, 205 headings
//  Every chapter also holds 30 comment/task/reference marks, a block quote and Chinese text. The character counts are the unit-test
//  fixture's (the brief of this slice); `testFixtureSizes_matchTheUnitTestFixture` asserts that this port produces exactly them, and the other
//  counts above are worked out by hand from the recipe (per chapter: 1 H1, 5 H2, 10 H3 and 1 closing H2 = 17 headings, plus the one `# Notes`;
//  66 body citation groups plus the two in footnote definitions 3 and 7 = 68; 9 footnotes).
//
//  WHICH SECTION IS DELETED: the middle of the sidebar, at chapter level, with all of its sub-sections (Delete Section removes the subtree).
//    article: the H2 "1.3 Prices at the Market" (the article's chapter-level sections are its H2s; same section as the committed tests)
//    book6:   the H1 "Chapter 3: The Quiet Archive and Its Ledgers"   (one chapter of six: about a sixth of the document)
//    book12:  the H1 "Chapter 6: The Quiet Archive and Its Ledgers"   (one chapter of twelve: about a twelfth of the document)
//  The titles live in `Phase4bDelSize.deleteTitle`, the one place to change them.
//
//  THE TESTS (each method launches the app on a fresh copy of the fixture with the diagnostic log forced on; the three sizes share one body)
//    testDeleteTiming_{article,book6,book12}: right-click the section card, choose Delete Section, wait for the app's own `performed` line,
//      then let the app's 30 s trace window of late Notes / bibliography / footnote rebuild pushes finish and read them from the log.
//    testUndoRedoTiming_{article,book6,book12}: the same delete, then Cmd-Z, then Cmd-Shift-Z, each pressed once the previous operation's
//      trace window has closed, each timed on the app's clock; the Cmd-Z and Cmd-Shift-Z key presses are timed from their own
//      `[TYPING-TRACE] key` line (the app's record of the key event), so the figure includes the editor's routing of the key.
//    testFixtureSizes_matchTheUnitTestFixture, testTraceAnalyser_handWorkedExample: no app is launched. The first checks the generated
//      documents' sizes against the unit-test fixture; the second runs the analyser below on canned lines whose expected figures were worked
//      out by hand.
//
//  WHAT EACH TIMING TEST PRINTS (one plain report per method, to the test output with the prefix `[P4B-DEL]`, and attached as
//  `timing-table-<method>.txt`; the raw `[STRUCT-TRACE]` and `[TYPING-TRACE]` lines of the run are attached as `trace-lines-<method>.txt`):
//  a summary row per operation, then per operation: the headline splits (click or key to the Swift sequence start, start to `performed`,
//  the whole), every trace line in time order with its offset and the step's own duration, the spans (snapshot sub-steps, section sync,
//  annotation sync, refreshSections, each Notes / bibliography / footnote rebuild push with its offset and size), the rebuild pushes that landed
//  after `performed`, the main-thread stalls, and the typing pairing when there are typed keys. EVERY ROW starts with the fixture's tag,
//  `[<size> W<words> S<sections> C<citation groups> F<footnote marks> L<characters>]`, so a figure never stands alone.
//
//  THE ANALYSER'S RULES (implemented in `Phase4bDelAnalyser`, run on canned lines by `testTraceAnalyser_handWorkedExample`):
//   1. An operation begins at its `click-start` line (delete and duplicate), whose own `start` line follows within 10 s and is taken as the
//      same operation; an operation with no click line (undo, redo) begins at its `start` line. Zero of the table is the click event
//      (`click-start` line's t) or the `start` line's t, i.e. the zero of the app's own `+timeline=` column.
//   2. LATE LINES BELONG TO THE MOST RECENT OPERATION: every other trace line (spans, rebuild pushes, main-stall, typing lines) belongs to the
//      operation whose entry came last in the log, which is exactly how the app labels them ("the timeline is the most recent op's"). A line
//      whose label names another operation is counted and reported, never moved.
//   3. Undo and redo are timed from the editor's key line: the nearest `[TYPING-TRACE] key` line with code 6 (the Z key) that precedes the
//      operation's `start` line by at most 10 s is that operation's key press, and "key -> performed" is the user-visible time.
//   4. KEYSTROKE TO ECHO: each `editor=true` key is paired with the FIRST `[TYPING-TRACE] echo` at or after it (not "the latest key before each
//      echo", which hides the worst keystroke); a key with no later echo is reported as unpaired. The echo time is a lower bound on "on screen".
//   5. Offsets are computed from `t=` (the app's uptime clock, the clock `NSEvent.timestamp` uses), never from the test process's wall clock.
//      `main-stall` lines are stamped at the END of the stall: it began `<n>` ms earlier.
//
//  TYPING IS SKIPPED in this slice (the analyser supports it and the hand-worked test covers it). The only proven way to place a caret in the
//  editor is the accessibility-snapshot anchor lookup of WriteQueuePhase4bTraceE2ETests; its own notes record 12 to 14 s for that lookup plus the
//  caret click on the 58,764-character article in the VM, which would fill about half of the 30 s trace window this slice records, and the POC
//  runs on book-length documents made no content query at all. The e2e-verify skill advises against a blind normalized-offset click (it lands on
//  whatever block is under the point, and after a delete on a book that block is unknown). A typed burst would therefore not be robust here. The
//  `[TYPING-TRACE] key` lines of the test's own Cmd-Z / Cmd-Shift-Z presses are used for timing instead.
//
//  WAITS: every wait is a condition (a log line, a database row, the follower reaching the end of the app's own trace window). The one wait the
//  script owns is the trace window: the app writes timeline lines for 30 s after an operation starts (`StructuralTrace.timelineWindowMs`), so the
//  script waits until 30 s plus a 1.5 s margin after the operation's own click or start line (the line's stamp, on the VM's wall clock that the
//  app's log shares), then until no span is left open (a span's end line is written even after the window). Nothing reads the accessibility
//  tree between `performed` and the end of that window, and the block table is read only by the check right after `performed` (a poll of the
//  heading's row count that stops at the wanted value, normally at the first read).
//
//  VM ONLY: these run in the disposable VM through scripts/vmtest/vmtest, never on the host screen. Suggested runs (the timeout covers the load,
//  the bibliography generation and three 32 s trace windows):
//    scripts/vmtest/vmtest run --scope "final finalUITests/WriteQueuePhase4bDeleteE2ETests/testDeleteTiming_article" --timeout 900
//    scripts/vmtest/vmtest run --scope "final finalUITests/WriteQueuePhase4bDeleteE2ETests/testUndoRedoTiming_book6" --timeout 1500
//    scripts/vmtest/vmtest run --scope "final finalUITests/WriteQueuePhase4bDeleteE2ETests/testUndoRedoTiming_book12" --timeout 2400
//
//  This class reuses the document primitives and log types of WriteQueuePhase4bTraceE2ETests.swift (`Phase4bGenerator`, `Phase4bDoc`,
//  `Phase4bCounts`, `Phase4bLogLine`, `Phase4bLog`); it changes nothing in that file.
//

// swiftlint:disable file_length
import AppKit
import XCTest

// MARK: - The three documents

/// The three fixtures this class measures.
enum Phase4bDelSize: CaseIterable {
    case article
    case book6
    case book12

    /// Chapters of the generated document (the article is one chapter).
    var chapters: Int {
        switch self {
        case .article: return 1
        case .book6: return 6
        case .book12: return 12
        }
    }

    var identifier: String {
        switch self {
        case .article: return "article"
        case .book6: return "book6"
        case .book12: return "book12"
        }
    }

    var title: String {
        switch self {
        case .article: return "ARTICLE (x1)"
        case .book6: return "BOOK (x6)"
        case .book12: return "BOOK (x12)"
        }
    }

    /// The section deleted: chapter level, in the middle of the sidebar (see the file header).
    var deleteTitle: String {
        switch self {
        case .article: return "1.3 Prices at the Market"
        case .book6: return "Chapter 3: The Quiet Archive and Its Ledgers"
        case .book12: return "Chapter 6: The Quiet Archive and Its Ledgers"
        }
    }

    /// The characters (UTF-16 units) the unit-test fixture reports for this size (ComplexDocumentFixture's header; the brief of this slice).
    var expectedCharacters: Int {
        switch self {
        case .article: return 58_764
        case .book6: return 349_810
        case .book12: return 699_139
        }
    }

    /// Citation groups, footnote marks and headings, worked out by hand from the recipe (see the file header).
    var expectedCitationGroups: Int { chapters * 68 }
    var expectedFootnoteMarks: Int { chapters * 9 }
    var expectedHeadings: Int { chapters * 17 + 1 }

    /// Waits sized for the document (seconds). The run's own wall-clock budget keeps every attachment: the runner's hard cap kills the guest.
    var loadTimeout: TimeInterval {
        switch self {
        case .article: return 90
        case .book6: return 180
        case .book12: return 300
        }
    }

    var bibliographyTimeout: TimeInterval {
        switch self {
        case .article: return 180
        case .book6: return 300
        case .book12: return 480
        }
    }

    var operationTimeout: TimeInterval {
        switch self {
        case .article: return 90
        case .book6: return 180
        case .book12: return 300
        }
    }

    var budgetSeconds: TimeInterval {
        switch self {
        case .article: return 12 * 60
        case .book6: return 22 * 60
        case .book12: return 35 * 60
        }
    }

    /// How many 500-point scrolls the sidebar may need to bring the card into view.
    var sidebarScrollAttempts: Int { chapters == 1 ? 25 : 40 }
}

/// The multi-chapter documents: `Phase4bGenerator`'s primitives (words, citations, marks, paragraphs, the CSL library, the counters) arranged
/// the way ComplexDocumentFixture arranges them. For one chapter the text is byte for byte `Phase4bGenerator.make()`'s.
enum Phase4bDelGenerator {
    typealias Base = Phase4bGenerator

    // swiftlint:disable cyclomatic_complexity
    /// One chapter: its headings, the 14 anchor lines (chapter 1 only), 60 body paragraphs, the block quote and the nine footnote definitions
    /// numbered from `(chapter - 1) * 9 + 1`. A port of ComplexDocumentFixture's `chapterBody`, as long and as branchy as the original.
    static func chapterBody(
        chapter: Int, chapters: Int, wordsPerParagraph: Int, withAnchors: Bool
    ) -> (blocks: [String], definitions: [String]) {
        var rng = Base.Rng(state: 20_261_009)
        var formSchedule: [Int] = []
        for entry in Base.formCounts { formSchedule += Array(repeating: entry.form, count: entry.count) }
        for index in stride(from: formSchedule.count - 1, to: 0, by: -1) { formSchedule.swapAt(index, rng.pick(index + 1)) }

        let paragraphTotal = 60
        let footnoteOffset = (chapter - 1) * 9
        let title = chapters == 1 ? "The Quiet Archive: Notes on Ledgers and Lanterns" : "Chapter \(chapter): The Quiet Archive and Its Ledgers"
        var blocks: [String] = ["# \(title)"]
        if withAnchors {
            for number in 1...14 { blocks.append("Anchor\(String(format: "%02d", number)) line of the fixture document.") }
        }
        var paragraphIndex = 0
        func nextParagraph() -> String {
            let index = paragraphIndex
            paragraphIndex += 1
            var plan = Base.BodyPlan()
            plan.citationSlots = (66 * index / paragraphTotal)..<(66 * (index + 1) / paragraphTotal)
            plan.markSlots = (30 * index / paragraphTotal)..<(30 * (index + 1) / paragraphTotal)
            if index >= 4, (index - 4) % 6 == 0, (index - 4) / 6 < 9 { plan.footnote = footnoteOffset + (index - 4) / 6 + 1 }
            plan.bold = index % 3 == 0
            plan.italic = index % 4 == 1
            plan.cjkClauses = index % 2 == 0 ? (index % 5 == 0 ? 2 : 1) : 0
            let count = wordsPerParagraph + (index * 7) % 21 - 10
            return Base.paragraph(plan: plan, wordCount: count, formSchedule: formSchedule, rng: &rng)
        }
        blocks.append(nextParagraph())
        let sectionTitles = [
            "Ledgers and Their Keepers", "The Village Registers", "Prices at the Market", "Bridges and Boundaries", "Lanterns After Dark"
        ]
        for (sectionIndex, sectionTitle) in sectionTitles.enumerated() {
            blocks.append("## \(chapter).\(sectionIndex + 1) \(sectionTitle)")
            for _ in 0..<3 { blocks.append(nextParagraph()) }
            if sectionIndex == 2 {
                let quote = Base.sentences(wordCount: 55, rng: &rng).joined(separator: " ") + " " + Base.cjk[rng.pick(Base.cjk.count)]
                blocks.append("> " + quote)
            }
            for subIndex in 1...2 {
                let first = Base.words[rng.pick(Base.words.count)].capitalized
                let second = Base.words[rng.pick(Base.words.count)].capitalized
                blocks.append("### \(chapter).\(sectionIndex + 1).\(subIndex) \(first) and \(second)")
                for _ in 0..<4 { blocks.append(nextParagraph()) }
            }
        }
        blocks.append("## \(chapter).6 Conclusion")
        for _ in 0..<4 { blocks.append(nextParagraph()) }

        var definitions: [String] = []
        for number in 1...9 {
            var text = Base.sentences(wordCount: 38 + rng.pick(30), rng: &rng).joined(separator: " ")
            if number == 3 || number == 7 { text += " See " + Base.citationText(form: 2, slot: number * 3, rng: &rng) + "." }
            if number % 2 == 0 { text += " " + Base.cjk[rng.pick(Base.cjk.count)] }
            definitions.append("[^\(footnoteOffset + number)]: \(text)")
        }
        return (blocks, definitions)
    }
    // swiftlint:enable cyclomatic_complexity

    /// The seed: every chapter, then one `# Notes` section with all the footnote definitions; ends with one newline. No bibliography yet.
    static func build(chapters: Int, wordsPerParagraph: Int) -> String {
        var blocks: [String] = []
        var definitions: [String] = []
        for chapter in 1...chapters {
            let body = chapterBody(chapter: chapter, chapters: chapters, wordsPerParagraph: wordsPerParagraph, withAnchors: chapter == 1)
            blocks += body.blocks
            definitions += body.definitions
        }
        blocks.append("# Notes")
        blocks += definitions
        return blocks.joined(separator: "\n\n") + "\n"
    }

    static func make(chapters: Int) -> Phase4bDoc {
        let markdown = build(chapters: chapters, wordsPerParagraph: Base.tuned)
        return Phase4bDoc(markdown: markdown, cslJSON: Base.cslJSON(), counts: Base.count(markdown))
    }
}

// MARK: - Reading the trace: one line

/// One `[STRUCT-TRACE] t=<ms>ms +<n>ms <label> op=<id> <step>` line of the sequence family (`+<n>ms` counts from the entry of the Swift
/// sequence) or `[STRUCT-TRACE] t=<ms>ms +timeline=<n>ms <label> op=<id> <step>` line of the timeline family (`+timeline=<n>ms` counts from
/// the click for delete and duplicate, else from the sequence entry). The editor's own `[STRUCT-TRACE] finalize ...` lines have no `t=` and
/// are not parsed here (they stay in the raw attachment).
struct Phase4bDelTraceLine {
    enum Family { case sequence, timeline }

    let line: Phase4bLogLine
    /// The app's clock, milliseconds since system start.
    let t: Int
    let family: Family
    /// The line's own `+<n>` or `+timeline=<n>` figure.
    let since: Int
    let label: String
    let opId: String
    let step: String

    /// The line that begins an operation's Swift sequence: `start` (today's whole sequence, undo, redo) or `start (editor-first) ...` (the
    /// editor-first delete, which adds its own figures after the words in brackets).
    var isOpStart: Bool { family == .sequence && (step == "start" || step.hasPrefix("start (")) }

    private static let pattern = try? NSRegularExpression(pattern: #"\[STRUCT-TRACE\] t=(\d+)ms \+(timeline=)?(\d+)ms (\S+) op=(\S+) (.*)$"#)

    init?(_ line: Phase4bLogLine) {
        guard let regex = Self.pattern else { return nil }
        let text = line.text
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
            return String(text[swiftRange])
        }
        guard let tText = group(1), let tValue = Int(tText), let sinceText = group(3), let sinceValue = Int(sinceText),
              let labelText = group(4), let opText = group(5), let stepText = group(6) else { return nil }
        self.line = line
        self.t = tValue
        self.family = group(2) == nil ? .sequence : .timeline
        self.since = sinceValue
        self.label = labelText
        self.opId = opText
        self.step = stepText
    }
}

// MARK: - Reading the trace: typing lines

struct Phase4bDelTypingKey {
    let t: Int
    let code: Int
    let inEditor: Bool
}

struct Phase4bDelEcho {
    let t: Int
    /// How many real user edits this one echo covers (nil when the line carried no count).
    let edits: Int?
}

struct Phase4bDelReplaced {
    let t: Int
    let kind: String
    let block: String
}

/// A key paired with the first echo at or after it.
struct Phase4bDelKeyEcho {
    let key: Phase4bDelTypingKey
    let echo: Phase4bDelEcho?
    var latencyMs: Int? { echo.map { $0.t - key.t } }
}

enum Phase4bDelTypingParser {
    /// The keyCode of the Z key: the test's own Cmd-Z and Cmd-Shift-Z presses.
    static let zKeyCode = 6

    /// The integer that follows `marker` in `text`, or nil.
    static func intAfter(_ marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        let digits = text[range.upperBound...].prefix(while: { $0.isASCII && $0.isNumber })
        return Int(digits)
    }

    /// The run of non-blank characters that follows `marker` in `text`, or nil.
    static func word(after marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        let run = text[range.upperBound...].prefix(while: { !$0.isWhitespace })
        return run.isEmpty ? nil : String(run)
    }

    /// `[TYPING-TRACE] key t=<ms> code=<keyCode> editor=<true|false>`.
    static func key(_ text: String) -> Phase4bDelTypingKey? {
        guard text.contains("[TYPING-TRACE] key t="), let t = intAfter("key t=", in: text), let code = intAfter(" code=", in: text) else {
            return nil
        }
        return Phase4bDelTypingKey(t: t, code: code, inEditor: text.contains("editor=true"))
    }

    /// `[TYPING-TRACE] echo t=<ms> n=<edits>` (the `n=` part may be absent).
    static func echo(_ text: String) -> Phase4bDelEcho? {
        guard text.contains("[TYPING-TRACE] echo t="), let t = intAfter("echo t=", in: text) else { return nil }
        return Phase4bDelEcho(t: t, edits: intAfter(" n=", in: text))
    }

    /// `[TYPING-TRACE] rebuild-replaced-pending kind=<kind> block=<id> t=<ms>`.
    static func replaced(_ text: String) -> Phase4bDelReplaced? {
        guard text.contains("[TYPING-TRACE] rebuild-replaced-pending"), let kind = word(after: "kind=", in: text),
              let block = word(after: "block=", in: text), let t = intAfter(" t=", in: text) else { return nil }
        return Phase4bDelReplaced(t: t, kind: kind, block: block)
    }

    /// ANALYSER RULE 4: each key is paired with the FIRST echo at or after it. One echo can cover several keys (every edit made before the
    /// frame), so pairing "the latest key before each echo" would hide the worst keystroke.
    static func pair(keys: [Phase4bDelTypingKey], echoes: [Phase4bDelEcho]) -> [Phase4bDelKeyEcho] {
        let ordered = echoes.sorted { $0.t < $1.t }
        return keys.map { key in Phase4bDelKeyEcho(key: key, echo: ordered.first { $0.t >= key.t }) }
    }
}

// MARK: - Reading the trace: one operation

/// A timed step of the timeline family: `start <name> <detail>` and `end <name> took=<n>ms`.
struct Phase4bDelSpan {
    let name: String
    var startT: Int?
    var endT: Int?
    var tookMs: Int?
    var detail: String
}

/// A `main-stall <n>ms` line: stamped at the END of the stall.
struct Phase4bDelStall {
    let endT: Int
    let durationMs: Int
    var beganT: Int { endT - durationMs }
}

/// Everything the trace says about one structural operation: its entry lines and every later line up to the next operation's entry.
struct Phase4bDelOp {
    let kind: String
    var opId = "--------"
    var click: Phase4bDelTraceLine?
    var start: Phase4bDelTraceLine?
    var performed: Phase4bDelTraceLine?
    /// The test's own Cmd-Z / Cmd-Shift-Z key press (undo and redo only).
    var key: Phase4bDelTypingKey?
    /// Every Swift trace line of this operation, in log order (entry lines included).
    var lines: [Phase4bDelTraceLine] = []
    var spans: [Phase4bDelSpan] = []
    var stalls: [Phase4bDelStall] = []
    /// One-off timeline lines that are neither spans nor stalls (for example `refreshSections requested`).
    var oneOffs: [Phase4bDelTraceLine] = []
    var typedKeys: [Phase4bDelTypingKey] = []
    var echoes: [Phase4bDelEcho] = []
    var replacedPending: [Phase4bDelReplaced] = []
    /// Lines whose label names another operation (they stay where the "most recent op" rule put them).
    var labelMismatches = 0

    init(kind: String) { self.kind = kind }

    /// The zero of the table: the click event, else the sequence entry (the zero of the app's own `+timeline=` column).
    var zero: Int { click?.t ?? start?.t ?? lines.first?.t ?? 0 }
    /// The moment the user acted: the key press when the log has it, else `zero`.
    var userZero: Int { key?.t ?? zero }
    var clickType: String? { click.flatMap { Phase4bDelTypingParser.word(after: "type=", in: $0.step) } }
    var clickAgeMs: Int? { click.flatMap { Phase4bDelTypingParser.intAfter("age=", in: $0.step) } }
    var openSpanNames: [String] { spans.filter { $0.startT != nil && $0.endT == nil }.map(\.name) }
    var pushes: [Phase4bDelSpan] { spans.filter { $0.name.hasSuffix("-rebuild-push") } }

    mutating func absorb(_ trace: Phase4bDelTraceLine) {
        lines.append(trace)
        if opId == "--------", trace.opId != "--------", trace.label == kind { opId = trace.opId }
        if trace.label != kind { labelMismatches += 1 }
        switch trace.family {
        case .sequence:
            if trace.step == "performed", performed == nil, trace.label == kind { performed = trace }
        case .timeline:
            absorbTimeline(trace)
        }
    }

    private mutating func absorbTimeline(_ trace: Phase4bDelTraceLine) {
        if trace.step.hasPrefix("main-stall "), let duration = Phase4bDelTypingParser.intAfter("main-stall ", in: trace.step) {
            stalls.append(Phase4bDelStall(endT: trace.t, durationMs: duration))
            return
        }
        let parts = trace.step.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        let rest = parts.count > 2 ? parts[2] : ""
        if parts.count >= 2, parts[0] == "start" {
            spans.append(Phase4bDelSpan(name: parts[1], startT: trace.t, endT: nil, tookMs: nil, detail: rest))
        } else if parts.count >= 2, parts[0] == "end" {
            let took = Phase4bDelTypingParser.intAfter("took=", in: rest)
            if let open = spans.firstIndex(where: { $0.name == parts[1] && $0.endT == nil }) {
                spans[open].endT = trace.t
                spans[open].tookMs = took
            } else {
                spans.append(Phase4bDelSpan(name: parts[1], startT: nil, endT: trace.t, tookMs: took, detail: rest))
            }
        } else {
            oneOffs.append(trace)
        }
    }
}

// MARK: - Reading the trace: splitting a log into operations

/// ANALYSER RULES 1 to 3 (see the file header). Pure: lines in, operations out.
enum Phase4bDelAnalyser {
    /// Mirrors `StructuralTrace.pendingClickMaxAgeMs`: a click belongs to the op that begins within this many ms.
    static let clickToStartMaxMs = 10_000
    /// A Cmd-Z / Cmd-Shift-Z key line belongs to the undo or redo that starts within this many ms after it.
    static let keyToStartMaxMs = 10_000

    private struct State {
        var ops: [Phase4bDelOp] = []
        var pendingClick: Int?
        var looseKeys: [Phase4bDelTypingKey] = []

        mutating func claimKey(startT: Int) -> Phase4bDelTypingKey? {
            func qualifies(_ key: Phase4bDelTypingKey) -> Bool {
                key.code == Phase4bDelTypingParser.zKeyCode && key.t <= startT && startT - key.t <= Phase4bDelAnalyser.keyToStartMaxMs
            }
            if let last = ops.indices.last, let index = ops[last].typedKeys.lastIndex(where: qualifies) {
                return ops[last].typedKeys.remove(at: index)
            }
            if let index = looseKeys.lastIndex(where: qualifies) { return looseKeys.remove(at: index) }
            return nil
        }
    }

    static func analyse(lines: [Phase4bLogLine]) -> [Phase4bDelOp] {
        var state = State()
        for line in lines {
            if let trace = Phase4bDelTraceLine(line) {
                consume(trace, into: &state)
            } else if let key = Phase4bDelTypingParser.key(line.text) {
                if state.ops.isEmpty { state.looseKeys.append(key) } else { state.ops[state.ops.count - 1].typedKeys.append(key) }
            } else if let echo = Phase4bDelTypingParser.echo(line.text), !state.ops.isEmpty {
                state.ops[state.ops.count - 1].echoes.append(echo)
            } else if let replaced = Phase4bDelTypingParser.replaced(line.text), !state.ops.isEmpty {
                state.ops[state.ops.count - 1].replacedPending.append(replaced)
            }
        }
        return state.ops
    }

    private static func consume(_ trace: Phase4bDelTraceLine, into state: inout State) {
        if trace.family == .timeline, trace.step.hasPrefix("click-start") {
            var operation = Phase4bDelOp(kind: trace.label)
            operation.click = trace
            operation.lines.append(trace)
            state.ops.append(operation)
            state.pendingClick = state.ops.count - 1
            return
        }
        if trace.isOpStart {
            if let index = state.pendingClick, belongsToClick(state.ops[index], start: trace) {
                state.ops[index].start = trace
                state.ops[index].lines.append(trace)
            } else {
                var operation = Phase4bDelOp(kind: trace.label)
                operation.start = trace
                operation.lines.append(trace)
                if trace.label == "undo" || trace.label == "redo" { operation.key = state.claimKey(startT: trace.t) }
                state.ops.append(operation)
            }
            state.pendingClick = nil
            return
        }
        guard !state.ops.isEmpty else { return }  // before the first operation the family is silent by design
        state.ops[state.ops.count - 1].absorb(trace)
    }

    private static func belongsToClick(_ operation: Phase4bDelOp, start: Phase4bDelTraceLine) -> Bool {
        guard let click = operation.click else { return false }
        return operation.kind == start.label && operation.start == nil && start.t - click.t <= clickToStartMaxMs
    }
}

// MARK: - The report (plain text)

extension Phase4bDelOp {
    /// Trigger (click event, or the key press when the log has it) to the Swift sequence's own `start` line.
    var triggerToStartMs: Int? { start.map { $0.t - userZero } }
    /// The sequence's own `start` line to its `performed` line.
    var startToPerformedMs: Int? {
        guard let startLine = start, let doneLine = performed else { return nil }
        return doneLine.t - startLine.t
    }
    /// Trigger to `performed`: the whole operation as the user feels it (click for delete, key press for Cmd-Z / Cmd-Shift-Z).
    var triggerToPerformedMs: Int? { performed.map { $0.t - userZero } }
    var stallTotalMs: Int { stalls.reduce(0) { $0 + $1.durationMs } }
    var stallLongestMs: Int { stalls.map(\.durationMs).max() ?? 0 }
}

/// What the report prints beside every number: the fixture's tag and counts.
struct Phase4bDelContext {
    /// `[article W7634 S31 C68 F9 L58764]`: starts every row.
    let tag: String
    let legend: String
    let sizeTitle: String
    let deleteTitle: String
    let countsLine: String
}

enum Phase4bDelTable {
    static func ms(_ value: Int?) -> String { value.map { "\($0) ms" } ?? "n/a" }

    static func padRight(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    static func padLeft(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }

    /// The whole report: a header, a summary row per operation, then each operation's detail. Every row after the header lines starts with the tag.
    static func render(ops: [Phase4bDelOp], context: Phase4bDelContext) -> [String] {
        var out = [
            "TIMING REPORT: \(context.sizeTitle); \(context.countsLine); section under test: \"\(context.deleteTitle)\"",
            "LEGEND: \(context.legend). Every figure is milliseconds on the app's own clock unless a row says otherwise."
        ]
        guard !ops.isEmpty else {
            out.append("\(context.tag) NO structural operation in the trace (no click-start line and no sequence start line since the first trigger)")
            return out
        }
        out.append("\(context.tag) SUMMARY (trigger = the click event for a delete, the key press for Cmd-Z / Cmd-Shift-Z)")
        out += summaryRows(ops).map { "\(context.tag) \($0)" }
        for (index, operation) in ops.enumerated() {
            out.append("")
            out += detailRows(operation, number: index + 1).map { "\(context.tag) \($0)" }
        }
        return out
    }

    static func summaryRows(_ ops: [Phase4bDelOp]) -> [String] {
        var rows = ["    op | trigger | trigger->start | start->performed | trigger->performed | rebuild pushes | main stalls"]
        for (index, operation) in ops.enumerated() {
            let trigger = operation.click != nil ? "click \(operation.clickType ?? "?")" : (operation.key != nil ? "key press" : "sequence entry")
            let pushes = operation.pushes
            let pushTotal = pushes.reduce(0) { $0 + ($1.tookMs ?? 0) }
            let stalls = "\(operation.stalls.count) (total \(operation.stallTotalMs) ms, longest \(operation.stallLongestMs) ms)"
            let name = "\(index + 1) \(operation.kind) op=\(operation.opId)"
            let splits = "\(ms(operation.triggerToStartMs)) | \(ms(operation.startToPerformedMs)) | \(ms(operation.triggerToPerformedMs))"
            rows.append("    \(name) | \(trigger) | \(splits) | \(pushes.count) (took \(pushTotal) ms in all) | \(stalls)")
        }
        return rows
    }

    static func detailRows(_ operation: Phase4bDelOp, number: Int) -> [String] {
        var rows = ["OP \(number): \(operation.kind) op=\(operation.opId); zero of the offsets below = t \(operation.zero) ms on the app's clock"]
        rows += headlineRows(operation)
        rows += ["SEQUENCE STEPS (the controller's own step lines: how long each step took, from the previous sequence line)"]
        rows += sequenceRows(operation)
        rows += ["CHRONOLOGY (every Swift trace line of this operation in the app's time order; offset from zero, then the gap to the previous line)"]
        rows += chronologyRows(operation)
        rows += ["SPANS (start/end pairs of the timeline family)"] + spanRows(operation)
        rows += ["REBUILD PUSHES (Notes / bibliography / footnote: the document pushed into the editor)"] + pushRows(operation)
        rows += ["MAIN-THREAD STALLS (a 20 ms ping answered over 50 ms late; written for 10 s after the operation starts)"] + stallRows(operation)
        rows += ["TYPING"] + typingRows(operation)
        rows += noteRows(operation)
        return rows
    }

    static func headlineRows(_ operation: Phase4bDelOp) -> [String] {
        var rows: [String] = []
        if let click = operation.click {
            let type = operation.clickType ?? "n/a"
            let age = operation.clickAgeMs.map { "\($0) ms" } ?? "n/a"
            rows.append("    trigger: click event type=\(type), \(age) old when the action ran (its t is the zero of the offsets, t=\(click.t))")
        } else if let key = operation.key {
            rows.append("    trigger: key press (Z key, code \(key.code), editor=\(key.inEditor)) at t=\(key.t); the Swift sequence is entered "
                + "\(ms(operation.triggerToStartMs)) later")
        } else {
            rows.append("    trigger: none found (no click-start line, no key line); the offsets are from the Swift sequence entry")
        }
        rows.append("    trigger -> Swift sequence start: \(ms(operation.triggerToStartMs))")
        rows.append("    Swift sequence start -> performed: \(ms(operation.startToPerformedMs))")
        rows.append("    trigger -> performed (the whole operation): \(ms(operation.triggerToPerformedMs))")
        return rows
    }

    static func describe(_ trace: Phase4bDelTraceLine) -> String {
        guard trace.family == .timeline, trace.step.hasPrefix("main-stall "),
              let duration = Phase4bDelTypingParser.intAfter("main-stall ", in: trace.step) else { return trace.step }
        return "\(trace.step) (stamped at the END of the stall; it began \(duration) ms earlier)"
    }

    /// The sequence-family lines only, so each step's duration is the gap to the previous STEP, not to an interleaved span line.
    static func sequenceRows(_ operation: Phase4bDelOp) -> [String] {
        let steps = operation.lines.filter { $0.family == .sequence }
        guard !steps.isEmpty else { return ["    none"] }
        var rows = ["    step | offset from zero | the line's own +ms (from the sequence entry) | step took"]
        var previous: Int?
        for step in steps {
            rows.append("    \(step.step) | +\(step.t - operation.zero) ms | +\(step.since) ms | \(ms(previous.map { step.t - $0 }))")
            previous = step.t
        }
        return rows
    }

    static func chronologyRows(_ operation: Phase4bDelOp) -> [String] {
        let ordered = operation.lines.enumerated().sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
        var rows = ["    offset(ms)  gap(ms)  family  line"]
        var previous = ordered.first?.t ?? 0
        for trace in ordered {
            let isLate = operation.performed.map { trace.t > $0.t } ?? false
            let family = trace.family == .sequence ? "seq" : "tl"
            rows.append("    \(padLeft("+\(trace.t - operation.zero)", 10))  \(padLeft("\(trace.t - previous)", 8))  \(padRight(family, 6))  "
                + "\(describe(trace))\(isLate ? "  [after performed]" : "")")
            previous = trace.t
        }
        return rows
    }

    static func spanRows(_ operation: Phase4bDelOp) -> [String] {
        guard !operation.spans.isEmpty else { return ["    none in this operation's timeline"] }
        var rows = ["    name | started | took | ended | detail"]
        let ordered = operation.spans.sorted { ($0.startT ?? $0.endT ?? 0) < ($1.startT ?? $1.endT ?? 0) }
        for span in ordered {
            let started = span.startT.map { "+\($0 - operation.zero) ms" } ?? "n/a (start line missing)"
            let ended = span.endT.map { "+\($0 - operation.zero) ms" } ?? "STILL OPEN"
            rows.append("    \(span.name) | \(started) | \(ms(span.tookMs)) | \(ended) | \(span.detail.isEmpty ? "-" : span.detail)")
        }
        return rows
    }

    static func pushRows(_ operation: Phase4bDelOp) -> [String] {
        let pushes = operation.pushes
        guard !pushes.isEmpty else { return ["    none in this operation's 30 s trace window"] }
        var rows = ["    kind | pushed at | took | after performed by | document size"]
        for push in pushes {
            let started = push.startT ?? push.endT ?? operation.zero
            let after = operation.performed.map { "\(started - $0.t) ms" } ?? "n/a"
            let size = push.detail.isEmpty ? "n/a" : push.detail
            rows.append("    \(push.name) | +\(started - operation.zero) ms | \(ms(push.tookMs)) | \(after) | \(size)")
        }
        let late = pushes.filter { push in operation.performed.map { (push.startT ?? 0) > $0.t } ?? false }
        let tookInAll = pushes.reduce(0) { $0 + ($1.tookMs ?? 0) }
        rows.append("    \(pushes.count) push(es), \(late.count) of them started after performed, took \(tookInAll) ms in all")
        return rows
    }

    static func stallRows(_ operation: Phase4bDelOp) -> [String] {
        guard !operation.stalls.isEmpty else { return ["    none"] }
        var rows = ["    began at | ended at | lasted"]
        for stall in operation.stalls {
            rows.append("    +\(stall.beganT - operation.zero) ms | +\(stall.endT - operation.zero) ms | \(stall.durationMs) ms")
        }
        let before = operation.performed.map { done in operation.stalls.filter { $0.endT <= done.t }.count } ?? 0
        rows.append("    \(operation.stalls.count) stall(s), \(operation.stallTotalMs) ms in all, longest \(operation.stallLongestMs) ms; "
            + "\(before) ended before performed")
        return rows
    }

    static func typingRows(_ operation: Phase4bDelOp) -> [String] {
        let typed = operation.typedKeys.filter { $0.inEditor && $0.code != Phase4bDelTypingParser.zKeyCode }
        var rows: [String] = []
        if typed.isEmpty {
            rows.append("    no typed key in this operation's lines (typing is not part of this slice; see the file header)")
        } else {
            rows.append("    key t | code | paired echo t | key -> echo   (each key is paired with the FIRST echo at or after it)")
            let pairs = Phase4bDelTypingParser.pair(keys: typed, echoes: operation.echoes)
            for pair in pairs {
                rows.append("    \(pair.key.t) | \(pair.key.code) | \(pair.echo.map { String($0.t) } ?? "none") | \(ms(pair.latencyMs))")
            }
            let latencies = pairs.compactMap(\.latencyMs).sorted()
            let median = latencies.isEmpty ? nil : latencies[latencies.count / 2]
            rows.append("    \(typed.count) key(s), \(latencies.count) paired, \(typed.count - latencies.count) with no later echo; "
                + "longest \(ms(latencies.last)), median \(ms(median)) (the element at index count/2 of the ascending list)")
        }
        rows.append("    echo lines: \(operation.echoes.count) (edits covered: \(operation.echoes.reduce(0) { $0 + ($1.edits ?? 0) }))")
        for replaced in operation.replacedPending {
            let offset = replaced.t - operation.zero
            rows.append("    rebuild-replaced-pending kind=\(replaced.kind) block=\(replaced.block) at t=\(replaced.t) (+\(offset) ms)")
        }
        let strayChords = operation.typedKeys.filter { $0.code == Phase4bDelTypingParser.zKeyCode }
        if !strayChords.isEmpty {
            rows.append("    \(strayChords.count) Z-key line(s) that started no undo or redo (a chord the app did not act on)")
        }
        return rows
    }

    static func noteRows(_ operation: Phase4bDelOp) -> [String] {
        var rows = ["NOTES"]
        for line in operation.oneOffs { rows.append("    one-off line at +\(line.t - operation.zero) ms: \(line.step)") }
        rows.append("    lines whose label names another operation (kept where the most-recent-op rule put them): \(operation.labelMismatches)")
        let stillOpen = operation.openSpanNames
        rows.append("    spans still open at the end of the log: \(stillOpen.isEmpty ? "none" : stillOpen.joined(separator: ", "))")
        if let start = operation.start, let click = operation.click {
            let delta = start.t - click.t
            rows.append("    the click's own t and the sequence start differ by \(delta) ms (the Task hop and the entry checks)")
        }
        return rows
    }
}

// MARK: - Following the app's log

/// Follows the app's `diagnostic.log` from the moment it is created, reading only the bytes written since the last `poll()`, so a poll every
/// 100 ms stays cheap on a long run (`Phase4bLog.read` re-reads and re-splits every rotation file each time, and the book-length documents write
/// megabytes). The log rotates at 2 MB (`DiagnosticLogFile`): when the file is found shorter than the last offset it was rotated, so the rest
/// of the old file (now `diagnostic.log.1`) is read before the new file is read from its start; no line written between two polls is lost.
/// Reads the log file and nothing else.
final class Phase4bDelLogTail {
    private var path: String?
    private var offset: UInt64 = 0
    /// Bytes of a last line the app has not finished writing yet.
    private var unfinished = Data()
    private var stamp = ""
    private(set) var lines: [Phase4bLogLine] = []
    /// How many times the file was found rotated since this tail began.
    private(set) var rotationsSeen = 0
    /// When the last new line arrived.
    private(set) var lastIngest = Date()

    init() {
        path = Self.currentLogPath()
        if let path, let size = Self.size(ofFileAt: path) { offset = size }
    }

    private static func currentLogPath() -> String? {
        UnifiedUndoE2ETests.diagnosticLogCandidateURLs()
            .first { $0.lastPathComponent == "diagnostic.log" && FileManager.default.fileExists(atPath: $0.path) }?.path
    }

    private static func size(ofFileAt path: String) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path), let size = attributes[.size] as? NSNumber else { return nil }
        return size.uint64Value
    }

    private static func bytes(ofFileAt path: String, from start: UInt64) -> Data {
        guard let handle = FileHandle(forReadingAtPath: path) else { return Data() }
        defer { try? handle.close() }
        try? handle.seek(toOffset: start)
        return handle.readDataToEndOfFile()
    }

    func poll() {
        if path == nil { path = Self.currentLogPath() }
        guard let path, let size = Self.size(ofFileAt: path) else { return }
        if size < offset {
            rotationsSeen += 1
            consume(Self.bytes(ofFileAt: path + ".1", from: offset))
            unfinished = Data()
            offset = 0
        } else if size == offset {
            return
        }
        let data = Self.bytes(ofFileAt: path, from: offset)
        offset += UInt64(data.count)
        consume(data)
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        var bytes = unfinished
        bytes.append(data)
        guard let lastNewline = bytes.lastIndex(of: UInt8(ascii: "\n")) else { unfinished = bytes; return }
        unfinished = Data(bytes[bytes.index(after: lastNewline)...])
        let text = String(bytes: bytes[...lastNewline], encoding: .utf8) ?? ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let head = Array(raw.utf8.prefix(24))
            if head.count == 24, head[4] == UInt8(ascii: "-"), head[10] == UInt8(ascii: "T") { stamp = String(raw.prefix(24)) }
            lines.append(Phase4bLogLine(stamp: stamp, text: String(raw)))
        }
        lastIngest = Date()
    }

    /// The index of the first line at or after `start` whose text contains `needle`.
    func indexOfFirstLine(containing needle: String, from start: Int = 0) -> Int? {
        guard start < lines.count else { return nil }
        return (start..<lines.count).first { lines[$0].text.contains(needle) }
    }
}

// MARK: - What a wait found

/// What `waitForOp` saw between a trigger and the end of the wait.
struct Phase4bDelOutcome {
    var performed: Phase4bDelTraceLine?
    var startSeen = false
    /// A Z-key `[TYPING-TRACE] key` line: the key reached the app.
    var keySeen = false
    var failure: Phase4bLogLine?
    var refusal: Phase4bLogLine?
    var noStart = false
    var timedOut = false

    var description: String {
        if let performed { return "PERFORMED (\(performed.line.text.suffix(100)))" }
        if let refusal { return "REFUSED BY THE EDITOR, no structural operation started (\(refusal.text.suffix(160)))" }
        if let failure { return "FAILED OR REFUSED BY THE CONTROLLER (\(failure.text.suffix(160)))" }
        if noStart {
            if keySeen { return "THE KEY REACHED THE APP but no `start` line followed" }
            return "NO `start` LINE and no Z-key line: the click or key did not reach the app"
        }
        return timedOut ? "STARTED BUT NOT FINISHED within the wait" : "unknown"
    }
}

/// A finished operation: where its lines begin in the tail, and its `performed` line.
struct Phase4bDelRun {
    let label: String
    let fromIndex: Int
    let performed: Phase4bDelTraceLine
}

// MARK: - The test class

/// The shared harness of this slice's two test classes (`WriteQueuePhase4bDeleteE2ETests`, the timing class below, and
/// `WriteQueuePhase4bDeleteFlowE2ETests` in WriteQueuePhase4bDeleteFlowE2ETests.swift, the behaviour class): the launch, the seeding, the
/// app-log follower, the sidebar driving and the evidence writer. It holds NO test method (XCTest finds nothing to run in it); a class
/// that inherits from it gets these helpers and none of the other class's tests, which a plain subclass of the timing class would not give.
///
/// Phase 7 (2026-11-11): the base type is named through an alias on purpose. `vmtest run --suite full` lists every test class it finds
/// by its declaration (a class declared directly on the framework's test base type) and fails the whole run with "class missing from
/// run" for one that runs no test; this harness runs none, so a plain declaration made every full run end `fail` by itself, even with
/// every test green. Through the alias the tool does not list it; its subclasses (declared on the harness) were never listed either.
typealias Phase4bDelHarnessBase = XCTestCase

class Phase4bDelHarness: Phase4bDelHarnessBase {
    var app: XCUIApplication!
    var size = Phase4bDelSize.article
    var methodName = ""
    var doc: Phase4bDoc?
    var startedAt = Date()
    var tail = Phase4bDelLogTail()
    var summaryLines: [String] = []
    var evidenceWritten = false
    /// Index into `tail.lines` of the first line written after the first trigger (the click of the delete); the report starts there.
    var firstTriggerIndex: Int?
    /// The section-table row count once the document has loaded (the sections beside every number).
    var sectionsInDatabase = -1
    /// Seconds `launchScenario` waited for the generated bibliography (nil: it did not appear within the size's wait). Phase 7: read by
    /// `WriteQueuePhase7ZoteroLateE2ETests`.
    var bibliographyReadySeconds: Double?
    /// Where `placeCaretAtAnchorEnd` clicked, relative to the editor area's top-left corner (for `clickBackIntoAnchor`).
    var caretOffset: CGVector?
    /// Index into `tail.lines` where the scenario's own window begins (set after the load by the behaviour tests). When set, `writeEvidence`
    /// also attaches the app's diagnostic log for the whole window since then, every category except the high-volume polling ones.
    var evidenceLogStart: Int?
    /// The exact lines of every row difference a behaviour test found (row, offset, characters around it), attached as
    /// `row-differences-<method>.txt`.
    var rowDifferenceLog: [String] = []
    /// Round 13d: the `sample` runs of `testDeleteSpeedOnly_book12`, by delete label: started after a delete's trigger, finished and attached
    /// once its trace window has closed (`Phase4bMainThreadSample`).
    var mainThreadSamples: [String: Phase4bMainThreadSample] = [:]

    /// The app writes timeline lines for 30 s after an operation starts (`StructuralTrace.timelineWindowMs`).
    static let traceWindowSeconds: TimeInterval = 30
    /// Added to the window before the script reads the late lines.
    static let traceWindowGraceSeconds: TimeInterval = 1.5
    /// The event types of a mouse click (`StructuralTrace.eventTypeName`).
    static let mouseEventTypes = ["leftMouseDown", "leftMouseUp", "rightMouseDown", "rightMouseUp", "otherMouseDown", "otherMouseUp"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.targetApp()
        app.terminate()
        // Fast typing into the WKWebView editor: the inline predictive-text feature can swallow keystrokes (e2e-verify skill).
        app.launchArguments += ["-NSAutomaticInlinePredictionEnabled", "NO"]
        // The `[STRUCT-TRACE]` and `[TYPING-TRACE]` lines reach diagnostic.log only with diagnostics on; the environment variable bypasses the
        // UI-test defaults wipe and is what switches the app's `.undo` log category on (StructuralTrace.isOn).
        app.launchArguments += ["-com.kerim.final-final.diagnosticsLoggingEnabled", "YES"]
        app.launchEnvironment["FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING"] = "1"
        try TestFixtureHelper.setupFixture(from: self)
    }

    override func tearDownWithError() throws {
        writeEvidence()
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }
}

/// Slice 0 of Phase 4b part 2: Delete Section, Cmd-Z and Cmd-Shift-Z timed on the app's own clock, on the article and two book-length
/// documents. See the file header. The tests are in the extensions at the end of this file; the helpers are `Phase4bDelHarness`'s.
final class WriteQueuePhase4bDeleteE2ETests: Phase4bDelHarness {}

// MARK: - Notes, results and assertions

extension Phase4bDelHarness {
    static func seconds(_ value: TimeInterval) -> String { String(format: "%.2f", value) }
    static func yesNo(_ flag: Bool) -> String { flag ? "YES" : "NO" }

    func capped(_ timeout: TimeInterval) -> TimeInterval {
        max(5, min(timeout, size.budgetSeconds - Date().timeIntervalSince(startedAt)))
    }

    /// Every note starts with the fixture's tag, so a figure never stands alone.
    func note(_ line: String) {
        let tagged = "\(fixtureTag) \(line)"
        summaryLines.append(tagged)
        print("[P4B-DEL] \(methodName) \(tagged)")
        fflush(stdout)
    }

    func result(_ line: String) { note("RESULT \(line)") }

    func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        note("HARNESS FAILURE: \(message)")
        XCTFail("HARNESS: \(message)", file: file, line: line)
    }

    /// A functional assertion (never a time limit): noted, and a failure carries the fixture's tag.
    func assertCheck(_ holds: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        note("\(holds ? "CHECK PASSED" : "CHECK FAILED"): \(message)")
        if !holds { XCTFail("\(fixtureTag) \(message)", file: file, line: line) }
    }

    func attachText(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// `[article W7634 S31 C68 F9 L58764]`: size, words, sections (section-table rows once loaded, "?" before), citation groups, footnote marks,
    /// characters.
    var fixtureTag: String {
        guard let counts = doc?.counts else { return "[\(size.identifier)]" }
        let sections = sectionsInDatabase >= 0 ? String(sectionsInDatabase) : "?"
        return "[\(size.identifier) W\(counts.words) S\(sections) C\(counts.citationGroups) F\(counts.footnoteMarks) L\(counts.characters)]"
    }

    var reportContext: Phase4bDelContext {
        let counts = doc?.counts
        let sections = sectionsInDatabase >= 0 ? "\(sectionsInDatabase) section-table rows after the load" : "section count not read"
        return Phase4bDelContext(
            tag: fixtureTag,
            legend: "W = words (whitespace-separated, in the seed), S = sections (section-table rows after the load), C = citation groups, "
                + "F = footnote marks, L = characters (UTF-16 units)",
            sizeTitle: size.title,
            deleteTitle: size.deleteTitle,
            countsLine: (counts?.reportLine ?? "counts n/a") + ", " + sections)
    }

    func begin(method: String, size: Phase4bDelSize) {
        methodName = method.replacingOccurrences(of: "()", with: "")
        self.size = size
        startedAt = Date()
        let generated = Phase4bDelGenerator.make(chapters: size.chapters)
        doc = generated
        note("METHOD \(methodName) started \(WriteQueuePhase4bTraceE2ETests.stamp(startedAt)) (UTC)")
        note("FIXTURE \(size.title): \(generated.counts.reportLine)")
        note("FIXTURE SIZE: \(generated.counts.characters) characters generated, \(size.expectedCharacters) in the unit-test fixture "
            + "(same size: \(Self.yesNo(generated.counts.characters == size.expectedCharacters)))")
    }
}

// MARK: - Seeding, launch and readiness

extension Phase4bDelHarness {
    func dbText(_ sql: String) -> String {
        FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func dbInt(_ sql: String) -> Int? { Int(dbText(sql)) }

    /// The heading rows whose text contains `title`, ANCHORED to the heading marker (`# <title>`): a number-prefixed subsection title such as
    /// "1.2.2 Lantern and Signal" is also a substring of the same title in chapters 10 to 12 ("### 11.2.2 Lantern and Signal": every chapter
    /// repeats the subsection words), which made the count 2 on the twelve-chapter book and a wait for 1 never end. Only stricter than the
    /// plain substring it replaces; a title that is a prefix of a longer heading ("... copy") still counts, as the duplicate checks rely on.
    func headingRows(_ title: String) -> Int {
        dbInt("SELECT count(*) FROM block WHERE blockType = 'heading' AND instr(markdownFragment, '# \(FixtureDatabase.escape(title))') > 0;") ?? -1
    }

    func waitForHeadingRows(_ title: String, equalTo wanted: Int, timeout: TimeInterval) -> Int {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var rows = headingRows(title)
        while rows != wanted, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            rows = headingRows(title)
        }
        return rows
    }

    /// Seeds `content.markdown` and clears `block` by feeding the SQL to the sqlite3 CLI through a file, not through the command line: a
    /// 700,000-character document in one argument comes close to the 1 MB limit on the arguments and environment together
    /// (`FixtureDatabase.seedMarkdown` passes the SQL as an argument; the book-length POC runs used this file form). Reads the seed back.
    func seedViaFile(_ markdown: String) -> Bool {
        let databasePath = TestFixtureHelper.fixturePath + "/content.sqlite"
        let sqlPath = NSTemporaryDirectory() + "ff-p4b-del-seed-\(UUID().uuidString).sql"
        let logPath = NSTemporaryDirectory() + "ff-p4b-del-seed-\(UUID().uuidString).log"
        let sql = "DELETE FROM block; UPDATE content SET markdown = '\(FixtureDatabase.escape(markdown))';\n"
        do {
            try sql.write(toFile: sqlPath, atomically: true, encoding: .utf8)
            try "".write(toFile: logPath, atomically: true, encoding: .utf8)
        } catch {
            fail("cannot write the seed SQL file \(sqlPath) or the log file \(logPath): \(error)")
            return false
        }
        guard let log = FileHandle(forWritingAtPath: logPath), let input = FileHandle(forReadingAtPath: sqlPath) else {
            fail("cannot open the seed SQL file \(sqlPath) or the log file \(logPath)")
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databasePath]
        process.standardInput = input
        process.standardOutput = log
        process.standardError = log
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            fail("sqlite3 failed to run for the seed (database \(databasePath), SQL \(sqlPath)): \(error)")
            return false
        }
        try? log.close()
        try? input.close()
        let said = (try? String(contentsOfFile: logPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "(log unreadable)"
        guard process.terminationStatus == 0 else {
            fail("sqlite3 exited with \(process.terminationStatus) while seeding \(databasePath) (\(sql.utf8.count) bytes of SQL); it said: \(said)")
            return false
        }
        guard dbInt("SELECT length(markdown) FROM content;") == markdown.unicodeScalars.count, dbInt("SELECT count(*) FROM block;") == 0 else {
            fail("the seeded markdown does not read back as written (database \(databasePath))")
            return false
        }
        return true
    }

    /// The line the CodeMirror coordinator logs right after it calls `onWebViewReady` (the same synchronous step, `webView(_:didFinish:)` or
    /// `handlePreloadedView`): by the time it is in the log, the app's `structuralUndoController.activeWebView` is the Markdown page. Only the
    /// stable prefix is matched (the line ends with the content length).
    static let markdownPageReadyLogLine = "[CodeMirrorEditor] batchInitialize: setting lastPushedContent"

    /// Waits until the new Markdown (CodeMirror) page has finished loading, reading the app's log from `index` (take it BEFORE the toggle
    /// keystroke, so a line written right after the keystroke cannot be missed). Reports a failure and returns false on a timeout.
    ///
    /// WHY THE BADGE ALONE IS NOT ENOUGH: the status-bar badge flips with `editorMode`, which is set the moment the toggle is handled, BEFORE
    /// the Markdown page exists. Until that page's `onWebViewReady`, `structuralUndoController.activeWebView` still points at the old Rich Text
    /// page. Since Phase 5 job A5 (t-633df056) the app HOLDS a section command pressed in that gap until the page is ready (so nothing is
    /// measured on the wrong path any more), but a test that waits only for the badge would still time the page load as part of its command,
    /// and a test of the held case must know the page was not there yet. On a busy host the gap is seconds long. Every test wait for the
    /// Markdown mode that is followed by a structural command goes through this helper (board t-55b63c87 listed the six that did not).
    func waitForMarkdownPageReady(from index: Int) -> Bool {
        guard waitForLog(containing: Self.markdownPageReadyLogLine, from: index, timeout: capped(size.operationTimeout * 2)) else {
            fail("the Markdown page never finished loading after the switch (no \"\(Self.markdownPageReadyLogLine)\" line in the app's log)")
            return false
        }
        return true
    }

    /// As `waitForLog(containing:timeout:)`, but only lines at or after log index `index` count (a relaunch must not be answered by a line the
    /// first run wrote: the follower keeps every line of the whole test).
    func waitForLog(containing needle: String, from index: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            tail.poll()
            if tail.indexOfFirstLine(containing: needle, from: index) != nil { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return false
    }

    func waitForLog(containing needle: String, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            tail.poll()
            if tail.indexOfFirstLine(containing: needle) != nil { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return false
    }

    /// Waits (up to `cap`) until the app has written no new log line for `quiet` seconds; the answer is recorded, never asserted.
    func waitForLogQuiet(quiet: TimeInterval, cap: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: cap)
        repeat {
            tail.poll()
            if Date().timeIntervalSince(tail.lastIngest) >= quiet { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return false
    }

    /// Polls the project database until the generated bibliography section exists and has stopped changing.
    func waitForBibliography(timeout: TimeInterval) -> Double? {
        let began = Date()
        var last = ""
        while Date().timeIntervalSince(began) < timeout {
            let text = dbText("SELECT markdownContent FROM section WHERE isBibliography = 1;")
            if text.count > 200, text == last { return Date().timeIntervalSince(began) }
            last = text
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 3))
        }
        return nil
    }

    func waitForBlocksToSettle() -> Int {
        var last = -1
        var steady = 0
        let deadline = Date(timeIntervalSinceNow: capped(90))
        while Date() < deadline {
            let count = dbInt("SELECT count(*) FROM block;") ?? -1
            steady = count == last ? steady + 1 : 0
            last = count
            if steady >= 3 { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
        }
        return last
    }

    /// Seed, launch, and wait until the document is loaded, its citations resolved, its bibliography generated, the block table steady and the
    /// app's log quiet. No content query is made (one `staticTexts` walk of a book-length editor can take longer than the whole budget), so
    /// no caret is placed and nothing is typed. Returns false after a reported harness failure.
    @discardableResult
    func launchScenario() -> Bool {
        guard let doc, seedViaFile(doc.markdown) else { return false }
        tail = Phase4bDelLogTail()
        let libraryPath = NSTemporaryDirectory() + "ff-p4b-del-csl-\(UUID().uuidString).json"
        do {
            try doc.cslJSON.write(toFile: libraryPath, atomically: true, encoding: .utf8)
        } catch {
            fail("cannot write the CSL library file \(libraryPath): \(error)")
            return false
        }
        app.launchEnvironment["FF_UI_TESTING_ZOTERO_MOCK"] = "1"
        app.launchEnvironment["FF_UI_TESTING_ZOTERO_MOCK_LIBRARY_FILE"] = libraryPath
        let baseArguments = app.launchArguments
        let launched = Date()
        app.launchArguments = baseArguments + ["-NSTreatUnknownArgumentsAsOpen", "NO", "-ApplePersistenceIgnoreState", "YES"]
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        if !app.editorArea.waitForExistence(timeout: 15) {
            note("no window appeared with -ApplePersistenceIgnoreState YES; relaunching without it")
            app.launchArguments = baseArguments
            app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        }
        guard app.editorArea.waitForExistence(timeout: capped(30)) else { fail("the editor area never appeared after the launch"); return false }
        guard app.staticTexts["status-bar-word-count"].waitForValueNot("== '0 words'", timeout: capped(size.loadTimeout)) else {
            fail("the status bar still shows 0 words \(Int(size.loadTimeout)) s after the launch (the seeded document did not load)")
            return false
        }
        let loadSeconds = Date().timeIntervalSince(launched)
        let gate = waitForLog(containing: "editor-ready gate satisfied", timeout: capped(size.loadTimeout))
        let bibliography = waitForBibliography(timeout: capped(size.bibliographyTimeout))
        bibliographyReadySeconds = bibliography
        let blocks = waitForBlocksToSettle()
        sectionsInDatabase = dbInt("SELECT count(*) FROM section;") ?? -1
        let quiet = waitForLogQuiet(quiet: 3, cap: capped(60))
        let bibliographyText: String
        if let bibliography {
            bibliographyText = "ready after \(Self.seconds(bibliography)) s"
        } else {
            bibliographyText = "NOT generated within \(Int(size.bibliographyTimeout)) s (the fixture is degraded)"
        }
        let elapsed = Self.seconds(Date().timeIntervalSince(startedAt))
        var ready = "READY: word count showed after \(Self.seconds(loadSeconds)) s; "
        ready += "\"editor-ready gate satisfied\" line: \(Self.yesNo(gate)); generated bibliography: \(bibliographyText); "
        ready += "block rows once steady: \(blocks); section rows: \(sectionsInDatabase); app log quiet for 3 s: \(Self.yesNo(quiet)); "
        ready += "seconds since the test began: \(elapsed)"
        note(ready)
        return true
    }
}

// MARK: - Driving the app

extension Phase4bDelHarness {
    /// Scrolls the Outline sidebar until the card is inside its scroll view (a card can exist in the tree while clipped: e2e-verify). With
    /// `failIfMissing` false a card that cannot be brought into view returns nil without failing the test.
    func bringSidebarCardIntoView(_ title: String, failIfMissing: Bool = true) -> XCUIElement? {
        let scroll = app.groups["outline-sidebar"].scrollViews.firstMatch
        guard scroll.waitForExistence(timeout: capped(30)) else {
            if failIfMissing { fail("the outline sidebar's scroll view never appeared") }
            return nil
        }
        let card = scroll.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", title, title)).firstMatch
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
                note("SIDEBAR card \"\(title)\" in view after \(attempt - 1) scroll(s): card y \(frame.minY), view y \(band.minY)-\(band.maxY)")
                return card
            }
            let wanted = max(-1200, min(1200, frame.midY - band.midY))
            scroll.scroll(byDeltaX: 0, deltaY: -wanted * direction)
            app.waitForStableFrame(card)
            // The card should have moved opposite to `wanted`; if it moved the other way the scroll sign is the other one.
            if card.exists, (card.frame.midY - frame.midY) * (-wanted) < 0 { direction = -direction }
        }
        let detail = "the sidebar card \"\(title)\" could not be scrolled into view (scroll view \(scroll.frame), card exists: \(card.exists))"
        if failIfMissing { fail(detail) } else { note(detail) }
        return nil
    }

    /// The paragraph the typed text goes after: "Anchor05 line of the fixture document." One plain line of the first chapter (the article's
    /// opening), on screen right after the load and outside every section the tests delete or zoom into.
    static let anchorPrefix = "Anchor05"

    /// Clicks into the end of the anchor paragraph and confirms, through the status bar's selection count, that the caret is there
    /// (`placeCaretByClicking`'s own probe). Fails the test (and returns false) when it cannot be confirmed: typing into an unknown
    /// place would make every later assertion mean nothing.
    /// `paragraph` (default the anchor) names another plain one-line paragraph near the top of the document to put the caret at the end of
    /// (the rapid-undo scenarios' "Join01 line of the fixture document."); it must be unique and begin the leaf's text.
    /// `exactLine` (default nil: today's behaviour) is that paragraph's complete one-run text, found by one exact-value query before the
    /// index walk (speed only: the walk reached "Inner01" in 1000-2000 s on the twelve-chapter book).
    @discardableResult
    func placeCaretAtAnchorEnd(paragraph prefix: String = Phase4bDelHarness.anchorPrefix, exactLine: String? = nil) -> Bool {
        let placed = app.placeCaretByClicking(
            paragraphStartingWith: prefix, atEnd: true, runProbe: true, findTimeout: capped(90), exactLine: exactLine)
        note("CARET at the end of the \"\(prefix)\" paragraph: probe \(placed.probe) after \(placed.attempts.count) click attempt(s)")
        guard placed.confirmed else {
            fail("the caret could not be placed at the end of the \"\(prefix)\" paragraph (probe: \(placed.probe); \(placed.attempts))")
            return false
        }
        // Remember where the click went ("(x, y)" in screen points, from the helper's own evidence), relative to the editor area.
        let numbers = ((placed.attempts.last?["clickPoint"] as? String) ?? "")
            .split(whereSeparator: { !"0123456789.-".contains($0) }).compactMap { Double($0) }
        if numbers.count == 2 {
            let editor = app.editorArea.frame
            caretOffset = CGVector(dx: numbers[0] - editor.minX, dy: numbers[1] - editor.minY)
        }
        return true
    }

    /// Reports every failure collected in `soft` together, in one assertion (`Phase4bFlowSoftChecks`, in the behaviour tests' file). The
    /// numbered failures also go to the notes, so a run shows all of them whichever the assertion's own message cuts off.
    func assertSoft(_ soft: Phase4bFlowSoftChecks, _ what: String) {
        for failure in soft.failures { note("SOFT CHECK FAILED: \(failure)") }
        let listed = soft.failures.enumerated().map { "(\($0.offset + 1)) \($0.element)" }.joined(separator: " | ")
        assertCheck(soft.failures.isEmpty, "\(what): \(soft.failures.count) check(s) failed together: \(listed)")
    }

    /// A person's click back into the line they were typing in, after a command that rebuilds or moves the editor (a sidebar command, an
    /// undo, a redo, a mode switch, a zoom): the PARAGRAPH is the target, not a screen point. A remembered point is wrong as soon as the
    /// document is laid out at a slightly different scroll offset after the rebuild (one run clicked a point that then sat on the NEXT
    /// paragraph, and the sentence was typed at the end of "Anchor06"). So: look for the exact-value text leaf "Anchor05 line of the fixture
    /// document." (`==` only: a heading's value is a number, so CONTAINS or BEGINSWITH on it throws; about 1.5 s on a book), let its frame
    /// settle, click at the right end of it, then Cmd-Right to the end of the line. Only when the leaf is not found within a few seconds does
    /// it fall back to the remembered point. The result line says which was used. Returns true when the paragraph itself was the target.
    /// `paragraph` (default "Anchor05 line of the fixture document.") is the exact text of the one-run leaf to click back into; the rapid-undo
    /// scenarios pass "Join01 line of the fixture document." (the caret there was placed by `placeCaretAtAnchorEnd(paragraph:)`).
    @discardableResult
    func clickBackIntoAnchor(paragraph: String? = nil) -> Bool {
        let plainLine = paragraph ?? (Self.anchorPrefix + " line of the fixture document.")
        let name = String(plainLine.prefix { !$0.isWhitespace })
        // e2e-lint: allow statictext-firstmatch -- scoped to `editor-area` (never the sidebar's mirror) and an exact `==` on the value.
        let leaf = app.editorArea.staticTexts.matching(NSPredicate(format: "value == %@", plainLine)).firstMatch
        if leaf.waitForExistence(timeout: 5) {
            app.waitForStableFrame(leaf)
            if leaf.exists {
                let frame = leaf.frame
                leaf.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()
                app.typeKey(.rightArrow, modifierFlags: .command)
                note("CLICK BACK: clicked the \"\(name)\" paragraph itself, at the right end of its leaf (\(Self.describeFrame(frame)))")
                return true
            }
        }
        guard let offset = caretOffset else {
            note("CLICK BACK: the \"\(name)\" leaf was not found and no point was remembered: nothing was clicked")
            return false
        }
        app.editorArea.coordinate(withNormalizedOffset: .zero).withOffset(offset).click()
        app.typeKey(.rightArrow, modifierFlags: .command)
        note("CLICK BACK: the \"\(name)\" leaf was not found within 5 s, so the REMEMBERED POINT was clicked instead "
            + "(it can sit on another paragraph after the editor was rebuilt)")
        return false
    }

    static func describeFrame(_ frame: CGRect) -> String { XCUIApplication.describeFrame(frame) }

    /// Right-clicks a sidebar card and chooses `item` ("Delete Section", "Duplicate Section") from its menu, and returns the index of the
    /// first app-log line after the click (where the operation's own lines begin). `activate` false skips the foreground check, for the
    /// command a person gives straight after the previous one (the app is already in front).
    @discardableResult
    func chooseSidebarItem(_ card: XCUIElement, item: String, activate: Bool = true) -> Int {
        if activate { app.activateAndWaitForForeground() }
        tail.poll()
        let fromIndex = tail.lines.count
        if firstTriggerIndex == nil { firstTriggerIndex = fromIndex }
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        app.menuItem(titleStartingWith: item).click()
        return fromIndex
    }

    /// Folds one batch of new log lines into what a wait has seen so far.
    func scan(_ fresh: [Phase4bLogLine], label: String, direction: String?, into outcome: inout Phase4bDelOutcome) {
        for line in fresh {
            if let trace = Phase4bDelTraceLine(line) {
                guard trace.label == label, trace.family == .sequence else { continue }
                if trace.isOpStart { outcome.startSeen = true }
                if trace.step == "performed", outcome.performed == nil { outcome.performed = trace }
            } else if let key = Phase4bDelTypingParser.key(line.text) {
                if key.code == Phase4bDelTypingParser.zKeyCode { outcome.keySeen = true }
            } else {
                let single = Phase4bLog(lines: [line])
                if outcome.failure == nil { outcome.failure = single.failureLine(since: "") }
                if outcome.refusal == nil, let direction { outcome.refusal = single.routingRefusal(since: "", direction: direction) }
            }
        }
    }

    /// Waits, by following the app's log, for the operation's own `<label> op=<id> performed` line, a logged refusal or failure, or the timeout.
    /// Reads the log and nothing else. `refusalDirection` is "undo" or "redo" for a key press (the editor's `routing-refused` line).
    func waitForOp(
        label: String, fromIndex: Int, timeout: TimeInterval, startRequiredWithin: TimeInterval, refusalDirection: String?
    ) -> Phase4bDelOutcome {
        let began = Date()
        var cursor = fromIndex
        var outcome = Phase4bDelOutcome()
        var refusalSeenAt: Date?
        repeat {
            tail.poll()
            if cursor < tail.lines.count {
                scan(Array(tail.lines[cursor...]), label: label, direction: refusalDirection, into: &outcome)
                cursor = tail.lines.count
            }
            if outcome.performed != nil { return outcome }
            if outcome.refusal != nil { refusalSeenAt = refusalSeenAt ?? Date() }
            if outcome.failure != nil, outcome.startSeen || outcome.refusal == nil { return outcome }
            // The editor refused to route the key to the structural operation: give a late Swift start a few seconds, then report it.
            if let seen = refusalSeenAt, !outcome.startSeen, Date().timeIntervalSince(seen) > 4 { return outcome }
            if !outcome.startSeen, Date().timeIntervalSince(began) > startRequiredWithin {
                outcome.noStart = true
                return outcome
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        } while Date().timeIntervalSince(began) < timeout
        outcome.timedOut = true
        return outcome
    }

    /// The heading rows of the section under test before any operation; nil (already reported) when the seeded document has none.
    func requireSectionRows() -> Int? {
        let title = size.deleteTitle
        let before = headingRows(title)
        note("heading rows titled \"\(title)\" before the delete: \(before); block rows: \(dbInt("SELECT count(*) FROM block;") ?? -1)")
        guard before >= 1 else { fail("the seeded document has no heading \"\(title)\" in the block table"); return nil }
        return before
    }

    /// Right-click the section's card, choose Delete Section, and wait for the app's own `sectionDelete ... performed` line and then for the
    /// heading to be gone from the block table. Nil (already reported) when any of that does not happen. Everything before the click may
    /// read the accessibility tree; after it only the log is followed, plus one database read.
    func deleteAndWait(before: Int) -> Phase4bDelRun? {
        let title = size.deleteTitle
        guard let card = bringSidebarCardIntoView(title) else { return nil }
        app.activateAndWaitForForeground()
        tail.poll()
        let fromIndex = tail.lines.count
        if firstTriggerIndex == nil { firstTriggerIndex = fromIndex }
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        app.menuItem(titleStartingWith: "Delete Section").click()
        let outcome = waitForOp(
            label: "sectionDelete", fromIndex: fromIndex, timeout: capped(size.operationTimeout), startRequiredWithin: 30, refusalDirection: nil)
        note("DELETE OPERATION \(outcome.description)")
        guard let performed = outcome.performed else { fail("the delete of \"\(title)\" did not finish: \(outcome.description)"); return nil }
        let rows = waitForHeadingRows(title, equalTo: 0, timeout: capped(15))
        result("delete of \"\(title)\": heading rows \(before) before, \(rows) after the delete finished")
        guard rows == 0 else { fail("after the delete finished the block table still holds \(rows) heading row(s) \"\(title)\""); return nil }
        return Phase4bDelRun(label: "sectionDelete", fromIndex: fromIndex, performed: performed)
    }

    /// Presses Cmd-Z (`label` "undo") or Cmd-Shift-Z ("redo") with no click and no caret placement, so the key goes to whatever has focus (the
    /// editor, as after any sidebar action), and waits for the operation's own `performed` line. A failure to perform is an assertion failure:
    /// the operation is the thing under test.
    func pressAndWait(label: String, flags: XCUIElement.KeyModifierFlags) -> Phase4bDelRun? {
        app.activateAndWaitForForeground()
        tail.poll()
        let fromIndex = tail.lines.count
        app.typeKey("z", modifierFlags: flags)
        let outcome = waitForOp(
            label: label, fromIndex: fromIndex, timeout: capped(size.operationTimeout), startRequiredWithin: 30, refusalDirection: label)
        note("\(label.uppercased()) OPERATION \(outcome.description)")
        guard let performed = outcome.performed else {
            assertCheck(false, "the structural \(label) must run after the key press; saw: \(outcome.description)")
            return nil
        }
        return Phase4bDelRun(label: label, fromIndex: fromIndex, performed: performed)
    }

    func pollTail(until date: Date) {
        while Date() < date {
            tail.poll()
            RunLoop.current.run(until: min(date, Date(timeIntervalSinceNow: 0.25)))
        }
    }

    /// The one wait the script owns: until the app's own 30 s trace window of the operation has closed (read from the operation's own click
    /// or start line stamp, on the VM's wall clock that the app's log shares), then until no span is left open (a span's end line is written
    /// even after the window). Nothing else is read in the meantime: the log follower only.
    func waitForTraceWindow(_ run: Phase4bDelRun) {
        tail.poll()
        let entry = tail.lines[run.fromIndex...].lazy.compactMap { Phase4bDelTraceLine($0) }
            .first { $0.label == run.label && ($0.step.hasPrefix("click-start") || $0.isOpStart) }
        let entryDate = entry?.line.date ?? run.performed.line.date ?? Date()
        let windowEnd = entryDate.addingTimeInterval(Self.traceWindowSeconds + Self.traceWindowGraceSeconds)
        let remaining = Self.seconds(max(0, windowEnd.timeIntervalSinceNow))
        note("TRACE WINDOW of \(run.label): the app writes timeline lines for \(Int(Self.traceWindowSeconds)) s after the operation starts; "
            + "following the log for \(remaining) s more")
        pollTail(until: windowEnd)
        let settleBy = Date(timeIntervalSinceNow: 30)
        var open = openSpanNames(from: run.fromIndex)
        while !open.isEmpty, Date() < settleBy {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            tail.poll()
            open = openSpanNames(from: run.fromIndex)
        }
        note("TRACE WINDOW of \(run.label) closed; spans still open: \(open.isEmpty ? "none" : open.joined(separator: ", ")); "
            + "log lines read so far: \(tail.lines.count); log rotations seen: \(tail.rotationsSeen)")
    }

    func openSpanNames(from index: Int) -> [String] {
        guard index <= tail.lines.count else { return [] }
        return Phase4bDelAnalyser.analyse(lines: Array(tail.lines[index...])).last?.openSpanNames ?? []
    }
}

// MARK: - Evidence

extension Phase4bDelHarness {
    /// The operations the trace shows since the first trigger.
    func currentOps() -> [Phase4bDelOp] {
        tail.poll()
        guard let first = firstTriggerIndex, first <= tail.lines.count else { return [] }
        return Phase4bDelAnalyser.analyse(lines: Array(tail.lines[first...]))
    }

    /// Prints the report to the test output and attaches it with the raw trace lines. Called from tearDown, so a failure keeps its evidence.
    func writeEvidence() {
        guard !evidenceWritten, !methodName.isEmpty else { return }
        evidenceWritten = true
        let ops = currentOps()
        let report = Phase4bDelTable.render(ops: ops, context: reportContext)
        for line in report { print("[P4B-DEL] \(methodName) \(line)") }
        fflush(stdout)
        let slice = firstTriggerIndex.map { Array(tail.lines[min($0, tail.lines.count)...]) } ?? []
        let raw = slice.filter { $0.text.contains("[STRUCT-TRACE]") || $0.text.contains("[TYPING-TRACE]") }.map(\.text)
        note("APP LOG: \(tail.lines.count) lines followed, \(slice.count) since the first trigger, \(raw.count) of them [STRUCT-TRACE] or "
            + "[TYPING-TRACE] lines; log rotations seen: \(tail.rotationsSeen); operations found: \(ops.count)")
        attachText("timing-table-\(methodName).txt", (summaryLines + [""] + report).joined(separator: "\n"))
        attachText("trace-lines-\(methodName).txt", raw.joined(separator: "\n"))
        if let start = evidenceLogStart { attachText("app-log-\(methodName).txt", appLogExport(from: start)) }
        if !rowDifferenceLog.isEmpty { attachText("row-differences-\(methodName).txt", rowDifferenceLog.joined(separator: "\n\n")) }
    }

    /// Categories whose lines are written many times a second and say nothing about a delete, a quit or a mode switch.
    static let noisyLogCategories = ["blockPoll", "viewUpdates", "contentPush", "reentrancy", "image", "theme", "proofing", "escape"]

    /// The app's diagnostic log since `index` (the follower's lines: ONE follower for the whole test, across a quit and a relaunch) as text:
    /// every category (`footnotes`, `editor`, `sync`, `lifecycle`, `undo`, `bib`, ... all reach the file while diagnostics are on) except the
    /// noisy ones, capped at `limitBytes` from the start of the window. The first lines say how much was read, kept and dropped, and whether the
    /// follower ever saw the file rotate (lines written while the test was blocked in a long accessibility query can be lost to rotation).
    func appLogExport(from index: Int, limitBytes: Int = 3_000_000) -> String {
        tail.poll()
        let window = index <= tail.lines.count ? Array(tail.lines[index...]) : []
        let noisyTags = Self.noisyLogCategories.map { " [\($0)] " }
        var kept: [String] = []
        var bytes = 0
        var truncated = 0
        for line in window where !noisyTags.contains(where: { line.text.contains($0) }) {
            if bytes + line.text.utf8.count > limitBytes {
                truncated += 1
            } else {
                kept.append(line.text)
                bytes += line.text.utf8.count + 1
            }
        }
        let header = "APP LOG EXPORT: \(window.count) line(s) in the window (log index \(index) to \(tail.lines.count)), \(kept.count) kept, "
            + "\(window.count - kept.count - truncated) dropped as polling noise (\(Self.noisyLogCategories.joined(separator: ", "))), "
            + "\(truncated) cut by the \(limitBytes)-byte cap; log rotations seen by the follower: \(tail.rotationsSeen)"
        return ([header] + kept).joined(separator: "\n")
    }

    /// The assertions about the delete's trace that are not time limits: the click-start line exists and names a MOUSE event (not a key, not
    /// "none"), so the click-to-performed figure is a figure for a real click.
    func assertDeleteClickWasAMouseEvent() {
        guard let delete = currentOps().first(where: { $0.kind == "sectionDelete" }) else {
            assertCheck(false, "the trace has a sectionDelete operation (a click-start or start line labelled sectionDelete)")
            return
        }
        let type = delete.clickType
        assertCheck(delete.click != nil, "the trace has a `click-start` line for the delete (written when Delete Section was chosen)")
        assertCheck(type.map { Self.mouseEventTypes.contains($0) } ?? false,
                    "the `click-start` line names a mouse event type (\(Self.mouseEventTypes.joined(separator: ", "))); it says "
                        + "type=\(type ?? "n/a"): a key or `none` would mean the click-to-performed figure is not for a click")
    }
}

// MARK: - The timing tests

extension WriteQueuePhase4bDeleteE2ETests {
    func testDeleteTiming_article() { runDeleteTiming(.article, method: #function) }
    func testDeleteTiming_book6() { runDeleteTiming(.book6, method: #function) }
    func testDeleteTiming_book12() { runDeleteTiming(.book12, method: #function) }

    func testUndoRedoTiming_article() { runUndoRedoTiming(.article, method: #function) }
    func testUndoRedoTiming_book6() { runUndoRedoTiming(.book6, method: #function) }
    func testUndoRedoTiming_book12() { runUndoRedoTiming(.book12, method: #function) }

    /// Delete the middle chapter-level section from the sidebar, follow the app's own trace until its 30 s window closes, and report.
    func runDeleteTiming(_ size: Phase4bDelSize, method: String) {
        begin(method: method, size: size)
        guard launchScenario(), let before = requireSectionRows(), let deleted = deleteAndWait(before: before) else { return }
        waitForTraceWindow(deleted)
        attachEvidenceScreenshot(app.screenshot(), name: "after-delete-\(size.identifier)")
        assertDeleteClickWasAMouseEvent()
    }

    /// Delete, then Cmd-Z, then Cmd-Shift-Z, each once the previous operation's trace window has closed; every figure is the app's own.
    func runUndoRedoTiming(_ size: Phase4bDelSize, method: String) {
        begin(method: method, size: size)
        guard launchScenario(), let before = requireSectionRows(), let deleted = deleteAndWait(before: before) else { return }
        waitForTraceWindow(deleted)
        attachEvidenceScreenshot(app.screenshot(), name: "after-delete-\(size.identifier)")

        let title = size.deleteTitle
        guard let undone = pressAndWait(label: "undo", flags: .command) else { return }
        let restored = waitForHeadingRows(title, equalTo: before, timeout: capped(15))
        let refusal = Phase4bLog(lines: Array(tail.lines[undone.fromIndex...])).routingRefusal(since: "", direction: "undo")
        waitForTraceWindow(undone)
        let cardBack = bringSidebarCardIntoView(title, failIfMissing: false) != nil
        attachEvidenceScreenshot(app.screenshot(), name: "after-undo-\(size.identifier)")
        result("Cmd-Z: heading rows \"\(title)\": \(before) before the delete, \(restored) after Cmd-Z; sidebar card back: \(Self.yesNo(cardBack)) "
            + "(recorded, not asserted); routing-refused line: \(refusal?.text.suffix(120).description ?? "none")")
        assertCheck(restored == before, "the heading \"\(title)\" must be back in the block table (\(before) row(s)); found \(restored)")
        assertCheck(refusal == nil, "no `routing-refused` line after Cmd-Z; saw: \(refusal?.text ?? "none")")

        guard let redone = pressAndWait(label: "redo", flags: [.command, .shift]) else { return }
        let afterRedo = waitForHeadingRows(title, equalTo: 0, timeout: capped(15))
        waitForTraceWindow(redone)
        attachEvidenceScreenshot(app.screenshot(), name: "after-redo-\(size.identifier)")
        result("Cmd-Shift-Z: heading rows \"\(title)\" after the redo: \(afterRedo)")
        assertCheck(afterRedo == 0, "the heading \"\(title)\" must be gone again after the redo; found \(afterRedo) row(s)")
        assertDeleteClickWasAMouseEvent()
    }
}

// MARK: - Old versus new: the editor-first delete's acceptance figures

/// The keystroke-to-echo figures of the editor keys in one window, on the app's own clock: each key is paired with the first echo at or after
/// it (analyser rule 4).
struct Phase4bDelKeyStats {
    /// Editor keys in the window.
    let keys: Int
    /// Key to echo, for the keys an echo followed, ascending.
    let latenciesMs: [Int]

    init(keys: [Phase4bDelTypingKey], echoes: [Phase4bDelEcho]) {
        self.keys = keys.count
        latenciesMs = Phase4bDelTypingParser.pair(keys: keys, echoes: echoes).compactMap(\.latencyMs).sorted()
    }

    /// Editor keys that no echo followed.
    var unpaired: Int { keys - latenciesMs.count }
    var maxMs: Int? { latenciesMs.last }
    var medianMs: Int? { latenciesMs.isEmpty ? nil : latenciesMs[latenciesMs.count / 2] }
    var p95Ms: Int? { latenciesMs.isEmpty ? nil : latenciesMs[min(latenciesMs.count - 1, Int((Double(latenciesMs.count) * 0.95).rounded(.up)) - 1)] }

    var text: String {
        "keys \(keys), paired \(latenciesMs.count), unpaired \(unpaired), median \(medianMs.map(String.init) ?? "n/a") ms, "
            + "p95 \(p95Ms.map(String.init) ?? "n/a") ms, max \(maxMs.map(String.init) ?? "n/a") ms"
    }

    /// True when keys were typed, every one was echoed, and the slowest echo took under `limitMs`.
    func allEchoedUnder(_ limitMs: Int) -> Bool { keys > 0 && unpaired == 0 && (maxMs ?? Int.max) < limitMs }
}

/// What one delete and the typing around it measured, on the app's own clock (see `WriteQueuePhase4bDeleteE2ETests.burst`).
struct Phase4bDelBurst {
    let label: String
    /// The in-app trigger's receipt line (`[UITEST-TRIGGER] ... deleteSection received`) to the controller's own `start` line, and the
    /// `click-start type=none` line (written at the action's entry) to the same `start` line: both a few milliseconds when nothing is in the way.
    let triggerToStartMs: Int?
    let clickLineToStartMs: Int?
    /// From the controller's `start` line (the action's entry, the zero of every figure here) to the first frame painted after the editor
    /// removed the section (the new path's `removal painted` line; nil on the legacy path), and to the operation's own `performed` line.
    let startToPaintedMs: Int?
    let startToPerformedMs: Int?
    /// The editor keys in the 3 s after the controller's `start` line.
    let afterStart: Phase4bDelKeyStats
    /// The main-thread stalls the app logged in those 3 s (length, when it began and ended).
    let stalls: [String]

    private func ms(_ value: Int?) -> String { value.map { "\($0) ms" } ?? "n/a" }

    var lines: [String] {
        [
            "\(label): trigger received \(ms(triggerToStartMs)) and click-start line \(ms(clickLineToStartMs)) before the controller start; "
                + "FROM THE CONTROLLER START: section removed on screen (removal painted) \(ms(startToPaintedMs)); "
                + "performed \(ms(startToPerformedMs))",
            "\(label): editor keys in the 3 s after the controller start: \(afterStart.text)",
            "\(label): main-thread stalls in the 3 s after the controller start: \(stalls.isEmpty ? "none logged" : stalls.joined(separator: "; "))"
        ]
    }
}

/// Round 13d: one run of macOS's own stack sampler (`/usr/bin/sample`) against the app under test, to see what the app's main thread is doing
/// DURING a delete's stalls (the run-loop tracer wrote no line for the longest one). Built before the delete's trigger is posted (the pid and
/// the output path are settled then), started right after it (`start`, which does not wait), and finished long afterwards (`finish`, which
/// waits for the 5 s run to have exited, reads its file and returns the texts to attach, cut by `Phase4bSampleFile`). It never fails the test:
/// whatever goes wrong, `finish` returns `.notTaken` with the reason.
final class Phase4bMainThreadSample {
    enum Outcome {
        /// The attachments (`Phase4bSampleFile.compose`).
        case taken(Phase4bSampleFile.Attachments)
        case notTaken(reason: String)
    }

    /// The harness's app (`XCUIApplication.targetApp()`), found among the running applications by its bundle id.
    static let bundleIdentifier = "com.kerim.final-final.testhost"
    static let durationSeconds = 5
    static let intervalMilliseconds = 2

    let label: String
    let path: String
    private var pid: pid_t?
    private var notTaken: String?
    private var started = false
    private let process = Process()
    private let standardOutput = Pipe()
    private let standardError = Pipe()

    init(label: String) {
        self.label = label
        let safeLabel = String(label.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        path = NSTemporaryDirectory() + "ff-p4b-del-sample-\(safeLabel)-\(UUID().uuidString).txt"
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).filter { !$0.isTerminated }
        guard let app = candidates.max(by: { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }) else {
            notTaken = "no running application has the bundle id \(Self.bundleIdentifier)"
            return
        }
        pid = app.processIdentifier
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(app.processIdentifier), String(Self.durationSeconds), String(Self.intervalMilliseconds), "-file", path]
        process.standardOutput = standardOutput
        process.standardError = standardError
    }

    /// Starts the sampler and returns at once (the process is not waited on).
    func start() {
        guard notTaken == nil else { return }
        do {
            try process.run()
            started = true
        } catch {
            notTaken = "sample could not be started: \(error)"
        }
    }

    /// Waits for the exit (a delete's trace window is long over by then, so this returns at once), then reads the sample file: the texts to
    /// attach, or why there are none.
    func finish() -> Outcome {
        if let notTaken { return .notTaken(reason: notTaken) }
        guard started else { return .notTaken(reason: "sample was never started") }
        process.waitUntilExit()
        let said = Self.firstLine(of: standardError) ?? Self.lastLine(of: standardOutput) ?? "it printed nothing"
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let how = process.terminationReason == .exit ? "exited with status" : "was killed by signal"
            return .notTaken(reason: "sample \(how) \(process.terminationStatus); \(said)")
        }
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
            return .notTaken(reason: "sample exited with status 0 but wrote no file at \(path); \(said)")
        }
        guard let text = String(bytes: data, encoding: .utf8) else {
            return .notTaken(reason: "sample exited with status 0 but its file at \(path) (\(data.count) bytes) is not valid UTF-8")
        }
        let command = "/usr/bin/sample \(pid.map { String($0) } ?? "?") \(Self.durationSeconds) \(Self.intervalMilliseconds) -file \(path)"
        let toolLine = "Tool: \(command) (\(Self.durationSeconds) s, one sample every \(Self.intervalMilliseconds) ms), "
            + "started right after the trigger of \"\(label)\" was posted. "
            + "It suspends the app briefly for each sample, so the delete ran slightly slower than it would unsampled."
        return .taken(Phase4bSampleFile.compose(file: text, label: label, toolLine: toolLine))
    }

    private static func lines(of pipe: Pipe) -> [String] {
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return (String(bytes: data, encoding: .utf8) ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func firstLine(of pipe: Pipe) -> String? { lines(of: pipe).first }

    private static func lastLine(of pipe: Pipe) -> String? { lines(of: pipe).last }
}

/// Round 13e: which parts of a `sample` file are attached. The file (682,676 characters for a 5 s sample of the twelve-chapter book) is the
/// header lines, then `Call graph:` (by far the biggest part), `Total number in stack`, `Sort by top of stack, same collapsed` (the functions
/// that were on top of the stack most often, aggregated: the part that matters most) and `Binary Images:`. A plain prefix cut the closing
/// sections off, so the main attachment holds: the header up to the `Call graph:` line; the MAIN THREAD's whole section of the call graph
/// (round 14c: from the main thread's `Thread_` header line, the one carrying `com.apple.main-thread` or `Main Thread`, up to the next
/// `Thread_` header line, not included, or to the end of the call graph; capped at 700,000 characters; the first 150,000 characters of ALL
/// threads, as round 13e attached, cut the main thread's run-loop branch at about a third); and everything from the `Sort by top of stack`
/// line to the end of the file, capped at 150,000 characters. A file with no recognisable main-thread header falls back to the first
/// 150,000 characters of the whole call graph. The closing section alone (up to the `Binary Images:` line) is a second attachment. Pure
/// text work, so `testMainThreadSampleFile_handWorkedExample` runs it on canned files.
enum Phase4bSampleFile {
    static let callGraphCharacterCap = 150_000
    /// The cap of the main thread's section of the call graph.
    static let mainThreadCharacterCap = 700_000
    static let closingCharacterCap = 150_000
    /// The cap of the closing-section-only attachment, and of a file whose layout is not recognised (then a prefix is attached).
    static let wholeCharacterCap = 400_000

    struct Attachments {
        let main: String
        /// The closing section alone; nil when the file has no `Sort by top of stack` line.
        let topOfStack: String?
    }

    static func attachmentName(label: String, topOfStackOnly: Bool) -> String {
        "main-thread-sample-\(label.replacingOccurrences(of: " ", with: "-"))\(topOfStackOnly ? "-top-of-stack" : "").txt"
    }

    static func compose(
        file text: String, label: String, toolLine: String,
        callGraphCap: Int = Phase4bSampleFile.callGraphCharacterCap, closingCap: Int = Phase4bSampleFile.closingCharacterCap,
        mainThreadCap: Int = Phase4bSampleFile.mainThreadCharacterCap
    ) -> Attachments {
        let total = text.count
        let callStart = lineStart(of: "Call graph:", in: text, from: text.startIndex)
        let topStart = lineStart(of: "Sort by top of stack", in: text, from: text.startIndex)
        guard let firstMarker = callStart ?? topStart else {
            let kept = cut(text[...], cap: wholeCharacterCap)
            return Attachments(
                main: "The sample file had \(total) characters and neither a \"Call graph:\" line nor a \"Sort by top of stack\" line, "
                    + "so its first part is attached (\(kept.described)).\n\(toolLine)\n\n\(kept.text)",
                topOfStack: nil)
        }
        let head = text[..<firstMarker]
        var described = ["the header (\(head.count) characters, everything before the \"Call graph:\" line)"]
        var blocks = ["----- the header -----\n" + String(head)]
        if let callStart {
            let ends = [lineStart(of: "Total number in stack", in: text, from: callStart), topStart].compactMap { $0 }.filter { $0 > callStart }
            let callEnd = ends.min() ?? text.endIndex
            if let main = mainThreadSection(in: text, from: callStart, to: callEnd) {
                let kept = cut(text[main], cap: mainThreadCap)
                described.append("the main thread's section of the call graph, from its header line to the next thread's header line "
                    + "or the end of the call graph (\(kept.described); the other threads' sections are not attached)")
                blocks.append("----- the main thread's section of the call graph -----\n" + kept.text)
            } else {
                let kept = cut(text[callStart..<callEnd], cap: callGraphCap)
                described.append("the call graph (\(kept.described))")
                blocks.append("----- the call graph -----\n" + kept.text)
            }
        } else {
            described.append("no \"Call graph:\" line in the file")
        }
        var topOnly: String?
        if let topStart {
            let kept = cut(text[topStart...], cap: closingCap)
            described.append("everything from the \"Sort by top of stack\" line to the end of the file (\(kept.described))")
            blocks.append("----- from the \"Sort by top of stack\" line to the end of the file -----\n" + kept.text)
            let end = lineStart(of: "Binary Images:", in: text, from: topStart) ?? text.endIndex
            let only = cut(text[topStart..<end], cap: wholeCharacterCap)
            topOnly = "The closing section of the sample file of \"\(label)\" (the file had \(total) characters): from the \"Sort by top of stack\" "
                + "line up to the line that starts the binary-image list (not included), or to the end of the file when there is none "
                + "(\(only.described)).\n\(toolLine)\n\n\(only.text)"
        } else {
            described.append("no \"Sort by top of stack\" line in the file")
        }
        let topNote = topStart == nil ? "" : " The closing section alone is the attachment \(attachmentName(label: label, topOfStackOnly: true))."
        let first = "The sample file had \(total) characters. Attached, in this order: \(described.joined(separator: "; ")).\(topNote)"
        return Attachments(main: first + "\n" + toolLine + "\n\n" + blocks.joined(separator: "\n\n"), topOfStack: topOnly)
    }

    /// The start of a thread's header line in the call graph (`    <samples> Thread_<id>...`), as a pattern that includes the newline before it.
    private static let threadHeaderPattern = "\n *[0-9]+ Thread_[0-9]+"

    /// The main thread's whole section of the call graph that lies between `callStart` and `callEnd`: from the first thread header line that
    /// carries `com.apple.main-thread` or `Main Thread` up to the next thread's header line (not included), or to `callEnd`. Nil when no thread
    /// header carries either marker (no recognisable main thread).
    private static func mainThreadSection(in text: String, from callStart: String.Index, to callEnd: String.Index) -> Range<String.Index>? {
        var searchFrom = callStart
        while let found = text.range(of: threadHeaderPattern, options: .regularExpression, range: searchFrom..<callEnd) {
            let headerStart = text.index(after: found.lowerBound)
            let headerEnd = text[headerStart..<callEnd].firstIndex(of: "\n") ?? callEnd
            let header = text[headerStart..<headerEnd]
            if header.contains("com.apple.main-thread") || header.contains("Main Thread") {
                let next = text.range(of: threadHeaderPattern, options: .regularExpression, range: headerEnd..<callEnd)
                return headerStart..<(next.map { text.index(after: $0.lowerBound) } ?? callEnd)
            }
            searchFrom = headerEnd
        }
        return nil
    }

    /// The start of the first line at or after `start` (itself a line start) that begins with `marker`.
    private static func lineStart(of marker: String, in text: String, from start: String.Index) -> String.Index? {
        if text[start...].hasPrefix(marker) { return start }
        guard let found = text.range(of: "\n" + marker, range: start..<text.endIndex) else { return nil }
        return text.index(after: found.lowerBound)
    }

    private static func cut(_ part: Substring, cap: Int) -> (text: String, described: String) {
        let count = part.count
        guard count > cap else { return (String(part), "all \(count) characters") }
        return (String(part.prefix(cap)), "the first \(cap) of \(count) characters")
    }
}

extension WriteQueuePhase4bDeleteE2ETests {
    func testOldVsNewTiming_book12() throws { try runOldVsNewTiming(.book12, method: #function) }

    /// The delete's own timings and nothing else (no typing): minutes, not the hour `testOldVsNewTiming_book12` takes. See `runDeleteSpeedOnly`.
    func testDeleteSpeedOnly_book12() throws { try runDeleteSpeedOnly(.book12, method: #function) }

    /// An editor key that is typing: not Z (undo and redo) and not an arrow key (the click-back's Cmd-Right).
    static func isTypedKey(_ key: Phase4bDelTypingKey) -> Bool {
        key.inEditor && key.code != Phase4bDelTypingParser.zKeyCode && !(123...126).contains(key.code)
    }

    /// The delete that began at app-log index `fromIndex`, measured two ways: from the click event (the mouse event that chose the menu item)
    /// and from the controller's own `start` line (the menu action's entry; about half a second of the first is the menu itself). For each
    /// start: the time to `removal painted` and to `performed`, and each editor key typed in the 3 s after it paired with its first echo; and
    /// the main-thread stalls the app logged in the 3 s after the controller's start. Reads the app's log only (no accessibility query
    /// measures anything). The analyser gives every line after an operation's start to that operation until the next one starts, so a second
    /// delete begun inside the first one's 3 s would take that window's later stalls away from the first: `stallsAcrossOps` true counts the
    /// stalls of every operation in the slice, by time (the speed-only test, which starts its second delete straight after the first one's
    /// `performed`). False (the default) keeps the first operation's own stalls.
    func burst(label: String, fromIndex: Int, stallsAcrossOps: Bool = false) -> Phase4bDelBurst {
        tail.poll()
        let slice = Array(tail.lines[min(fromIndex, tail.lines.count)...])
        let operations = Phase4bDelAnalyser.analyse(lines: slice)
        guard let operation = operations.first(where: { $0.kind == "sectionDelete" }),
              let startT = operation.start?.t else {
            return Phase4bDelBurst(
                label: label, triggerToStartMs: nil, clickLineToStartMs: nil, startToPaintedMs: nil, startToPerformedMs: nil,
                afterStart: Phase4bDelKeyStats(keys: [], echoes: []), stalls: [])
        }
        let triggerT = slice.first { $0.text.contains("[UITEST-TRIGGER]") }
            .flatMap { Phase4bDelTypingParser.intAfter("t=", in: $0.text) }
        let painted = operation.oneOffs.first { $0.step == "removal painted" }
        let keys = operation.typedKeys.filter { Self.isTypedKey($0) && $0.t >= startT && $0.t - startT <= 3_000 }
        let candidates = stallsAcrossOps ? operations.flatMap(\.stalls) : operation.stalls
        let stalls = candidates.filter { $0.beganT < startT + 3_000 && $0.endT > startT }.map { stall in
            "\(stall.durationMs) ms, began +\(stall.beganT - startT) ms, ended +\(stall.endT - startT) ms"
        }
        return Phase4bDelBurst(
            label: label, triggerToStartMs: triggerT.map { startT - $0 }, clickLineToStartMs: operation.click.map { startT - $0.t },
            startToPaintedMs: painted.map { $0.t - startT }, startToPerformedMs: operation.performed.map { $0.t - startT },
            afterStart: Phase4bDelKeyStats(keys: keys, echoes: operation.echoes), stalls: stalls)
    }

    /// The same figures for a burst typed with NO delete (the control, on the same document, to compare the delete's figures with).
    func controlStats(fromIndex: Int) -> Phase4bDelKeyStats {
        tail.poll()
        let lines = Array(tail.lines[min(fromIndex, tail.lines.count)...])
        let keys = lines.compactMap { Phase4bDelTypingParser.key($0.text) }.filter(Self.isTypedKey)
        let echoes = lines.compactMap { Phase4bDelTypingParser.echo($0.text) }
        guard let first = keys.first else { return Phase4bDelKeyStats(keys: [], echoes: echoes) }
        return Phase4bDelKeyStats(keys: keys.filter { $0.t - first.t <= 3_000 }, echoes: echoes)
    }

    /// Waits until the app has logged no new key or echo line for `quiet` seconds since log index `fromIndex` (the burst has been typed and
    /// every echo has arrived), up to `cap`.
    func waitForTypingQuiet(fromIndex: Int, quiet: TimeInterval = 1.5, cap: TimeInterval) {
        var seen = -1
        var changedAt = Date()
        let deadline = Date(timeIntervalSinceNow: cap)
        repeat {
            tail.poll()
            let count = tail.lines[min(fromIndex, tail.lines.count)...]
                .filter { $0.text.contains("[TYPING-TRACE] key t=") || $0.text.contains("[TYPING-TRACE] echo t=") }.count
            if count != seen {
                seen = count
                changedAt = Date()
            }
            if Date().timeIntervalSince(changedAt) >= quiet { return }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
    }

    /// Delete, and type straight after it, on the legacy path (`FF_UI_TESTING_STRUCT_LEGACY_DELETE=1`) and on the new one, on the same
    /// document. THE SEAM IS AN ENVIRONMENT VARIABLE OF THE APP'S PROCESS, fixed when the app starts, so the two paths cannot be switched
    /// inside one app session: each gets its own launch and its own fresh copy of the fixture, back to back in this one method. The new
    /// path's launch also sets `FF_UI_TESTING_STRUCT_JOB_HOLD_MS`, so the first delete's job is still queued when the second delete is
    /// chosen and typed after (the case the plan asks about); the hold delays the job in the writer, never the editor's own removal or echo.
    /// Acceptance (new path): the removal is painted in under 100 ms of the action's start, and every keystroke typed in the 3 s after it is
    /// echoed in under 100 ms, for the first delete and for the second one with the first one's job still queued. THE TARGETS ARE THE
    /// PLAN'S AND ARE NOT WEAKENED; the checks are SOFT, so one run reports every figure whichever miss.
    ///
    /// WHAT IS MEASURED WITH NOTHING OF THE TEST'S OWN IN THE WAY. The caret is placed in the Anchor05 paragraph ONCE, before anything is
    /// measured (an accessibility search). A CONTROL burst is typed first with no delete at all, for the same document's baseline. Each delete
    /// is then started WITHOUT the sidebar menu: the test posts the app's UI-testing distributed notification
    /// (`com.kerim.final-final.uitest.deleteSection`, userInfo `title`, `UITestingDeleteTrigger`), the app runs the same entry point the menu
    /// action runs (`deleteSectionFromSidebar`, so both the editor-first and the legacy path), and the test types its burst at once with no
    /// click (the focus never left the editor) and reads only the app's log until the burst and the `performed` line are done. After a menu
    /// click XCUITest runs its own "find the menu item" accessibility query, which on a 700,000-character document waits on the web process and
    /// blocks the app's main thread; the mouse-down also precedes the menu action by 0.4 to 0.5 s of menu tracking. So every figure is taken from
    /// the app's own `start` line (the action's entry), never from a mouse event.
    func runOldVsNewTiming(_ size: Phase4bDelSize, method: String) throws {
        begin(method: method, size: size)
        var bursts: [Phase4bDelBurst] = []
        var controls: [(label: String, stats: Phase4bDelKeyStats)] = []
        var soft = Phase4bFlowSoftChecks()
        let text = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 5)
        for legacy in [true, false] {
            try prepareTimingPass(legacy: legacy)
            let path = legacy ? "LEGACY" : "NEW"
            guard launchScenario(), let before = requireSectionRows(), placeCaretAtAnchorEnd() else { return }

            // The control: the same burst, no delete, caret already in place.
            tail.poll()
            let controlFrom = tail.lines.count
            typeBurst(text)
            waitForTypingQuiet(fromIndex: controlFrom, cap: capped(120))
            controls.append((label: "\(path) control burst (no delete)", stats: controlStats(fromIndex: controlFrom)))

            // Delete 1: the trigger, then the burst at once; only the app's log is read until both are done.
            guard let firstBurst = measuredDelete(title: size.deleteTitle, label: "\(path) delete 1", text: text, size: size) else { return }
            bursts.append(firstBurst)
            if !legacy {
                // The second delete, with the first one's job still held in the writer's queue.
                let secondTitle = "Chapter 4: The Quiet Archive and Its Ledgers"
                guard let secondBurst = measuredDelete(
                    title: secondTitle, label: "NEW delete 2 (the first one's job still queued)", text: text, size: size) else { return }
                bursts.append(secondBurst)
                soft.check(waitForHeadingRows(secondTitle, equalTo: 0, timeout: capped(size.operationTimeout)) == 0,
                           "the second chapter is not gone from the block table once its job has run")
            }
            soft.check(waitForHeadingRows(size.deleteTitle, equalTo: 0, timeout: capped(size.operationTimeout)) == 0,
                       "\"\(size.deleteTitle)\" (\(before) heading row(s) before) is not gone from the block table once its job has run")
            _ = waitForLogQuiet(quiet: 3, cap: capped(60))
        }
        judgeTiming(controls: controls, bursts: bursts, soft: &soft)
        assertSoft(soft, "old versus new timing")
    }

    /// Gets one pass of an old-versus-new timing test ready to launch: the new pass first starts over with a fresh copy of the fixture (the
    /// legacy pass uses the fixture `setUp` made), then both passes set the launch environment of their path. THE SEAM IS AN ENVIRONMENT
    /// VARIABLE OF THE APP'S PROCESS (see `runOldVsNewTiming`), so each pass launches the app itself afterwards (`launchScenario`).
    func prepareTimingPass(legacy: Bool, jobHoldMs: Int = 45_000) throws {
        if !legacy {
            app.terminate()
            TestFixtureHelper.cleanupFixture()
            try TestFixtureHelper.setupFixture(from: self)
            firstTriggerIndex = nil
        }
        startedAt = Date()  // each pass gets the size's whole wall-clock budget
        note("PASS: \(legacy ? "LEGACY path (FF_UI_TESTING_STRUCT_LEGACY_DELETE=1)" : "NEW path (editor-first)")")
        app.launchEnvironment["FF_UI_TESTING_STRUCT_LEGACY_DELETE"] = legacy ? "1" : nil
        // Long enough that the first delete's job is still queued when the second delete starts (the first burst and the waits between
        // them take tens of seconds on this book). `runDeleteSpeedOnly` passes a longer hold: its second delete waits for the first one's
        // whole 30 s trace window.
        app.launchEnvironment["FF_UI_TESTING_STRUCT_JOB_HOLD_MS"] = legacy ? nil : String(jobHoldMs)
    }

    /// Round 13c: the same two passes as `runOldVsNewTiming` (legacy, then new with a second delete while the first one's job is still
    /// queued), taking only the app's own trace lines. NO typing, NO control burst, NO caret placement and no accessibility query beyond what
    /// the launch and `requireSectionRows` need: each delete is the in-app trigger, then a wait on the log for its `performed` line, then the
    /// log's 30 s trace window. Round 13e: EACH DELETE IS FINISHED BEFORE THE NEXT BEGINS (`finishDeleteOnly`): trigger, `performed`, the whole
    /// trace window, the delete's main-thread sample attached, its figures reported; only then does the next delete's trigger go out, so a
    /// harness failure at a later delete cannot take an earlier one's sample or figures with it. The new pass therefore posts its second
    /// trigger after the first delete's whole trace window, not straight after its `performed`. Reported for each delete,
    /// from the controller's own `start` line: `removal painted` (none on the legacy path), `performed`, the trigger-receipt and
    /// `click-start` figures, the main-thread stalls in the first 3 s, and the editor's own per-step timing line. The plan's target (the
    /// removal painted in under 100 ms) is ONE soft check per NEW delete, worded as `judgeTiming` words it, so the run still ends red while
    /// the target is missed, after every figure was reported.
    func runDeleteSpeedOnly(_ size: Phase4bDelSize, method: String) throws {
        begin(method: method, size: size)
        var soft = Phase4bFlowSoftChecks()
        note("NOTE: round 13d: right after each delete's trigger the test starts "
            + "`/usr/bin/sample <app pid> \(Phase4bMainThreadSample.durationSeconds) \(Phase4bMainThreadSample.intervalMilliseconds) -file <file>` "
            + "against the app (not waited on) and attaches its output as main-thread-sample-<delete label>.txt (the header, the main thread's "
            + "whole section of the call graph (round 14c: not the other threads') and the closing section; round 13e: that closing "
            + "\"Sort by top of stack\" section alone as main-thread-sample-<delete label>-top-of-stack.txt) once the delete's trace window "
            + "has closed; sample briefly suspends the app for each of its samples, so every delete runs slightly slower than it would unsampled")
        for legacy in [true, false] {
            // The speed-only second delete waits for the first one's whole trace window (31.5 s after its start at the least), so the first
            // job's hold is 90 s, not the old-versus-new test's 45 s: the hold starts when the job's body starts (a few seconds after the click).
            try prepareTimingPass(legacy: legacy, jobHoldMs: 90_000)
            let path = legacy ? "LEGACY" : "NEW"
            guard launchScenario(), requireSectionRows() != nil else { return }
            app.activateAndWaitForForeground()
            guard finishDeleteOnly(title: size.deleteTitle, label: "\(path) delete 1", size: size, soft: &soft) else { return }
            if !legacy {
                // The second delete, with the first one's job still held in the writer's queue (the note says whether it really is).
                let rows = headingRows(size.deleteTitle)
                note("NOTE: delete 2's trigger is posted after delete 1's `performed`, its whole trace window and the attachment of its sample, "
                    + "so the two 3 s stall windows do not overlap. Delete 1's job (held 90 s from the start of its body) "
                    + "\(rows >= 1 ? "IS" : "is NOT") still queued now: the block table holds \(rows) heading row(s) titled "
                    + "\"\(size.deleteTitle)\" (-1 = unreadable)")
                guard finishDeleteOnly(
                    title: "Chapter 4: The Quiet Archive and Its Ledgers", label: "NEW delete 2 (the first one's job still queued)",
                    size: size, soft: &soft) else { return }
            }
        }
        assertSoft(soft, "delete speed only")
    }

    /// One delete of `runDeleteSpeedOnly` from trigger to report: the trigger and the wait for `performed` (`startDeleteOnly`), the whole
    /// trace window, the delete's main-thread sample (attached at once), then its figures. False when the delete did not finish (reported).
    func finishDeleteOnly(title: String, label: String, size: Phase4bDelSize, soft: inout Phase4bFlowSoftChecks) -> Bool {
        guard let delete = startDeleteOnly(title: title, label: label, size: size) else { return false }
        waitForTraceWindow(delete.run)
        attachMainThreadSample(label: label)
        reportDeleteOnly(delete, soft: &soft)
        return true
    }

    /// Posts the in-app delete trigger for `title` and follows the log until the delete's own `performed` line. Types nothing. Nil (reported)
    /// when the app never received the trigger or the delete did not finish; the delete's sample is attached first in that case too.
    func startDeleteOnly(title: String, label: String, size: Phase4bDelSize) -> (label: String, run: Phase4bDelRun)? {
        tail.poll()
        let from = tail.lines.count
        if firstTriggerIndex == nil { firstTriggerIndex = from }
        let sample = Phase4bMainThreadSample(label: label)
        postDeleteTrigger(title: title)
        sample.start()
        mainThreadSamples[label] = sample
        guard let performed = waitForOp(label: "sectionDelete", fromIndex: from, timeout: capped(size.operationTimeout), startRequiredWithin: 30,
                                        refusalDirection: nil).performed else {
            attachMainThreadSample(label: label)  // before the failure below, which ends the test
            failUnfinishedDelete(title: title, label: label, fromIndex: from)
            return nil
        }
        return (label: label, run: Phase4bDelRun(label: "sectionDelete", fromIndex: from, performed: performed))
    }

    /// The `result` lines of one delete of `runDeleteSpeedOnly`: the controller's figures (`burst`, whose keystroke line is empty here), the
    /// editor's own timing line, and, for a NEW delete, the plan's soft check.
    func reportDeleteOnly(_ delete: (label: String, run: Phase4bDelRun), soft: inout Phase4bFlowSoftChecks) {
        let entry = burst(label: delete.label, fromIndex: delete.run.fromIndex, stallsAcrossOps: true)
        for line in entry.lines { result(line) }
        result("\(delete.label): editor timing line: \(editorTimingLine(fromIndex: delete.run.fromIndex) ?? "none found")")
        if delete.label.hasPrefix("NEW") { checkRemovalPainted(entry, soft: &soft) }
    }

    /// Finishes the delete's `sample` (its 5 s are long over once the trace window has closed, so the wait returns at once), attaches its
    /// output as `main-thread-sample-<label with dashes>.txt` and, when the file has the section, its closing "Sort by top of stack" part alone
    /// as `...-top-of-stack.txt` (`Phase4bSampleFile`), and reports the one `sample` line of that delete. NEVER fails the test: a sample that
    /// could not be taken is reported with its reason (the pid, the tool's exit status and its first line of stderr).
    func attachMainThreadSample(label: String) {
        guard let sample = mainThreadSamples.removeValue(forKey: label) else {
            result("sample \(label): not taken (no sample was started for this delete)")
            return
        }
        switch sample.finish() {
        case .taken(let attachments):
            let name = Phase4bSampleFile.attachmentName(label: label, topOfStackOnly: false)
            attachText(name, attachments.main)
            var line = "sample \(label): \(attachments.main.utf8.count) bytes written to the attachment \(name)"
            if let topOfStack = attachments.topOfStack {
                let topName = Phase4bSampleFile.attachmentName(label: label, topOfStackOnly: true)
                attachText(topName, topOfStack)
                line += "; \(topOfStack.utf8.count) bytes written to the attachment \(topName)"
            } else {
                line += "; the file has no \"Sort by top of stack\" section, so there is no top-of-stack attachment"
            }
            result(line)
        case .notTaken(let reason):
            result("sample \(label): not taken (\(reason))")
        }
    }

    /// The editor's own timing line of the delete that began at log index `fromIndex` (the web side's per-step laps, `jsMs total=...`), as the
    /// text after the `[STRUCT-TRACE]` prefix; nil when the log has none (the legacy path never runs the editor-first call).
    func editorTimingLine(fromIndex: Int) -> String? {
        tail.poll()
        guard fromIndex <= tail.lines.count, let found = tail.lines[fromIndex...].first(where: {
            $0.text.contains("delete-editor-first") && $0.text.contains("jsMs total=")
        }) else { return nil }
        guard let prefix = found.text.range(of: "[STRUCT-TRACE]") else { return found.text }
        return found.text[prefix.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    /// One keystroke burst, typed in a single `typeText` call, never retyped or verified: the keystrokes ARE the measurement.
    func typeBurst(_ text: String) {
        // e2e-lint: allow raw-typetext -- the keystrokes are the measurement: typed straight after the click, never retyped or verified.
        app.typeText(text)
    }

    /// The in-app trigger of the UI-testing seam (`UITestingDeleteTrigger`, DEBUG builds with `FF_UI_TESTING=1`): the app finds the section by
    /// its exact sidebar title and runs the SAME entry point the sidebar's menu action runs. Posted from this process (the UI-test runner is
    /// unsandboxed, see its entitlements, so a distributed notification with a property-list `userInfo` reaches the app).
    func postDeleteTrigger(title: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.kerim.final-final.uitest.deleteSection"), object: nil, userInfo: ["title": title], deliverImmediately: true)
    }

    /// One measured delete, with nothing of the test's own in the way: the app is brought to the front first (nothing is measured yet), then
    /// the trigger is posted and the burst typed at once (no menu, no click: the focus never left the editor), and from then on only the app's
    /// log is read until the delete's own `performed` line and the last echo. The figures are taken from the app's own `start` line. Nil
    /// (reported) when the app never received the trigger or the delete did not finish.
    func measuredDelete(title: String, label: String, text: String, size: Phase4bDelSize) -> Phase4bDelBurst? {
        app.activateAndWaitForForeground()
        tail.poll()
        let from = tail.lines.count
        if firstTriggerIndex == nil { firstTriggerIndex = from }
        postDeleteTrigger(title: title)
        typeBurst(text)
        guard waitForOp(label: "sectionDelete", fromIndex: from, timeout: capped(size.operationTimeout), startRequiredWithin: 30,
                        refusalDirection: nil).performed != nil else {
            failUnfinishedDelete(title: title, label: label, fromIndex: from)
            return nil
        }
        waitForTypingQuiet(fromIndex: from, cap: capped(120))
        return burst(label: label, fromIndex: from)
    }

    /// Reports (as a harness failure) a delete that did not finish, saying whether the app ever received its trigger.
    func failUnfinishedDelete(title: String, label: String, fromIndex: Int) {
        let received = tail.indexOfFirstLine(containing: "[UITEST-TRIGGER]", from: fromIndex) != nil
        fail("the delete of \"\(title)\" (\(label)) did not finish; the app \(received ? "received" : "NEVER received") the trigger "
            + "(it needs a DEBUG build with FF_UI_TESTING=1 and a section titled exactly that)")
    }

    /// Reports every figure first (so one run gives them all), then adds the plan's targets as SOFT checks (not weakened): the removal is
    /// painted in under 100 ms of the click and every keystroke in the 3 s after the click is echoed in under 100 ms, for each NEW delete.
    func judgeTiming(controls: [(label: String, stats: Phase4bDelKeyStats)], bursts: [Phase4bDelBurst], soft: inout Phase4bFlowSoftChecks) {
        for control in controls { result("\(control.label): editor keys in the 3 s after the first key: \(control.stats.text)") }
        for entry in bursts { for line in entry.lines { result(line) } }
        for control in controls {
            soft.check(control.stats.keys > 0, "\(control.label): no editor key was logged, so the keystroke figures cannot be trusted")
        }
        for entry in bursts where entry.label.hasPrefix("NEW") {
            checkRemovalPainted(entry, soft: &soft)
            soft.check(entry.afterStart.allEchoedUnder(100),
                       "\(entry.label): not every keystroke typed in the 3 s after the controller start was echoed in under 100 ms "
                           + "(\(entry.afterStart.text))")
        }
    }

    /// The plan's removal target as a SOFT check: the removal is painted in under 100 ms of the controller start.
    func checkRemovalPainted(_ entry: Phase4bDelBurst, soft: inout Phase4bFlowSoftChecks) {
        let painted = entry.startToPaintedMs.map { "\($0) ms" } ?? "no `removal painted` line"
        soft.check(entry.startToPaintedMs.map { $0 < 100 } ?? false,
                   "\(entry.label): the removal is not painted in under 100 ms of the controller start (measured: \(painted))")
    }
}

// MARK: - Tests that launch no app

extension WriteQueuePhase4bDeleteE2ETests {
    /// The generated documents have the sizes the unit-test fixture reports (characters from ComplexDocumentFixture's header and this slice's
    /// brief; the other counts worked out by hand from the recipe: per chapter 66 body citation groups plus 2 in footnote definitions, 9
    /// footnotes, 17 headings, plus the one `# Notes` heading), so figures from this class and from the unit tests are for the same text.
    func testFixtureSizes_matchTheUnitTestFixture() {
        for size in Phase4bDelSize.allCases {
            let counts = Phase4bDelGenerator.make(chapters: size.chapters).counts
            print("[P4B-DEL] testFixtureSizes \(size.title): \(counts.reportLine)")
            XCTAssertEqual(counts.characters, size.expectedCharacters, "\(size.title): characters")
            XCTAssertEqual(counts.citationGroups, size.expectedCitationGroups, "\(size.title): citation groups")
            XCTAssertEqual(counts.footnoteMarks, size.expectedFootnoteMarks, "\(size.title): footnote marks")
            XCTAssertEqual(counts.footnoteDefinitions, size.expectedFootnoteMarks, "\(size.title): footnote definitions")
            XCTAssertEqual(counts.headings, size.expectedHeadings, "\(size.title): headings")
        }
        XCTAssertEqual(
            Phase4bDelGenerator.make(chapters: 1).markdown, Phase4bGenerator.make().markdown,
            "the one-chapter document must be byte for byte the article of the committed Phase 4b tests")
    }

    /// Which parts of a `sample` file are attached (round 13e), on a made-up file whose figures were worked out by hand. Its call graph is
    /// "Call graph:\n" (12 characters) + "    10 alpha\n" (4 spaces, "10", a space, "alpha", a newline: 13) + "    + 10 beta\n" (14) = 39
    /// characters, so a cap of 21 keeps the 12 of the first line and the first 9 of the second ("    10 al"); a closing cap of 10 keeps
    /// "Sort by to" (S-o-r-t, space, b-y, space, t-o). The call graph ends at the "Total number in stack" line, which is not attached.
    ///
    /// Round 14c: a call graph with thread headers attaches the MAIN THREAD's section only. In `twoThreads` the main thread's section is its
    /// header line "    9 Thread_100   DispatchQueue_1: com.apple.main-thread  (serial)\n" (4 spaces, "9", a space, "Thread_100" = 10, 3 spaces,
    /// "DispatchQueue_1:" = 16, a space, "com.apple.main-thread" = 21, 2 spaces, "(serial)" = 8, a newline: 4+1+1+10+3+16+1+21+2+8+1 = 68),
    /// "    + 9 mainA\n" (4 + "+ 9 mainA" = 9, + newline = 14) and "    +   9 mainB\n" (4 + "+   9 mainB" = 11, + newline = 16): 98
    /// characters, ending just before the worker thread's header line, so a cap of 75 keeps the header line and the first 7 characters of
    /// the next line ("    + 9"). In `mainLast` the worker thread comes first and the main thread's section is its header line (68) and
    /// "    + 9 mainA\n" (14) = 82 characters, ending at the "Total number in stack" line.
    func testMainThreadSampleFile_handWorkedExample() {
        let file = "Analysis of sampling app (pid 7) every 2 milliseconds\nProcess:  app [7]\n\n----\n\n"
            + "Call graph:\n    10 alpha\n    + 10 beta\n"
            + "Total number in stack (recursive counted multiple, when >=5):\n        10 beta\n\n"
            + "Sort by top of stack, same collapsed (when >= 5):\n        gamma  10\n        delta  5\n\n"
            + "Binary Images:\n       0x1000 - 0x2000  app\n"
        let label = "LEGACY delete 1"

        let cut = Phase4bSampleFile.compose(file: file, label: label, toolLine: "TOOL-LINE", callGraphCap: 21, closingCap: 1_000)
        XCTAssertTrue(cut.main.hasPrefix("The sample file had \(file.count) characters. Attached, in this order: the header ("), "first line")
        XCTAssertTrue(cut.main.contains("the call graph (the first 21 of 39 characters)"), "the call graph's size is said")
        XCTAssertTrue(cut.main.contains("Call graph:\n    10 al\n\n----- from"), "the call graph is cut after 21 characters")
        XCTAssertFalse(cut.main.contains("alpha"), "nothing of the call graph past the cap")
        XCTAssertFalse(cut.main.contains("beta"), "no `Total number in stack` section")
        XCTAssertFalse(cut.main.contains("Total number in stack"), "the call graph stops before the `Total number in stack` line")
        XCTAssertTrue(cut.main.contains("gamma  10\n        delta  5"), "the closing section is attached")
        XCTAssertTrue(cut.main.contains("0x1000"), "the closing part runs to the end of the file")
        XCTAssertTrue(cut.main.contains("main-thread-sample-LEGACY-delete-1-top-of-stack.txt"), "the first line names the second attachment")
        XCTAssertTrue(cut.main.contains("TOOL-LINE"), "the tool line")
        guard let only = cut.topOfStack else { return XCTFail("no top-of-stack text") }
        XCTAssertTrue(
            only.contains("Sort by top of stack, same collapsed (when >= 5):\n        gamma  10\n        delta  5\n"), "the closing section")
        XCTAssertFalse(only.contains("0x1000"), "the closing section alone stops before the binary images")
        XCTAssertFalse(only.contains("alpha"), "the closing section alone holds none of the call graph")

        let whole = Phase4bSampleFile.compose(file: file, label: label, toolLine: "TOOL-LINE")
        XCTAssertTrue(whole.main.contains("the call graph (all 39 characters)"), "under the cap the whole call graph is attached")
        XCTAssertTrue(whole.main.contains("    + 10 beta\n"), "its last line")
        XCTAssertFalse(whole.main.contains("Total number in stack"), "still not the `Total number in stack` section")

        let short = Phase4bSampleFile.compose(file: file, label: label, toolLine: "TOOL-LINE", callGraphCap: 1_000, closingCap: 10)
        XCTAssertTrue(short.main.hasSuffix("Sort by to"), "the closing part is cut after 10 characters")
        XCTAssertTrue(short.main.contains("to the end of the file (the first 10 of "), "and says so")

        let unknown = Phase4bSampleFile.compose(file: "plain text", label: label, toolLine: "TOOL-LINE")
        XCTAssertNil(unknown.topOfStack)
        XCTAssertTrue(unknown.main.hasSuffix("plain text") && unknown.main.contains("neither a"), "a file of another layout is attached as it is")

        assertMainThreadSectionIsAttached(label: label)

        let long = "NEW delete 2 (the first one's job still queued)"
        XCTAssertEqual(Phase4bSampleFile.attachmentName(label: long, topOfStackOnly: false),
                       "main-thread-sample-NEW-delete-2-(the-first-one's-job-still-queued).txt")
        XCTAssertEqual(Phase4bSampleFile.attachmentName(label: long, topOfStackOnly: true),
                       "main-thread-sample-NEW-delete-2-(the-first-one's-job-still-queued)-top-of-stack.txt")
    }

    /// The round-14c half of `testMainThreadSampleFile_handWorkedExample`: canned files whose call graph has thread header lines (the figures
    /// are worked out in that test's comment).
    private func assertMainThreadSectionIsAttached(label: String) {
        let mainHeader = "    9 Thread_100   DispatchQueue_1: com.apple.main-thread  (serial)\n"
        let closing = "Total number in stack (recursive counted multiple, when >=5):\n        9 mainB\n\n"
            + "Sort by top of stack, same collapsed (when >= 5):\n        gamma  10\n        delta  5\n\n"
            + "Binary Images:\n       0x1000 - 0x2000  app\n"
        let top = "Analysis of sampling app (pid 7) every 2 milliseconds\nProcess:  app [7]\n\n----\n\nCall graph:\n"

        // The main thread first, a worker thread after it: the section ends at the worker's header line, which is not attached.
        let twoThreads = top + mainHeader + "    + 9 mainA\n    +   9 mainB\n" + "    4 Thread_200: worker\n    + 4 workerA\n" + closing
        let both = Phase4bSampleFile.compose(file: twoThreads, label: label, toolLine: "TOOL-LINE")
        XCTAssertTrue(both.main.contains("the main thread's section of the call graph, from its header line to the next thread's header line "
            + "or the end of the call graph (all 98 characters; the other threads' sections are not attached)"), "the section's size is said")
        XCTAssertTrue(both.main.contains("----- the main thread's section of the call graph -----\n" + mainHeader
            + "    + 9 mainA\n    +   9 mainB\n\n\n----- from the \"Sort by top of stack\""), "exactly the main thread's lines, then the closing")
        XCTAssertFalse(both.main.contains("workerA") || both.main.contains("Thread_200"), "nothing of the worker thread")
        XCTAssertFalse(both.main.contains("Total number in stack"), "the call graph still stops before the `Total number in stack` line")
        XCTAssertTrue(both.main.contains("gamma  10\n        delta  5"), "the closing section is attached")
        XCTAssertTrue(both.topOfStack?.contains("gamma  10") == true, "the top-of-stack attachment is kept")

        // The main thread's own cap: 75 characters are the header line (68) and "    + 9" (7).
        let capped = Phase4bSampleFile.compose(file: twoThreads, label: label, toolLine: "TOOL-LINE", mainThreadCap: 75)
        XCTAssertTrue(capped.main.contains("(the first 75 of 98 characters; the other threads' sections are not attached)"), "the cap is said")
        XCTAssertTrue(capped.main.contains("(serial)\n    + 9\n\n----- from the \"Sort by top of stack\""), "the section is cut after 75 characters")
        XCTAssertFalse(capped.main.contains("mainA"), "nothing past the cap")

        // The main thread last: the worker thread's section comes first and is skipped; the section ends at the `Total number in stack` line.
        let mainLast = top + "    4 Thread_200: worker\n    + 4 workerA\n" + mainHeader + "    + 9 mainA\n" + closing
        let last = Phase4bSampleFile.compose(file: mainLast, label: label, toolLine: "TOOL-LINE")
        XCTAssertTrue(last.main.contains("(all 82 characters; the other threads' sections are not attached)"), "the section's size is said")
        XCTAssertTrue(last.main.contains("----- the main thread's section of the call graph -----\n" + mainHeader
            + "    + 9 mainA\n\n\n----- from the \"Sort by top of stack\""), "exactly the main thread's lines")
        XCTAssertFalse(last.main.contains("workerA") || last.main.contains("Thread_200"), "nothing of the worker thread")
        XCTAssertFalse(last.main.contains("Total number in stack"), "the section stops at the `Total number in stack` line")

        // A header that says only `Main Thread` is recognised too.
        let named = Phase4bSampleFile.compose(
            file: twoThreads.replacingOccurrences(of: "DispatchQueue_1: com.apple.main-thread  (serial)", with: "Main Thread"),
            label: label, toolLine: "TOOL-LINE")
        XCTAssertTrue(named.main.contains("mainB\n\n\n----- from") && !named.main.contains("workerA"), "`Main Thread` marks the main thread")

        // No thread header names the main thread: today's behaviour, the start of the whole call graph (53 characters here: "Call graph:\n"
        // = 12, "    4 Thread_200: worker\n" = 25, "    + 4 workerA\n" = 16).
        let noMain = "Call graph:\n    4 Thread_200: worker\n    + 4 workerA\n" + closing
        let fallback = Phase4bSampleFile.compose(file: noMain, label: label, toolLine: "TOOL-LINE")
        XCTAssertTrue(fallback.main.contains("the call graph (all 53 characters)"), "the whole call graph is attached as before")
        XCTAssertTrue(fallback.main.contains("workerA"), "all threads, as before")
        XCTAssertFalse(fallback.main.contains("the main thread's section"), "no main-thread section without a main-thread header")
    }

    static func canned(_ message: String) -> Phase4bLogLine {
        let stamp = "2026-10-12T10:00:00.000Z"
        return Phase4bLogLine(stamp: stamp, text: "\(stamp) \(message)")
    }

    /// A made-up log: a delete (click at t=50000, sequence start 40 ms later, performed at 50900) with a snapshot span, a Notes rebuild push
    /// and a main-thread stall; then an undo whose Cmd-Z key line is stamped 45 ms before its start, whose bibliography push lands after its
    /// `performed` line (it belongs to the undo, the most recent op), and a typed burst after it. Every expected figure in
    /// `testTraceAnalyser_handWorkedExample` was worked out from these lines by hand.
    static let cannedLog: [Phase4bLogLine] = [
        canned("[undo] [TYPING-TRACE] key t=49000 code=3 editor=false"),
        canned("[undo] [STRUCT-TRACE] t=50000ms +timeline=0ms sectionDelete op=-------- click-start type=rightMouseUp age=6ms"),
        canned("[undo] [STRUCT-TRACE] t=50040ms +0ms sectionDelete op=-------- start"),
        canned("[undo] [STRUCT-TRACE] t=50120ms +80ms sectionDelete op=-------- after modeAwareFlush"),
        canned("[editor] [MilkdownEditor] JS DEBUG: [STRUCT-TRACE] finalize nodes=10"),
        canned("[undo] [STRUCT-TRACE] t=50410ms +timeline=410ms sectionDelete op=ab12cd34 start snapshot.fetchBlocks"),
        canned("[undo] [STRUCT-TRACE] t=50447ms +timeline=447ms sectionDelete op=ab12cd34 end snapshot.fetchBlocks took=37ms"),
        canned("[undo] [STRUCT-TRACE] t=50900ms +860ms sectionDelete op=ab12cd34 performed"),
        canned("[undo] [STRUCT-TRACE] t=51000ms +timeline=1000ms sectionDelete op=ab12cd34 start notes-rebuild-push chars=58000"),
        canned("[undo] [STRUCT-TRACE] t=51120ms +timeline=1120ms sectionDelete op=ab12cd34 end notes-rebuild-push took=120ms"),
        canned("[undo] [STRUCT-TRACE] t=51300ms +timeline=1300ms sectionDelete op=ab12cd34 main-stall 90ms"),
        canned("[undo] [TYPING-TRACE] key t=70000 code=6 editor=true"),
        canned("[undo] [STRUCT-TRACE] t=70045ms +0ms undo op=cafe0001 start"),
        canned("[undo] [STRUCT-TRACE] t=70500ms +455ms undo op=cafe0001 performed"),
        canned("[undo] [STRUCT-TRACE] t=71000ms +timeline=955ms undo op=cafe0001 start bibliography-rebuild-push chars=60000"),
        canned("[undo] [STRUCT-TRACE] t=71200ms +timeline=1155ms undo op=cafe0001 end bibliography-rebuild-push took=200ms"),
        canned("[undo] [TYPING-TRACE] key t=80000 code=0 editor=true"),
        canned("[undo] [TYPING-TRACE] key t=80030 code=11 editor=true"),
        canned("[undo] [TYPING-TRACE] echo t=80040 n=2"),
        canned("[undo] [TYPING-TRACE] key t=80100 code=8 editor=true"),
        canned("[undo] [TYPING-TRACE] key t=80160 code=2 editor=true"),
        canned("[undo] [TYPING-TRACE] echo t=80160 n=1"),
        canned("[undo] [TYPING-TRACE] key t=80200 code=1 editor=true"),
        canned("[undo] [TYPING-TRACE] key t=80300 code=3 editor=false"),
        canned("[undo] [TYPING-TRACE] rebuild-replaced-pending kind=notes block=b7 t=80500")
    ]

    /// The analyser's rules on a made-up log whose figures were worked out by hand (see `cannedLog`): the click is the delete's zero, the Cmd-Z key
    /// line is the undo's trigger, late lines go to the most recent operation, and each key pairs with the first echo AT OR AFTER it.
    func testTraceAnalyser_handWorkedExample() {
        let ops = Phase4bDelAnalyser.analyse(lines: Self.cannedLog)
        XCTAssertEqual(ops.map(\.kind), ["sectionDelete", "undo"], "a delete, then an undo; the editor's own JS line is not an operation")
        guard ops.count == 2 else { return }
        let delete = ops[0]
        let undo = ops[1]

        // Delete: zero is the click (t=50000); the sequence starts at 50040 and is performed at 50900.
        XCTAssertEqual(delete.zero, 50000)
        XCTAssertEqual(delete.clickType, "rightMouseUp")
        XCTAssertEqual(delete.clickAgeMs, 6)
        XCTAssertEqual(delete.opId, "ab12cd34", "the real id is the first one after the dashes of the start line")
        XCTAssertEqual(delete.triggerToStartMs, 40)
        XCTAssertEqual(delete.startToPerformedMs, 860)
        XCTAssertEqual(delete.triggerToPerformedMs, 900)
        XCTAssertEqual(delete.lines.count, 9, "click-start, start, one step, two span lines, performed, two push lines, one stall")
        XCTAssertNil(delete.key, "a delete has no key press")
        XCTAssertEqual(delete.typedKeys.count, 0, "the key line before the click belongs to no operation")
        XCTAssertEqual(delete.spans.count, 2)
        XCTAssertEqual(delete.spans.first?.name, "snapshot.fetchBlocks")
        XCTAssertEqual(delete.spans.first?.tookMs, 37)
        XCTAssertEqual(delete.pushes.count, 1)
        XCTAssertEqual(delete.pushes.first?.name, "notes-rebuild-push")
        XCTAssertEqual((delete.pushes.first?.startT ?? 0) - delete.zero, 1000)
        XCTAssertEqual(delete.pushes.first?.tookMs, 120)
        XCTAssertEqual(delete.pushes.first?.detail, "chars=58000")
        XCTAssertEqual(delete.stalls.count, 1)
        XCTAssertEqual(delete.stalls.first?.durationMs, 90)
        XCTAssertEqual((delete.stalls.first?.beganT ?? 0) - delete.zero, 1210, "stamped at the END (+1300): it began 90 ms earlier")
        XCTAssertEqual(delete.openSpanNames, [])
        XCTAssertEqual(delete.labelMismatches, 0)

        // Undo: the key line (t=70000) is the trigger, 45 ms before the sequence start; the bibliography push landing after `performed` is its.
        XCTAssertEqual(undo.key?.t, 70000)
        XCTAssertEqual(undo.zero, 70045)
        XCTAssertEqual(undo.userZero, 70000)
        XCTAssertEqual(undo.triggerToStartMs, 45)
        XCTAssertEqual(undo.startToPerformedMs, 455)
        XCTAssertEqual(undo.triggerToPerformedMs, 500)
        XCTAssertEqual(undo.opId, "cafe0001")
        XCTAssertEqual(undo.pushes.count, 1, "the late bibliography push belongs to the undo, the most recent op")
        XCTAssertEqual(undo.pushes.first?.name, "bibliography-rebuild-push")
        XCTAssertEqual((undo.pushes.first?.startT ?? 0) - undo.zero, 955, "its own `+timeline=955ms`")
        XCTAssertEqual(delete.pushes.count, 1, "and the delete keeps only its own push")

        // Typing after the undo: a(80000) and b(80030) pair with the echo at 80040 (40 and 10 ms), c(80100) with the echo at 80160 (60 ms),
        // d(80160) with the echo AT 80160 (0 ms), e(80200) with none; the key with editor=false is not typing.
        let typed = undo.typedKeys.filter { $0.inEditor }
        XCTAssertEqual(typed.map(\.code), [0, 11, 8, 2, 1])
        let pairs = Phase4bDelTypingParser.pair(keys: typed, echoes: undo.echoes)
        XCTAssertEqual(pairs.map(\.latencyMs), [40, 10, 60, 0, nil])
        XCTAssertEqual(undo.echoes.count, 2)
        XCTAssertEqual(undo.echoes.first?.edits, 2)
        XCTAssertEqual(undo.replacedPending.first?.kind, "notes")
        XCTAssertEqual(undo.replacedPending.first?.block, "b7")

        // The report: every row after the two header lines carries the fixture's tag, and it prints the hand-worked figures.
        let tag = "[article W1 S2 C3 F4 L5]"
        let context = Phase4bDelContext(
            tag: tag, legend: "legend", sizeTitle: "ARTICLE (x1)", deleteTitle: "1.3 Prices at the Market", countsLine: "counts")
        let report = Phase4bDelTable.render(ops: ops, context: context)
        let untagged = report.dropFirst(2).filter { !$0.isEmpty && !$0.hasPrefix(tag) }
        XCTAssertEqual(untagged.count, 0, "rows without the fixture's tag: \(untagged.prefix(3))")
        XCTAssertTrue(report.contains { $0.contains("trigger -> performed (the whole operation): 900 ms") }, "the delete's whole figure")
        XCTAssertTrue(report.contains { $0.contains("trigger -> performed (the whole operation): 500 ms") }, "the undo's whole figure")
        XCTAssertTrue(report.contains { $0.contains("median 40 ms") && $0.contains("longest 60 ms") }, "the typing summary")
        XCTAssertTrue(report.contains { $0.contains("after modeAwareFlush | +120 ms | +80 ms | 80 ms") }, "a step's own duration: 50120 - 50040")
        XCTAssertTrue(report.contains { $0.contains("performed | +900 ms | +860 ms | 780 ms") },
                      "performed took 50900 - 50120 = 780 ms: the snapshot span lines in between are not sequence steps")
    }
}
