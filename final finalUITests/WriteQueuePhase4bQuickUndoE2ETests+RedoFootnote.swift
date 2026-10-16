//
//  WriteQueuePhase4bQuickUndoE2ETests+RedoFootnote.swift
//  final finalUITests
//
//  PHASE 4b PART 2, SLICE 2b, THE REDO-HISTORY FIX (bt task t-07eac5cb, parent t-94369a83), proven in the real app on a book with
//  footnotes. The defect: Delete Section, then type a sentence somewhere after it, then Cmd-Z until the section is back, then Cmd-Shift-Z:
//  the quick undo swapped the editor's saved copy back in and threw away the redo steps of the typing (redo depth 0), so the sentence could
//  not be redone. Two parts were fixed in the web editor: (A) the quick undo carries the live redo steps across the swap; (B) the footnote
//  renumber that follows the quick REDO (a recorded step, because "undo the renumber" must stay its own Cmd-Z) keeps the redo steps too.
//  `WriteQueuePhase4bDeleteFlowE2ETests/testDeleteTypeUndo_book6` (unedited) catches (A) with the sentence typed BEFORE any footnote; this
//  test is the variant the judge asked for (verdict-fix-redo-v1.md): the sentence goes into a paragraph AFTER the deleted section that itself
//  holds a footnote reference, right behind that reference, whose label the delete renumbers.
//
//  THE DOCUMENT: book6 with ONE seeded paragraph (`withFootnoteParagraph`): "Foot01 line of the fixture document.[^5]" directly under
//  the heading "## 1.3 Prices at the Market", with its own definition in the Notes; the labels after it are shifted up by one so the
//  document still reads 1..n in reading order (the loaded document is checked for that before anything happens). The section deleted is
//  "1.2.2 ..." (it holds footnote 4), which ends right before that heading: deleting it renumbers the Foot01 reference from 5 to 4, and
//  the sentence is typed behind the reference. The paragraph is early in the document on purpose: finding a paragraph in the
//  accessibility tree walks the leaves in order, and a leaf in the last chapter of a book would take minutes.
//
//  THE STEPS (keys pressed straight through; every wait is a condition the app or the database shows, never a time):
//   1. Delete the section from its sidebar card; 2. wait until its card is gone (what the user sees); 3. scroll to "1.3 ..." and click into the
//   Foot01 paragraph; 4. type the sentence; 5. Cmd-Z one press at a time, at once, until the editor decides `structural` (the first press
//   takes the typing away, the next brings the section back); 6. only then the test's own reading of the database: the section is back and the
//   rows are exactly the rows before the delete, the sentence is gone; 7. Cmd-Shift-Z until the editor's text redo has consumed its last
//   step; 8. the sentence is back on screen and in the database, the section is gone, the footnotes read 1..n with one definition each.
//  The editor's own `[UnifiedUndo] keydown` lines (the redo depth before every press) are printed as RESULT lines and named in the message
//  of the assertion that catches the defect.
//
//  RUNNING (VM only; the sandbox off; see .claude/superdev/quick-undo-section-delete/e2e-map.md):
//    scripts/vmtest/vmtest run --timeout 1800 \
//      --scope "final finalUITests/WriteQueuePhase4bQuickUndoE2ETests/testDeleteTypeUndoRedoWithFootnotes_book6"
//

import XCTest

// MARK: - One key press, as the editor's own keydown line reports it

/// One Cmd-Z or Cmd-Shift-Z: the editor's routing decision and the text history depths it reported just before acting on the press.
struct Phase4bQuPress {
    let number: Int
    let redo: Bool
    /// `fallthrough` (a plain text step of the editor's own history), `structural`, `swallow` (held behind a running one), or `none` when
    /// the editor wrote no `[UnifiedUndo] keydown` line within 3 s.
    let decision: String
    let undoDepth: Int?
    let redoDepth: Int?
    /// For a structural press: its `performed` line arrived (false on a logged refusal, a failure or the operation timeout).
    let performed: Bool
    /// The editor's keydown line, from its `[UnifiedUndo]` marker on.
    let line: String

