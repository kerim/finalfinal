// swiftlint:disable identifier_name
// (The test text is the plan's section 7.1 verbatim; its short locals `es`, `sw`, `q`, `t` trip identifier_name.)

import Foundation
import Testing
@testable import final_final

@MainActor
@Suite("Lifecycle token precedence (t-94369a83 3a-1b)", .serialized)
struct LifecycleTokenTests {
    private func armed(_ r: ArmResult) -> LifecycleToken? { if case .armed(let t) = r { return t }; return nil }
    private func joined(_ r: ArmResult) -> LifecycleToken? { if case .joined(let t) = r { return t }; return nil }

    @Test func armWhenIdleInstallsToken() throws {
        let es = EditorViewState()
        let t = try #require(armed(es.armLifecycle(.close, wasGettingStarted: false)))
        #expect(es.activeLifecycle == t)
    }
    @Test func sameKindRepeatIsADuplicateNoOp() throws {
        let es = EditorViewState()
        let t = try #require(armed(es.armLifecycle(.close, wasGettingStarted: false)))
        #expect(es.armLifecycle(.close, wasGettingStarted: false) == .duplicate)
        #expect(es.activeLifecycle == t)
    }
    @Test func otherKindWhileArmedIsRefusedBusy() throws {
        let es = EditorViewState()
        _ = try #require(armed(es.armLifecycle(.projectSwitch, wasGettingStarted: false)))
        #expect(es.armLifecycle(.close, wasGettingStarted: false) == .refusedBusy(active: .projectSwitch))
    }
    @Test func quitJoinsAndTheOldClearIsANoOp() throws {
        let es = EditorViewState()
        let sw = try #require(armed(es.armLifecycle(.projectSwitch, wasGettingStarted: false)))
        let q = try #require(joined(es.armLifecycle(.quit, wasGettingStarted: false)))
        #expect(es.clearLifecycle(sw.id) == false)
        #expect(es.activeLifecycle == q)
    }
    @Test func compareAndClear() throws {
        let es = EditorViewState()
        let t = try #require(armed(es.armLifecycle(.close, wasGettingStarted: true)))
        #expect(t.wasGettingStarted)
        #expect(es.clearLifecycle(UUID()) == false)
        #expect(es.clearLifecycle(t.id))
        #expect(es.activeLifecycle == nil)
    }
}

// swiftlint:enable identifier_name
