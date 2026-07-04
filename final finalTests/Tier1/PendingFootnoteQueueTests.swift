//
//  PendingFootnoteQueueTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Regression tests for PendingFootnoteQueue: a single-slot `String?` used to
//  silently drop a footnote insertion when a second one arrived before the first
//  drained. Lost footnote definitions corrupt documents.
//

import Testing
import Foundation
@testable import final_final

@Suite("Pending Footnote Queue — Tier 1: Silent Killers")
struct PendingFootnoteQueueTests {

    @Test("Two footnotes queued while busy drain in order across separate busy periods; none dropped")
    func pendingFootnoteQueueDrainsBothLabelsInOrderAcrossTwoBusyPeriods() {
        var queue = PendingFootnoteQueue()

        // Editor is busy (e.g. mid-rebuild) when two footnote insertions arrive.
        // A single `String?` slot would let "B" silently overwrite "A" here — the exact
        // shape of the original bug.
        queue.enqueue("A")
        queue.enqueue("B")

        // First idle transition: exactly one label drains, FIFO (oldest first).
        #expect(queue.dequeue() == "A", "Oldest queued label must drain first")
        #expect(!queue.isEmpty, "B must still be waiting — not double-dequeued alongside A")

        // Processing "A" makes the editor busy again (its own rebuild Task) before
        // returning to idle for the next drain.
        #expect(queue.dequeue() == "B", "B must drain on the next idle transition")
        #expect(queue.isEmpty, "Queue must be empty — nothing left behind")
    }

    @Test("dequeue on an empty queue returns nil without side effects")
    func pendingFootnoteQueueDequeueEmptyReturnsNil() {
        var queue = PendingFootnoteQueue()
        #expect(queue.dequeue() == nil)
        queue.enqueue("1")
        #expect(queue.dequeue() == "1")
        #expect(queue.dequeue() == nil)
    }
}
