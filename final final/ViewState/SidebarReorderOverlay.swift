//
//  SidebarReorderOverlay.swift
//  final final
//
//  t-0b70d1e9 (plan-v2 decision 3): what the Outline sidebar shows between an editor-first drag-reorder and the moment its queued job has
//  renumbered the rows. The editor moves the section(s) at once and the sidebar's own list is set to the new order in the same main-actor
//  turn, but every outline result that arrives before the job commits still carries the OLD row order, and would put the cards back.
//  This overlay puts such a result into the order the editor shows, until the job's settle lifts it.
//
//  THE RULE. Applied by `EditorViewState.withoutPendingRemovals`, last of three: the pending removals filter first and always win, the
//  restore overlays merge next, this one puts the result in order. It NEVER adds an id the incoming list lacks (a section deleted after
//  the drag stays gone). Its output is the WHOLE outline array in final order:
//    - the listed leaders (`order`), in `order` order;
//    - an unlisted leader (a heading typed a moment ago, one the sidebar did not list when the plan was made) sits right after the nearest
//      listed leader before it in the INCOMING order, because the database groups it with that leader and it moves with it; with no listed
//      leader before it, it goes first, ahead of every listed leader (the preamble's side of the document). The nearest listed leader is
//      looked up in the UNFILTERED incoming list: a listed leader that a later delete removed still anchors the leaders that hung after it
//      (they take the removed leader's place in the order), so removing a card never re-parents its neighbours (G1);
//    - Notes, then Bibliography, last, whatever `order` says;
//    - every entry's `sortOrder` renumbered 0, 1, 2... (the plan's own numbering);
//    - a listed HEADING with an entry in `levels` takes the planned `headingLevel` and a `markdownFragment` whose `#` prefix is rebuilt by
//      the pure `SectionSyncService.updateHeaderLevel`, so its card shows the right level; every other leader keeps its level.
//
//  The same rule orders the sidebar's own list (`[SectionViewModel]`) in the click's `afterReply` (`showReorderInSidebar`), so a card or
//  an update that arrived during the click's JavaScript window is kept rather than replaced by the plan.
//
//  Pure (no editor state, no database) so a unit test can drive it with plain values.
//

import Foundation

/// One editor-first reorder the sidebar is still showing ahead of the database. `order` is the job's `leaderIds` (the editor's working
/// order with the ids it held no node for taken out); `levels` is the headings whose level the plan changed (id -> new level).
struct PendingReorder: Equatable, Sendable {
    let opId: UUID
    let order: [String]
    let levels: [String: Int]
}

/// What the ordering rule needs to know about an outline entry; `Block` (outline results) and `SectionViewModel` (the sidebar's own list)
/// both have it.
protocol ReorderOverlayItem: RestoreOverlayItem {
    var isNotes: Bool { get }
}

extension Block: ReorderOverlayItem {}
extension SectionViewModel: ReorderOverlayItem {}

enum SidebarReorderOverlay {

    /// `blocks` (an outline result, in its own order) put into `reorder`'s order. See the file header for the rule. `unfiltered` is the
    /// incoming list BEFORE the pending removals were taken out of `blocks` (nil: `blocks` itself); it is only used to find each unlisted
    /// leader's anchor.
    static func apply(_ reorder: PendingReorder, to blocks: [Block], unfiltered: [Block]? = nil) -> [Block] {
        guard !blocks.isEmpty else { return blocks }
        var result = arranged(order: reorder.order, items: blocks, incoming: unfiltered ?? blocks)
        let listedSet = Set(reorder.order)
        for index in result.indices {
            let id = result[index].id
            if let level = reorder.levels[id], listedSet.contains(id), result[index].blockType == .heading {
                result[index].headingLevel = level
                result[index].markdownFragment = SectionSyncService.updateHeaderLevel(in: result[index].markdownFragment, to: level)
            }
            result[index].sortOrder = Double(index)
        }
        return result
    }

