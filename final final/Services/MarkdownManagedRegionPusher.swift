//
//  MarkdownManagedRegionPusher.swift
//  final final
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), round 4, O28 and O30: the database-to-editor push of the Notes and
//  Bibliography in Markdown mode, as a REGION-SCOPED replace in the page instead of a whole-document replace.
//
//  WHY. The rebuild handlers used to put the text they read from the rows into the content record (`content = result.markdown`) and
//  let the view push it into CodeMirror as a whole document. Keystrokes typed while a rebuild runs (the content state is not idle,
//  `isResettingContent` is up) never reach that record, so the push replaced the document with text that lacked them. Here the page
//  replaces only the region (`window.FinalFinal.markdownReplaceManagedRegion`, web/codemirror/src/api-managed-region.ts) and only if
//  the region still holds what the editor held when the rebuild read the rows (`expectedOld`). Body text is never touched.
//
//  THE CONTRACT WITH THE CALLER.
//    - `expectedOld` is the region text of the CONTENT RECORD taken on the line where the rebuild stamps its read (`MarkdownManagedRegions
//      .snapshot` of `editorState.content`). The record is kept in step with the page by O25/O29/O30, and typing inside the region while
//      the rebuild runs never reaches it, so a page whose region moved is told apart from one that did not.
//    - `newText` is the same region of the text the rebuild assembled from the rows.
//    - `.pushed` carries the page's own text back (`postRaw`): the pusher hands it to `adopt` (O30: the record only ever takes the page's
//      text, never the rows'), in the same synchronous turn as the reply.
//    - `.stale`: the page's region differs from `expectedOld` (the user typed in it, or a structural command changed it). Nothing was
//      written. The caller raises `managedRegionsNeedRepush` (the settle re-posts once the pending write has applied).
//    - `.noRegion`: the page has no such region. The caller falls back to the whole-text path ONLY when the region truly does not
//      exist yet (the record has none either: the first footnote or the first citation). KNOWN LIMIT: that one push still replaces
//      the whole document, as it always did.
//    - `.skipped`: `stillWanted()` said no before anything was sent (the B4 stamp guard, kept).
//    - `.failed`: the page did not answer, or answered with an error. Nothing was written; the caller treats it like `.stale`.
//

import Foundation

@MainActor
struct MarkdownManagedRegionPusher {

    /// Runs a JavaScript expression in the editor page and returns its string result (nil: no page, an error, or no string).
    typealias Evaluate = @MainActor (String) async -> String?

    enum Outcome: Equatable {
        case pushed(changed: Bool)
        case stale(String)
        case noRegion
        case skipped
        case failed(String)
    }

    let evaluate: Evaluate
    /// O30: takes the page's text after a region replace into the content record (`EditorViewState.adoptMarkdownPageText`).
    let adopt: @MainActor (String) -> Void

    init(evaluate: @escaping Evaluate, adopt: @escaping @MainActor (String) -> Void) {
        self.evaluate = evaluate
        self.adopt = adopt
    }

    /// The JavaScript that makes the page replace `region`. `JSON.stringify` of the page's answer comes back as a string.
    static func script(region: MarkdownManagedRegion, headingLine: String?, expectedOld: String, newText: String) -> String? {
        let request: [String: Any] = [
            "region": region.rawValue,
            "headingLine": headingLine ?? NSNull(),
            "expectedOld": expectedOld,
            "newText": newText
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "JSON.stringify(window.FinalFinal.markdownReplaceManagedRegion(\(json)))"
    }

    /// What a whole rebuild did, for the caller (`ContentView.pushRebuildToMarkdownEditor`) to act on.
    struct RebuildReport: Equatable {
        /// The stamp went stale (a click or a job is unapplied): nothing (more) was pushed. The caller calls `noteStalePushSkipped`.
        var staleSkipped = false
        /// A region push was rejected (the page's region moved) or failed: nothing was written. The caller raises `managedRegionsNeedRepush`.
        var repushOwed = false
        /// The editor has no such region yet (the first footnote or citation) and the stamp is still current: the caller runs the
        /// existing whole-text path. A stale stamp reports `staleSkipped` instead, never this.
        /// KNOWN LIMIT: that one push still replaces the whole document, as it always did.
        var wholeTextFallback = false
    }

    /// The Markdown tail of a rebuild: pushes each of `regions` that differs between what the editor held at the read (`read`) and what
    /// the rows now say (`fresh`). Only decisions and page calls; the caller applies the report.
    func pushRebuild(
        regions: [MarkdownManagedRegion],
        read: MarkdownRegionSnapshot,
        fresh: MarkdownRegionSnapshot,
        stillWanted: () -> Bool
    ) async -> RebuildReport {
        var report = RebuildReport()
        for region in regions {
            let expectedOld = read.text(region)
            let newText = fresh.text(region)
            if expectedOld == newText { continue }
            guard let expectedOld else {
                // The whole-text path replaces the page with the rows' text, so it takes the same stamp check as a region push
                // (review F1): a Delete's job that is still unapplied would otherwise put the deleted section and its Notes back,
                // and lose what was typed since. The caller treats `staleSkipped` like the region path does (`noteStalePushSkipped`).
                guard stillWanted() else {
                    report.staleSkipped = true
                    return report
                }
                report.wholeTextFallback = true
                return report
            }
            let outcome = await push(
                region: region, headingLine: fresh.notesHeadingLine ?? read.notesHeadingLine,
                expectedOld: expectedOld, newText: newText ?? "", stillWanted: stillWanted)
            switch outcome {
            case .pushed:
                break
            case .skipped:
                report.staleSkipped = true
                return report
            case .stale, .noRegion, .failed:
                // Nothing was written and nothing is overwritten; the settle (or the next rebuild) puts the region in.
                report.repushOwed = true
            }
        }
        return report
    }

    func push(
        region: MarkdownManagedRegion,
        headingLine: String?,
        expectedOld: String,
        newText: String,
        stillWanted: () -> Bool = { true }
    ) async -> Outcome {
        guard stillWanted() else { return .skipped }
        guard let script = Self.script(region: region, headingLine: headingLine, expectedOld: expectedOld, newText: newText) else {
            return .failed("request could not be encoded")
        }
        guard let reply = await evaluate(script),
              let data = reply.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failed("the page did not answer")
        }
        if object["ok"] as? Bool == true {
            if let postRaw = object["postRaw"] as? String { adopt(postRaw) }
            return .pushed(changed: object["changed"] as? Bool ?? true)
        }
        let reason = object["reason"] as? String ?? "unknown"
        switch reason {
        case "regionChanged": return .stale(reason)
        case "noRegion": return .noRegion
        default: return .failed(reason)
        }
    }
}
