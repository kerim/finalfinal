//
//  TypewriterBridgeTests.swift
//  final finalTests
//
//  Bridge coverage for the typewriter-scrolling API (review finding M12): a renamed
//  `setTypewriterConfig` method or a changed `__testSnapshot()` payload would otherwise fail
//  neither a web test nor a Swift test — the exact silent drift the bridge role exists to
//  catch.
//
//  Shape mirrors `EditorBridgeTests.swift`'s existing focus-mode bridge coverage: a real
//  WKWebView per editor, `EditorTestHelper`, XCTest (not Swift Testing) because WKWebView tests
//  must not run in parallel.
//
//  What this file can and cannot prove: it proves the `window.FinalFinal.setTypewriterConfig`
//  surface exists, is callable from Swift with the exact payload shape the coordinators send,
//  and that `__testSnapshot()` carries each of the five typewriter fields the plan adds. It
//  does NOT prove any on-screen behaviour — jsdom unit tests and the app's own verification
//  list own that.
//
//  No existing test file's expectations are touched by this file.
//

import XCTest
@testable import final_final

/// The five fields `__testSnapshot()` gained for this feature, read raw so the assertion fails
/// if any one of them is renamed or dropped.
private let expectedTypewriterSnapshotKeys = [
    "typewriterActive",
    "typewriterReserve",
    "typewriterRest",
    "typewriterTriggerCount",
    "typewriterLastReason",
]

private func typewriterSnapshotKeys(from raw: Any?) throws -> [String: Any] {
    guard let json = raw as? String, let data = json.data(using: .utf8) else {
        throw EditorTestError.snapshotFailed
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw EditorTestError.snapshotFailed
    }
    return object
}

/// Reads `__testSnapshot()` straight from JS, so the assertion is about the real payload rather
/// than about whatever subset the Swift snapshot model happens to decode.
private func rawSnapshot(_ helper: EditorTestHelper) async throws -> [String: Any] {
    let raw = try await helper.webView.evaluateJavaScript(
        "JSON.stringify(window.FinalFinal.__testSnapshot())"
    )
    return try typewriterSnapshotKeys(from: raw)
}

final class MilkdownTypewriterBridgeTests: XCTestCase {
    private var helper: EditorTestHelper!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        helper = EditorTestHelper(editorType: .milkdown)
        try await helper.loadAndWaitForReady(timeout: 15)
    }

    @MainActor
    func testSetTypewriterConfigIsCallableWithTheCoordinatorPayloadShape() async throws {
        // Exactly the expression both coordinators evaluate: the config object, not two
        // positional arguments.
        _ = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.setTypewriterConfig({enabled: true, lineOffset: -3})"
        )
        let enabled = try await rawSnapshot(helper)
        XCTAssertTrue(enabled["typewriterActive"] is Bool)

        _ = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.setTypewriterConfig({enabled: false, lineOffset: 0})"
        )
        let disabled = try await rawSnapshot(helper)
        XCTAssertEqual(disabled["typewriterActive"] as? Bool, false, "Disabling must report inactive")
    }

    @MainActor
    func testSetTypewriterConfigToleratesAnOutOfRangeOffset() async throws {
        // The module re-clamps; an out-of-range value must not throw or wedge the API.
        _ = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.setTypewriterConfig({enabled: true, lineOffset: 99})"
        )
        let snapshot = try await rawSnapshot(helper)
        XCTAssertNotNil(snapshot["typewriterRest"], "Snapshot must still answer after a clamp")

        _ = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.setTypewriterConfig({enabled: false, lineOffset: 0})"
        )
    }

    @MainActor
    func testSnapshotCarriesEveryTypewriterField() async throws {
        let snapshot = try await rawSnapshot(helper)
        for key in expectedTypewriterSnapshotKeys {
            XCTAssertNotNil(snapshot[key], "__testSnapshot() must carry '\(key)'")
        }
        XCTAssertTrue(snapshot["typewriterReserve"] is NSNumber)
        XCTAssertTrue(snapshot["typewriterRest"] is NSNumber)
        XCTAssertTrue(snapshot["typewriterTriggerCount"] is NSNumber)
    }
}

final class CodeMirrorTypewriterBridgeTests: XCTestCase {
    private var helper: EditorTestHelper!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        helper = EditorTestHelper(editorType: .codemirror)
        try await helper.loadAndWaitForReady(timeout: 15)
    }

    @MainActor
    func testSetTypewriterConfigIsCallableWithTheCoordinatorPayloadShape() async throws {
        _ = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.setTypewriterConfig({enabled: true, lineOffset: 3})"
        )
        let enabled = try await rawSnapshot(helper)
        XCTAssertTrue(enabled["typewriterActive"] is Bool)

        _ = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.setTypewriterConfig({enabled: false, lineOffset: 0})"
        )
        let disabled = try await rawSnapshot(helper)
        XCTAssertEqual(disabled["typewriterActive"] as? Bool, false, "Disabling must report inactive")
    }

    @MainActor
    func testSnapshotCarriesEveryTypewriterField() async throws {
        let snapshot = try await rawSnapshot(helper)
        for key in expectedTypewriterSnapshotKeys {
            XCTAssertNotNil(snapshot[key], "__testSnapshot() must carry '\(key)'")
        }
    }
}
