//
//  EditorViewState+ObservableListDiff.swift
//  final final
//

import SwiftUI

// MARK: - Observable List Diff

extension EditorViewState {

    /// Merge freshly-fetched source elements into an existing `[ViewModel]` array by id,
    /// reusing (and updating in place) any view model whose id is still present instead of
    /// replacing the array wholesale. This is Fix 2: wholesale array replacement hands every
    /// sidebar card a new view-model reference on every database tick, forcing that card's
    /// `@Observable` dependency tracking to tear down and reinstall -- 48% of main-thread busy
    /// time in the 2026-08-10 Instruments trace. Shared by `mergeSections` and
    /// `mergeAnnotations`, which differ only in element/view-model type and in what `apply`
    /// does to a reused view model. Word counts are patched separately, in `finalize`.
    ///
    /// - Parameters:
    ///   - existing: the view-model array to update in place.
    ///   - source: freshly-fetched elements to merge in, keyed by `Element.id`.
    ///   - make: builds a new view model for a source element with no existing counterpart.
    ///   - apply: updates a reused view model in place from its matching source element.
    ///   - finalize: runs on every element's view model, new or reused, after `make`/`apply` --
    ///     this is where `mergeSections` patches word counts, unconditionally on both paths, so
    ///     a newly-created view model's count is never left stuck at zero.
    /// - Returns: `true` if `existing` was structurally replaced (count changed, or any
    ///   element's identity or position changed) -- i.e. a change SwiftUI's `ForEach` diff
    ///   needs to see. In-place field updates on retained objects (via `apply`/`finalize`) do
    ///   not count as "structure changed" here; `@Observable` already propagates those.
    private static func mergeById<Element: Identifiable, ViewModel: AnyObject & Identifiable>(
        into existing: inout [ViewModel],
        from source: [Element],
        make: (Element) -> ViewModel,
        apply: (ViewModel, Element) -> Void,
        finalize: (ViewModel, Element) -> Void = { _, _ in }
    ) -> Bool where Element.ID == String, ViewModel.ID == String {
        var byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [ViewModel] = []
        result.reserveCapacity(source.count)
        for element in source {
            let vm: ViewModel
            if let reused = byId.removeValue(forKey: element.id) {
                apply(reused, element)
                vm = reused
            } else {
                vm = make(element)
            }
            finalize(vm, element)
            result.append(vm)
        }
        let structureChanged = result.count != existing.count
            || zip(result, existing).contains { $0 !== $1 }
        if structureChanged { existing = result }
        return structureChanged
    }

    /// Merge freshly-fetched `Block`s into an existing `[SectionViewModel]` array by id,
    /// reusing (and updating in place via `apply(_:)`) any view model whose id is still
    /// present instead of replacing the array wholesale. See `mergeById`'s doc comment for
    /// why identity-preserving merge matters.
    @discardableResult
    static func mergeSections(
        into existing: inout [SectionViewModel],
        from blocks: [Block],
        counts: [String: ProjectDatabase.HeadingWordCounts]
    ) -> Bool {
        mergeById(
            into: &existing,
            from: blocks,
            make: { SectionViewModel(from: $0) },
            apply: { $0.apply($1) },
            finalize: { vm, block in
                if let wc = counts[block.id] {
                    if vm.wordCount != wc.sectionOnly { vm.wordCount = wc.sectionOnly }
                    if vm.aggregateGoal != nil, vm.aggregateWordCount != wc.aggregate {
                        vm.aggregateWordCount = wc.aggregate
                    }
                }
            }
        )
    }

    /// Merge freshly-fetched `Annotation`s into an existing `[AnnotationViewModel]` array by
    /// id. Same shape as `mergeSections`, no word-count patching. See `mergeById`'s doc
    /// comment for why identity-preserving merge matters.
    @discardableResult
    static func mergeAnnotations(
        into existing: inout [AnnotationViewModel],
        from annotations: [Annotation]
    ) -> Bool {
        mergeById(
            into: &existing,
            from: annotations,
            make: { AnnotationViewModel(from: $0) },
            apply: { $0.apply($1) }
        )
    }

}
