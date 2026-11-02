//
//  MarkdownScanMemo.swift
//  final final
//
//  t-2fbe4c9b Phase 4c job 3, round C2b (plan v3 amendments A4, plan v2 section 3(C)): the HANDLER SCAN MEMO. Owned by the writer's
//  `MarkdownParseCache` (`scans`). The content-change handlers run three whole-text scans on the main thread after every Markdown
//  command (about 125 to 130 ms on the 12-chapter book): `onContentChange` strips the section anchors and the bibliography marker from
//  the page's raw text, `syncCitationsAndFootnotes` extracts the citation keys and the footnote references, and the delete settle's
//  resync extracts both again. They are pure functions of the text, so the parse memo's background task computes them ahead of time,
//  from the same text it is about to parse, and publishes them HERE as soon as they are ready (about 60 ms, before the parse, which
//  takes about 200 ms). A consumer asks by text and, on a miss, runs exactly the scan it ran before.
//
//  WHAT IS KEPT. The newest `capacity` (2) entries: the raw text the request gave (the page's text, anchors included), its stripped text
//  (`MarkdownLeaderMap.recordText`: what `onContentChange` makes of it), the project, and the results of
//  `BibliographySyncService.extractCitekeys` and `FootnoteSyncService.extractFootnoteRefs` on the stripped text. The results are the
//  direct scans' own return values (same elements, same order), made by the same functions.
//
//  A HIT IS BYTE-EXACT. Every lookup compares the candidate text with the stored text byte for byte (UTF-8, `Key.sameBytes`), never with
//  Swift's `String ==`, so a text that differs by one byte, or is only canonically equivalent, MISSES. Two cheap checks come first so
//  that the per-keystroke callers stay cheap: the stored text's length in the candidate's own representation (a Swift string has either
//  contiguous UTF-8, whose byte count is free, or is a bridged Foundation string, whose UTF-16 length is free), which a typed character
//  changes, and an empty memo.
//
//  NO SUSPENSION, NO REORDERING. Every method is synchronous. A consumer calls the memo in the same turn, with the same text, in the place
//  of the scan it replaces; `checkAndUpdateBibliography`, `checkAndUpdateFootnotes` and everything after them are untouched and get
//  the same values. `reset()` (the writer's reset: a project switch or close, a mode change, a zoom start) empties it, and a result the
//  background task finishes after a reset is not stored (the parse memo's `generation`).
//
//  SWITCHED OFF (round C9). Under the UI-test flag `FF_UI_TESTING_NO_PARSE_MEMO` the owning `MarkdownParseCache` is disabled: no
//  background job ever runs, so nothing ever fills this memo, every lookup finds it empty and returns at once, and the consumers scan
//  exactly as they did before job 3 (the lookups cost one empty-array test).
//
//  WHEN IT CAN HIT. The prewarm for a command's post-click text is requested at the top of the reply turn and starts inside that call
//  (round C4), so its scans (about 60 ms) are normally stored during the reply turn's wait for the writer's last write, before the
//  adopt's content change reaches the handlers; whether the first handler run after the click hits depends on whether the main actor
//  gets to store them before that run. The settle's resyncs and the footnote renumber that follows come later and hit.
//

import Foundation

@MainActor
final class MarkdownScanMemo {

    // MARK: - Entry

    /// One text's scans. Built in the background (`makeEntry`), stored on the main actor.
    struct Entry: Sendable {
        let projectId: String
        /// The text as the request gave it (the page's raw text), contiguous UTF-8.
        let raw: String
        /// `MarkdownLeaderMap.recordText(fromRaw: raw)`, contiguous UTF-8: what `editorState.content` holds for this text.
        let stripped: String
        let citekeys: [String]
        let footnoteRefs: [String]
        /// The texts' lengths in both units, for the cheap check that comes before a byte comparison.
        let rawUTF8: Int
        let rawUTF16: Int
        let strippedUTF8: Int
        let strippedUTF16: Int
    }

    /// How many entries are kept: the post-click text and the text the footnote renumber then makes of it.
    static let capacity = 2

    // MARK: - State

    /// Oldest first.
    private(set) var entries: [Entry] = []
    #if DEBUG
    /// Test-only counters: consumer lookups answered from the memo, and ones that ran the scan themselves.
    private(set) var hitCount = 0
    private(set) var missCount = 0
    #endif

    // MARK: - Lookup (synchronous)

    /// The entry whose stripped text is byte-identical to `stripped`, for this project, or nil.
    func entry(forStripped stripped: String, projectId: String) -> Entry? {
        guard !entries.isEmpty else { return nil }
        return entries.last {
            $0.projectId == projectId
                && Self.sameText(stripped, $0.stripped, utf8: $0.strippedUTF8, utf16: $0.strippedUTF16)
        }
    }

    /// The entry whose raw text is byte-identical to `raw`, or nil.
    func entry(forRaw raw: String) -> Entry? {
        guard !entries.isEmpty else { return nil }
        return entries.last { Self.sameText(raw, $0.raw, utf8: $0.rawUTF8, utf16: $0.rawUTF16) }
    }

    /// What `onContentChange` makes of the page's raw text (anchors and the bibliography opening marker removed), if it is stored; nil
    /// means "strip it yourself".
    func stripped(forRaw raw: String) -> String? {
        let found = entry(forRaw: raw)
        countLookup(hit: found != nil)
        return found?.stripped
    }

    /// `BibliographySyncService.extractCitekeys(from: stripped)`: the stored result for a byte-identical text, otherwise the scan itself.
    func citekeys(for stripped: String, projectId: String) -> [String] {
        if let found = entry(forStripped: stripped, projectId: projectId) {
            countLookup(hit: true)
            return found.citekeys
        }
        countLookup(hit: false)
        return BibliographySyncService.extractCitekeys(from: stripped)
    }

