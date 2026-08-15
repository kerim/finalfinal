//
//  EditorViewState+ObservableListDiff.swift
//  final final
//

import SwiftUI

// MARK: - Observable List Diff

extension EditorViewState {

    /// Merge freshly-fetched `Block`s into an existing `[SectionViewModel]` array by id,
    /// reusing (and updating in place via `apply(_:)`) any view model whose id is still
    /// present instead of replacing the array wholesale. This is Fix 2: wholesale array
    /// replacement hands every sidebar card a new view-model reference on every database
    /// tick, forcing that card's `@Observable` dependency tracking to tear down and
    /// reinstall -- 48% of main-thread busy time in the 2026-08-10 Instruments trace.
    ///
    /// - Returns: `true` if `existing` was structurally replaced (count changed, or any
    ///   element's identity or position changed) -- i.e. a change SwiftUI's `ForEach` diff
    ///   needs to see. Word-count-only or other in-place field updates on retained objects
    ///   do not count as "structure changed" here; `@Observable` already propagates those.
    @discardableResult
    static func mergeSections(
        into existing: inout [SectionViewModel],
        from blocks: [Block],
        counts: [String: ProjectDatabase.HeadingWordCounts]
    ) -> Bool {
        var byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [SectionViewModel] = []
        result.reserveCapacity(blocks.count)
        for block in blocks {
            let vm: SectionViewModel
            if let reused = byId.removeValue(forKey: block.id) {
                reused.apply(block)
                vm = reused
            } else {
                vm = SectionViewModel(from: block)
            }
            if let wc = counts[block.id] {
                if vm.wordCount != wc.sectionOnly { vm.wordCount = wc.sectionOnly }
                if vm.aggregateGoal != nil, vm.aggregateWordCount != wc.aggregate {
                    vm.aggregateWordCount = wc.aggregate
                }
            }
            result.append(vm)
        }
        let structureChanged = result.count != existing.count
            || zip(result, existing).contains { $0 !== $1 }
        if structureChanged { existing = result }
        return structureChanged
    }

    /// Merge freshly-fetched `Annotation`s into an existing `[AnnotationViewModel]` array by
    /// id. Same shape as `mergeSections`, no word-count patching. See that method's doc
    /// comment for why identity-preserving merge matters.
    @discardableResult
    static func mergeAnnotations(
        into existing: inout [AnnotationViewModel],
        from annotations: [Annotation]
    ) -> Bool {
        var byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [AnnotationViewModel] = []
        result.reserveCapacity(annotations.count)
        for annotation in annotations {
            let vm: AnnotationViewModel
            if let reused = byId.removeValue(forKey: annotation.id) {
                reused.apply(annotation)
                vm = reused
            } else {
                vm = AnnotationViewModel(from: annotation)
            }
            result.append(vm)
        }
        let structureChanged = result.count != existing.count
            || zip(result, existing).contains { $0 !== $1 }
        if structureChanged { existing = result }
        return structureChanged
    }

}
