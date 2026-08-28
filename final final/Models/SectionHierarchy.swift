//
//  SectionHierarchy.swift
//  final final
//
//  Pure section-parent derivation rule, extracted so it has exactly one implementation
//  shared by the in-memory path (EditorViewState.recalculateParentRelationships(), which
//  needs a fresh answer every observation tick and must never itself write to the database)
//  and the DB-write path (Database+BlockParents.swift's recomputeSectionParents(), which
//  persists the same answer so anything reading parent relationships straight from the
//  database -- rather than through the live in-memory EditorViewState -- gets the real
//  current structure instead of a stale or absent value).
//

import Foundation

enum SectionHierarchy {
    /// Computes the section-hierarchy parent id for every entry, in document order.
    ///
    /// The rule (unchanged from the original `EditorViewState.findParentByLevel`): a section's
    /// parent is the nearest PRECEDING entry with a STRICTLY LOWER level. A level-1 entry
    /// always has no parent (`nil`), regardless of what precedes it.
    ///
    /// - Parameter entries: Outline entries (heading or pseudo-section blocks) in the exact
    ///   document order the caller wants parents computed over. `level` must already be
    ///   coalesced by the caller -- e.g. `block.headingLevel ?? 1` for a pseudo-section, which
    ///   carries `headingLevel == nil` -- so this function never needs to special-case a nil
    ///   level itself. Both callers (`EditorViewState`'s in-memory path, via
    ///   `SectionViewModel.headerLevel`, and `Database+BlockParents.swift`'s DB-write path, via
    ///   the same `?? 1` coalescing on `Block.headingLevel`) MUST apply that coalescing
    ///   identically before calling in, or a pseudo-section would get different parentage on
    ///   disk than in memory.
    /// - Returns: One parent id per entry, in the same order as `entries` -- `result[i]` is the
    ///   parent of `entries[i]`.
    static func parentIds(for entries: [(id: String, level: Int)]) -> [String?] {
        var result: [String?] = []
        result.reserveCapacity(entries.count)

        for index in entries.indices {
            let level = entries[index].level
            guard level > 1 else {
                result.append(nil)
                continue
            }

            var parentId: String?
            for candidateIndex in stride(from: index - 1, through: 0, by: -1) {
                if entries[candidateIndex].level < level {
                    parentId = entries[candidateIndex].id
                    break
                }
            }
            result.append(parentId)
        }

        return result
    }
}
