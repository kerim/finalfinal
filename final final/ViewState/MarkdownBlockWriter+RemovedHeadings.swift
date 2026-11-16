//
//  MarkdownBlockWriter+RemovedHeadings.swift
//  final final
//
//  t-b097670d: the writer's side of the memory of deleted headings (`RemovedHeadingMemory`): recording after a write, and forgetting
//  when the project goes away. The diff reads the memory in `MarkdownBlockWriter.diffAgainstBaseline`.
//

import Foundation

extension MarkdownBlockWriter {

    /// What an APPLIED write did to the remembered headings (clean or not: the deletes and inserts it wrote are real). Called by
    /// `complete`, before the verdict.
    ///
    /// The remembered items an insert took leave the memory, but only those whose insert the write minted (`idMapping` holds its temp
    /// id): a refused or dropped insert keeps its item for the retry. The heading rows the write really deleted, which the diff listed
    /// (`Result.removedHeadings`), are remembered with the fields and the `sortOrder` they had just before the delete
    /// (`EditorApplyResult.deletedHeadings`); a heading whose delete was dropped or refused is not in that dictionary and is not
    /// remembered, because its row still exists. A row a moved heading of the same save takes directly (`carriedByTempId`) is remembered
    /// only when that insert was NOT minted (refused for a stale anchor, say), so the fields are not lost with it; when it was minted the
    /// new row already has them. Not tied to the baseline `version`: a push or reset that landed meanwhile does not undo a delete that
    /// was written.
    func updateRemovedHeadings(from result: MarkdownBlockDiff.Result, projectId: String, applied: EditorApplyResult) {
        let takenTokens = Set(result.usedRemembered.filter { applied.idMapping[$0.tempId] != nil }.map(\.token))
        removedHeadings.consume(tokens: takenTokens)
        let removals = result.removedHeadings.compactMap { removed -> RemovedHeadingMemory.Removal? in
            guard let record = applied.deletedHeadings[removed.id] else { return nil }
            if let carrier = removed.carriedByTempId, applied.idMapping[carrier] != nil { return nil }
            return RemovedHeadingMemory.Removal(key: removed.key, metadata: record.metadata, sortOrder: record.sortOrder)
        }
        removedHeadings.record(removals, projectId: projectId)
    }

    /// The zoomed Markdown save's share of the memory (`applyZoomedRangeWrite`, after `replaceBlocksInRange` has committed): the remembered
    /// items its new headings took leave, and the heading rows it deleted without a same-title partner are remembered.
    func recordZoomedHeadingCarry(_ carry: ZoomedHeadingCarry, projectId: String) {
        removedHeadings.consume(tokens: Set(carry.usedTokens))
        removedHeadings.record(carry.removed, projectId: projectId)
    }

    /// The project is going away (close or project switch): the remembered headings belong to it. Deliberately not part of `reset()`,
    /// which a zoom and a mode switch call on the same document and which must keep them.
    func forgetRemovedHeadings() {
        removedHeadings.forget()
    }
}
