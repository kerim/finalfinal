//
//  MainLagSampler.swift
//  final final
//
//  Phase 5 job B2 measurement (b2-b4-design.md section 2.4), UI tests only (`FF_UI_TESTING_LAG_SAMPLER=1`): how late the main run
//  loop answers. A utility-queue timer asks the main queue every 10 ms (one question at a time) and records, in a histogram of whole
//  milliseconds, how long the answer took. Every 5 seconds it persists the histogram and starts a new one:
//    [LAG] hist n=<answers> max=<ms> b=<ms>:<count>,<ms>:<count>,...   (only non-empty buckets; 2000 and above share bucket 2000)
//  A test merges the lines of its own window and reads p95 / p99 from the merged histogram.
//

import Foundation
import os

enum MainLagSampler {
    private struct State {
        var running = false
        var inFlight = false
        var buckets: [Int: Int] = [:]
        var count = 0
        var maxMs = 0
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())
    private static let queue = DispatchQueue(label: "final-final.lag-sampler", qos: .utility)
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    static let intervalMs = 10
    static let flushSeconds = 5
    static let lastBucket = 2_000

    /// Starts the sampler only in a UI test launched with `FF_UI_TESTING_LAG_SAMPLER=1` (`TestMode.isUITestingLagSampler`).
    static func startIfRequested() {
        if TestMode.isUITestingLagSampler { start() }
    }

    static func start() {
        let shouldStart = state.withLock { current -> Bool in
            guard !current.running else { return false }
            current.running = true
            return true
        }
        guard shouldStart else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(intervalMs), leeway: .milliseconds(1))
        var lastFlush = DispatchTime.now()
        source.setEventHandler {
            if DispatchTime.now().uptimeNanoseconds - lastFlush.uptimeNanoseconds >= UInt64(flushSeconds) * 1_000_000_000 {
                lastFlush = .now()
                flush()
            }
            let busy = state.withLock { current -> Bool in
                if current.inFlight { return true }
                current.inFlight = true
                return false
            }
            guard !busy else { return }
            let sent = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async {
                let latency = Int((DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000)
                state.withLock { current in
                    current.inFlight = false
                    current.buckets[min(latency, lastBucket), default: 0] += 1
                    current.count += 1
                    current.maxMs = max(current.maxMs, latency)
                }
            }
        }
        timer = source
        source.resume()
        DebugLog.alwaysPersisted("[LAG] sampler started interval=\(intervalMs)ms")
    }

    private static func flush() {
        let snapshot = state.withLock { current -> State in
            let taken = current
            current.buckets = [:]
            current.count = 0
            current.maxMs = 0
            return taken
        }
        guard snapshot.count > 0 else { return }
        let buckets = snapshot.buckets.keys.sorted().map { "\($0):\(snapshot.buckets[$0] ?? 0)" }.joined(separator: ",")
        DebugLog.alwaysPersisted("[LAG] hist n=\(snapshot.count) max=\(snapshot.maxMs) b=\(buckets)")
    }
}