    var isStructural: Bool { decision == "structural" || decision == "swallow" }

    var summary: String {
        "press \(number) (\(redo ? "redo" : "undo")): \(decision), undo depth \(undoDepth.map(String.init) ?? "n/a"), "
            + "redo depth \(redoDepth.map(String.init) ?? "n/a")" + (isStructural ? (performed ? ", performed" : ", NOT performed") : "")
    }
}

// MARK: - The seed and its titles

extension WriteQueuePhase4bQuickUndoE2ETests {
    /// The paragraph the sentence is typed into: one plain line followed by a footnote reference.
    static let footPrefix = "Foot01"
    static var footLine: String { footPrefix + " line of the fixture document." }
    /// The section whose heading the Foot01 paragraph sits directly under (its card scrolls the editor there).
    static let footSectionTitle = "1.3 Prices at the Market"
    /// No character the editor transforms (no quote, dash, asterisk, underscore, slash, bracket).
    static let footnoteSentence = "Redo sentence KEPTFN here"
    /// More than the presses the scenario needs (a text group or two, one structural press); a lost redo ends the loop at once anyway.
    static let footnotePressCap = 12

    /// `generated` with the Foot01 paragraph (and a definition for its reference) added directly under "## 1.3 ...", and every footnote
    /// label from the new one on shifted up by one, in the body and in the Notes, so the document still reads 1..n in reading order.
    static func withFootnoteParagraph(_ generated: Phase4bDoc) -> Phase4bDoc {
        let text = generated.markdown
        guard let heading = text.range(of: "\n\n## 1.3 "), let lineEnd = text.range(of: "\n\n", range: heading.upperBound..<text.endIndex) else {
            return generated
        }
        let referencesBefore = Phase4bGenerator.matches(#"\[\^\d+\](?!:)"#, in: String(text[..<lineEnd.lowerBound])).count
        let label = referencesBefore + 1
        var seeded = shiftingFootnoteLabels(in: text, from: label)
        guard let shiftedHeading = seeded.range(of: "\n\n## 1.3 "),
              let shiftedLineEnd = seeded.range(of: "\n\n", range: shiftedHeading.upperBound..<seeded.endIndex) else { return generated }
        seeded.replaceSubrange(shiftedLineEnd, with: "\n\n" + footLine + "[^\(label)]\n\n")
        guard let definition = seeded.range(of: "\n\n[^\(label + 1)]: ") else { return generated }
        seeded.insert(contentsOf: "\n\n[^\(label)]: A note attached to the paragraph that holds the new reference.", at: definition.lowerBound)
        return Phase4bDoc(markdown: seeded, cslJSON: generated.cslJSON, counts: Phase4bGenerator.count(seeded))
    }

    /// Every footnote label `[^n]` (a reference or a definition's label) with `n >= first` written as `[^n+1]`.
    static func shiftingFootnoteLabels(in text: String, from first: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[\^(\d+)\]"#) else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let digits = Range(match.range(at: 1), in: text),
                  let number = Int(text[digits]), number >= first else { continue }
            result.append(contentsOf: text[cursor..<whole.lowerBound])
            result += "[^\(number + 1)]"
            cursor = whole.upperBound
        }
        result.append(contentsOf: text[cursor...])
        return result
    }
}

// MARK: - Driving the keys

