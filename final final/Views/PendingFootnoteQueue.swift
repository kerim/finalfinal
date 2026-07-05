//
//  PendingFootnoteQueue.swift
//  final final
//

/// FIFO queue of footnote labels awaiting insertion while the editor is mid-rebuild.
/// Replaces a former single `String?` slot that silently dropped an insertion when a
/// second one arrived before the first drained (see docs/deferred or task history for
/// "footnote-pending-queue"). ContentView enqueues on the busy guard and dequeues one
/// label per idle transition; order is preserved and nothing is ever overwritten.
struct PendingFootnoteQueue {
    private var labels: [String] = []

    mutating func enqueue(_ label: String) {
        labels.append(label)
    }

    /// Removes and returns the oldest queued label, or nil if empty.
    mutating func dequeue() -> String? {
        guard !labels.isEmpty else { return nil }
        return labels.removeFirst()
    }

    var isEmpty: Bool { labels.isEmpty }

    /// Clears all queued labels (e.g. on project switch) so a pending insertion
    /// from a closed project cannot drain into a newly opened one.
    mutating func reset() {
        labels.removeAll()
    }
}
