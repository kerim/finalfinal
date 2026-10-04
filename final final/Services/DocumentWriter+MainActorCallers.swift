//
//  DocumentWriter+MainActorCallers.swift
//  final final
//
//  t-94369a83 Phase 3a-1b, coder obligation N19: the MainActor-caller assertion for the writer's four
//  synchronous `nonisolated` entry points. The `assertsMainActorCallers` flag itself and the four
//  `assertMainActorCaller(...)` call sites stay in DocumentWriter.swift: a stored property cannot live in
//  an extension, and the call sites are inside `reserve`, `reserveSystem`, `enqueueBarrier` and `retire`.
//

import Foundation

extension DocumentWriter {
    /// N19: the MainActor-caller assertion shared by `reserve`, `reserveSystem`, `enqueueBarrier` and
    /// `retire`. A no-op unless the writer was built with `assertsMainActorCallers: true`.
    nonisolated func assertMainActorCaller(_ entryPoint: String) {
        guard assertsMainActorCallers else { return }
        MainActor.assertIsolated("DocumentWriter.\(entryPoint) must be called on the MainActor (N19)")
    }
}