extension WriteQueuePhase4bQuickUndoE2ETests {
    /// One Cmd-Z (or Cmd-Shift-Z), then only as much waiting as the press needs, told by the app's own log: the editor writes a
    /// `[UnifiedUndo] keydown` line for every press before it acts on it (polled every 0.1 s, at most 3 s; none: decision `none`); a
    /// `structural` or `swallow` decision means a structural undo or redo is coming, and its `performed` line is waited for as long as the
    /// operation timeout. A text step (`fallthrough`) returns at once, so a burst of text steps is pressed as fast as the log answers.
    func pressAndRead(redo: Bool, number: Int) -> Phase4bQuPress {
        let label = redo ? "redo" : "undo"
        tail.poll()
        let from = tail.lines.count
        if redo { pressRedo() } else { pressUndo() }
        let marker = "[UnifiedUndo] keydown direction=\(label) "
        var text: String?
        let deadline = Date(timeIntervalSinceNow: 3)
        repeat {
            tail.poll()
            text = tail.lines[from...].first { $0.text.contains(marker) }?.text
            if text != nil { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        } while Date() < deadline
        let decision = text.flatMap { Phase4bDelTypingParser.word(after: "decision=", in: $0) } ?? "none"
        let structural = decision == "structural" || decision == "swallow"
        let performed = structural && waitForPerformed(
            label, from: from, timeout: appWait(size.operationTimeout, before: "the \(label) performed line of press \(number)"))
        let shown = text.flatMap { full in full.range(of: "[UnifiedUndo]").map { String(full[$0.lowerBound...]) } } ?? "no keydown line"
        return Phase4bQuPress(
            number: number, redo: redo, decision: decision,
            undoDepth: text.flatMap { Phase4bDelTypingParser.intAfter("undoDepth=", in: $0) },
            redoDepth: text.flatMap { Phase4bDelTypingParser.intAfter("redoDepth=", in: $0) },
            performed: performed, line: shown)
    }

    /// Scrolls the editor to "1.3 ..." (its sidebar card) and clicks into the Foot01 paragraph, then Cmd-Right to the end of its line. The
    /// click lands in the middle of the plain text, never on the reference pill (a click on a pill jumps to its definition). The caret probe
    /// is switched off: what a footnote reference adds to the status bar's word count is not known, and the sentence's place is checked in
    /// the database afterwards instead.
    func placeCaretInFootnoteParagraph() -> Bool {
        guard let card = bringSidebarCardIntoView(Self.footSectionTitle) else { return false }
        app.activateAndWaitForForeground()
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        // `exactLine`: the paragraph's plain text is a leaf of its own that reads exactly `footLine` (VM run 2026-10-16: the index walk
        // to it took 660 s on book6); the exact-value query is the fast path, the walk only the fallback.
        let placed = app.placeCaretByClicking(
            paragraphStartingWith: Self.footPrefix, atEnd: true, runProbe: false, findTimeout: capped(90), exactLine: Self.footLine)
        note("CARET at the end of the \"\(Self.footPrefix)\" paragraph, behind its footnote reference: \(placed.probe) after "
            + "\(placed.attempts.count) click attempt(s), click point \((placed.attempts.last?["clickPoint"] as? String) ?? "n/a")")
        guard placed.probe == "retired" else {
            fail("the caret could not be placed in the \"\(Self.footPrefix)\" paragraph (\(placed.probe); \(placed.attempts))")
            return false
        }
        return true
    }

    /// `timeout` is a fixed number of seconds, never `capped(...)` (see `appWait`).
    func waitForSentenceGone(_ sentence: String, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: appWait(timeout, before: "\"\(sentence)\" is looked for as gone from the database"))
        repeat {
            if blocksContaining(sentence) == 0 { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return false
    }

    /// The text the Foot01 row must read once `sentence` is typed at the end of its line: behind the reference (the caret at the line end,
    /// as Cmd-Right puts it) or, if the editor kept the caret in front of the reference pill, before it. The reference's number is read as
    /// `#` (the delete renumbers it). Nil when the row reads neither way: the sentence is somewhere else, or not there.
    func expectedFootnoteRow(sentence: String, in rows: [Phase4bFlowRow], footnoteRow: Int) -> (text: String, behindReference: Bool)? {
        guard let row = rows.first(where: { $0.fragment.hasPrefix(Self.footLine) }) else { return nil }
        let mark = Phase4bGenerator.matches(#"\[\^\d+\]"#, in: pre[footnoteRow].fragment).first ?? ""
        let behind = pre[footnoteRow].fragment + " " + sentence
        let before = Self.footLine + " " + sentence + mark
        if Phase4bFlow.normalized(row.fragment) == Phase4bFlow.normalized(behind) { return (behind, true) }
        if Phase4bFlow.normalized(row.fragment) == Phase4bFlow.normalized(before) { return (before, false) }
        return nil
    }

    /// A line for the result: what the accessibility tree shows of the Foot01 paragraph. NOT asserted: the on-screen proof is the
    /// screen-equals-database check. Exact-value queries only (about 1.5 s each on a book; the VM run of 2026-10-16 showed the paragraph's
    /// plain text is a leaf of its own that reads exactly `footLine`, the reference pill and the typed sentence are not part of it); the
    /// index walk of `editorStaticText` is never used here, it took 660 s to reach this paragraph.
    func footnoteLineOnScreen(_ sentence: String) -> String {
        // e2e-lint: allow statictext-firstmatch -- scoped to `editor-area` (never the sidebar's mirror) and an exact `==` on the value.
        let plain = app.editorArea.staticTexts.matching(NSPredicate(format: "value == %@", Self.footLine)).firstMatch
        guard plain.waitForExistence(timeout: 15) else { return "the Foot01 text leaf is not in the accessibility tree right now" }
        // e2e-lint: allow statictext-firstmatch -- as above.
        let spaced = app.editorArea.staticTexts.matching(NSPredicate(format: "value == %@", " " + sentence)).firstMatch
        // e2e-lint: allow statictext-firstmatch -- as above.
        let bare = app.editorArea.staticTexts.matching(NSPredicate(format: "value == %@", sentence)).firstMatch
        return "the Foot01 text leaf reads \"\(Self.footLine)\"; a leaf of its own holds the sentence: \(Self.yesNo(spaced.exists || bare.exists))"
    }
}

// MARK: - The test

extension WriteQueuePhase4bQuickUndoE2ETests {
    /// Delete "1.2.2 ..." (footnote 4), type a sentence behind the footnote reference of the Foot01 paragraph after it, press Cmd-Z until the
    /// section is back (text step, then the quick structural undo), then Cmd-Shift-Z until the sentence is back (the quick redo removes the
    /// section again and renumbers the footnotes, then the text redo). The assertion that catches the defect: the sentence is back in the
    /// database, with the editor's redo depth before every press in its message.
    func testDeleteTypeUndoRedoWithFootnotes_book6() {
        let size = Phase4bDelSize.book6
        guard startScenario(size, method: #function, seed: Self.withFootnoteParagraph), let title = innerSectionTitle(),
              let range = section(title) else { return }
        guard let footnoteRow = pre.firstIndex(where: { $0.fragment.hasPrefix(Self.footLine) }) else {
            fail("the seeded document has no \"\(Self.footLine)\" paragraph in the block table (the seed did not take)")
            return
        }
        guard footnoteRow >= range.upperBound, Phase4bFlow.footnoteRefs(in: pre[footnoteRow].fragment).count == 1 else {
            fail("the Foot01 row \(footnoteRow) is not after the deleted section \(range) or holds no single footnote reference: "
                + pre[footnoteRow].fragment)
            return
        }
        let sentence = Self.footnoteSentence
        let deletedReferences = range.flatMap { Phase4bFlow.footnoteRefs(in: pre[$0].fragment) }
        note("SCENARIO: delete \"\(title)\" (rows \(range.lowerBound)..<\(range.upperBound), footnote reference(s) \(deletedReferences)); "
            + "type \"\(sentence)\" in row \(footnoteRow), \"\(pre[footnoteRow].fragment)\", which comes after it and holds the reference "
            + "the delete renumbers")

        // 1-4: the delete, the click into the paragraph, the typing. No database reading in between.
        guard let deleteFrom = deleteSection(title) else { return }
        assertCheck(waitForCard(title, present: false, timeout: capped(30)), "the section's sidebar card is gone (the user sees the section vanish)")
        guard placeCaretInFootnoteParagraph() else { return }
        _ = typeAndRecord(" " + sentence)

        // 5: Cmd-Z, one press at a time, straight after the typing.
        tail.poll()
        let undoFrom = tail.lines.count
        var undoPresses: [Phase4bQuPress] = []
        for number in 1...Self.footnotePressCap {
            let press = pressAndRead(redo: false, number: number)
            undoPresses.append(press)
            result(press.summary)
            if press.isStructural { break }
        }
        let textUndos = undoPresses.filter { $0.decision == "fallthrough" }.count
        let undoDepths = undoPresses.map { $0.undoDepth.map(String.init) ?? "n/a" }
        result("UNDO DEPTH before each Cmd-Z press: \(undoDepths); \(textUndos) text step(s), then the structural press: "
            + "\(undoPresses.last?.isStructural == true ? "yes" : "NO")")
        assertCheck(undoPresses.last?.isStructural == true && undoPresses.last?.performed == true,
                    "the deleted section came back by a structural undo within \(Self.footnotePressCap) Cmd-Z presses "
                        + "(\(undoPresses.count) pressed; \(undoPresses.map(\.summary)))")
        assertCheck(textUndos >= 1, "the first Cmd-Z took the typing away (a text step): the sentence is newer than the delete in the timeline")
        let undoRuns = quickRuns(from: undoFrom, label: "undo")
        assertCheck(undoRuns.count == 1 && undoRuns[0].quick,
                    "the structural Cmd-Z took the quick path (`undo ... start (quick)`; the log says \(Self.describePaths(undoRuns)); "
                        + "\(describeSequence(from: deleteFrom)))")

        // 6: the test's own reading of the database: the document before the delete is back, the sentence is gone.
        var soft = Phase4bFlowSoftChecks()
        soft.check(waitForCard(title, present: true, timeout: capped(60)), "the section's sidebar card \"\(title)\" is back")
        soft.check(settle(back: [title]), "the heading row \"\(title)\" is back in the block table")
        soft.check(waitForSentenceGone(sentence, timeout: 90), "the typed sentence is gone from the database once the section is back")
        let afterUndo = addDocumentChecks("after the Cmd-Z presses (before any redo)", to: &soft)
        addExactMatchCheck("after the Cmd-Z presses", expected: pre, actual: afterUndo, to: &soft)
        assertSoft(soft, "after the Cmd-Z presses")

        // 7: Cmd-Shift-Z, one press at a time, until the editor's text redo has used its last step (a text press with redo depth 1), or
        // there is nothing left to redo (a text press with redo depth 0: the defect).
        var redoPresses: [Phase4bQuPress] = []
        for number in 1...Self.footnotePressCap {
            let press = pressAndRead(redo: true, number: number)
            redoPresses.append(press)
            result("\(press.summary); the editor's line: \(press.line)")
            if press.decision == "fallthrough", (press.redoDepth ?? 0) <= 1 { break }
        }
        let redoDepths = redoPresses.map { "\($0.decision) \($0.redoDepth.map(String.init) ?? "n/a")" }
        result("REDO DEPTH before each Cmd-Shift-Z press (`[UnifiedUndo] keydown direction=redo ... redoDepth=`): \(redoDepths)")
        attachEvidenceScreenshot(app.screenshot(), name: "delete-type-undo-redo-footnotes-book6")

        // 8: the sentence is back. THE assertion that catches the defect.
        assertCheck(waitForSentenceInDatabase(sentence, timeout: 60),
                    "the typed sentence is back in the database after Cmd-Shift-Z: the editor's redo depth before each Cmd-Shift-Z press was "
                        + "\(redoDepths) (0 before the structural redo: the redo steps of the typing were lost by the quick undo's swap; 1 before it "
                        + "and 0 before the text redo: lost by the footnote renumber after the quick redo; undo-side depths \(undoDepths))")
        var redoSoft = Phase4bFlowSoftChecks()
        redoSoft.check(redoPresses.first?.isStructural == true && redoPresses.first?.performed == true,
                    "the first Cmd-Shift-Z was the structural redo (the section removed again): \(redoPresses.map(\.summary))")
        redoSoft.check(redoPresses.count == undoPresses.count,
                    "Cmd-Shift-Z needed as many presses (\(redoPresses.count)) as Cmd-Z did (\(undoPresses.count)): \(redoPresses.map(\.summary))")
        redoSoft.check(settle(gone: [title]), "the section is gone again in the block table")
        redoSoft.check(waitForCard(title, present: false, timeout: capped(60)), "the section's sidebar card is gone again")
        let runs = quickRuns(from: undoFrom)
        note("RUNS: \(runs.map { "\($0.label) \($0.quick ? "quick" : "slow")\($0.refusal.map { " (\($0))" } ?? "")" })")
        redoSoft.check(runs.map(\.label) == ["undo", "redo"] && runs.allSatisfy(\.quick),
                    "the undo and then the redo both ran the quick path (the log says \(Self.describePaths(runs)))")
        let fallbacks = traceLines(from: undoFrom).filter { $0.step.contains("fallback") || $0.step.hasPrefix("refused") }
        redoSoft.check(fallbacks.isEmpty, "no undo or redo fell back or was refused (\(fallbacks.map(\.step)))")
        // Only the controller's failure line counts here: a text undo press legitimately logs `routing-refused ... decision=fallthrough`, so only
        // a structural press that was refused counts, and each structural press already has to reach its own `performed` line (checked above).
        let failure = Phase4bLog(lines: Array(tail.lines[deleteFrom...])).failureLine(since: "")?.text
        redoSoft.check(failure == nil, "no undo or redo failed (\(failure ?? "none"))")
        redoSoft.check(performedCount("sectionDelete", from: deleteFrom) >= 1, "the delete reached its performed line")
        redoSoft.check(plainPushCount(from: undoFrom) == 0,
                    "\(plainPushCount(from: undoFrom)) `[SYNC-DIAG:UpdateNSView] PUSHING` line(s) from the first Cmd-Z to the end (must be 0)")
        redoSoft.check(undoingToastCount(from: undoFrom) == 0, "an \"Undoing...\" toast was shown by the quick undo or redo")

        // The saved document: the section gone, the sentence in the Foot01 paragraph, the footnotes 1..n with one definition each.
        let rows = readRows()
        var typed: [Int: String] = [:]
        if let expected = expectedFootnoteRow(sentence: sentence, in: rows, footnoteRow: footnoteRow) {
            typed[footnoteRow] = expected.text
            note("TYPED ROW: the sentence sits \(expected.behindReference ? "behind" : "in front of") the footnote reference in the Foot01 row")
        } else {
            let found = rows.first { $0.fragment.hasPrefix(Self.footLine) }?.fragment ?? "no Foot01 row"
            redoSoft.check(false, "the Foot01 row reads neither \"\(pre[footnoteRow].fragment) \(sentence)\" nor the sentence in front of "
                + "the reference: \(found)")
        }
        addDocumentChecks("after the Cmd-Shift-Z presses (section gone, sentence back)", removed: [range], typedRows: typed, to: &redoSoft)
        note("ON SCREEN (accessibility tree, not asserted): \(footnoteLineOnScreen(sentence))")
        addScreenEqualsDatabaseCheck(before: rows, what: "after undo and redo", to: &redoSoft)
        attachEvidenceScreenshot(app.screenshot(), name: "delete-type-undo-redo-footnotes-book6-end")
        assertSoft(redoSoft, "delete, type behind a footnote reference, undo, redo")
    }
}