    /// `FootnoteSyncService.extractFootnoteRefs(from: stripped)`: the stored result for a byte-identical text, otherwise the scan itself.
    func footnoteRefs(for stripped: String, projectId: String) -> [String] {
        if let found = entry(forStripped: stripped, projectId: projectId) {
            countLookup(hit: true)
            return found.footnoteRefs
        }
        countLookup(hit: false)
        return FootnoteSyncService.extractFootnoteRefs(from: stripped)
    }

    // MARK: - Store and reset

    /// Remembers `entry` as the newest (an entry for the same stripped text and project is replaced); the oldest beyond `capacity` goes.
    func store(_ entry: Entry) {
        entries.removeAll {
            $0.projectId == entry.projectId && Self.sameText(entry.stripped, $0.stripped, utf8: $0.strippedUTF8, utf16: $0.strippedUTF16)
        }
        entries.append(entry)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    func reset() {
        entries.removeAll()
    }

    /// Makes the stored entry for this stripped text the newest one (a re-requested or skipped text is the live text: it must outlive an
    /// older one when the memo is full). Nothing when it is not stored.
    func touch(stripped: String, projectId: String) {
        guard let found = entry(forStripped: stripped, projectId: projectId) else { return }
        entries.removeAll { $0.projectId == projectId && Self.sameText(stripped, $0.stripped, utf8: $0.strippedUTF8, utf16: $0.strippedUTF16) }
        entries.append(found)
    }

    private func countLookup(hit: Bool) {
        #if DEBUG
        if hit { hitCount += 1 } else { missCount += 1 }
        #endif
    }

    // MARK: - The background half

    /// True when `entries` already holds the scans of this stripped text for this project (so the background task need not scan again).
    nonisolated static func contains(_ entries: [Entry], stripped: String, projectId: String) -> Bool {
        entries.contains {
            $0.projectId == projectId && sameText(stripped, $0.stripped, utf8: $0.strippedUTF8, utf16: $0.strippedUTF16)
        }
    }

    /// Runs the two scans on `stripped` and packs the entry. Pure; called off the main thread.
    nonisolated static func makeEntry(raw: String, stripped: String, projectId: String) -> Entry {
        let rawText = raw.contiguousUTF8Copy
        var strippedText = stripped
        strippedText.makeContiguousUTF8()
        return Entry(
            projectId: projectId, raw: rawText, stripped: strippedText,
            citekeys: BibliographySyncService.extractCitekeys(from: strippedText),
            footnoteRefs: FootnoteSyncService.extractFootnoteRefs(from: strippedText),
            rawUTF8: rawText.utf8.count, rawUTF16: rawText.utf16.count,
            strippedUTF8: strippedText.utf8.count, strippedUTF16: strippedText.utf16.count)
    }

    // MARK: - Comparing

    /// Byte-exact equality of `candidate` with `stored` (whose lengths are `utf8` and `utf16`). The length check uses the unit that is free
    /// for the candidate's representation; equal bytes always have equal lengths in both units, so it never rejects a true match.
    nonisolated private static func sameText(_ candidate: String, _ stored: String, utf8: Int, utf16: Int) -> Bool {
        if candidate.isContiguousUTF8 {
            guard candidate.utf8.count == utf8 else { return false }
        } else {
            guard candidate.utf16.count == utf16 else { return false }
        }
        return MarkdownParseCache.Key.sameBytes(candidate, stored)
    }
}

// MARK: - Reaching the memo

extension EditorViewState {

    /// The handler scan memo of this editor's Markdown writer.
    var scanMemo: MarkdownScanMemo { markdownWriter.parseCache.scans }

    /// Trigger (i), the load prewarm: asks the writer's parse memo to prepare the text the Markdown editor is about to be handed
    /// (`sourceContent`), for the open project. Never awaited, but not O(1): it is an undelayed request, so the call makes one indexed
    /// database read and one settings decode (about a millisecond) and spawns the background job. Called from the editor's ready callback
    /// (`prepareMarkdownBlockWriter`) and again by `handleEditorModeChange` right after the writer's `reset()`, which can run after that
    /// callback and wipe its request; a second request for the same text costs no second parse (the job's result is kept, or the stored
    /// text is skipped).
    func requestMarkdownLoadPrewarm(documentManager: DocumentManager) {
        guard let database = documentManager.projectDatabase, let projectId = documentManager.projectId else { return }
        markdownWriter.prewarmParse(raw: sourceContent, projectId: projectId, database: database)
    }

    /// The editor switched to `mode` (the `editorMode` onChange, ViewNotificationModifiers.swift). The pending re-parse belongs to the
    /// editor that just went away; the Markdown per-block writer's baseline too: Phase 4a, a write in flight is not cancelled (its reserved
    /// sequence must settle: it lands before the switch's own whole-document flush, or Milkdown's `configure` skips it
    /// (`skippedConsumed`); either way its completion sees the new version and leaves the baseline alone). `reset()` also empties the parse
    /// memo. Switching TO Markdown then asks for the load prewarm AGAIN, after that reset: the editor's ready callback can come before the
    /// onChange (the preloaded web view is ready inside `makeNSView`, in the update that changes the mode) and the reset wipes its request.
    func handleEditorModeChange(to mode: EditorMode, documentManager: DocumentManager) {
        blockReparseTask?.cancel()
        blockReparseTask = nil
        markdownWriter.reset()
        if mode == .source { requestMarkdownLoadPrewarm(documentManager: documentManager) }   // after the reset
    }
}
