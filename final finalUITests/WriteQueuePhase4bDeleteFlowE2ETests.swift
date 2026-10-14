//
//  WriteQueuePhase4bDeleteFlowE2ETests.swift
//  final finalUITests
//
//  PHASE 4b PART 2, SLICE 2a (bt task t-94369a83): THE BEHAVIOUR OF THE EDITOR-FIRST SECTION DELETE, on documents long enough to matter.
//  In Rich Text mode, Delete Section removes the section on screen at once; a queued job then deletes the rows in the database and writes
//  the Version History copy behind anything typed; commands pressed while an earlier one is finishing WAIT in order and are never refused;
//  Cmd-Z and Cmd-Shift-Z of a section delete stay today's slow snapshot undo (about 0.7 s on the article, 1.9 s on the six-chapter book,
//  3 s on the twelve-chapter book); zoom, Save Version, export, the switch to Markdown, close and quit wait only for the delete's own job.
//
//  EVERY SCENARIO RUNS ON A LONG DOCUMENT (the e2e-verify skill's fixture rule): the generated article (about 7,500 words, 17 sections, 68
//  citation groups, 9 footnotes), the six-chapter book (about 44,700 words, 102 sections, 408 citation groups, 54 footnotes) or the
//  twelve-chapter book (about 89,300 words). The documents, the launch and the app-log follower are those of WriteQueuePhase4bDeleteE2ETests.swift
//  (`Phase4bDelGenerator`, `Phase4bDelHarness`); every note and result line starts with the fixture's tag, so a figure never stands alone.
//
//  WHAT THE TESTS DO NOT DO (binding, from the plan's A22 and the brief):
//   - No test types while a slow Cmd-Z is running and expects that typing to survive: that loss is the known floor debt A22, kept until slice 2b.
//     Typing happens before the delete, between the delete and the next command (the section is already off the screen), or after the undo's own
//     `performed` line; never inside the undo.
//   - No wait exists to dodge that debt, and no test waits a fixed time. Every wait is a condition: the app's own log
//     (`[STRUCT-TRACE] ... performed`, the editor-ready line), a database row, the sidebar card, a status-bar label, a toast.
//
//  HOW A DELETE IS HELD OPEN ON PURPOSE: the scenarios whose point is a command arriving while the delete's job is still running set
//  `FF_UI_TESTING_STRUCT_JOB_HOLD_MS` (a seam of the app, `TestMode.uiTestingStructuralJobHoldMs`: it delays the job's body in the writer, never the
//  editor's own removal), so the job is pending when the next command comes, on a fast machine as on a slow one. Without it, the article's job can
//  be finished before the VM has even sent the next key. The hold is never a wait of the test: the test still waits only for the app's signals.
//
//  READING THE SAVED DOCUMENT: every comparison reads the block table (`blockType`, the two managed flags and the markdown fragment of every row, in
//  order, hex-encoded so a newline or a `|` inside a fragment cannot confuse the parse). The footnote numbers are the app's to renumber, so row
//  comparisons treat `[^7]` as `[^#]`, and a separate walk checks the numbers themselves.
//
//  WHERE THE KEYS GO: the caret is placed once, at the end of the plain paragraph "Anchor05 line of the fixture document." (first chapter,
//  on screen at launch, outside every section deleted here; `placeCaretByClicking` confirms it with the status bar's selection count).
//  The sidebar's context menu does not take the keyboard focus away from the editor, so keys typed straight after a menu click land at
//  that caret.
//
//  RUNNING (VM only; every vmtest call needs the sandbox off; the functional set is one scope, the timing test is in the other class):
//    scripts/vmtest/vmtest run --scope "final finalUITests/WriteQueuePhase4bDeleteFlowE2ETests" --timeout 7200
//    scripts/vmtest/vmtest run --scope "final finalUITests/WriteQueuePhase4bDeleteFlowE2ETests/testDeleteThenTypeAtOnce_article" --timeout 1500
//    scripts/vmtest/vmtest run --scope "final finalUITests/WriteQueuePhase4bDeleteE2ETests/testOldVsNewTiming_book12" --timeout 3600
//
//  THE RAPID-UNDO SET (section 16 at the end; the user's data-loss report: delete, type at once, then Cmd-Z over and over, and only the typed
//  text came back): `testDeleteTypeThenRapidUndos_{book6,article}` (caret at Anchor05), `..._atTheJoin_{book6,article}` (caret at the end of a
//  paragraph seeded directly above the deleted section), `..._jobPending_{book6,article}` (the delete's job held 6 s; these two PIN THE KNOWN
//  BUG t-dfc4fb02 as an expected failure until its fix lands, see the comment above them). Each scope:
//    scripts/vmtest/vmtest run --scope "final finalUITests/WriteQueuePhase4bDeleteFlowE2ETests/testDeleteTypeThenRapidUndos_book6" --timeout 1800
//  A burst of 12 Cmd-Z presses is followed by a second burst only when the section's undo has not been reached (`pressRapidUndoBursts`).
//

// swiftlint:disable file_length
import XCTest

// MARK: - The saved document, row by row

/// One row of the `block` table, as the tests compare them.
struct Phase4bFlowRow {
    let type: String
    let isNotes: Bool
    let isBibliography: Bool
    let fragment: String

    var isManaged: Bool { isNotes || isBibliography }

    /// 1 to 6 for an ATX heading row, else nil.
    var headingLevel: Int? {
        guard type == "heading" else { return nil }
        let level = fragment.prefix(while: { $0 == "#" }).count
        return level > 0 ? level : nil
    }

