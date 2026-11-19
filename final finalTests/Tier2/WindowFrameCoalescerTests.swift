//
//  WindowFrameCoalescerTests.swift
//  final finalTests
//

import Testing
import Foundation
import AppKit
@testable import final_final

@MainActor
struct WindowFrameCoalescerTests {

    /// Points at a fresh isolated `UserDefaults` suite for the duration of `body`, instead of
    /// touching the real `com.kerim.final-final` defaults domain -- mirrors the pattern in
    /// `DiagnosticsSettingsTests`.
    private func withIsolatedUserDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "com.kerim.final-final.tests.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        defer {
            testDefaults.removePersistentDomain(forName: suiteName)
        }
        body(testDefaults)
    }

    @Test func twentyNotesCoalesceToOnePendingValue() {
        var coalescer = WindowFrameCoalescer()
        for i in 0..<20 {
            coalescer.note("{{0, 0}, {\(i), \(i)}}")
        }
        let value = coalescer.takeValueToWrite()
        #expect(value == "{{0, 0}, {19, 19}}")
    }

    @Test func noteWithValueEqualToLastWrittenLeavesPendingNil() {
        var coalescer = WindowFrameCoalescer()
        coalescer.note("A")
        #expect(coalescer.takeValueToWrite() == "A")

        // "A" now equals lastWritten -- re-noting it must not create a spurious pending write.
        coalescer.note("A")
        #expect(coalescer.pending == nil)
        #expect(coalescer.takeValueToWrite() == nil)
    }

    @Test func takeValueToWriteCalledTwiceInARowReturnsNilSecondTime() {
        var coalescer = WindowFrameCoalescer()
        coalescer.note("A")
        #expect(coalescer.takeValueToWrite() == "A")
        #expect(coalescer.takeValueToWrite() == nil)
    }

    /// Sanity check that two gestures noting *different* values each get their own value back
    /// from `takeValueToWrite()`. This does NOT catch a `lastWritten`-update bug: since "A" and
    /// "B" are never renoted after being taken, a `takeValueToWrite()` that fails to update
    /// `lastWritten` produces the exact same "A", "B" results here. The tests that actually catch
    /// that bug are `reNotingTheLastWrittenValueSuppressesTheWrite` and
    /// `secondGestureCorrectlyUpdatesLastWrittenNotJustTheFirst` below, which renote a value
    /// that was just taken and assert the guard suppresses it.
    @Test func twoGesturesEachFlushTheirOwnValue() {
        var coalescer = WindowFrameCoalescer()

        coalescer.note("A")
        #expect(coalescer.takeValueToWrite() == "A")

        coalescer.note("B")
        #expect(coalescer.takeValueToWrite() == "B")
    }

    /// The equality guard's whole purpose: renoting a value that's already the last-written value
    /// on disk must not create a pending write, even after an intervening gesture noted (but never
    /// flushed) a different value -- i.e. returning to a previously-written frame (e.g. the user
    /// drags a window away and back) must not queue a redundant write. Before this test there was
    /// no coverage of this "return to a previously-written value" direction at all.
    @Test func reNotingTheLastWrittenValueSuppressesTheWrite() {
        var coalescer = WindowFrameCoalescer()

        coalescer.note("A")
        #expect(coalescer.takeValueToWrite() == "A")

        coalescer.note("B")
        coalescer.note("A")
        #expect(coalescer.pending == nil)
    }

    /// Confirms `lastWritten` is updated by *every* `takeValueToWrite()` call, not just the
    /// first -- i.e. this is the test that actually fails under the `lastWritten = value` deletion
    /// mutation from `takeValueToWrite()`. A sequence that alternates to a *new* value at every
    /// step (A, B, A, ...) does NOT distinguish correct from buggy behavior here: since `note(_:)`
    /// is never called with a value equal to the immediately preceding `takeValueToWrite()`
    /// result, the equality guard never gets exercised either way, and both the correct and the
    /// mutated code return identical "A", "B", "A" results throughout. The guard only gets
    /// exercised -- and only then does correct vs. buggy behavior diverge -- when a value equal to
    /// the just-taken one is renoted immediately afterward, which is what this test does after the
    /// *second* take() (the first take() alone is already covered by
    /// `reNotingTheLastWrittenValueSuppressesTheWrite`).
    @Test func secondGestureCorrectlyUpdatesLastWrittenNotJustTheFirst() {
        var coalescer = WindowFrameCoalescer()

        coalescer.note("A")
        #expect(coalescer.takeValueToWrite() == "A")

        coalescer.note("B")
        #expect(coalescer.takeValueToWrite() == "B")

        // "B" is now lastWritten -- set by the *second* take(), not the first. Renoting it must
        // be suppressed. Under the lastWritten-never-updated mutation, lastWritten would still be
        // nil (or "A") here, so this note("B") would wrongly leave a pending write instead of nil.
        coalescer.note("B")
        #expect(coalescer.pending == nil)
    }

    @Test func takeValueToWriteWithNoInterveningFlushStillReturnsPendingValue() {
        var coalescer = WindowFrameCoalescer()
        coalescer.note("A")
        coalescer.note("B")
        coalescer.note("C")
        #expect(coalescer.takeValueToWrite() == "C")
    }

    @Test func quitAndRelaunchRoundTripThroughWindowFrameStore() {
        withIsolatedUserDefaults { testDefaults in
            var coalescer = WindowFrameCoalescer()
            let finalFrame = NSRect(x: 10, y: 20, width: 800, height: 600)
            coalescer.note(NSStringFromRect(NSRect(x: 0, y: 0, width: 400, height: 300)))
            coalescer.note(NSStringFromRect(NSRect(x: 5, y: 10, width: 600, height: 450)))
            coalescer.note(NSStringFromRect(finalFrame))

            guard let value = coalescer.takeValueToWrite() else {
                Issue.record("expected a pending value to write")
                return
            }
            WindowFrameStore.save(value, to: testDefaults)

            let loaded = WindowFrameStore.load(from: testDefaults)
            #expect(loaded == finalFrame)
        }
    }

    @Test func loadReturnsNilForAbsentKeyInFreshStore() {
        withIsolatedUserDefaults { testDefaults in
            #expect(WindowFrameStore.load(from: testDefaults) == nil)
        }
    }
}