    /// The sidebar's own list put into `reorder`'s order, in place on the live view models (so a card keeps its identity and whatever
    /// arrived on it meanwhile): the same rule as above, with the planned level and its `#` prefix set on the listed headings and the
    /// sort orders renumbered. Used by the click's `afterReply`.
    @MainActor
    static func apply(_ reorder: PendingReorder, to sections: [SectionViewModel]) -> [SectionViewModel] {
        guard !sections.isEmpty else { return sections }
        let result = arranged(order: reorder.order, items: sections, incoming: sections)
        let listedSet = Set(reorder.order)
        for (index, section) in result.enumerated() {
            if let level = reorder.levels[section.id], listedSet.contains(section.id),
               !section.isPseudoSection, !section.isNotes, !section.isBibliography, section.headerLevel != level {
                section.headerLevel = level
                section.markdownContent = SectionSyncService.updateHeaderLevel(in: section.markdownContent, to: level)
            }
            section.sortOrder = Double(index)
        }
        return result
    }

    /// The ordering itself. `items` is what is shown (removals already taken out, restores merged in); `incoming` is the list the
    /// anchors of the unlisted leaders are worked out on (the unfiltered outline result). An unlisted item that `incoming` lacks (a
    /// restore overlay's leader) is anchored on its place in `items`.
    private static func arranged<Item: ReorderOverlayItem>(order: [String], items: [Item], incoming: [Item]) -> [Item] {
        // Notes and Bibliography always end the outline, Notes first (the document keeps them at its end).
        let managed = items.filter(\.isNotes) + items.filter { $0.isBibliography && !$0.isNotes }
        let body = items.filter { !$0.isNotes && !$0.isBibliography }

        var byId: [String: Item] = [:]
        for item in body where byId[item.id] == nil { byId[item.id] = item }
        var seen = Set<String>()
        // A listed id counts even when `items` lacks it now (a removed leader): it still holds its slot in the order for the leaders
        // that hung after it. Only the ids that are shown produce an entry below.
        let listed = order.filter { seen.insert($0).inserted }
        let listedSet = Set(listed)

        // The nearest listed leader before each incoming entry, on the unfiltered list (managed entries are not leaders of this order).
        var incomingAnchor: [String: String] = [:]
        var lastListed: String?
        for item in incoming where !item.isNotes && !item.isBibliography {
            if listedSet.contains(item.id) {
                lastListed = item.id
            } else if let lastListed {
                incomingAnchor[item.id] = lastListed
            }
        }
        let inIncoming = Set(incoming.map(\.id))

        // Every unlisted body item hangs after its anchor (nil: nothing listed before it, it goes first).
        var leading: [Item] = []
        var following: [String: [Item]] = [:]
        var lastListedInItems: String?
        for item in body {
            if listedSet.contains(item.id) {
                lastListedInItems = item.id
                continue
            }
            let anchor = inIncoming.contains(item.id) ? incomingAnchor[item.id] : lastListedInItems
            if let anchor {
                following[anchor, default: []].append(item)
            } else {
                leading.append(item)
            }
        }

        var result = leading
        for id in listed {
            if let item = byId[id], listedSet.contains(item.id) { result.append(item) }
            result.append(contentsOf: following[id] ?? [])
        }
        result.append(contentsOf: managed)
        return result
    }
}

extension EditorViewState {

    /// `blocks` put into the order of the pending reorder, if there is one (`SidebarReorderOverlay`). Returns `blocks` itself when there
    /// is none (the normal case). `unfiltered`: the outline result before the pending removals were taken out (see the overlay's rule).
    func mergingPendingReorder(into blocks: [Block], unfiltered: [Block]? = nil) -> [Block] {
        guard let pendingReorder else { return blocks }
        return SidebarReorderOverlay.apply(pendingReorder, to: blocks, unfiltered: unfiltered)
    }

    /// Lifts the reorder overlay of operation `opId`, and only that one: a settle or a put-back that finishes after a newer reorder (or
    /// a slow undo) has taken the slot must leave the newer one alone. Called by the job's settle once an outline read after the commit
    /// has shown the real rows, and by the put-back on every way out.
    func liftPendingReorder(opId: UUID) {
        if pendingReorder?.opId == opId { pendingReorder = nil }
    }
}