    var headingTitle: String? {
        headingLevel.map { fragment.dropFirst($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// What two rows must agree on to be "the same row" when the app is free to renumber footnotes.
    var key: String { "\(type)\u{1F}\(Phase4bFlow.normalized(fragment))" }
    /// Byte-for-byte identity (type, flags and text).
    var exactKey: String { "\(type)|\(isNotes)|\(isBibliography)|\(fragment)" }
}

/// Pure helpers on rows (no app, no accessibility): the section rule, the footnote parse, the difference report.
enum Phase4bFlow {
    /// The rows of the section whose heading is titled `title`: the heading row up to the row before the next heading of the same or a higher
    /// level, or before the first Notes / Bibliography row (the app's own rule, `resolveSectionSubtree`).
    static func sectionRange(_ title: String, in rows: [Phase4bFlowRow]) -> Range<Int>? {
        guard let start = rows.firstIndex(where: { $0.headingTitle == title }), let level = rows[start].headingLevel else { return nil }
        var end = start + 1
        while end < rows.count {
            if rows[end].isManaged { break }
            if let other = rows[end].headingLevel, other <= level { break }
            end += 1
        }
        return start..<end
    }

    /// The numbers of the footnote references (`[^7]` not followed by a colon) in one fragment, in reading order.
    static func footnoteRefs(in fragment: String) -> [Int] {
        Phase4bGenerator.matches(#"\[\^\d+\](?!:)"#, in: fragment).compactMap { Int($0.dropFirst(2).dropLast()) }
    }

    /// `[^7]: text` -> (7, "text"); nil for any other fragment.
    static func definition(_ fragment: String) -> (number: Int, text: String)? {
        guard fragment.hasPrefix("[^"), let close = fragment.range(of: "]:") else { return nil }
        let digits = fragment[fragment.index(fragment.startIndex, offsetBy: 2)..<close.lowerBound]
        guard let number = Int(digits) else { return nil }
        return (number, fragment[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Footnote numbers are the app's to renumber, so a comparison reads every `[^7]` as `[^#]`.
    static func normalized(_ fragment: String) -> String {
        fragment.replacingOccurrences(of: #"\[\^\d+\]"#, with: "[^#]", options: .regularExpression)
    }

    /// sqlite's `hex()` output (upper-case) back to text.
    static func decodeHex(_ hex: Substring) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.utf8.count / 2)
        func nibble(_ character: UInt8) -> UInt8 { character >= 65 ? character - 55 : character - 48 }
        var iterator = hex.utf8.makeIterator()
        while let high = iterator.next(), let low = iterator.next() { bytes.append(nibble(high) << 4 | nibble(low)) }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    // MARK: Showing a difference exactly
    //
    // A difference is reported with the row, the offset of the first differing character (UTF-16 units, the unit the app counts in) and 60
    // characters either side of it from BOTH texts, control characters, non-breaking and other invisible spaces written as `\u{XX}`, so a
    // difference that sits far into a long paragraph, or one that cannot be seen, is still shown. The old report cut each row at 160
    // characters and printed two identical-looking prefixes.

    /// Characters a reader cannot see or tell apart: written as `\u{XX}` (newline, return and tab as `\n`, `\r`, `\t`).
    static func escaped(_ units: ArraySlice<UInt16>) -> String {
        var out = ""
        for scalar in String(decoding: units, as: UTF16.self).unicodeScalars {
            switch scalar {
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                let category = scalar.properties.generalCategory
                let invisible = category == .control || category == .format || category == .lineSeparator || category == .paragraphSeparator
                    || category == .privateUse || category == .unassigned || (category == .spaceSeparator && scalar != " ")
                out += invisible ? "\\u{\(String(scalar.value, radix: 16, uppercase: true))}" : String(scalar)
            }
        }
        return out
    }

    /// The UTF-16 offset of the first unit at which the two texts differ (the shorter length when one is a prefix of the other).
    static func firstDifference(_ left: [UInt16], _ right: [UInt16]) -> Int {
        zip(left, right).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(left.count, right.count)
    }

    /// 60 characters before the offset, the character AT it in ⟦ ⟧ (or `end of text`), and 60 characters after, escaped and quoted.
    static func window(_ units: [UInt16], at requestedOffset: Int, radius: Int = 60) -> String {
        let offset = min(max(0, requestedOffset), units.count)
        let start = max(0, offset - radius)
        let before = units[start..<min(offset, units.count)]
        let atText = offset < units.count ? escaped(units[offset...offset]) : "end of text"
        let after = units[min(offset + 1, units.count)..<min(offset + 1 + radius, units.count)]
        return "\"\(start > 0 ? "…" : "")\(escaped(before))⟦\(atText)⟧\(escaped(after))\(offset + 1 + radius < units.count ? "…" : "")\""
    }

    /// Where two texts first differ, and what is around that point in each.
    static func describeText(_ expected: String, _ actual: String) -> String {
        let left = Array(expected.utf16)
        let right = Array(actual.utf16)
        let offset = firstDifference(left, right)
        return "first difference at character \(offset) (lengths \(left.count) expected / \(right.count) found): "
            + "expected \(window(left, at: offset)) found \(window(right, at: offset))"
    }

    /// The footnote marks of a fragment as written (`[^3]`, `[^3]:`, `[^a]`), so a difference in number or in form shows.
    static func marks(in fragment: String) -> String {
        let found = Phase4bGenerator.matches(#"\[\^[^\]\n]*\]:?"#, in: fragment)
        return found.count <= 12 ? "\(found)" : "\(found.prefix(12)) ... (\(found.count) marks)"
    }

    /// The raw UTF-16 offset that corresponds to `offset` in the number-normalised text (`[^7]` read as `[^#]`, 4 characters).
    static func rawOffset(forNormalizedOffset offset: Int, in raw: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"\[\^\d+\]"#) else { return offset }
        var shift = 0
        for match in regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            if match.range.location - shift < offset { shift += match.range.length - 4 } else { break }
        }
        return offset + shift
    }

    /// One line per differing position, up to `limit`, after a header (empty when the two lists are the same). `exact` compares type, flags
    /// and the raw text; otherwise footnote numbers are read as `[^#]` and the raw text is shown beside the normalised one at the same place.
    static func rowDifferences(
        expected: [(row: Int, value: Phase4bFlowRow)], actual: [(row: Int, value: Phase4bFlowRow)], exact: Bool, limit: Int = 10
    ) -> [String] {
        func same(_ left: (row: Int, value: Phase4bFlowRow)?, _ right: (row: Int, value: Phase4bFlowRow)?) -> Bool {
            guard let left, let right else { return false }
            return exact ? left.value.exactKey == right.value.exactKey : left.value.key == right.value.key
        }
        let positions = (0..<max(expected.count, actual.count)).filter { index in
            !same(index < expected.count ? expected[index] : nil, index < actual.count ? actual[index] : nil)
        }
        guard !positions.isEmpty else { return [] }
        var lines = ["\(expected.count) row(s) expected, \(actual.count) found; \(positions.count) position(s) differ"
            + (positions.count > limit ? " (the first \(limit) follow)" : "")]
        for index in positions.prefix(limit) {
            guard index < expected.count, index < actual.count else {
                let one = index < expected.count ? expected[index] : actual[index]
                lines.append("position \(index): only the \(index < expected.count ? "expected" : "found") side has a row there "
                    + "(document row \(one.row), type \(one.value.type), \(window(Array(one.value.fragment.utf16), at: 0)))")
                continue
            }
            let left = expected[index]
            let right = actual[index]
            var line = "position \(index) (document row \(left.row) expected / \(right.row) found): "
            if left.value.type != right.value.type { line += "type expected \(left.value.type) found \(right.value.type); " }
            if left.value.isNotes != right.value.isNotes || left.value.isBibliography != right.value.isBibliography {
                line += "flags (Notes, Bibliography) expected (\(left.value.isNotes), \(left.value.isBibliography)) "
                    + "found (\(right.value.isNotes), \(right.value.isBibliography)); "
            }
            let normalisedLeft = normalized(left.value.fragment)
            let normalisedRight = normalized(right.value.fragment)
            if exact || normalisedLeft == normalisedRight {
                line += "raw text: \(describeText(left.value.fragment, right.value.fragment))"
            } else {
                let offset = firstDifference(Array(normalisedLeft.utf16), Array(normalisedRight.utf16))
                line += "number-normalised text: \(describeText(normalisedLeft, normalisedRight)); "
                let rawLeft = Array(left.value.fragment.utf16)
                let rawRight = Array(right.value.fragment.utf16)
                line += "raw text at the same place: expected "
                    + "\(window(rawLeft, at: rawOffset(forNormalizedOffset: offset, in: left.value.fragment))) found "
                    + "\(window(rawRight, at: rawOffset(forNormalizedOffset: offset, in: right.value.fragment))); "
                line += "raw lengths \(rawLeft.count) / \(rawRight.count); first raw difference at character "
                    + "\(firstDifference(rawLeft, rawRight))"
            }
            line += "; footnote marks expected \(marks(in: left.value.fragment)) found \(marks(in: right.value.fragment))"
            lines.append(line)
        }
        return lines
    }

    /// One line per differing entry of two lists of texts, up to `limit`, after a header (empty when the two lists are the same).
    static func differenceLines(_ expected: [String], _ actual: [String], limit: Int = 10) -> [String] {
        guard expected != actual else { return [] }
        let positions = (0..<max(expected.count, actual.count)).filter { index in
            index >= expected.count || index >= actual.count || expected[index] != actual[index]
        }
        var lines = ["\(expected.count) entr(ies) expected, \(actual.count) found; \(positions.count) position(s) differ"
            + (positions.count > limit ? " (the first \(limit) follow)" : "")]
        for index in positions.prefix(limit) {
            if index < expected.count, index < actual.count {
                lines.append("entry \(index): \(describeText(expected[index], actual[index]))")
            } else {
                let one = index < expected.count ? expected[index] : actual[index]
                let side = index < expected.count ? "expected" : "found"
                lines.append("entry \(index): only the \(side) side has one: \(window(Array(one.utf16), at: 0))")
            }
        }
        return lines
    }

    /// Nil when the two lists are the same; else the lines of `differenceLines` joined into one text.
    static func difference(_ expected: [String], _ actual: [String]) -> String? {
        let lines = differenceLines(expected, actual)
        return lines.isEmpty ? nil : lines.joined(separator: " | ")
    }

    /// The footnote definitions of a saved document judged BY THEIR WORDS, not their numbers, so that "the numbers are wrong" and "the text
    /// is wrong or blank" are two separate facts. `survivors` are the definitions the references that remain must carry; `orphans` are
    /// definitions whose words belong to a reference the delete removed.
    static func definitionFacts(
        pre: [Phase4bFlowRow], removed: Set<Int>, post: [(number: Int, text: String)]
    ) -> Phase4bFlowDefinitionFacts {
        var textByNumber: [Int: String] = [:]
        for row in pre { if let found = definition(row.fragment) { textByNumber[found.number] = found.text } }
        var surviving: [String] = []
        for (index, row) in pre.enumerated() where !row.isManaged && !removed.contains(index) {
            surviving += footnoteRefs(in: row.fragment).compactMap { textByNumber[$0] }
        }
        let postTexts = post.map(\.text)
        // NO "the deleted section's words are still there" check, on purpose: the book fixtures repeat the same prose in every chapter, so the
        // deleted chapter's definition words legitimately appear in the chapters that remain. That a deleted section's footnotes are gone is
        // proved by the COUNT check (definitions and references both equal the number the remaining text must hold).
        return Phase4bFlowDefinitionFacts(
            expected: surviving.count, found: post.count,
            missing: surviving.filter { !postTexts.contains($0) }.map { String($0.prefix(60)) },
            blank: post.filter { $0.text.isEmpty }.map(\.number))
    }

    /// The texts of the footnote definitions a document must carry once the rows in `removed` are gone: the definitions of the references that
    /// remain, in reading order (the app renumbers them 1...n and keeps each one's own words).
    static func expectedDefinitionTexts(pre: [Phase4bFlowRow], removed: Set<Int>) -> [String] {
        var textByNumber: [Int: String] = [:]
        for row in pre { if let found = definition(row.fragment) { textByNumber[found.number] = found.text } }
        var order: [Int] = []
        for (index, row) in pre.enumerated() where !row.isManaged && !removed.contains(index) { order += footnoteRefs(in: row.fragment) }
        return order.compactMap { textByNumber[$0] }
    }
}

/// The scripted walk over every footnote reference of a saved document (addendum A19): the numbers in reading order are 1...n with no gap or
/// repeat, every definition matches a reference, and none is blank.
struct Phase4bFlowWalk {
    var refs: [Int] = []
    var definitions: [(number: Int, text: String)] = []
    var problems: [String] = []

    init(rows: [Phase4bFlowRow]) {
        for row in rows {
            if let found = Phase4bFlow.definition(row.fragment) {
                definitions.append(found)
            } else if !row.isManaged {
                refs += Phase4bFlow.footnoteRefs(in: row.fragment)
            }
        }
        let wanted = Array(stride(from: 1, through: refs.count, by: 1))
        if refs != wanted { problems.append("reference numbers in reading order are \(describe(refs)), not 1...\(refs.count)") }
        let definitionNumbers = definitions.map(\.number)
        if definitionNumbers != Array(stride(from: 1, through: definitions.count, by: 1)) {
            problems.append("definition numbers are \(describe(definitionNumbers)), not 1...\(definitions.count)")
        }
        if refs.count != definitions.count { problems.append("\(refs.count) reference(s) but \(definitions.count) definition(s)") }
        let blank = definitions.filter { $0.text.isEmpty }.map(\.number)
        if !blank.isEmpty { problems.append("blank definition(s): \(blank)") }
    }

    private func describe(_ numbers: [Int]) -> String {
        numbers.count <= 24 ? "\(numbers)" : "\(numbers.prefix(12)) ... \(numbers.suffix(12)) (\(numbers.count) numbers)"
    }

    var summary: String { "\(refs.count) reference(s), \(definitions.count) definition(s)" }
}

/// What `Phase4bFlow.definitionFacts` found: the definition words that must survive a delete against the definitions the document holds.
struct Phase4bFlowDefinitionFacts {
    /// Definitions the references that remain must carry, and how many definitions the document holds.
    let expected: Int
    let found: Int
    /// Surviving definitions whose words are not among the document's definitions (first 60 characters each).
    let missing: [String]
    /// Numbers of definitions with no text at all.
    let blank: [Int]

    /// True when every surviving definition has its own words and none is blank (the numbering is a separate fact).
    var textsIntact: Bool { missing.isEmpty && blank.isEmpty }

    var summary: String {
        "\(expected) surviving definition(s) expected, \(found) found; words missing or changed: \(missing.count)"
            + (missing.isEmpty ? "" : " (e.g. \"\(missing[0])\")") + "; blank: \(blank)"
    }
}

/// Checks that do not stop the test at the first failure (`continueAfterFailure` is false): each one is recorded, and `assertSoft` reports every
/// failure together in ONE assertion at the end, so a single run shows all the facts.
struct Phase4bFlowSoftChecks {
    private(set) var failures: [String] = []

    mutating func check(_ holds: Bool, _ message: @autoclosure () -> String) {
        if !holds { failures.append(message()) }
    }
}

// MARK: - What a scenario expects of the saved document

/// What must be true of the saved document after a scenario: which sections are gone, which sentences were typed, and whether the Notes and
/// Bibliography rows must be unchanged.
struct Phase4bFlowExpectation {
    /// Sections (as ranges of the document BEFORE the scenario) that must be gone.
    var removed: [Range<Int>] = []
    /// Sentences that must sit inside the anchor paragraph.
    var typed: [String] = []
    /// True when the document must be exactly the one before apart from `typed` (nothing removed, nothing renumbered).
    var exactManaged: Bool { removed.isEmpty }
}

// MARK: - The titles the scenarios use

extension Phase4bDelSize {
    /// Two ADJACENT sections of the six-chapter book, both on screen in the sidebar at once: the last section of chapter 3 and all of chapter 4.
    static let pairFirst = "3.6 Conclusion"
    static let pairSecond = "Chapter 4: The Quiet Archive and Its Ledgers"
}

// MARK: - The test class

/// The behaviour of the editor-first section delete (slice 2a). See the file header.
final class WriteQueuePhase4bDeleteFlowE2ETests: Phase4bDelHarness {
    /// The saved document right after the load settled, before the scenario's first command.
    var pre: [Phase4bFlowRow] = []

    /// The job hold of the scenarios that need a command to arrive while the delete's job is pending (see the file header).
    static let holdShortMs = 2_500
    /// For the scenarios that open a dialog or a panel between the delete and the command.
    static let holdLongMs = 6_000
    /// A text with no character the editor transforms (no quote, dash, asterisk, underscore, slash, bracket).
    static func sentence(_ tag: String) -> String { "Flow sentence \(tag) typed in place" }
}

// MARK: - Reading the saved document

extension WriteQueuePhase4bDeleteFlowE2ETests {
    func readRows() -> [Phase4bFlowRow] {
        let output = FixtureDatabase.read(
            fixturePath: TestFixtureHelper.fixturePath,
            sql: "SELECT blockType || '|' || isNotes || '|' || isBibliography || '|' || hex(markdownFragment) FROM block ORDER BY sortOrder, id;")
        var rows: [Phase4bFlowRow] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4 else {
                fail("a block row could not be read from \(TestFixtureHelper.fixturePath)/content.sqlite (line starts \"\(line.prefix(60))\")")
                continue
            }
            rows.append(Phase4bFlowRow(
                type: String(parts[0]), isNotes: parts[1] == "1", isBibliography: parts[2] == "1", fragment: Phase4bFlow.decodeHex(parts[3])))
        }
        return rows
    }

    func isAnchor(_ row: Phase4bFlowRow) -> Bool {
        row.type == "paragraph" && row.fragment.hasPrefix(Self.anchorPrefix + " line of the fixture document.")
    }

    func section(_ title: String) -> Range<Int>? { Phase4bFlow.sectionRange(title, in: pre) }

    /// The problems (empty: none) of a saved document against the one before the scenario, per `expect`.
    func problems(of post: [Phase4bFlowRow], expect: Phase4bFlowExpectation, _ what: String = "document") -> [String] {
        var found = rowProblems(of: post, expect: expect, what)
        let removedIndexes = Set(expect.removed.flatMap { Array($0) })
        let walk = Phase4bFlowWalk(rows: post)
        found += walk.problems.map { "footnotes: \($0)" }
        let expectedTexts = Phase4bFlow.expectedDefinitionTexts(pre: pre, removed: removedIndexes)
        let textLines = Phase4bFlow.differenceLines(expectedTexts, walk.definitions.map(\.text))
        recordDifferences(what, "footnote definition texts", textLines)
        found += textLines.map { "the footnote definition texts are not those of the references that remain: \($0)" }
        return found
    }

    /// Remembers the exact lines of a difference for the `row-differences-<method>.txt` attachment.
    func recordDifferences(_ what: String, _ label: String, _ lines: [String]) {
        guard !lines.isEmpty else { return }
        rowDifferenceLog.append("[\(what)] \(label)\n" + lines.map { "  " + $0 }.joined(separator: "\n"))
    }

    /// The rows of a saved document that satisfy `include`, each with its row number in the document.
    func indexedRows(_ rows: [Phase4bFlowRow], where include: (Phase4bFlowRow) -> Bool = { _ in true }) -> [(row: Int, value: Phase4bFlowRow)] {
        rows.enumerated().filter { include($0.element) }.map { (row: $0.offset, value: $0.element) }
    }

    /// Nil when the two row lists are identical (type, flags and raw text); else the exact difference of each differing row (and it goes to
    /// the attachment too).
    func exactDifference(
        _ what: String, _ label: String, expected: [(row: Int, value: Phase4bFlowRow)], actual: [(row: Int, value: Phase4bFlowRow)]
    ) -> String? {
        let lines = Phase4bFlow.rowDifferences(expected: expected, actual: actual, exact: true)
        recordDifferences(what, label, lines)
        return lines.isEmpty ? nil : lines.joined(separator: " | ")
    }

    /// Nil when the two lists of texts are the same; else the exact difference (and it goes to the attachment too).
    func differenceText(_ what: String, _ label: String, _ expected: [String], _ actual: [String]) -> String? {
        let lines = Phase4bFlow.differenceLines(expected, actual)
        recordDifferences(what, label, lines)
        return lines.isEmpty ? nil : lines.joined(separator: " | ")
    }

    /// The text rows, the anchor paragraph and the Notes / Bibliography rows (everything but the footnote numbering and definition texts).
    /// One entry per differing row (up to 10 per list) with the exact offset and the characters around it, from both sides.
    func rowProblems(of post: [Phase4bFlowRow], expect: Phase4bFlowExpectation, _ what: String = "document") -> [String] {
        var found: [String] = []
        let removedIndexes = Set(expect.removed.flatMap { Array($0) })
        let expectedUser = pre.enumerated().filter { !removedIndexes.contains($0.offset) && !$0.element.isManaged && !isAnchor($0.element) }
            .map { (row: $0.offset, value: $0.element) }
        let actualUser = post.enumerated().filter { !$0.element.isManaged && !isAnchor($0.element) }.map { (row: $0.offset, value: $0.element) }
        let userLines = Phase4bFlow.rowDifferences(expected: expectedUser, actual: actualUser, exact: false)
        recordDifferences(what, "text rows outside the anchor paragraph", userLines)
        found += userLines.map { "text rows outside the anchor paragraph: \($0)" }
        if let anchor = post.first(where: isAnchor) {
            for sentence in expect.typed where !anchor.fragment.contains(sentence) {
                found.append("the anchor paragraph lost the typed sentence \"\(sentence)\" (it reads \"\(anchor.fragment.suffix(120))\")")
            }
        } else {
            found.append("the anchor paragraph \"\(Self.anchorPrefix)\" is gone from the block table")
        }
        if expect.exactManaged {
            let expectedManaged = pre.enumerated().filter { $0.element.isManaged }.map { (row: $0.offset, value: $0.element) }
            let actualManaged = post.enumerated().filter { $0.element.isManaged }.map { (row: $0.offset, value: $0.element) }
            let managedLines = Phase4bFlow.rowDifferences(expected: expectedManaged, actual: actualManaged, exact: true)
            recordDifferences(what, "Notes / Bibliography rows", managedLines)
            found += managedLines.map { "the Notes / Bibliography rows differ from before: \($0)" }
        }
        return found
    }

    /// Asserts `problems(of:expect:)` is empty, and notes the walk's size beside the result.
    func assertDocument(_ post: [Phase4bFlowRow], expect: Phase4bFlowExpectation, _ what: String) {
        let found = problems(of: post, expect: expect, what)
        let walk = Phase4bFlowWalk(rows: post)
        result("\(what): \(post.count) block rows (\(pre.count) before), footnotes \(walk.summary)")
        assertCheck(found.isEmpty, "\(what): the saved document is as it must be (\(found.joined(separator: " | ")))")
    }

    /// How many footnote references the document must hold once the rows in `removed` are gone.
    func remainingRefCount(removed: Set<Int>) -> Int {
        pre.enumerated().filter { !$0.element.isManaged && !removed.contains($0.offset) }
            .reduce(0) { $0 + Phase4bFlow.footnoteRefs(in: $1.element.fragment).count }
    }

    /// Adds every fact about a saved document to `soft` WITHOUT stopping the test: the rows, the footnote numbering, the reference count, the
    /// definitions' WORDS (numbering-independent: missing, changed or blank texts) and whether the deleted section's footnotes are still
    /// there. Notes the footnote facts once, so one run shows each of them whichever others fail.
    func addDocumentChecks(
        _ post: [Phase4bFlowRow], expect: Phase4bFlowExpectation, _ what: String, to soft: inout Phase4bFlowSoftChecks
    ) {
        let removed = Set(expect.removed.flatMap { Array($0) })
        let walk = Phase4bFlowWalk(rows: post)
        let facts = Phase4bFlow.definitionFacts(pre: pre, removed: removed, post: walk.definitions)
        let remaining = remainingRefCount(removed: removed)
        note("\(what): FOOTNOTE FACTS: \(walk.refs.count) reference(s) (\(remaining) expected), "
            + "numbers \(walk.refs.prefix(6))...\(walk.refs.suffix(3)); "
            + "definitions: \(facts.summary)")
        // One numbered entry per differing row, each with its exact offset and the characters around it.
        for rowProblem in rowProblems(of: post, expect: expect, what) { soft.check(false, "\(what): \(rowProblem)") }
        soft.check(walk.problems.isEmpty, "\(what): footnote NUMBERING is wrong (\(walk.problems))")
        soft.check(walk.refs.count == remaining, "\(what): footnote COUNT is \(walk.refs.count), expected \(remaining)")
        soft.check(facts.textsIntact, "\(what): footnote definition TEXTS are wrong or blank (\(facts.summary))")
        // The deleted section's footnotes are gone when the DEFINITIONS number as many as the references that remain. (Not judged by their words:
        // the book fixtures repeat the same prose in every chapter, so a deleted chapter's words also sit in the chapters that remain.)
        soft.check(walk.definitions.count == remaining, "\(what): footnote definition COUNT is \(walk.definitions.count), expected \(remaining)")
    }

    func blocksContaining(_ text: String) -> Int {
        dbInt("SELECT count(*) FROM block WHERE instr(markdownFragment, '\(FixtureDatabase.escape(text))') > 0;") ?? -1
    }

    func waitForSentenceInDatabase(_ sentence: String, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if blocksContaining(sentence) >= 1 { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return false
    }

    /// Waits until the named sections' heading rows are gone / back (the delete's job, or an undo's restore, has applied) and the block table
    /// and the app's log have stopped changing. Every wait is a condition.
    @discardableResult
    func settle(gone: [String] = [], back: [String] = []) -> Bool {
        var allDone = true
        for title in gone { allDone = waitForHeadingRows(title, equalTo: 0, timeout: capped(size.operationTimeout)) == 0 && allDone }
        for title in back { allDone = waitForHeadingRows(title, equalTo: 1, timeout: capped(size.operationTimeout)) == 1 && allDone }
        _ = waitForBlocksToSettle()
        _ = waitForLogQuiet(quiet: 3, cap: capped(30))
        return allDone
    }
}

// MARK: - Reading the app's trace

extension WriteQueuePhase4bDeleteFlowE2ETests {
    func traceLines(from index: Int) -> [Phase4bDelTraceLine] {
        tail.poll()
        guard index <= tail.lines.count else { return [] }
        return tail.lines[index...].compactMap { Phase4bDelTraceLine($0) }
    }

    /// How many `<label> op=... performed` lines the app wrote since log index `index`.
    func performedCount(_ label: String, from index: Int) -> Int {
        traceLines(from: index).filter { $0.family == .sequence && $0.label == label && $0.step == "performed" }.count
    }

    func startedCount(_ label: String, from index: Int) -> Int {
        traceLines(from: index).filter { $0.family == .sequence && $0.label == label && $0.step.hasPrefix("start") }.count
    }

    /// The `routing-refused` lines of the editor's trace since `index` (any direction).
    private func routingRefusedLines(from index: Int) -> [Phase4bLogLine] {
        tail.poll()
        guard index <= tail.lines.count else { return [] }
        return tail.lines[index...].filter { $0.text.contains("[STRUCT-TRACE] routing-refused") }
    }

    /// A `routing-refused` line that says `failed=latched` is NOT a refusal. The word is the trace's, and misleading: the editor's undo
    /// coordinator (plan D9) keeps one structural undo or redo in flight at a time, holds a Cmd-Z or Cmd-Shift-Z pressed meanwhile in a
    /// first-in-first-out queue, and runs it when the in-flight one's reply arrives, so the press is neither dropped nor refused. The trace
    /// line it writes at the press (`decision=swallow ... failed=latched latched=true`) only records that the press was HELD. Every other
    /// `failed=` value (`docs-not-equal`, `pendingMapsEmpty=false`, `no-registry-entry`) means the press was not routed structurally.
    /// A queued press must not hide a lost one: the tests that press quickly wait for the right number of `performed` lines and fail
    /// with a clear message when one never arrives (`waitForPerformed`, the performed-order assertions).
    static func isQueuedBehindRunningUndo(_ line: Phase4bLogLine) -> Bool { line.text.contains(" failed=latched ") }

    /// The start of the "nothing refused" assertion messages of the tests that press quickly.
    static let notRefused = "no key press was refused (a press held behind a running undo is not a refusal)"

    /// The first `routing-refused` line since `index` that is a real refusal (not one queued behind a running undo; see above).
    func realRoutingRefusal(from index: Int) -> Phase4bLogLine? {
        routingRefusedLines(from: index).first { !Self.isQueuedBehindRunningUndo($0) }
    }

    /// How many presses the editor held in its queue behind a running undo or redo since `index` (`failed=latched`).
    func queuedPressCount(from index: Int) -> Int {
        routingRefusedLines(from: index).filter(Self.isQueuedBehindRunningUndo).count
    }

    /// Notes how many presses were queued, as evidence beside the performed lines that prove each queued press ran.
    func noteQueuedPresses(from index: Int) {
        note("QUEUED PRESSES: \(queuedPressCount(from: index)) press(es) were held behind a running undo or redo (routing-refused failed=latched, "
            + "plan D9); each must show as a performed line")
    }

    /// A refusal or failure the app logged since `index`: the editor's REAL `routing-refused` line (only when `includeRouting`; a press queued
    /// behind a running undo is not one) or the controller's.
    func problemLine(from index: Int, includeRouting: Bool = true) -> String? {
        guard index <= tail.lines.count else { return nil }
        if includeRouting, let refusal = realRoutingRefusal(from: index) { return refusal.text }
        return Phase4bLog(lines: Array(tail.lines[index...])).failureLine(since: "")?.text
    }

    /// Waits for `count` `<label> performed` lines since `index`; false on a logged refusal or failure (noted) or on the timeout (noted).
    @discardableResult
    func waitForPerformed(_ label: String, count: Int = 1, from index: Int, timeout: TimeInterval, includeRouting: Bool = true) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if performedCount(label, from: index) >= count { return true }
            if let problem = problemLine(from: index, includeRouting: includeRouting) {
                note("PROBLEM while waiting for \(count) \(label) performed line(s): \(problem)")
                return false
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        } while Date() < deadline
        note("TIMED OUT after \(Int(timeout)) s waiting for \(count) \(label) performed line(s); saw \(performedCount(label, from: index))")
        return false
    }

    /// Asserts that `count` `<label> performed` lines turn up since `index`, within the size's operation timeout (twice that when `slow`).
    func expectPerformed(_ label: String, count: Int = 1, from index: Int, _ message: String, slow: Bool = false) {
        let timeout = capped(size.operationTimeout * (slow ? 2 : 1))
        assertCheck(waitForPerformed(label, count: count, from: index, timeout: timeout), message)
    }

    /// The labels of the operations that performed since `index`, in the order they did.
    func performedOrder(from index: Int) -> [String] {
        traceLines(from: index).filter { $0.family == .sequence && $0.step == "performed" }.map(\.label)
    }
}

// MARK: - Driving the app

extension WriteQueuePhase4bDeleteFlowE2ETests {
    func sidebarCard(_ title: String) -> XCUIElement {
        app.groups["outline-sidebar"].scrollViews.firstMatch.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", title, title)).firstMatch
    }

    func waitForCard(_ title: String, present: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if sidebarCard(title).exists == present { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return false
    }

    /// Types straight into whatever has the keyboard focus (the editor, where the caret was placed). One `typeText` call: a verified retype
    /// would wait, and these scenarios are about what happens when typing comes right after another command.
    func typeNow(_ text: String) {
        // e2e-lint: allow raw-typetext -- typed at once on purpose; the saved document is what the scenario checks, not the keystrokes.
        app.typeText(text)
    }

    // MARK: The anchor line on screen (Rich Text editor)
    //
    // WHY NOT `editorContainsText`: on a book it snapshots the whole accessibility tree under `editor-area`, and that single snapshot took
    // about 63 s on the six-chapter book (first VM runs, 2026-10-13). A 90 s wait fits two of them; a miss reports nothing, and a failure there
    // stopped `testDeleteThenTypeAtOnce_book6` before its database check ran. The anchor paragraph is ONE text run, so its whole value can be
    // matched exactly: an exact-value query on `editor-area`'s staticTexts resolves in about 1.5 s on the same book. `==` only: a heading's
    // value is a number, and CONTAINS or BEGINSWITH on it throws (e2e-verify skill, "Never use a CONTAINS predicate against staticTexts").
    //
    // The sentence is typed once, by one `typeText` call, onto the end of the line, so the line reads "<anchor line> <sentence>" as one run.
    // If the editor exposed the typed text as a leaf of its own, a leaf whose value is exactly " " + sentence is accepted too, beside the
    // database check that every caller makes first.

    enum AnchorLine {
        /// The line carries the sentence (as one run, or as a run of its own).
        case withSentence
        /// The line is exactly as seeded: the anchor text and nothing else.
        case plain
        /// Neither (for example while a text undo has taken only part of the sentence), or the tree could not be read in time.
        case other
    }

    static let anchorLine = Phase4bDelHarness.anchorPrefix + " line of the fixture document."

    private func exactLeaf(_ value: String) -> XCUIElement {
        // e2e-lint: allow statictext-firstmatch -- scoped to `editor-area` (never the sidebar's mirror) and an exact `==` on the value.
        app.editorArea.staticTexts.matching(NSPredicate(format: "value == %@", value)).firstMatch
    }

    /// One reading of the anchor line, retried for up to `timeout`. `.withSentence` is checked first, so the answer never depends on the
    /// order the editor lists its leaves; `.plain` means the anchor text itself was found with no sentence beside it.
    /// `line` (default the Anchor05 line) is the plain text the sentence was typed after: the rapid-undo scenarios that type at the join
    /// pass "Join01 line of the fixture document.".
    func readAnchorLine(_ sentence: String, timeout: TimeInterval, line: String = WriteQueuePhase4bDeleteFlowE2ETests.anchorLine) -> AnchorLine {
        let whole = exactLeaf("\(line) \(sentence)")
        let separate = exactLeaf(" " + sentence)
        let plain = exactLeaf(line)
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if whole.exists || separate.exists { return .withSentence }
            if plain.exists { return .plain }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return .other
    }

    /// Waits until the anchor line shows the sentence. On the article the whole-tree search is still fine (it passed); on a book the exact leaf.
    func waitForTypedLine(_ sentence: String, timeout: TimeInterval) -> Bool {
        if size == .article { return app.editorContainsText(sentence, timeout: timeout) }
        let whole = exactLeaf("\(Self.anchorLine) \(sentence)")
        let separate = exactLeaf(" " + sentence)
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if whole.exists || separate.exists { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return false
    }

    /// "The sentence is NOT on screen" that cannot pass for the wrong reason. A search that finds nothing proves nothing when the tree could
    /// not be read, so this first waits for the plain anchor line itself to be found (the positive control: the tree IS being read, and that
    /// leaf is the very one the sentence would have been part of), and only then asks for the sentence. `.plain` is returned only when the
    /// anchor text was found and neither sentence form was.
    func sentenceGoneFromScreen(
        _ sentence: String, timeout: TimeInterval, line: String = WriteQueuePhase4bDeleteFlowE2ETests.anchorLine
    ) -> Bool {
        readAnchorLine(sentence, timeout: timeout, line: line) == .plain
    }

    /// The database half of "gone": no block row holds the sentence any more.
    func waitForSentenceGoneFromDatabase(_ sentence: String, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if blocksContaining(sentence) == 0 { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return false
    }

    func pressUndo() { app.typeKey("z", modifierFlags: .command) }
    func pressRedo() { app.typeKey("z", modifierFlags: [.command, .shift]) }

    /// Cmd-Q, then the app is gone. False (reported) if it is still running after the wait.
    func quitWithCommandQ() -> Bool {
        app.typeKey("q", modifierFlags: .command)
        guard app.wait(for: .notRunning, timeout: capped(180)) else {
            fail("the app was still running 180 s after Cmd-Q")
            return false
        }
        // The app wrote its last lines (the quit's own saving) while it shut down; the follower reads them now that the file is quiet.
        tail.poll()
        note("QUIT: the app is gone (Cmd-Q); the app log holds \(tail.lines.count) line(s) so far")
        return true
    }

    /// Starts the app again on the same project and waits until the editor shows the document: the editor area, a word count, the app's own
    /// "editor-ready gate satisfied" line of THIS run. The log follower is the same one for the whole test (the app appends to the same
    /// `diagnostic.log` across launches): replacing it at the relaunch threw away every line of the first run, so the evidence of the delete
    /// and the quit was empty. A line of the first run cannot answer for this run because the wait only looks past the index noted here.
    func relaunch() -> Bool {
        app.launchEnvironment["FF_UI_TESTING_STRUCT_JOB_HOLD_MS"] = nil
        tail.poll()
        let relaunchIndex = tail.lines.count
        note("RELAUNCH: app-log line \(relaunchIndex) is the first line the reopened app can write")
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        guard app.editorArea.waitForExistence(timeout: capped(60)) else { fail("the editor area never appeared after the relaunch"); return false }
        guard app.staticTexts["status-bar-word-count"].waitForValueNot("== '0 words'", timeout: capped(size.loadTimeout)) else {
            fail("the status bar still shows 0 words \(Int(size.loadTimeout)) s after the relaunch")
            return false
        }
        let ready = waitForLog(containing: "editor-ready gate satisfied", from: relaunchIndex, timeout: capped(size.loadTimeout))
        note("REOPENED: the editor shows the document; \"editor-ready gate satisfied\" line: \(Self.yesNo(ready))")
        return true
    }

    func reopen() -> Bool { quitWithCommandQ() && relaunch() }

    /// Begins the method, seeds and launches the document (with the job hold if wanted), and reads the saved document. The footnote numbers of
    /// the document as loaded are checked first: every later comparison assumes they are 1...n. False after a reported failure.
    func startScenario(_ size: Phase4bDelSize, method: String, holdMs: Int = 0, seed: ((Phase4bDoc) -> Phase4bDoc)? = nil) -> Bool {
        begin(method: method, size: size)
        if let seed, let generated = doc {
            let seeded = seed(generated)
            doc = seeded
            note("SEED variant: \(seeded.counts.reportLine)")
        }
        if holdMs > 0 {
            app.launchEnvironment["FF_UI_TESTING_STRUCT_JOB_HOLD_MS"] = String(holdMs)
            note("JOB HOLD: the delete's job body is delayed \(holdMs) ms (FF_UI_TESTING_STRUCT_JOB_HOLD_MS)")
        }
        guard launchScenario(), requireSectionRows() != nil else { return false }
        pre = readRows()
        // The app-log export (`app-log-<method>.txt`) covers everything from here: placing the caret, typing, the delete, a quit and a reopen.
        tail.poll()
        evidenceLogStart = tail.lines.count
        let walk = Phase4bFlowWalk(rows: pre)
        note("BEFORE: \(pre.count) block rows; footnotes \(walk.summary); Notes rows \(pre.filter(\.isNotes).count); Bibliography rows "
            + "\(pre.filter(\.isBibliography).count)")
        guard walk.problems.isEmpty else {
            fail("the loaded document's footnotes are not 1...n before anything was done: \(walk.problems)")
            return false
        }
        return true
    }

    /// Scrolls the card into view and chooses Delete Section. The card's sections must exist in `pre`.
    @discardableResult
    func deleteViaMenu(_ title: String) -> Int? {
        guard let card = bringSidebarCardIntoView(title) else { return nil }
        return chooseSidebarItem(card, item: "Delete Section")
    }
}

// MARK: - 1. Delete, then type at once

extension WriteQueuePhase4bDeleteFlowE2ETests {
    func testDeleteThenTypeAtOnce_article() { runDeleteThenTypeAtOnce(.article, method: #function) }
    func testDeleteThenTypeAtOnce_book6() { runDeleteThenTypeAtOnce(.book6, method: #function) }

    /// The caret is in the first chapter; the section in the middle is deleted; a sentence is typed at once (the delete's job is held, so it is
    /// still pending). After the job: the section is gone, the sentence is in the editor and in the database, nothing else changed; the
    /// reopened project agrees.
    func runDeleteThenTypeAtOnce(_ size: Phase4bDelSize, method: String) {
        guard startScenario(size, method: method, holdMs: Self.holdShortMs), let range = section(size.deleteTitle),
              placeCaretAtAnchorEnd(), let card = bringSidebarCardIntoView(size.deleteTitle) else { return }
        let sentence = Self.sentence("ONE")
        let from = chooseSidebarItem(card, item: "Delete Section")
        clickBackIntoAnchor()
        typeNow(" " + sentence)
        expectPerformed("sectionDelete", from: from, "the delete reached its performed line")
        assertCheck(waitForCard(size.deleteTitle, present: false, timeout: capped(30)), "the section's sidebar card is gone")
        // The database first: a failure of the on-screen check below must always say whether the text was saved.
        assertCheck(settle(gone: [size.deleteTitle]), "the delete's job finished: no heading row \"\(size.deleteTitle)\" is left")
        assertCheck(waitForSentenceInDatabase(sentence, timeout: capped(60)), "the typed sentence reached the database")
        let expectation = Phase4bFlowExpectation(removed: [range], typed: [sentence])
        assertDocument(readRows(), expect: expectation, "after the delete and the typing")
        assertCheck(waitForTypedLine(sentence, timeout: capped(90)),
                    "the typed sentence is on screen in the editor (the anchor line reads \"\(Self.anchorLine) \(sentence)\")")
        attachEvidenceScreenshot(app.screenshot(), name: "type-at-once-\(size.identifier)-before-reopen")

        guard reopen() else { return }
        assertCheck(!sidebarCard(size.deleteTitle).exists, "after the reopen the section is still not in the sidebar")
        assertDocument(readRows(), expect: expectation, "after the reopen")
        assertCheck(waitForTypedLine(sentence, timeout: capped(90)),
                    "after the reopen the typed sentence is in the editor (the anchor line reads \"\(Self.anchorLine) \(sentence)\")")
        attachEvidenceScreenshot(app.screenshot(), name: "type-at-once-\(size.identifier)-after-reopen")
    }
}

// MARK: - 2. Delete, then Cmd-Z at once

extension WriteQueuePhase4bDeleteFlowE2ETests {
    func testDeleteUndoAtOnce_article() { runDeleteUndoAtOnce(.article, method: #function) }
    func testDeleteUndoAtOnce_book6() { runDeleteUndoAtOnce(.book6, method: #function) }

    /// Delete, and Cmd-Z at once (the job is held, so the undo has to wait for it). The section comes back with every row it had, text,
    /// citations and footnote definitions included, and the saved document is the one before the delete; the reopened project agrees.
    func runDeleteUndoAtOnce(_ size: Phase4bDelSize, method: String) {
        guard startScenario(size, method: method, holdMs: Self.holdShortMs), let card = bringSidebarCardIntoView(size.deleteTitle) else { return }
        let from = chooseSidebarItem(card, item: "Delete Section")
        pressUndo()
        expectPerformed("undo", from: from, "the Cmd-Z pressed at once ran (nothing refused it)")
        assertCheck(waitForCard(size.deleteTitle, present: true, timeout: capped(60)), "the section's sidebar card is back")
        assertCheck(settle(back: [size.deleteTitle]), "the heading row \"\(size.deleteTitle)\" is back in the block table")
        let expectation = Phase4bFlowExpectation()
        assertDocument(readRows(), expect: expectation, "after delete then Cmd-Z at once")
        attachEvidenceScreenshot(app.screenshot(), name: "delete-undo-at-once-\(size.identifier)")

        guard reopen() else { return }
        assertCheck(sidebarCard(size.deleteTitle).exists, "after the reopen the section is in the sidebar")
        assertDocument(readRows(), expect: expectation, "after the reopen")
    }
}

// MARK: - 3. Two deletes in a row

extension WriteQueuePhase4bDeleteFlowE2ETests {
    func testTwoDeletesInARow_book6() {
        let size = Phase4bDelSize.book6
        let first = Phase4bDelSize.pairFirst
        let second = Phase4bDelSize.pairSecond
        guard startScenario(size, method: #function, holdMs: Self.holdShortMs), let firstRange = section(first), let secondRange = section(second),
              let firstCard = bringSidebarCardIntoView(first) else { return }
        // Both cards are on screen at once (adjacent in the sidebar); the second is looked up again at its click, after the first one has left.
        let secondCard = sidebarCard(second)
        assertCheck(secondCard.exists, "the second section's card is on screen beside the first")
        let from = chooseSidebarItem(firstCard, item: "Delete Section")
        chooseSidebarItem(secondCard, item: "Delete Section", activate: false)
        assertCheck(waitForCard(first, present: false, timeout: capped(30)), "the first section's card is gone from the sidebar")
        assertCheck(waitForCard(second, present: false, timeout: capped(30)), "the second section's card is gone from the sidebar")
        expectPerformed("sectionDelete", count: 2, from: from, "both deletes reached their performed line")
        assertCheck(settle(gone: [first, second]), "both sections are gone from the block table once the jobs have run")
        assertDocument(readRows(), expect: Phase4bFlowExpectation(removed: [firstRange, secondRange]), "after two deletes in a row")

        // Cmd-Z twice brings both back in the right order: the second one first, then the first one.
        let undoFrom = tail.lines.count
        pressUndo()
        expectPerformed("undo", from: undoFrom, "the first Cmd-Z ran")
        assertCheck(waitForCard(second, present: true, timeout: capped(60)), "the first Cmd-Z brought the SECOND deleted section back")
        assertCheck(!sidebarCard(first).exists, "the first deleted section is still gone after one Cmd-Z")
        pressUndo()
        expectPerformed("undo", count: 2, from: undoFrom, "the second Cmd-Z ran")
        assertCheck(waitForCard(first, present: true, timeout: capped(60)), "the second Cmd-Z brought the FIRST deleted section back")
        assertCheck(settle(back: [first, second]), "both sections are back in the block table")
        assertDocument(readRows(), expect: Phase4bFlowExpectation(), "after both Cmd-Z")
        attachEvidenceScreenshot(app.screenshot(), name: "two-deletes-undone-book6")
    }
}

// MARK: - 4. Cmd-Z twice with real keystrokes

extension WriteQueuePhase4bDeleteFlowE2ETests {
    /// Two sections are deleted and the jobs have run; then two real Cmd-Z key presses, the second pressed while the first undo is still
    /// running (the editor's JavaScript queue holds it). Both sections return, in order, with their text.
    func testUndoTwiceRealKeys_book6() {
        let size = Phase4bDelSize.book6
        let first = Phase4bDelSize.pairFirst
        let second = Phase4bDelSize.pairSecond
        guard startScenario(size, method: #function), let firstRange = section(first), let secondRange = section(second),
              let firstCard = bringSidebarCardIntoView(first) else { return }
        let secondCard = sidebarCard(second)
        assertCheck(secondCard.exists, "the second section's card is on screen beside the first")
        let from = chooseSidebarItem(firstCard, item: "Delete Section")
        chooseSidebarItem(secondCard, item: "Delete Section", activate: false)
        expectPerformed("sectionDelete", count: 2, from: from, "both deletes reached their performed line")
        assertCheck(settle(gone: [first, second]), "both sections are gone from the block table")
        assertDocument(readRows(), expect: Phase4bFlowExpectation(removed: [firstRange, secondRange]), "after two deletes")

        app.activateAndWaitForForeground()
        let undoFrom = tail.lines.count
        pressUndo()
        pressUndo()
        expectPerformed("undo", count: 2, from: undoFrom, "both real Cmd-Z key presses ran")
        noteQueuedPresses(from: undoFrom)
        let problem = problemLine(from: undoFrom)
        assertCheck(problem == nil, "\(Self.notRefused) and no undo failed (\(problem ?? "none"))")
        assertCheck(waitForCard(first, present: true, timeout: capped(60)) && waitForCard(second, present: true, timeout: capped(60)),
                    "both sections are back in the sidebar")
        assertCheck(settle(back: [first, second]), "both sections are back in the block table")
        let rows = readRows()
        assertDocument(rows, expect: Phase4bFlowExpectation(), "after two real Cmd-Z")
        let order = rows.compactMap(\.headingTitle).filter { $0 == first || $0 == second }
        assertCheck(order == [first, second], "the two sections are back in the order they had: \(order)")
        attachEvidenceScreenshot(app.screenshot(), name: "undo-twice-real-keys-book6")
    }
}

// MARK: - 5. Cmd-Z, Cmd-Shift-Z, Cmd-Z, one right after the other

extension WriteQueuePhase4bDeleteFlowE2ETests {
    /// A sentence is typed (and has reached the database), a section is deleted, and Cmd-Z, Cmd-Shift-Z, Cmd-Z are pressed as fast as a
    /// person's fingers go. None is refused or lost: undo, redo, undo ran in that order, the section is back, and the sentence is intact.
    func testUndoRedoUndoAtOnce_book6() {
        let size = Phase4bDelSize.book6
        guard startScenario(size, method: #function), placeCaretAtAnchorEnd() else { return }
        let sentence = Self.sentence("FIVE")
        typeNow(" " + sentence)
        assertCheck(waitForSentenceInDatabase(sentence, timeout: capped(90)), "the sentence reached the database before the delete")
        guard let card = bringSidebarCardIntoView(size.deleteTitle) else { return }
        let from = chooseSidebarItem(card, item: "Delete Section")
        pressUndo()
        pressRedo()
        pressUndo()
        expectPerformed("undo", count: 2, from: from, "both Cmd-Z ran", slow: true)
        expectPerformed("redo", from: from, "the Cmd-Shift-Z ran")
        let order = performedOrder(from: from)
        note("OPERATIONS in the order they performed: \(order)")
        assertCheck(order == ["sectionDelete", "undo", "redo", "undo"],
                    "the four operations ran in the order pressed (a press that never ran is missing): \(order)")
        noteQueuedPresses(from: from)
        let problem = problemLine(from: from)
        assertCheck(problem == nil, "\(Self.notRefused) and nothing failed (\(problem ?? "none"))")
        assertCheck(waitForCard(size.deleteTitle, present: true, timeout: capped(60)), "the section's card is back in the sidebar")
        assertCheck(settle(back: [size.deleteTitle]), "the section's heading row is back in the block table")
        assertDocument(readRows(), expect: Phase4bFlowExpectation(typed: [sentence]), "after Cmd-Z, Cmd-Shift-Z, Cmd-Z")
        assertCheck(waitForTypedLine(sentence, timeout: capped(90)),
                    "the typed sentence is still in the editor (the anchor line reads \"\(Self.anchorLine) \(sentence)\")")
    }
}

// MARK: - 6. Delete, type, then Cmd-Z step by step

extension WriteQueuePhase4bDeleteFlowE2ETests {
    /// The most Cmd-Z (or Cmd-Shift-Z) presses `testDeleteTypeUndo_book6` makes. The typed sentence is undone by several plain text steps first,
    /// as many as the editor grouped the typing into (a pause starts a new group), which depends on typing speed on a loaded machine.
    static let maxUndoPresses = 40

    /// What one Cmd-Z or Cmd-Shift-Z did, read from the screen once it had finished.
    struct Phase4bFlowPress {
        let number: Int
        let structural: Bool
        /// The editor's own routing decision for the press, from its `[UnifiedUndo] keydown` line: `fallthrough` (a plain text undo or redo),
        /// `structural`, `swallow` (held behind a running one), or `none` when no such line appeared.
        let decision: String
        /// The text history depth the editor reported just before this press (`undoDepth=` for an undo, `redoDepth=` for a redo).
        let depth: Int?
        let line: AnchorLine
        let sectionOnScreen: Bool

        /// Anything but exactly the plain anchor line: the sentence, or part of it, is still there (or the line could not be read).
        var sentenceStillThere: Bool { line != .plain }
        /// The whole sentence is on the anchor line.
        var sentenceBack: Bool { line == .withSentence }
    }

    /// What the editor's own keydown line said about one Cmd-Z or Cmd-Shift-Z (`[UnifiedUndo] keydown direction=<d> decision=<x> undoDepth=<n>
    /// redoDepth=<m> ...`, written for every press in the Rich Text editor before the press is acted on).
    struct Phase4bFlowKeydown {
        let decision: String
        let undoDepth: Int?
        let redoDepth: Int?
        /// The document's size in the editor when the press arrived (`docLength=`), or nil when the line carries none.
        let docLength: Int?

        /// Reads one `[UnifiedUndo] keydown ...` line (the one parse every reader of these lines shares).
        init(parsing text: String) {
            decision = Phase4bDelTypingParser.word(after: "decision=", in: text) ?? "none"
            undoDepth = Phase4bDelTypingParser.intAfter("undoDepth=", in: text)
            redoDepth = Phase4bDelTypingParser.intAfter("redoDepth=", in: text)
            docLength = Phase4bDelTypingParser.intAfter("docLength=", in: text)
        }
    }

    /// The first `[UnifiedUndo] keydown` line for `direction` since log index `index`, or nil when the editor wrote none yet.
    func keydownLine(direction: String, from index: Int) -> Phase4bFlowKeydown? {
        tail.poll()
        guard index <= tail.lines.count else { return nil }
        let marker = "[UnifiedUndo] keydown direction=\(direction) "
        guard let line = tail.lines[index...].first(where: { $0.text.contains(marker) }) else { return nil }
        return Phase4bFlowKeydown(parsing: line.text)
    }

    /// EVERY `[UnifiedUndo] keydown` line for `direction` since log index `index`, in the order the editor wrote them: one per press that
    /// reached the editor. Reads only what the log holds now; it never waits (a burst's decisions are collected after the burst).
    func keydownLines(direction: String, from index: Int) -> [Phase4bFlowKeydown] {
        tail.poll()
        guard index <= tail.lines.count else { return [] }
        let marker = "[UnifiedUndo] keydown direction=\(direction) "
        return tail.lines[index...].filter { $0.text.contains(marker) }.map { Phase4bFlowKeydown(parsing: $0.text) }
    }

    /// One key press, then only as much waiting as the press needs, told by the editor's own keydown line, polled every 0.2 s:
    /// - `decision=fallthrough` is a plain text step (the editor's own history): done at once, no waiting.
    /// - `decision=structural` or `swallow` means a structural undo or redo is coming: wait for its `start` and then its `performed` line, as
    ///   long as the operation timeout (a loaded machine can take seconds to get to it).
    /// - No keydown line within 3 s: treated as not structural.
    /// Then the screen is read when `readScreen` or when the press was structural: is the sentence on the anchor line, is the section's card in
    /// the sidebar. A text step in an undo loop does not need it (it cannot bring the section back), which keeps those presses cheap.
    func pressStep(redo: Bool, number: Int, sentence: String, title: String, readScreen: Bool = true) -> Phase4bFlowPress {
        let label = redo ? "redo" : "undo"
        tail.poll()
        let from = tail.lines.count
        if redo { pressRedo() } else { pressUndo() }
        var keydown: Phase4bFlowKeydown?
        var structural = false
        let deadline = Date(timeIntervalSinceNow: 3)
        repeat {
            keydown = keydownLine(direction: label, from: from)
            if startedCount(label, from: from) > 0 { structural = true; break }
            if keydown?.decision == "fallthrough" { break }
            if keydown?.decision == "structural" || keydown?.decision == "swallow" {
                // A structural one is on its way: give it the whole operation timeout to start.
                let startBy = Date(timeIntervalSinceNow: capped(size.operationTimeout))
                while startedCount(label, from: from) == 0, Date() < startBy { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2)) }
                structural = startedCount(label, from: from) > 0
                break
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        } while Date() < deadline
        if structural { waitForPerformed(label, from: from, timeout: capped(size.operationTimeout), includeRouting: false) }
        let read = readScreen || structural
        let line = read ? readAnchorLine(sentence, timeout: 20) : .other
        let card = read ? sidebarCard(title).exists : false
        let depth = redo ? keydown?.redoDepth : keydown?.undoDepth
        note("PRESS \(number) (\(label)): the editor decided \(keydown?.decision ?? "none") (\(redo ? "redo" : "undo") depth before it: "
            + "\(depth.map(String.init) ?? "n/a")); \(structural ? "structural" : "text/other")"
            + (read ? "; the anchor line shows: \(line); section card in the sidebar: \(Self.yesNo(card))" : "; screen not read (a text step)"))
        return Phase4bFlowPress(
            number: number, structural: structural, decision: keydown?.decision ?? "none", depth: depth, line: line, sectionOnScreen: card)
    }

    /// Delete a section, type a sentence in another chapter, then Cmd-Z one press at a time until the section is back, then Cmd-Shift-Z until
    /// the state before the first Cmd-Z. Follows the unified timeline of docs/architecture/unified-undo.md: the newest thing is undone first (the
    /// typing), the delete after it; redo goes the other way. What is asserted, and no more: the section never returns while the sentence is still
    /// on screen; it does return (by a structural undo) within `maxUndoPresses` presses; redo never shows the sentence while the section is
    /// back; nothing was refused; the saved
    /// document at the end is the one after the delete and the typing.
    func testDeleteTypeUndo_book6() {
        let size = Phase4bDelSize.book6
        guard startScenario(size, method: #function), let range = section(size.deleteTitle), placeCaretAtAnchorEnd(),
              let card = bringSidebarCardIntoView(size.deleteTitle) else { return }
        let sentence = Self.sentence("SIX")
        let from = chooseSidebarItem(card, item: "Delete Section")
        expectPerformed("sectionDelete", from: from, "the delete reached its performed line")
        assertCheck(waitForCard(size.deleteTitle, present: false, timeout: capped(30)), "the section is off the screen")
        clickBackIntoAnchor()
        typeNow(" " + sentence)
        // The database first, then the screen (a failure of the screen check must always say whether the text was saved).
        assertCheck(waitForSentenceInDatabase(sentence, timeout: capped(90)), "the typed sentence reached the database")
        assertCheck(settle(gone: [size.deleteTitle]), "the delete's job finished")
        assertCheck(waitForTypedLine(sentence, timeout: capped(90)),
                    "the typed sentence is on screen (the anchor line reads \"\(Self.anchorLine) \(sentence)\")")

        let afterEdits = Phase4bFlowExpectation(removed: [range], typed: [sentence])
        // How many plain text steps the typed sentence needs before the delete itself is undone depends on how the editor grouped the typing
        // (its history starts a new group after a pause), so it varies with the machine's speed: the cap is generous, not a claim.
        var undoPresses: [Phase4bFlowPress] = []
        for number in 1...Self.maxUndoPresses {
            let press = pressStep(redo: false, number: number, sentence: sentence, title: size.deleteTitle, readScreen: false)
            undoPresses.append(press)
            if press.structural && press.sectionOnScreen { break }
        }
        let textPresses = undoPresses.filter { !$0.structural }.count
        result("TEXT UNDO GROUPS: the editor's text history held \(undoPresses.first?.depth.map(String.init) ?? "n/a") undo step(s) before the "
            + "first press (the typed sentence's groups); \(textPresses) text press(es) ran before the structural undo; "
            + "the editor's decisions: \(undoPresses.map(\.decision))")
        let comeBack = undoPresses.last
        assertCheck(comeBack?.structural == true && comeBack?.sectionOnScreen == true,
                    "the deleted section came back by a structural undo within \(Self.maxUndoPresses) Cmd-Z presses (\(undoPresses.count) pressed, "
                        + "\(textPresses) of them text steps; decisions \(undoPresses.map(\.decision)))")
        assertCheck(undoPresses.allSatisfy { !($0.sectionOnScreen && $0.sentenceStillThere) },
                    "at no press was the section back while the typed sentence was still there (the typing is undone first, then the delete): "
                        + undoPresses.map { "press \($0.number): \($0.line), section \($0.sectionOnScreen)" }.joined(separator: "; "))
        let failure = problemLine(from: from, includeRouting: false)
        assertCheck(failure == nil, "no undo failed (\(failure ?? "none"))")
        assertCheck(settle(back: [size.deleteTitle]), "the section's heading row is back in the block table")
        // Gone, twice over, neither able to pass for the wrong reason: the database no longer holds the sentence; and on screen the plain anchor
        // line was FOUND (the tree is being read, and it is the very line the sentence was part of) with no sentence beside it.
        assertCheck(waitForSentenceGoneFromDatabase(sentence, timeout: capped(90)),
                    "the typed sentence is gone from the database once the section is back")
        assertCheck(sentenceGoneFromScreen(sentence, timeout: capped(90)),
                    "the typed sentence is gone from the editor once the section is back (the anchor line reads \"\(Self.anchorLine)\")")

        var redoPresses: [Phase4bFlowPress] = []
        for number in 1...Self.maxUndoPresses {
            let press = pressStep(redo: true, number: number, sentence: sentence, title: size.deleteTitle)
            redoPresses.append(press)
            if !press.sectionOnScreen && press.sentenceBack { break }
        }
        let forward = redoPresses.last
        assertCheck(forward.map { !$0.sectionOnScreen && $0.sentenceBack } == true,
                    "Cmd-Shift-Z stepped forward again to the state before the first Cmd-Z within \(Self.maxUndoPresses) presses "
                        + "(\(redoPresses.count) pressed; decisions \(redoPresses.map(\.decision)))")
        assertCheck(redoPresses.allSatisfy { !($0.sectionOnScreen && $0.sentenceStillThere) },
                    "redo never showed the sentence with the section back: "
                        + redoPresses.map { "press \($0.number): \($0.line), section \($0.sectionOnScreen)" }.joined(separator: "; "))
        assertCheck(settle(gone: [size.deleteTitle]), "the section is gone again in the block table")
        assertCheck(waitForSentenceInDatabase(sentence, timeout: capped(90)), "the sentence is back in the database")
        assertDocument(readRows(), expect: afterEdits, "after undoing and redoing everything")
    }
}

// MARK: - 7. Delete, then zoom at once

extension WriteQueuePhase4bDeleteFlowE2ETests {
    /// A sentence is typed, a chapter is deleted, and at once another section is zoomed into. Zoom opens on the section asked for, only after
    /// the delete's job has finished (the heading row is already gone when the zoom shows), the sentence is not lost, and the section stays
    /// deleted. The zoom is a double-click on the sidebar card: a Command-click needs `perform(withKeyModifiers:)`, which does not exist for
    /// macOS in XCUITest and a synthesized modifier is untrusted in the guest; the card's double-click calls the same `zoomToSection`.
    func testDeleteThenZoomAtOnce_book12() {
        let size = Phase4bDelSize.book12
        let zoomTitle = "5.6 Conclusion"
        guard startScenario(size, method: #function, holdMs: Self.holdShortMs), let range = section(size.deleteTitle), placeCaretAtAnchorEnd(),
              let deleteCard = bringSidebarCardIntoView(size.deleteTitle) else { return }
        // "5.6 Conclusion" is the card right above the chapter's, so it stays in place when the chapter's cards leave.
        let zoomCard = sidebarCard(zoomTitle)
        assertCheck(zoomCard.exists, "the section to zoom into is on screen beside the one to delete")
        let sentence = Self.sentence("SEVEN")
        typeNow(" " + sentence)
        let from = chooseSidebarItem(deleteCard, item: "Delete Section")
        zoomCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        let exit = app.buttons["status-bar-zoom-exit"]
        assertCheck(exit.waitForExistence(timeout: capped(size.operationTimeout)), "the zoom opened (the exit-zoom button is on screen)")
        let rowsWhenZoomOpened = headingRows(size.deleteTitle)
        result("when the zoom opened: heading rows \"\(size.deleteTitle)\" in the block table: \(rowsWhenZoomOpened)")
        assertCheck(rowsWhenZoomOpened == 0, "the zoom opened after the delete's job finished: the deleted section's heading row is already gone")
        let outline = app.buttons["status-bar-outline"]
        let zoomedOnTarget = outline.waitForValue("CONTAINS '\(zoomTitle)'", timeout: 30)
        let shown = outline.exists ? String(describing: outline.value) : "nothing"
        assertCheck(zoomedOnTarget, "the zoom is on \"\(zoomTitle)\" (the status bar reads \(shown))")
        expectPerformed("sectionDelete", from: from, "the delete reached its performed line")
        attachEvidenceScreenshot(app.screenshot(), name: "zoomed-after-delete-book12")
        exit.click()
        assertCheck(exit.waitForDisappearance(timeout: capped(size.operationTimeout)), "the zoom closed again")
        assertCheck(settle(gone: [size.deleteTitle]), "the deleted section is still gone")
        assertCheck(waitForSentenceInDatabase(sentence, timeout: capped(90)), "the sentence typed before the delete is in the database")
        assertDocument(readRows(), expect: Phase4bFlowExpectation(removed: [range], typed: [sentence]), "after delete, zoom in, zoom out")
        assertCheck(waitForTypedLine(sentence, timeout: capped(90)),
                    "the sentence is in the editor after leaving the zoom (the anchor line reads \"\(Self.anchorLine) \(sentence)\")")
    }
}

// MARK: - 8. Delete, duplicate, undo, undo, redo, type

extension WriteQueuePhase4bDeleteFlowE2ETests {
    /// The model answer, from the unified timeline: timeline [delete A, duplicate B]. Cmd-Z undoes the duplicate (B's copy leaves), the next
    /// Cmd-Z undoes the delete (A returns), Cmd-Shift-Z redoes the delete (A leaves again; the duplicate stays undone), and the sentence typed
    /// afterwards stays. Final: A gone, B present once with no copy, the sentence in place. The reopened project agrees.
    func testMixedTimeline_book6() {
        let size = Phase4bDelSize.book6
        let deleted = Phase4bDelSize.pairSecond      // A: chapter 4
        let duplicated = Phase4bDelSize.pairFirst    // B: the section just above it
        guard startScenario(size, method: #function), let deletedRange = section(deleted), section(duplicated) != nil,
              let deleteCard = bringSidebarCardIntoView(deleted) else { return }
        let duplicateCard = sidebarCard(duplicated)
        assertCheck(duplicateCard.exists, "the section to duplicate is on screen beside the one to delete")
        let from = chooseSidebarItem(deleteCard, item: "Delete Section")
        expectPerformed("sectionDelete", from: from, "the delete reached its performed line")
        chooseSidebarItem(duplicateCard, item: "Duplicate Section")
        expectPerformed("sectionDuplicate", from: from, "the duplicate reached its performed line")
        let copies = blocksContaining(duplicated + " copy")
        assertCheck(copies >= 1, "the copy of \"\(duplicated)\" exists in the block table (\(copies) row(s))")
        pressUndo()
        pressUndo()
        pressRedo()
        expectPerformed("undo", count: 2, from: from, "both Cmd-Z ran", slow: true)
        expectPerformed("redo", from: from, "the Cmd-Shift-Z ran", slow: true)
        let order = performedOrder(from: from)
        assertCheck(order == ["sectionDelete", "sectionDuplicate", "undo", "undo", "redo"],
                    "the five operations ran in the order pressed (a press that never ran is missing): \(order)")
        noteQueuedPresses(from: from)
        let problem = problemLine(from: from)
        assertCheck(problem == nil, "\(Self.notRefused) and nothing failed (\(problem ?? "none"))")
        assertCheck(settle(gone: [deleted]), "A is gone again in the block table")

        assertCheck(placeCaretAtAnchorEnd(), "the caret is back at the anchor paragraph")
        let sentence = Self.sentence("EIGHT")
        typeNow(" " + sentence)
        assertCheck(waitForSentenceInDatabase(sentence, timeout: capped(90)), "the sentence reached the database")
        let expectation = Phase4bFlowExpectation(removed: [deletedRange], typed: [sentence])
        func check(_ what: String) {
            assertDocument(readRows(), expect: expectation, what)
            let rows = headingRows(duplicated)
            assertCheck(rows == 1, "\(what): \"\(duplicated)\" is there once, with no copy (heading rows \(rows))")
            assertCheck(blocksContaining(duplicated + " copy") == 0, "\(what): no \"copy\" of it is left")
        }
        check("after delete, duplicate, Cmd-Z, Cmd-Z, Cmd-Shift-Z, typing")
        guard reopen() else { return }
        assertCheck(!sidebarCard(deleted).exists, "after the reopen A is not in the sidebar")
        check("after the reopen")
    }
}

// MARK: - 9. Quit right after a delete: the footnote numbers

extension WriteQueuePhase4bDeleteFlowE2ETests {
    /// A sentence is typed, a chapter is deleted, Cmd-Q at once (the job is held, so the quit has to wait for it). The reopened book has no
    /// chapter, keeps the sentence, and a scripted walk of every footnote reference in the saved document shows 1...n with no gap or repeat, every
    /// definition matches a reference, none is blank, and the definitions are the words of the references that remain (addendum A19).
    func testQuitRightAfterDeleteNumbering_book6() {
        let size = Phase4bDelSize.book6
        guard startScenario(size, method: #function, holdMs: Self.holdShortMs), let range = section(size.deleteTitle), placeCaretAtAnchorEnd(),
              let card = bringSidebarCardIntoView(size.deleteTitle) else { return }
        let beforeWalk = Phase4bFlowWalk(rows: pre)
        let chapterRefs = pre[range].filter { !$0.isManaged }.reduce(0) { $0 + Phase4bFlow.footnoteRefs(in: $1.fragment).count }
        note("the chapter holds \(chapterRefs) of the book's \(beforeWalk.refs.count) footnote references")
        let sentence = Self.sentence("NINE")
        typeNow(" " + sentence)
        chooseSidebarItem(card, item: "Delete Section")
        guard quitWithCommandQ() else { return }

        // Every check from here is SOFT: it is recorded, and all the failures are reported together at the end, so a single run says whether
        // the footnote NUMBERS, the definition WORDS or the rows are wrong, and whether the quit or the reopen made them so.
        var soft = Phase4bFlowSoftChecks()
        let expectation = Phase4bFlowExpectation(removed: [range], typed: [sentence])
        // The saved project exactly as the quit left it, before the reopened app can touch it.
        addDocumentChecks(readRows(), expect: expectation, "right after the quit, before the reopen", to: &soft)
        guard relaunch() else { return }

        soft.check(!sidebarCard(size.deleteTitle).exists, "after the reopen the deleted chapter is still in the sidebar")
        soft.check(headingRows(size.deleteTitle) == 0, "after the reopen the chapter's heading row is still in the block table")
        let rows = readRows()
        let walk = Phase4bFlowWalk(rows: rows)
        result("the walk of the reopened book: \(walk.summary); numbers \(walk.refs.prefix(8))...\(walk.refs.suffix(4)); problems \(walk.problems)")
        note("the book had \(beforeWalk.refs.count) footnotes, the chapter held \(chapterRefs), so "
            + "\(beforeWalk.refs.count - chapterRefs) must remain")
        addDocumentChecks(rows, expect: expectation, "after the reopen", to: &soft)
        soft.check(waitForTypedLine(sentence, timeout: capped(90)),
                   "the sentence typed before the delete is not in the reopened editor (the anchor line must read "
                       + "\"\(Self.anchorLine) \(sentence)\")")
        attachEvidenceScreenshot(app.screenshot(), name: "quit-after-delete-reopened-book6")
        assertSoft(soft, "quit right after a delete")
    }
}

// MARK: - 10. Delete two, Cmd-Z, Cmd-Z, Cmd-W at once

extension WriteQueuePhase4bDeleteFlowE2ETests {
    /// How a Cmd-W that is waiting on queued undos ended.
    enum CloseOutcome {
        /// The project picker is on screen.
        case closed
        /// The close waited out its time budget and gave up, and the app said so with its notice (the text is carried).
        case cancelledWithNotice(String)
        /// Neither the picker nor the notice within the wait.
        case neither
    }

    /// Watches for the end of a close: the project picker, or the app's own "Couldn't close the project ..." notice (`lifecycleCloseCancelled`,
    /// shown for nine seconds, so it is looked for in the same loop that looks for the picker rather than after a long wait).
    func waitForCloseOutcome(timeout: TimeInterval) -> CloseOutcome {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if app.groups["project-picker"].exists { return .closed }
            if let message = toastMessage(), message.hasPrefix("Couldn't close the project") { return .cancelledWithNotice(message) }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        } while Date() < deadline
        return .neither
    }

    /// Asserts the close happened, and when it did not says WHICH way it failed: cancelled by the lifecycle's time budget with its notice on
    /// screen (the undos were still running on a loaded machine: no press was lost), or no close and no notice at all.
    func assertClosed(_ outcome: CloseOutcome, from index: Int) {
        let ran = "undo lines performed so far: \(performedCount("undo", from: index)); order: \(performedOrder(from: index))"
        switch outcome {
        case .closed:
            assertCheck(true, "the project closed (the project picker is on screen)")
        case .cancelledWithNotice(let message):
            assertCheck(false, "the close was CANCELLED by its time budget and the app showed its notice (\"\(message)\"): the queued undos "
                + "were still running when the budget ran out, so this is a timing result and not a dropped press; \(ran)")
        case .neither:
            assertCheck(false, "the project did not close and the app showed NO cancel notice (the project picker never appeared): "
                + "this is not the budget's cancel, a press may have been dropped or the close is stuck; \(ran)")
        }
    }

    /// The exact sequence of the bug the judge found (item F3): two sections deleted, Cmd-Z, Cmd-Z, and Cmd-W at once. The project closes with BOTH
    /// sections back, and the user's latest typing (a sentence typed before the first delete) was NOT undone by a stray text undo; the reopened
    /// project proves it.
    func testUndoUndoCloseAtOnce_book6() {
        let size = Phase4bDelSize.book6
        let first = Phase4bDelSize.pairFirst
        let second = Phase4bDelSize.pairSecond
        guard startScenario(size, method: #function, holdMs: Self.holdShortMs), section(first) != nil, section(second) != nil,
              placeCaretAtAnchorEnd() else { return }
        let sentence = Self.sentence("TEN")
        typeNow(" " + sentence)
        assertCheck(waitForSentenceInDatabase(sentence, timeout: capped(90)), "the sentence reached the database before the first delete")
        guard let firstCard = bringSidebarCardIntoView(first) else { return }
        let secondCard = sidebarCard(second)
        assertCheck(secondCard.exists, "the second section's card is on screen beside the first")
        let from = chooseSidebarItem(firstCard, item: "Delete Section")
        chooseSidebarItem(secondCard, item: "Delete Section", activate: false)
        pressUndo()
        pressUndo()
        // e2e-lint: allow cmd-w -- closing the project IS the scenario (Cmd-W is the app's Close Project).
        app.typeKey("w", modifierFlags: .command)
        let closeOutcome = waitForCloseOutcome(timeout: capped(300))
        note("OPERATIONS in the order they performed: \(performedOrder(from: from))")
        noteQueuedPresses(from: from)
        assertClosed(closeOutcome, from: from)
        let undoLines = performedCount("undo", from: from)
        assertCheck(undoLines >= 2, "both Cmd-Z ran before the project closed (\(undoLines) undo line(s))")
        let afterClose = readRows()
        assertDocument(afterClose, expect: Phase4bFlowExpectation(typed: [sentence]), "after the close")
        let firstRows = headingRows(first)
        let secondRows = headingRows(second)
        assertCheck(firstRows == 1 && secondRows == 1, "both sections are back in the saved project (\(firstRows), \(secondRows) heading row(s))")

        guard relaunch() else { return }
        assertCheck(sidebarCard(first).exists && sidebarCard(second).exists, "after the reopen both sections are in the sidebar")
        assertDocument(readRows(), expect: Phase4bFlowExpectation(typed: [sentence]), "after the reopen")
        assertCheck(waitForTypedLine(sentence, timeout: capped(90)),
                    "after the reopen the sentence typed before the first delete is in the editor (no text undo took it; "
                        + "the anchor line reads \"\(Self.anchorLine) \(sentence)\")")
    }
}

// MARK: - 11. Delete, switch to Markdown at once, type

extension WriteQueuePhase4bDeleteFlowE2ETests {
    /// A chapter is deleted and the Rich Text / Markdown switch (Cmd-/) is pressed at once. The switch waits for the delete's job and then
    /// happens; a sentence typed in the Markdown editor is saved; the section stays gone; the mode is Markdown.
    func testDeleteThenSwitchToMarkdownAndType_book12() {
        let size = Phase4bDelSize.book12
        guard startScenario(size, method: #function, holdMs: Self.holdShortMs), let range = section(size.deleteTitle), placeCaretAtAnchorEnd(),
              let card = bringSidebarCardIntoView(size.deleteTitle) else { return }
        let from = chooseSidebarItem(card, item: "Delete Section")
        app.typeKey("/", modifierFlags: .command)
        let mode = app.buttons["status-bar-editor-mode"]
        assertCheck(mode.waitForLabel("== 'Markdown'", timeout: capped(size.operationTimeout)),
                    "the switch was held and then happened: the mode button reads Markdown (it reads \(mode.label))")
        // The Markdown editor shows the document's raw text: the first heading line with its `#` is the proof it is mounted. CodeMirror draws
        // only the lines near the viewport, so its tree is small; the long wait covers one slow snapshot of the Rich Text tree it replaces.
        assertCheck(app.editorContainsText("# Chapter 1: The Quiet Archive", timeout: capped(size.operationTimeout * 2)),
                    "the Markdown editor is mounted (it shows the first heading's raw text)")
        let sentence = Self.sentence("ELEVEN")
        typeNow(" " + sentence)
        expectPerformed("sectionDelete", from: from, "the delete reached its performed line")
        // Every check from here is SOFT: recorded, and all failures reported together at the end, so one run says whether the footnote NUMBERS,
        // the definition WORDS or the rows are wrong after the delete and the switch (the app-log attachment says why).
        var soft = Phase4bFlowSoftChecks()
        soft.check(settle(gone: [size.deleteTitle]), "the deleted chapter is not gone from the block table")
        soft.check(waitForSentenceInDatabase(sentence, timeout: capped(180)), "the sentence typed in the Markdown editor was not saved")
        addDocumentChecks(readRows(), expect: Phase4bFlowExpectation(removed: [range], typed: [sentence]),
                          "after delete, switch to Markdown, typing", to: &soft)
        // On screen, after the database: in the Markdown editor the whole-tree search is cheap (CodeMirror draws only the lines near the
        // viewport), unlike the Rich Text tree of a book, which is why the other tests use the exact anchor-line leaf instead.
        soft.check(app.editorContainsText(sentence, timeout: capped(90)), "the sentence is not in the Markdown editor")
        soft.check(mode.label == "Markdown", "the mode is no longer Markdown (it reads \(mode.label))")
        attachEvidenceScreenshot(app.screenshot(), name: "delete-switch-markdown-type-book12")
        assertSoft(soft, "delete then switch to Markdown")
    }
}

// MARK: - 12. Delete, Cmd-Z, then type as soon as the undo has finished

extension WriteQueuePhase4bDeleteFlowE2ETests {
    /// F7: after the slow undo settles, the Notes and bibliography are pushed back from the database. A sentence typed the moment the undo's own
    /// `performed` line appears (the app's settle signal) survives that push, and the Notes and bibliography match the reopened project.
    func testDeleteUndoThenTypeStraightAfter_book6() {
        let size = Phase4bDelSize.book6
        guard startScenario(size, method: #function, holdMs: Self.holdShortMs), placeCaretAtAnchorEnd(),
              let card = bringSidebarCardIntoView(size.deleteTitle) else { return }
        let from = chooseSidebarItem(card, item: "Delete Section")
        pressUndo()
        expectPerformed("undo", from: from, "the undo finished (its own performed line)")
        let sentence = Self.sentence("TWELVE")
        clickBackIntoAnchor()
        typeNow(" " + sentence)
        assertCheck(waitForCard(size.deleteTitle, present: true, timeout: capped(60)), "the section is back in the sidebar")
        assertCheck(settle(back: [size.deleteTitle]), "the section is back in the block table")
        assertCheck(waitForSentenceInDatabase(sentence, timeout: capped(180)), "the sentence typed straight after the undo reached the database")
        let expectation = Phase4bFlowExpectation(typed: [sentence])
        let rows = readRows()
        assertDocument(rows, expect: expectation, "after delete, Cmd-Z, typing straight after")
        let managedDifference = exactDifference(
            "after delete, Cmd-Z, typing straight after", "Notes / Bibliography rows against before the delete",
            expected: indexedRows(pre, where: \.isManaged), actual: indexedRows(rows, where: \.isManaged))
        assertCheck(managedDifference == nil, "the Notes and Bibliography rows are those of before the delete (\(managedDifference ?? "same"))")
        assertCheck(waitForTypedLine(sentence, timeout: capped(90)),
                    "the sentence is still in the editor (the anchor line reads \"\(Self.anchorLine) \(sentence)\")")

        guard reopen() else { return }
        let reopened = readRows()
        assertDocument(reopened, expect: expectation, "after the reopen")
        let reopenedDifference = exactDifference(
            "after the reopen", "Notes / Bibliography rows against before the reopen",
            expected: indexedRows(rows, where: \.isManaged), actual: indexedRows(reopened, where: \.isManaged))
        assertCheck(reopenedDifference == nil,
                    "the Notes and Bibliography saved before the reopen are the ones the reopened project holds (\(reopenedDifference ?? "same"))")
        assertCheck(waitForTypedLine(sentence, timeout: capped(90)),
                    "after the reopen the sentence is in the editor (the anchor line reads \"\(Self.anchorLine) \(sentence)\")")
    }
}

// MARK: - 13. Delete, Cmd-Z, then the mode switch while the undo runs

extension WriteQueuePhase4bDeleteFlowE2ETests {
    /// F5: the Rich Text / Markdown switch pressed while a slow undo is still running is held, never dropped; it happens when the undo is done,
    /// the final mode is Markdown, and the restored section is part of the Markdown text.
    func testDeleteUndoThenSwitchModeAtOnce_book6() {
        let size = Phase4bDelSize.book6
        guard startScenario(size, method: #function, holdMs: Self.holdShortMs), let card = bringSidebarCardIntoView(size.deleteTitle) else { return }
        let from = chooseSidebarItem(card, item: "Delete Section")
        pressUndo()
        app.typeKey("/", modifierFlags: .command)
        let mode = app.buttons["status-bar-editor-mode"]
        assertCheck(mode.waitForLabel("== 'Markdown'", timeout: capped(size.operationTimeout * 2)),
                    "the switch was held and then happened: the mode button reads Markdown (it reads \(mode.label))")
        expectPerformed("undo", from: from, "the undo ran to its performed line")
        assertCheck(problemLine(from: from) == nil, "nothing was refused or failed (\(problemLine(from: from) ?? "none"))")
        // The database first; the on-screen check after it (it may have to wait out one slow snapshot of the Rich Text tree it replaces).
        assertCheck(settle(back: [size.deleteTitle]), "the restored section's heading row is in the saved document the Markdown editor shows")
        assertDocument(readRows(), expect: Phase4bFlowExpectation(), "after delete, Cmd-Z, switch to Markdown")
        assertCheck(app.editorContainsText("# Chapter 1: The Quiet Archive", timeout: capped(size.operationTimeout * 2)),
                    "the Markdown editor is mounted")
        assertCheck(mode.label == "Markdown", "the mode is Markdown at the end")
        attachEvidenceScreenshot(app.screenshot(), name: "delete-undo-switch-markdown-book6")
    }
}

// MARK: - 14. Delete, then print or Save Version: a toast the whole time

/// One look at the toast slot: seconds since the click, and the message shown (nil: the slot was empty).
struct Phase4bFlowToastSample {
    let seconds: TimeInterval
    let message: String?
}

/// One toast event from the APP'S OWN LOG: `[toast] show style=<style> message=<message>` or `[toast] dismiss ...`, with the app's own timestamp.
/// The accessibility looks above cannot be trusted to catch a toast that stays three seconds when one look takes 5 to 10 s on the twelve-chapter
/// book; the log is not subject to that timing, so every "was a toast on screen" judgement is made from these.
struct Phase4bFlowToastEvent {
    enum Kind: String { case show, dismiss }

    let date: Date
    let kind: Kind
    let style: String
    /// The toast's message; nil when the line carried none (a dismiss may name only an id).
    let message: String?
}

/// A stretch during which the toast slot was empty between one toast going and the next one showing.
struct Phase4bFlowToastGap {
    let start: Date
    let length: TimeInterval
}

/// What a sequence of toast events says about the slot: how long it stayed empty after the click, the empty stretches between toasts, and
/// when it last became empty (nil when it ended holding a toast).
struct Phase4bFlowToastTimeline {
    /// From the start moment to the first `show`; nil when no toast was ever shown.
    let leading: TimeInterval?
    let gaps: [Phase4bFlowToastGap]
    let emptySince: Date?

    var longestGap: TimeInterval { gaps.map(\.length).max() ?? 0 }
}

extension Phase4bFlow {
    /// Reads one log line as a toast event; nil for any other line or a line without an app timestamp.
    static func toastEvent(_ line: Phase4bLogLine) -> Phase4bFlowToastEvent? {
        let text = line.text
        let kind: Phase4bFlowToastEvent.Kind
        let rest: Substring
        if let range = text.range(of: "[toast] show ") {
            kind = .show
            rest = text[range.upperBound...]
        } else if let range = text.range(of: "[toast] dismiss") {
            kind = .dismiss
            rest = text[range.upperBound...]
        } else {
            return nil
        }
        guard let date = line.date else { return nil }
        let style = Phase4bDelTypingParser.word(after: "style=", in: String(rest)) ?? ""
        var message = rest.range(of: "message=").map { String(rest[$0.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = message, value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { message = String(value.dropFirst().dropLast()) }
        return Phase4bFlowToastEvent(date: date, kind: kind, style: style, message: message)
    }

    /// The slot's history from `start`: it is empty until the first `show`; a `show` fills it; a `dismiss` empties it (a dismiss that names
    /// another toast than the one showing is ignored). A gap is the time from a dismiss to the next show.
    static func toastTimeline(_ events: [Phase4bFlowToastEvent], from start: Date) -> Phase4bFlowToastTimeline {
        var showing: String?
        var emptySince: Date? = start
        var shownBefore = false
        var leading: TimeInterval?
        var gaps: [Phase4bFlowToastGap] = []
        for event in events {
            switch event.kind {
            case .show:
                if let since = emptySince {
                    let length = max(0, event.date.timeIntervalSince(since))
                    if shownBefore { gaps.append(Phase4bFlowToastGap(start: since, length: length)) } else { leading = length }
                }
                showing = event.message ?? ""
                emptySince = nil
                shownBefore = true
            case .dismiss:
                if let current = showing, event.message == nil || event.message == current {
                    showing = nil
                    emptySince = event.date
                }
            }
        }
        return Phase4bFlowToastTimeline(leading: leading, gaps: gaps, emptySince: showing == nil ? emptySince : nil)
    }
}

extension WriteQueuePhase4bDeleteFlowE2ETests {
    /// The toast events the app logged since log index `index`, read through the same follower as every other line (no accessibility query).
    func toastEvents(from index: Int) -> [Phase4bFlowToastEvent] {
        tail.poll()
        guard index <= tail.lines.count else { return [] }
        return tail.lines[index...].compactMap { Phase4bFlow.toastEvent($0) }
    }

    /// The events as text, each offset in seconds from `start` on the app's own timestamps.
    func describe(_ events: [Phase4bFlowToastEvent], from start: Date) -> String {
        events.map { event in
            "+\(String(format: "%.1f", event.date.timeIntervalSince(start))) s \(event.kind.rawValue)"
                + (event.message.map { " \"\($0)\"" } ?? "")
        }.joined(separator: ", ")
    }

    /// The message of the toast on screen right now, from one accessibility snapshot (a single round trip: a toast that goes away between an
    /// existence check and a property read cannot fail the test).
    func toastMessage() -> String? {
        guard let snapshot = try? app.staticTexts["toast-message"].snapshot() else { return nil }
        return (snapshot.value as? String) ?? snapshot.label
    }

    /// The accessibility looks as text (supplementary evidence only: on a book one look takes 5 to 10 s and a three-second toast falls between two).
    func describe(_ samples: [Phase4bFlowToastSample]) -> String {
        var parts: [String] = []
        var previous: String??
        for sample in samples where previous == nil || previous! != sample.message {
            parts.append("+\(String(format: "%.1f", sample.seconds)) s \(sample.message.map { "\"\($0)\"" } ?? "(empty)")")
            previous = .some(sample.message)
        }
        return "\(samples.count) look(s): " + parts.joined(separator: ", ")
    }

    /// Asserts a toast was on screen the whole time, judged from the app's OWN log (the `[toast] show` and `[toast] dismiss` lines with the app's
    /// own timestamps; the accessibility looks are recorded beside them and never asserted): at least one toast line since the click, and no
    /// more than a second between one toast going and the next showing. The time from the click to the FIRST toast is NOT asserted: on a book
    /// the app's main thread can be stalled for seconds by the delete's follow-up work, and the first toast shows only when it is free. That
    /// time is recorded, with the main-thread stalls the app logged from the click up to the first toast (the app's own `main-stall` lines).
    func assertToastThroughout(
        events: [Phase4bFlowToastEvent], samples: [Phase4bFlowToastSample], clickedAt: Date, logIndex: Int, what: String
    ) {
        let timeline = Phase4bFlow.toastTimeline(events, from: clickedAt)
        let firstShow = events.first { $0.kind == .show }?.date
        let stalls = traceLines(from: logIndex).filter { $0.family == .timeline && $0.step.hasPrefix("main-stall ") }
            .filter { $0.line.date.map { $0 >= clickedAt && (firstShow == nil || $0 <= firstShow!) } ?? false }
            .map { stall -> String in
                let length = Phase4bDelTypingParser.intAfter("main-stall ", in: stall.step) ?? 0
                let end = stall.line.date.map { String(format: "%.1f", $0.timeIntervalSince(clickedAt)) } ?? "?"
                return "\(length) ms ending at +\(end) s"
            }
        let first = timeline.leading.map { String(format: "%.1f s", $0) } ?? "no toast was shown"
        let gapList = timeline.gaps.map { gap -> String in
            let length = String(format: "%.1f", gap.length)
            return "\(length) s at +\(String(format: "%.1f", gap.start.timeIntervalSince(clickedAt))) s"
        }
        let gapText = gapList.isEmpty ? "none" : gapList.joined(separator: ", ")
        let stallText = stalls.isEmpty
            ? "none in the log (the trace writes them only for 30 s after a structural operation starts)" : stalls.joined(separator: ", ")
        // The figure is recorded (result lines, and a small attachment of its own), never asserted: it is judged from the quiet-machine run.
        let figure = [
            "\(what): click to the first toast (recorded, not asserted): \(first)",
            "\(what): main-thread stalls the app logged from the click to the first toast: \(stallText)",
            "\(what): empty stretches between toasts: \(gapText)",
            "\(what): toasts in the app log since the click: \(events.isEmpty ? "none" : describe(events, from: clickedAt))",
            "\(what): accessibility looks (supplementary, never asserted): \(describe(samples))"
        ]
        for line in figure { result(line) }
        attachText("toast-figure-\(methodName).txt", figure.joined(separator: "\n"))
        assertCheck(!events.isEmpty,
                    "\(what): the app log has toast lines since the click (a `[toast] show ...` line for every toast the app shows)")
        assertCheck(timeline.longestGap <= 1.0,
                    "\(what): a toast was on screen the whole time: no gap of more than a second between one toast going and the next showing "
                        + "(longest \(String(format: "%.1f", timeline.longestGap)) s; \(gapList.joined(separator: ", ")))")
    }

    /// The Print panel's own Cancel button (a sheet, a dialog or a window titled "Print": the panel's accessibility shape varies, as
    /// PrintE2ETests notes), scoped by the panel's title so the Touch Bar's own "Cancel" is never matched; nil while no panel is on screen.
    func printPanelCancelButton() -> XCUIElement? {
        [app.sheets["Print"], app.dialogs["Print"], app.windows["Print"]].map { $0.buttons["Cancel"] }.first { $0.exists }
    }

    /// F6 on the path where it applies. File > Print > Formatted... claims its "Preparing to print" progress toast at the click, BEFORE it
    /// reads the document (and so before it waits for the delete's job); the delayed "Finishing the last change" notice must not take that
    /// slot or leave it empty. The toast is watched from the click until the print panel appears: that is where the print path's own
    /// progress toast ends, and the panel is its own feedback. The panel's own Cancel ends the test. No save panel is involved (the export
    /// routes need one, which the VM guest cannot present); printing to PDF would need one too, so no print job is ever sent.
    func testDeleteThenPrintShowsAToastThroughout_book12() {
        let size = Phase4bDelSize.book12
        guard startScenario(size, method: #function, holdMs: Self.holdLongMs), let card = bringSidebarCardIntoView(size.deleteTitle) else { return }
        chooseSidebarItem(card, item: "Delete Section")
        app.menuBars.menuBarItems["File"].waitForExistenceOrFail(timeout: 5).click()
        app.menuItems["Print"].waitForExistenceOrFail(timeout: 5).click()
        let printItem = app.menuItems["Formatted..."].waitForExistenceOrFail(timeout: 5)
        // The moment and the log index just before the click: the app's toast lines from here on are this click's.
        tail.poll()
        let fromIndex = tail.lines.count
        let clickedAt = Date()
        printItem.click()
        var samples: [Phase4bFlowToastSample] = []
        var cancel: XCUIElement?
        var alert: String?
        var panelAt: Date?
        let deadline = Date(timeIntervalSinceNow: capped(size.operationTimeout * 3))
        repeat {
            samples.append(Phase4bFlowToastSample(seconds: Date().timeIntervalSince(clickedAt), message: toastMessage()))
            cancel = printPanelCancelButton()
            if cancel != nil { panelAt = Date(); break }
            if app.staticTexts["Pandoc Not Found"].exists { alert = "Pandoc Not Found"; break }
            if app.staticTexts["Print Failed"].exists { alert = "Print Failed"; break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        } while Date() < deadline
        attachText("toast-timeline-print-book12.txt", "accessibility looks (supplementary): \(describe(samples))\n"
            + "app log toast lines: \(describe(toastEvents(from: fromIndex), from: clickedAt))")
        attachEvidenceScreenshot(app.screenshot(), name: "print-after-delete-book12")
        let ended = cancel != nil ? "the print panel appeared" : (alert.map { "the \"\($0)\" alert appeared" } ?? "the wait timed out")
        note("PRINT WATCH ended after \(String(format: "%.1f", samples.last?.seconds ?? 0)) s: \(ended)")
        if let alert {
            app.clickDialogButton("OK")
            note("PRINT: dismissed the \"\(alert)\" alert")
        }
        guard let cancel else {
            fail("PRINT NOT DRIVABLE TO THE PRINT PANEL: \(ended). The toasts seen: \(describe(samples)). The Save Version sibling "
                + "(testDeleteThenSaveVersionShowsAToastThroughout_book12) covers the same wait without the print pipeline.")
            return
        }
        cancel.click()
        // The toast judgement is the app log's. After the last toast went, the time until the panel appeared is the print path's own hand-over
        // to the panel (not the wait for the delete): recorded, not asserted.
        let events = toastEvents(from: fromIndex)
        let timeline = Phase4bFlow.toastTimeline(events, from: clickedAt)
        if let since = timeline.emptySince, let panel = panelAt {
            result("delete then Print: the last toast went at +\(String(format: "%.1f", since.timeIntervalSince(clickedAt))) s and the print panel "
                + "was seen \(String(format: "%.1f", max(0, panel.timeIntervalSince(since)))) s later (recorded, not asserted)")
        }
        assertCheck(samples.contains { $0.message?.hasPrefix("Preparing to print") == true },
                    "the print path's own \"Preparing to print\" toast was on screen")
        assertToastThroughout(events: events, samples: samples, clickedAt: clickedAt, logIndex: fromIndex, what: "delete then Print")
        assertCheck(settle(gone: [size.deleteTitle]), "the deleted chapter is gone from the block table")
    }

    /// File > Save Version at once after a delete: the same wait as print's (the flush waits for the delete's job), with no print pipeline.
    func testDeleteThenSaveVersionShowsAToastThroughout_book12() {
        let size = Phase4bDelSize.book12
        guard startScenario(size, method: #function, holdMs: Self.holdLongMs), let card = bringSidebarCardIntoView(size.deleteTitle) else { return }
        chooseSidebarItem(card, item: "Delete Section")
        app.typeKey("s", modifierFlags: [.command, .shift])
        let alert = waitForSaveVersionAlert()
        guard alert.exists else { fail("the Save Version alert never appeared"); return }
        let field = alert.textFields.firstMatch
        guard field.waitForExistence(timeout: 10) else { fail("the Save Version alert has no name field"); return }
        field.click()
        field.typeText("After delete")
        let save = alert.buttons["Save"]
        guard save.waitForExistence(timeout: 10) else { fail("the Save Version alert has no Save button"); return }
        // The moment and the log index just before the click: the app's toast lines from here on are this Save's.
        tail.poll()
        let fromIndex = tail.lines.count
        let clickedAt = Date()
        save.click()
        // "Version saved." stays about three seconds, and on a book one accessibility look takes 5 to 10 s, so it can come and go between two
        // looks: it is confirmed from the app's own log (the `[toast] show` line), which is not subject to that timing. The looks are kept as
        // supplementary evidence, and the loop checks the log before every look.
        var samples: [Phase4bFlowToastSample] = []
        var onScreen = false
        var loggedSaved = false
        let deadline = Date(timeIntervalSinceNow: capped(size.operationTimeout * 2))
        func versionSavedLogged() -> Bool {
            toastEvents(from: fromIndex).contains { $0.kind == .show && ($0.message ?? "").hasPrefix("Version saved") }
        }
        repeat {
            loggedSaved = versionSavedLogged()
            if loggedSaved { break }
            let message = toastMessage()
            samples.append(Phase4bFlowToastSample(seconds: Date().timeIntervalSince(clickedAt), message: message))
            if message?.hasPrefix("Version saved") == true {
                onScreen = true
                loggedSaved = versionSavedLogged()
                break
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        } while Date() < deadline
        let events = toastEvents(from: fromIndex)
        attachText("toast-timeline-save-version-book12.txt", "accessibility looks (supplementary): \(describe(samples))\n"
            + "app log toast lines: \(describe(events, from: clickedAt))")
        attachEvidenceScreenshot(app.screenshot(), name: "save-version-after-delete-book12")
        assertCheck(loggedSaved,
                    "\"Version saved.\" is in the app log as a `[toast] show` line at or after the Save click (seen on screen by an accessibility "
                        + "look: \(Self.yesNo(onScreen)); toast lines in the log: \(events.isEmpty ? "none" : describe(events, from: clickedAt)))")
        assertCheck(settle(gone: [size.deleteTitle]), "the deleted chapter is gone from the block table")
        let snapshotRows = dbInt("SELECT count(*) FROM snapshot WHERE name = 'After delete';") ?? -1
        assertCheck(snapshotRows == 1, "the saved version exists exactly once (\(snapshotRows) row(s) named \"After delete\")")
        assertToastThroughout(events: events, samples: samples, clickedAt: clickedAt, logIndex: fromIndex, what: "delete then Save Version")
    }

    func waitForSaveVersionAlert() -> XCUIElement {
        let deadline = Date(timeIntervalSinceNow: 15)
        repeat {
            if app.sheets.firstMatch.exists { return app.sheets.firstMatch }
            if app.dialogs.firstMatch.exists { return app.dialogs.firstMatch }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return app.sheets.firstMatch
    }
}

// MARK: - 15. Delete the last chapter of a document that ends in a bibliography

extension WriteQueuePhase4bDeleteFlowE2ETests {
    /// The article without footnotes (no Notes section) and with one more last section of plain text: its last chapter is directly followed by
    /// the generated bibliography, whose opening marker is a row of its own (F12).
    static func articleEndingInBibliography(_ generated: Phase4bDoc) -> Phase4bDoc {
        var text = generated.markdown
        if let notes = text.range(of: "\n\n# Notes\n") { text = String(text[..<notes.lowerBound]) }
        text = text.replacingOccurrences(of: #"\[\^\d+\]"#, with: "", options: .regularExpression)
        let closing = [
            "## 1.7 Appendix Note",
            "The appendix holds no citation and no footnote, so deleting it takes no entry out of the bibliography.",
            "A second plain paragraph, so the last section is more than a heading.",
            "A third plain paragraph that ends the document before the generated bibliography."
        ]
        text += "\n\n" + closing.joined(separator: "\n\n") + "\n"
        return Phase4bDoc(markdown: text, cslJSON: generated.cslJSON, counts: Phase4bGenerator.count(text))
    }

    /// The last section is deleted; the app quits and reopens; the Bibliography region (its marker row included) is exactly what it was before:
    /// the editor keeps the marker row and the job must not delete it.
    func testDeleteLastChapterWithBibliography_quitAndReopen_article() {
        let size = Phase4bDelSize.article
        let title = "1.7 Appendix Note"
        guard startScenario(size, method: #function, seed: Self.articleEndingInBibliography), let range = section(title) else {
            if !pre.isEmpty { fail("the document has no section \"\(title)\"") }
            return
        }
        let bibliography = pre.filter(\.isBibliography)
        let markers = bibliography.filter { $0.type == "bibliography" }.count
        result("the document before: \(bibliography.count) Bibliography row(s), \(markers) of them the opening marker; "
            + "the last section \"\(title)\" is rows \(range.lowerBound)..<\(range.upperBound) of \(pre.count)")
        assertCheck(!bibliography.isEmpty, "the document has a generated bibliography before the delete")
        let next = range.upperBound < pre.count ? pre[range.upperBound] : nil
        assertCheck(next?.isBibliography == true,
                    "the last section is directly followed by the bibliography (row \(range.upperBound) is \(next?.type ?? "past the end"))")
        guard let card = bringSidebarCardIntoView(title) else { return }
        let from = chooseSidebarItem(card, item: "Delete Section")
        expectPerformed("sectionDelete", from: from, "the delete reached its performed line")
        assertCheck(settle(gone: [title]), "the last section is gone from the block table once the job has run")
        let expectation = Phase4bFlowExpectation(removed: [range])
        func exactlyTheRestOfTheDocument(_ rows: [Phase4bFlowRow], _ what: String) {
            let expected = pre.enumerated().filter { !range.contains($0.offset) }.map { (row: $0.offset, value: $0.element) }
            let difference = exactDifference(what, "every row but the deleted section", expected: expected, actual: indexedRows(rows))
            assertCheck(difference == nil,
                        "\(what): every row but the deleted section is as before, the whole Bibliography region included (\(difference ?? "same"))")
            assertDocument(rows, expect: expectation, what)
        }
        exactlyTheRestOfTheDocument(readRows(), "after the delete")
        guard reopen() else { return }
        assertCheck(!sidebarCard(title).exists, "after the reopen the last section is not in the sidebar")
        exactlyTheRestOfTheDocument(readRows(), "after the quit and the reopen")
        attachEvidenceScreenshot(app.screenshot(), name: "last-chapter-deleted-reopened-article")
    }
}

// MARK: - 16. Delete, type at once, then Cmd-Z over and over with no wait (the user's data-loss report)

/// Where the caret stands when the sentence is typed straight after the delete.
enum Phase4bFlowCaretSpot {
    /// The end of "Anchor05 line of the fixture document." (first chapter, on screen at launch). The section deleted is the size's
    /// `deleteTitle` (the article's "1.3 ...", the six-chapter book's chapter 3), far from the caret.
    case anchor
    /// The end of "Join01 line of the fixture document.", a plain one-line paragraph the seed puts DIRECTLY ABOVE the deleted section
    /// (`Phase4bDelSize.joinTitle`), so the sentence is typed right where the section used to be.
    case join
}

extension Phase4bDelSize {
    /// The first level-2 section of chapter 1, on screen at launch and near the top of the accessibility tree (a paragraph deep in a book
    /// costs hundreds of tree walks to find). The join scenarios delete it, with the "Join01" paragraph directly above it.
    static let joinTitle = "1.1 Ledgers and Their Keepers"
}

/// What the burst of Cmd-Z presses did, read from the app's log after the burst.
struct Phase4bFlowBurstFacts {
    /// One entry per press that reached the editor (its own `[UnifiedUndo] keydown` line), in order.
    let keydowns: [WriteQueuePhase4bDeleteFlowE2ETests.Phase4bFlowKeydown]
    /// Refusal lines (a beep: "neither a structural entry nor text history was available") written BEFORE the section came back, and how
    /// many came after (the presses that had nothing left to undo: expected once everything is undone).
    let refusalsBeforeRestore: [String]
    let refusalsAfterRestore: Int
    /// `undo ... performed` lines the app wrote since the burst began.
    let undoPerformed: Int
}

extension WriteQueuePhase4bDeleteFlowE2ETests {
    /// How many Cmd-Z presses the burst makes: a person pressing repeatedly, more than the few steps a short sentence needs.
    static let burstPresses = 12
    /// The plain paragraph the join scenarios type after (unique, one run, so the editor's text can be read exactly).
    static let joinLinePrefix = "Join01"
    static var joinLine: String { joinLinePrefix + " line of the fixture document." }

    /// The seeded document with `joinLine` as its own paragraph directly above the heading of `Phase4bDelSize.joinTitle`.
    static func withJoinParagraph(_ generated: Phase4bDoc) -> Phase4bDoc {
        let heading = "\n\n## \(Phase4bDelSize.joinTitle)\n\n"
        var text = generated.markdown
        guard let found = text.range(of: heading) else { return generated }
        text.replaceSubrange(found, with: "\n\n" + joinLine + heading)
        return Phase4bDoc(markdown: text, cslJSON: generated.cslJSON, counts: Phase4bGenerator.count(text))
    }

    /// "text" (the editor's own history step), "structural" (the section's undo), "held" (queued behind a running structural undo).
    static func pressKind(_ decision: String) -> String {
        switch decision {
        case "fallthrough": return "text"
        case "swallow": return "held"
        default: return decision
        }
    }

    /// The log index of the first line at or after `index` for which `matches` holds.
    func firstLogIndex(from index: Int, where matches: (Phase4bLogLine) -> Bool) -> Int? {
        tail.poll()
        guard index <= tail.lines.count else { return nil }
        return (index..<tail.lines.count).first { matches(tail.lines[$0]) }
    }

    func isSequenceLine(_ line: Phase4bLogLine, label: String, step: String) -> Bool {
        guard let trace = Phase4bDelTraceLine(line) else { return false }
        return trace.family == .sequence && trace.label == label && trace.step == step
    }

    /// The refusal lines since `index`, split at the first `undo ... performed` line (the section is back from then on).
    func refusalLines(from index: Int) -> (before: [String], afterCount: Int) {
        tail.poll()
        guard index <= tail.lines.count else { return ([], 0) }
        let restoredAt = firstLogIndex(from: index) { isSequenceLine($0, label: "undo", step: "performed") }
        var before: [String] = []
        var afterJavaScript = 0
        var afterSwift = 0
        for position in index..<tail.lines.count {
            let text = tail.lines[position].text
            let fromJavaScript = text.contains("refusal beep:")
            let fromSwift = text.contains("structural undo refused (direction=")
            guard fromJavaScript || fromSwift else { continue }
            if let restoredAt, position > restoredAt {
                if fromJavaScript { afterJavaScript += 1 } else { afterSwift += 1 }
            } else {
                before.append(String(text.suffix(160)))
            }
        }
        // The editor's own line and the app's line describe the same refusal: count it once.
        return (before, max(afterJavaScript, afterSwift))
    }

    /// Reads the burst from the app's log (no waiting) and writes everything the report needs as notes: what each press decided, how many
    /// Cmd-Z keys the app saw, the operations in the order they performed, where the delete's job stood against the typing and the first
    /// press, and the editor's own reason for every press it did not route to the section's undo (`routing-refused`).
    @discardableResult
    func readBurst(from: Int, burstFrom: Int, bursts: [Int]) -> Phase4bFlowBurstFacts {
        let keydowns = keydownLines(direction: "undo", from: burstFrom)
        let zKeys = tail.lines[min(burstFrom, tail.lines.count)...].compactMap { Phase4bDelTypingParser.key($0.text) }
            .filter { $0.code == Phase4bDelTypingParser.zKeyCode }.count
        let sent = bursts.reduce(0, +)
        let perBurst = bursts.enumerated().map { "burst \($0.offset + 1): \($0.element)" }.joined(separator: ", ")
        note("BURST: \(sent) Cmd-Z presses were sent in \(bursts.count) burst(s) (\(perBurst)), with no wait of the test between the presses of "
            + "a burst; the editor logged \(keydowns.count) keydown line(s) (one per press that reached it); the app saw \(zKeys) Z key event(s)")
        let decisions = keydowns.enumerated().map { entry -> String in
            let depth = entry.element.undoDepth.map { " (undo depth \($0))" } ?? ""
            return "\(entry.offset + 1) \(Self.pressKind(entry.element.decision))\(depth)"
        }
        note("PRESS DECISIONS (the editor's own, in order; text = a step of its own history, structural = the section's undo, "
            + "held = queued behind a running undo): \(decisions.joined(separator: ", "))")
        let started = startedCount("undo", from: burstFrom)
        let performed = performedCount("undo", from: burstFrom)
        note("STRUCTURAL UNDOS since the burst began: \(started) started, \(performed) performed; operations in the order they performed "
            + "since the delete: \(performedOrder(from: from))")
        noteQueuedPresses(from: burstFrom)
        let typedAt = firstLogIndex(from: from) { line in
            Phase4bDelTypingParser.key(line.text).map { $0.code != Phase4bDelTypingParser.zKeyCode } ?? false
        }
        let deleteDoneAt = firstLogIndex(from: from) { isSequenceLine($0, label: "sectionDelete", step: "performed") }
        let firstPressAt = firstLogIndex(from: from) { $0.text.contains("[UnifiedUndo] keydown direction=undo ") }
        let undoStartAt = firstLogIndex(from: from) { line in
            Phase4bDelTraceLine(line).map { $0.family == .sequence && $0.label == "undo" && $0.isOpStart } ?? false
        }
        let undoDoneAt = firstLogIndex(from: from) { isSequenceLine($0, label: "undo", step: "performed") }
        func position(_ index: Int?) -> String { index.map(String.init) ?? "never" }
        func before(_ left: Int?, _ right: Int?) -> String {
            guard let left, let right else { return "n/a" }
            return Self.yesNo(left < right)
        }
        note("ORDER IN THE APP LOG (a smaller line number is earlier): first typed key \(position(typedAt)); delete job performed "
            + "\(position(deleteDoneAt)); first Cmd-Z keydown \(position(firstPressAt)); undo started \(position(undoStartAt)); "
            + "undo performed \(position(undoDoneAt)). The delete's job was still pending when typing started: "
            + "\(before(typedAt, deleteDoneAt)); when the first Cmd-Z arrived: \(before(firstPressAt, deleteDoneAt))")
        let refused = routingRefusedLines(from: from)
        let reasons = refused.prefix(14).map { line -> String in
            let text = line.text
            let trace = text.range(of: "routing-refused ").map { String(text[$0.upperBound...]) } ?? text
            return String(trace.prefix(430))
        }
        note("ROUTING (the editor's reason for each press it did not send to the section's undo; \"latched\" is a press held behind a running "
            + "one, not a refusal): \(refused.count) line(s)" + (reasons.isEmpty ? "" : "; the first \(reasons.count): ")
            + reasons.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: " || "))
        let refusals = refusalLines(from: burstFrom)
        note("REFUSALS (a beep: neither a structural entry nor text history available): \(refusals.before.count) before the section came back "
            + "\(refusals.before.prefix(3)); \(refusals.afterCount) after (presses with nothing left to undo)")
        return Phase4bFlowBurstFacts(
            keydowns: keydowns, refusalsBeforeRestore: refusals.before, refusalsAfterRestore: refusals.afterCount, undoPerformed: performed)
    }

    /// The paragraph that starts with `prefix`, exactly as it was before the scenario and as it is now (the typed sentence must not remain).
    func addParagraphUnchangedCheck(prefix: String, post: [Phase4bFlowRow], to soft: inout Phase4bFlowSoftChecks) {
        let before = pre.first { $0.type == "paragraph" && $0.fragment.hasPrefix(prefix) }
        let after = post.first { $0.type == "paragraph" && $0.fragment.hasPrefix(prefix) }
        soft.check(before != nil && after != nil && before?.fragment == after?.fragment,
                   "(e) the \"\(prefix)\" paragraph is exactly as before the delete (before: \"\(before?.fragment.suffix(90) ?? "missing")\", "
                       + "now: \"\(after?.fragment.suffix(90) ?? "missing")\")")
    }

    /// The most Cmd-Z presses one rapid-undo scenario sends, both bursts together. A limit, not a target: a press past the section's undo
    /// would undo an older edit.
    static let burstPressCap = 40

    /// Waits (polling the app's log every 0.2 s, never a fixed time) until the editor has logged a `[UnifiedUndo] keydown direction=undo` line
    /// for each of `count` presses sent since log index `index`, or until `timeout`, and returns the lines it has. The editor decides a press when
    /// its web process gets to the key event, which on a book can be well after the test's `typeKey` returned, so the editor's own last decision
    /// and text history depth can be read only once its lines are all there.
    func waitForKeydownLines(count: Int, from index: Int, timeout: TimeInterval) -> [Phase4bFlowKeydown] {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var lines = keydownLines(direction: "undo", from: index)
        while lines.count < count, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
            lines = keydownLines(direction: "undo", from: index)
        }
        return lines
    }

    /// The Cmd-Z presses of a rapid-undo scenario: a burst of `burstPresses` with no wait of the test between presses, and, only when the
    /// section's undo has not been reached, one more burst.
    ///
    /// Why a second burst: the typed sentence is undone by plain text steps of the editor's own history, one per group, before the section's
    /// undo comes next on the timeline, and how many groups the typing made depends on typing speed (the six-chapter book split one sentence
    /// into 13, so 12 presses only undid text). The rule, read from the editor's own `[UnifiedUndo] keydown` lines once it has logged one for
    /// every press of the first burst (`waitForKeydownLines`): when none of the presses was decided `structural` or `swallow`, no section undo
    /// started or performed (app log), and the LAST press's `undoDepth=` (the depth BEFORE that press) is above 0, press `depth + 2` more times
    /// with no wait between them (the remaining text steps are `depth - 1`, the section's undo is the next press, two spare), never more than
    /// `burstPressCap` presses in all. Otherwise send nothing more. Returns the size of each burst, in order.
    func pressRapidUndoBursts(burstFrom: Int) -> [Int] {
        for _ in 1...Self.burstPresses { pressUndo() }
        var bursts = [Self.burstPresses]
        let keydowns = waitForKeydownLines(count: Self.burstPresses, from: burstFrom, timeout: capped(30))
        let sectionUndoStarted = startedCount("undo", from: burstFrom) > 0 || performedCount("undo", from: burstFrom) > 0
        let decidedStructural = keydowns.contains { $0.decision == "structural" || $0.decision == "swallow" }
        let seen = "the editor had logged \(keydowns.count) of \(Self.burstPresses) keydown line(s) when read"
        if sectionUndoStarted || decidedStructural {
            note("SECOND BURST: none; the section's undo is already on its way or done (started or performed in the app log: "
                + "\(Self.yesNo(sectionUndoStarted)); a press decided structural or held: \(Self.yesNo(decidedStructural))); \(seen)")
            return bursts
        }
        guard let depth = keydowns.last?.undoDepth else {
            note("SECOND BURST: none; no keydown line with an undo depth was read; \(seen)")
            return bursts
        }
        guard depth > 0 else {
            note("SECOND BURST: none; the last press saw undo depth \(depth) (the text history is used up); \(seen)")
            return bursts
        }
        let extra = min(depth + 2, Self.burstPressCap - Self.burstPresses)
        note("SECOND BURST: \(extra) more Cmd-Z presses, with no wait of the test between them: no section undo had started and the last press "
            + "of the first burst saw undo depth \(depth) (\(depth) + 2, at most \(Self.burstPressCap - Self.burstPresses)); \(seen)")
        for _ in 0..<extra { pressUndo() }
        bursts.append(extra)
        return bursts
    }

    /// The editor's `routing-refused` lines (since log index `index`) that carry the reason of the known bug t-dfc4fb02.
    func knownBugRefusalCount(from index: Int) -> Int {
        routingRefusedLines(from: index).filter { $0.text.contains(Self.knownBugReasonText) }.count
    }

    /// The editor's own words for the refusal of the known bug t-dfc4fb02 (`equivalenceReason=` of a `routing-refused` line).
    static let knownBugReasonText = "a footnote label is defined twice"

    /// The reason carried by the expected failure of the scenarios that pin the known bug t-dfc4fb02.
    static let knownBugReason = "Known bug t-dfc4fb02: after an editor-first delete, typing before the Notes rebuild lands makes the undo "
        + "comparison refuse permanently ('a footnote label is defined twice')"

    /// `assertSoft` for a scenario that pins a KNOWN BUG as an expected failure (non-strict): the soft checks' verdict is expected to fail, a
    /// run in which it passes is accepted (the bug is timing dependent), and the failure is recorded as the EXPECTED one, not as a red test.
    ///
    /// The expectation wraps only the soft checks' own verdict, the single failure `assertSoft` records; every harness failure (`fail`, a
    /// block table that cannot be read, ...) is recorded outside it and stays a real failure. Every note that carries the evidence (BURST,
    /// PRESS DECISIONS, ROUTING, the `SOFT CHECK FAILED` lines, the `CHECK FAILED` line) is written by `readBurst` and `assertSoft` exactly as
    /// for a strict scenario. `continueAfterFailure` is true only inside the block: the expected failure then never interrupts the test, so the
    /// evidence screenshot after it is still attached (the setUp value, false, is restored straight after).
    func assertSoftExpectingKnownBug(_ soft: Phase4bFlowSoftChecks, _ what: String, from: Int, reason: String) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        note("KNOWN BUG PINNED (\(reason)): this scenario expects its soft checks to fail and accepts a pass; the editor's routing-refused lines "
            + "naming \"\(Self.knownBugReasonText)\": \(knownBugRefusalCount(from: from)); soft checks failed: \(soft.failures.count)")
        let wasContinuing = continueAfterFailure
        continueAfterFailure = true
        XCTExpectFailure(reason, options: options) { assertSoft(soft, what) }
        continueAfterFailure = wasContinuing
        if soft.failures.isEmpty {
            note("KNOWN BUG t-dfc4fb02 DID NOT SHOW in this run (every check passed): accepted, because the bug depends on timing. "
                + "REMOVE THE EXPECTED-FAILURE WRAPPER WHEN THE FIX LANDS (the test must then pass strictly).")
        } else {
            note("KNOWN BUG t-dfc4fb02 SHOWED: \(soft.failures.count) check(s) failed and were recorded as the EXPECTED failure (not a red test). "
                + "REMOVE THE EXPECTED-FAILURE WRAPPER WHEN THE FIX LANDS (the test must then pass strictly).")
        }
    }

    /// Delete a section from the sidebar's menu, click back into the editor and type a sentence AT ONCE, then press Cmd-Z `burstPresses` times
    /// in a row with no wait of the test between presses (and, when the section's undo is not yet reached, one more burst:
    /// `pressRapidUndoBursts`), and only then look. The user's report (hand test of the unmerged build): "if I
    /// delete a section, start typing, and then hit Cmd-Z repeatedly, only the typed text is restored; the deleted section does not get
    /// recovered". `testDeleteTypeUndo_book6` waits for the sentence to reach the database and for the delete's job before the first press
    /// and presses once at a time; this one does neither. `holdMs` > 0 keeps the delete's job pending for that long (the seam of
    /// `FF_UI_TESTING_STRUCT_JOB_HOLD_MS`) so the typing and the first presses come while it is still running on a fast machine too.
    ///
    /// Asserted together at the end (every one is reported, whichever others fail): (a) the section's heading row is back in the block
    /// table, (b) its card is in the sidebar, (c) the sentence is gone from the database and from the editor, (d) no undo failed, no
    /// "could not be carried out" warning toast, no press refused before the section came back, (e) the saved document is the one before the
    /// delete (every row, the Notes and Bibliography rows, the footnote numbering and texts, and the paragraph the sentence was typed after).
    ///
    /// `expectedFailure` (the reason text) pins a KNOWN BUG: the soft checks' verdict is then recorded through
    /// `assertSoftExpectingKnownBug` (an expected, non-strict failure) instead of `assertSoft`. Every check is the same either way.
    func runRapidUndos(
        _ size: Phase4bDelSize, method: String, spot: Phase4bFlowCaretSpot, holdMs: Int = 0, expectedFailure: String? = nil
    ) {
        let title = spot == .join ? Phase4bDelSize.joinTitle : size.deleteTitle
        let line = spot == .join ? Self.joinLine : Self.anchorLine
        let prefix = spot == .join ? Self.joinLinePrefix : Self.anchorPrefix
        let seed: ((Phase4bDoc) -> Phase4bDoc)? = spot == .join ? Self.withJoinParagraph : nil
        guard startScenario(size, method: method, holdMs: holdMs, seed: seed), section(title) != nil,
              placeCaretAtAnchorEnd(paragraph: prefix), let card = bringSidebarCardIntoView(title) else { return }
        let sentence = Self.sentence("RAPID")
        // From this click to the last Cmd-Z press the test waits for nothing: not for the delete's job, not for the database, not between presses.
        let from = chooseSidebarItem(card, item: "Delete Section")
        clickBackIntoAnchor(paragraph: line)
        typeNow(" " + sentence)
        tail.poll()
        let burstFrom = tail.lines.count
        let bursts = pressRapidUndoBursts(burstFrom: burstFrom)

        let quiet = waitForLogQuiet(quiet: 3, cap: capped(size.operationTimeout))
        note("AFTER THE BURST: the app's log went quiet for 3 s: \(Self.yesNo(quiet))")
        // The section's heading row back in the block table, then the log quiet again; the burst is read after both so its notes are complete.
        let backInTable = settle(back: [title])
        let burst = readBurst(from: from, burstFrom: burstFrom, bursts: bursts)
        var soft = Phase4bFlowSoftChecks()
        soft.check(backInTable, "(a) the heading row \"\(title)\" is back in the block table")
        soft.check(waitForCard(title, present: true, timeout: capped(60)), "(b) the section's card \"\(title)\" is in the sidebar")
        let sentenceRows = blocksContaining(sentence)
        soft.check(waitForSentenceGoneFromDatabase(sentence, timeout: capped(30)),
                   "(c) the typed sentence is gone from the database (\(sentenceRows) block row(s) held it when last read)")
        soft.check(sentenceGoneFromScreen(sentence, timeout: capped(90), line: line),
                   "(c) the typed sentence is gone from the editor, and the plain line \"\(line)\" is on screen")
        let failure = problemLine(from: from, includeRouting: false)
        soft.check(failure == nil, "(d) no undo failed (\(failure ?? "none"))")
        let warnings = toastEvents(from: from).filter { $0.kind == .show && ($0.message ?? "").contains("could not be carried out") }
        soft.check(warnings.isEmpty, "(d) no \"could not be carried out\" warning toast was shown (\(warnings.count) shown)")
        soft.check(burst.refusalsBeforeRestore.isEmpty,
                   "(d) no Cmd-Z press was refused before the section came back (\(burst.refusalsBeforeRestore.count) refusal line(s) "
                       + "before it; \(burst.refusalsAfterRestore) after, which are presses with nothing left to undo)")
        soft.check(burst.undoPerformed >= 1, "(a) the section's structural undo ran (\(burst.undoPerformed) `undo performed` line(s))")
        let rows = readRows()
        let pressesText = bursts.map(String.init).joined(separator: " + ")
        addDocumentChecks(rows, expect: Phase4bFlowExpectation(), "after the delete, the typing and \(pressesText) Cmd-Z presses", to: &soft)
        addParagraphUnchangedCheck(prefix: line, post: rows, to: &soft)
        let spotName = spot == .join ? "join" : "anchor"
        let what = "delete, type at once, then \(pressesText) Cmd-Z presses with no wait (caret at the \(spotName))"
        if let expectedFailure {
            assertSoftExpectingKnownBug(soft, what, from: from, reason: expectedFailure)
        } else {
            assertSoft(soft, what)
        }
        attachEvidenceScreenshot(app.screenshot(), name: "rapid-undos-\(size.identifier)-\(spotName)")
    }

    // MARK: The scenarios (scope: final finalUITests/WriteQueuePhase4bDeleteFlowE2ETests/<method>)

    /// The caret at Anchor05; the job takes as long as it takes.
    func testDeleteTypeThenRapidUndos_book6() { runRapidUndos(.book6, method: #function, spot: .anchor) }
    func testDeleteTypeThenRapidUndos_article() { runRapidUndos(.article, method: #function, spot: .anchor) }
    /// The caret at the end of the paragraph directly above the deleted section.
    func testDeleteTypeThenRapidUndos_atTheJoin_book6() { runRapidUndos(.book6, method: #function, spot: .join) }
    func testDeleteTypeThenRapidUndos_atTheJoin_article() { runRapidUndos(.article, method: #function, spot: .join) }
    /// As the first pair, with the delete's job held for `holdLongMs` so it is still pending while the typing and the first presses happen.
    ///
    /// PINNED KNOWN BUG, board task t-dfc4fb02 (this test and `_jobPending_article` below): after an editor-first delete whose job is still
    /// pending, typing before the Notes rebuild lands makes the editor's undo comparison refuse permanently (`routing-refused ...
    /// failed=docs-not-equal equivalenceReason=a footnote label is defined twice in b target=postOpDoc`), so every Cmd-Z is a plain text step
    /// and the section never comes back. The test is an EXPECTED FAILURE (`XCTExpectFailure`, non-strict because the bug depends on timing:
    /// a pass is accepted too), so the UI suite stays green and the bug stays on record: the evidence lines (BURST, PRESS DECISIONS,
    /// ROUTING, SOFT CHECK FAILED) are written in either case. REMOVE THE EXPECTED-FAILURE WRAPPER WHEN THE FIX LANDS (the test must then
    /// pass strictly): drop the `expectedFailure:` argument.
    func testDeleteTypeThenRapidUndos_jobPending_book6() {
        runRapidUndos(.book6, method: #function, spot: .anchor, holdMs: Self.holdLongMs, expectedFailure: Self.knownBugReason)
    }
    /// PINNED KNOWN BUG t-dfc4fb02, exactly as `_jobPending_book6` above (it FAILS on the article in the VM today): REMOVE THE EXPECTED-FAILURE
    /// WRAPPER WHEN THE FIX LANDS (the test must then pass strictly): drop the `expectedFailure:` argument.
    func testDeleteTypeThenRapidUndos_jobPending_article() {
        runRapidUndos(.article, method: #function, spot: .anchor, holdMs: Self.holdLongMs, expectedFailure: Self.knownBugReason)
    }
}
