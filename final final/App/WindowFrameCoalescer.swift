//
//  WindowFrameCoalescer.swift
//  final final
//

import AppKit

/// Coalesces rapid window-frame updates (one per AppKit tick during a live resize/move) down to
/// a single pending value, so callers can debounce the actual UserDefaults write instead of
/// performing it synchronously on every tick. See `AppDelegate.scheduleFrameFlush()` for why this
/// matters: writing UserDefaults synchronously on every resize/move tick was measured (Time
/// Profiler) to trigger a CFPreferences KVO-notification storm and cfprefsd daemon merge that
/// dominates CPU during a live drag.
///
/// Pure value type -- no UserDefaults access, no timers, no AppKit dependency beyond the `NSRect`
/// string representation callers pass in -- so it is trivially unit-testable without touching any
/// real defaults domain.
struct WindowFrameCoalescer {
    /// The last value actually written out (via `takeValueToWrite()`), used as an equality guard
    /// in `note(_:)` to avoid re-queuing a value that's already persisted.
    private var lastWritten: String?

    /// The most recently noted value not yet written out. `nil` when there is nothing pending
    /// (either nothing has been noted since the last flush, or the noted value equals
    /// `lastWritten` and was suppressed).
    private(set) var pending: String?

    /// Records a new frame value from a resize/move tick. Sets `pending` to `value`, except when
    /// `value` equals `lastWritten` -- in that case there's nothing new to persist, so `pending`
    /// is cleared instead of being set to a value that's already on disk.
    mutating func note(_ value: String) {
        if value == lastWritten {
            pending = nil
        } else {
            pending = value
        }
    }

    /// Returns the value that should be written to storage, or `nil` if nothing is pending.
    /// Updates `lastWritten` to the returned value and clears `pending` as a side effect, so the
    /// next `note(_:)` call for the same value hits the equality guard above.
    ///
    /// If this update to `lastWritten` were skipped, `lastWritten` would stay stale (or nil)
    /// forever, so the equality guard in `note(_:)` would never suppress anything -- a later
    /// `note(_:)` call re-noting an already-written value would wrongly be treated as new and
    /// queued again. That's harmless on its own (an extra write, not a lost one), but it silently
    /// disables the guard's actual purpose: suppressing a re-note of the value already on disk.
    /// See `WindowFrameCoalescerTests.reNotingTheLastWrittenValueSuppressesTheWrite` and
    /// `WindowFrameCoalescerTests.secondGestureCorrectlyUpdatesLastWrittenNotJustTheFirst` for the
    /// tests covering this.
    mutating func takeValueToWrite() -> String? {
        guard let value = pending else { return nil }
        lastWritten = value
        pending = nil
        return value
    }
}

/// Thin, testable wrapper around reading/writing the main window's persisted frame. Keyed on
/// `AppDelegate.mainWindowFrameDefaultsKey`, the single existing UserDefaults key for this value
/// -- both this type and `FinalFinalApp`'s `.defaultWindowPlacement` read from it.
enum WindowFrameStore {
    static func save(_ value: String, to store: UserDefaults = .standard) {
        store.set(value, forKey: AppDelegate.mainWindowFrameDefaultsKey)
    }

    /// Returns `nil` when no frame has been saved yet -- never fabricates a default rect. Callers
    /// that need a fallback (e.g. `FinalFinalApp`'s initial-placement default) are responsible for
    /// supplying one themselves.
    static func load(from store: UserDefaults = .standard) -> NSRect? {
        guard let frameString = store.string(forKey: AppDelegate.mainWindowFrameDefaultsKey) else {
            return nil
        }
        return NSRectFromString(frameString)
    }
}
