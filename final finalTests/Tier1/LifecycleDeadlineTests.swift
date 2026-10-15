// swiftlint:disable identifier_name
// (The test text is the plan's section 7.1 verbatim; its one-letter locals `c`, `d`, `s` trip identifier_name.)

import Foundation
import Testing
@testable import final_final

@MainActor
@Suite("LifecycleDeadline (t-94369a83 3a-1b)", .serialized)
struct LifecycleDeadlineTests {
    final class FakeClock { var now = ContinuousClock.now; func advance(_ s: Double) { now = now.advanced(by: .seconds(s)) } }

    @Test func boundIsOwnWhenPlentyRemains() {
        let c = FakeClock(); let d = LifecycleDeadline(total: 18, now: { c.now })
        #expect(d.bound(own: 8, floor: 6) == 8)
    }
    @Test func boundClampsToRemainingMinusFloor() {
        let c = FakeClock(); let d = LifecycleDeadline(total: 18, now: { c.now })
        c.advance(10.9)
        #expect(abs(d.bound(own: 8, floor: 6) - 1.1) < 0.0001)
    }
    @Test func boundNeverNegative() {
        let c = FakeClock(); let d = LifecycleDeadline(total: 15, now: { c.now })
        c.advance(14.5)
        #expect(d.bound(own: 3, floor: 1) == 0)
    }
    @Test func tightenTakesTheSmallerRemaining() {
        let c = FakeClock()
        let close = LifecycleDeadline(total: 15, now: { c.now }); c.advance(2)
        let quit = LifecycleDeadline(total: 18, now: { c.now }); c.advance(10)
        quit.tighten(to: close)
        #expect(abs(quit.remaining - 3) < 0.0001)
    }
}

// swiftlint:enable identifier_name
