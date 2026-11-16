//
//  DiagnosticLogPrivacyTests.swift
//  final finalTests
//
//  t-561c4083: the diagnostic log (the file the user's Diagnostics switch writes, and which they may attach to a bug report)
//  must not hold key codes or pieces of the document. Document text goes into a log line only through `DebugLog.docText`,
//  which writes `len=<n>` unless the developer-only switch (`FF_DEV_LOG_KEYS_AND_TEXT=1`) is on.
//
//  WHAT THE SOURCE SCAN COVERS, AND WHAT IT DOES NOT. It covers the NAMED expressions (`bannedPatterns`, plus the ones scoped
//  to a call's label) inside the parentheses of a `DebugLog.log / always / alwaysPersisted` call, and a message built into a
//  variable whose name says "message", "msg" or "log" (the shape of the zoom heading line). It does NOT see document text
//  under a name that is not in the list, or text that reaches a call by another route (a message built several steps away,
//  a helper that logs on the caller's behalf). It is a guard against the known leaks coming back, not proof that no other
//  line leaks; the end-to-end proof is the UI test that searches the real log. Add a pattern when a new text-bearing line
//  appears. The expected values here are worked out by hand from the rule (a length is the character count), never read
//  back from the code.
//

import Foundation
import Testing
@testable import final_final

@Suite("Diagnostic log keeps no key codes or document text (t-561c4083)")
struct DiagnosticLogPrivacyTests {

    @Test func docTextIsLengthOnlyWhenTheDeveloperSwitchIsOff() {
        #expect(DebugLog.docText("Zyxquorbit and more", developerDetail: false) == "len=19")
        #expect(DebugLog.docText("", developerDetail: false) == "len=0")
        #expect(DebugLog.docText("Zyxquorbit", developerDetail: true) == "\"Zyxquorbit\"")
    }

    /// The scanner itself works: raw text is flagged, a length or a docText-wrapped text is not, also when nested, and a
    /// label-scoped name (a bare `line` in a stripNotesSection call) is flagged only inside that call.
    @Test func scannerFlagsOnlyRawText() {
        let source = #"""
        DebugLog.log(.footnotes, "fragment=\"\(row.markdownFragment)\" n=\(row.markdownFragment.count) ok=\(DebugLog.docText(row.markdownFragment))")
        DebugLog.log(.sync, { let firstHeading = "x"; return "firstH=\"\(firstHeading)\" ok=\(DebugLog.docText(firstHeading))" }())
        DebugLog.log(.proofing, "bad: \(dropped.map { "\($0.word)[\($0.ruleId ?? "?")]" }.joined(separator: ", "))")
        DebugLog.log(.proofing, "good: \(dropped.map { "\(DebugLog.docText($0.word))[\($0.ruleId ?? "?")]" }.joined(separator: ", "))")
        DebugLog.log(.lifecycle, "project \(project.title) empty=\(first.title.isEmpty)")
        DebugLog.log(.footnotes, "stripNotesSection: opened line=\"\(line.prefix(60))\" ok=\(DebugLog.docText(line)) n=\(line.count)")
        DebugLog.log(.editor, "[CURSOR-SYNC] Relay: line=\(position.line) col=\(position.column)")
        """#
        let flagged = Self.rawTextExpressions(in: source).map { $0.expression.trimmingCharacters(in: .whitespaces) }
        #expect(flagged == [
            "row.markdownFragment",
            "firstHeading",
            #"dropped.map { "\($0.word)[\($0.ruleId ?? "?")]" }.joined(separator: ", ")"#,
            "$0.word",
            "line.prefix(60)"
        ])
    }

    /// The key-code check flags a key code interpolated into a line or passed to a call, except through the key monitor's
    /// own `keyPressLine` (which leaves the code out unless the developer switch is on).
    @Test func scannerFlagsOnlyKeyCodes() {
        let source = #"""
        DebugLog.log(.undo, "key \(event.keyCode)")
        DebugLog.alwaysPersisted("[TRANS] dropped the resend (code=\(keyCode))")
        DebugLog.log(.undo, keyPressLine(t: 1, code: event.keyCode, inEditor: true))
        DebugLog.log(.undo, "echo t=\(t)")
        """#
        let leaking = Self.debugLogCalls(in: source).filter { Self.carriesKeyCode($0.text) }.map { $0.line }
        #expect(leaking == [1, 2])
    }

    /// The hoisted-message check flags raw text in a `let …Message/Msg/Log… = "…"` string (the zoom heading line was built
    /// that way and passed to the log afterwards), also over a `+` continuation, and nothing else.
    @Test func scannerFlagsOnlyHoistedLogMessagesWithRawText() {
        let source = #"""
        let headingLogMessage = "[Zoom] Heading: id=\(block.id), " +
            "fragment=\"\(String(block.markdownFragment.prefix(80)))\""
        let sizeLogMessage = "[Zoom] n=\(block.markdownFragment.count)"
        let wrappedLogMessage = "[Zoom] fragment=\(DebugLog.docText(block.markdownFragment))"
        let unrelated = "\(block.markdownFragment)"
        """#
        let flagged = Self.hoistedLogMessages(in: source).flatMap { message in
            Self.interpolations(in: message.text).filter { Self.isRawText($0, callText: message.text) }
        }
        #expect(flagged == ["String(block.markdownFragment.prefix(80))"])
    }

    /// No DebugLog call in the app interpolates one of the named text expressions except through DebugLog.docText. The scan
    /// must have looked at the calls: a scan that found nothing to look at would pass this test for the wrong reason.
    @Test func noLogCallInterpolatesDocumentTextDirectly() throws {
        var offenders: [String] = []
        var callCount = 0
        for file in try Self.appSources() {
            callCount += Self.debugLogCalls(in: file.source).count
            for hit in Self.rawTextExpressions(in: file.source) {
                offenders.append("\(file.name):\(hit.line): \(hit.expression)")
            }
        }
        #expect(callCount > 1000, "the scan saw only \(callCount) DebugLog calls (the app has well over a thousand)")
        #expect(offenders.isEmpty, "log lines that put document text in the log: \(offenders)")
    }

    /// No DebugLog call in the app carries a key code.
    @Test func noLogCallCarriesAKeyCode() throws {
        var offenders: [String] = []
        for file in try Self.appSources() {
            for call in Self.debugLogCalls(in: file.source) where Self.carriesKeyCode(call.text) {
                offenders.append("\(file.name):\(call.line)")
            }
        }
        #expect(offenders.isEmpty, "log lines that carry a key code: \(offenders)")
    }

    /// No `let …Message/Msg/Log… = "…"` string in the app interpolates one of the named text expressions: a message built
    /// outside the log call is not seen by the call scan above.
    @Test func noHoistedLogMessageInterpolatesDocumentText() throws {
        var offenders: [String] = []
        for file in try Self.appSources() {
            for message in Self.hoistedLogMessages(in: file.source) {
                for expression in Self.interpolations(in: message.text) where Self.isRawText(expression, callText: message.text) {
                    offenders.append("\(file.name):\(message.line): \(expression)")
                }
            }
        }
        #expect(offenders.isEmpty, "log messages built outside the call that put document text in the log: \(offenders)")
    }

    // MARK: - Source scan helpers (UTF-16 throughout, so NSRange offsets and indices agree)

    /// The expressions that carry document text into a log line (t-561c4083), by the names they had when the leaks were
    /// found. Exact identifiers only: a broad `title` would flag the project titles that are left in the log on purpose.
    static let bannedPatterns: [String] = [
        #"\bmarkdownFragment\b"#,                          // a block's text (footnote, image, migration, zoom lines)
        #"\bfragment\b"#,                                  // the same, under a local name
        #"\bfirstHeading\b"#,                              // BlockSyncService setContentWithBlockIds firstH=
        #"\bfirstLine\(of:[^)]*startingWith:"#,            // MilkdownCoordinator+MessageHandlers ContentPush firstH=
        #"\bfirst\.title\b"#,                              // ContentView Version History first section title
        #"\b(head|tail)\.replacingOccurrences\b"#,         // LanguageToolProvider [LT] head / tail
        #"\$0\.word\b"#,                                   // SpellCheckService spellingBucket sample
        #"\bfrag\b"#,                                      // FootnoteSyncService orphan sweep: a trimmed block text
        #"\bcurrentBlock\b"#                               // BlockParser+Splitting list-interruption guard: the block's text
    ]

    /// Names that are banned only inside a call whose own text carries the label (the least brittle form for a name as
    /// common as `line`, which is also a cursor line number elsewhere): the label is a fixed string in the log line.
    static let labelScopedPatterns: [(label: String, pattern: String)] = [
        ("stripNotesSection:", #"\bline\b"#)               // FootnoteSyncService stripNotesSection: a line of the document
    ]

    static func repoRoot(_ testFilePath: String = #filePath) -> URL {
        URL(fileURLWithPath: testFilePath)
            .deletingLastPathComponent()   // Tier1/
            .deletingLastPathComponent()   // final finalTests/
            .deletingLastPathComponent()   // repo root
    }

    /// Every Swift source file of the app (`final final/`), as (file name, text).
    static func appSources() throws -> [(name: String, source: String)] {
        let root = repoRoot().appendingPathComponent("final final")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var sources: [(name: String, source: String)] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            sources.append((url.lastPathComponent, text))
        }
        return sources
    }

    static func debugLogCalls(in source: String) -> [(line: Int, text: String)] {
        let units = Array(source.utf16)
        // swiftlint:disable:next force_try
        let regex = try! NSRegularExpression(pattern: #"DebugLog\.(log|always|alwaysPersisted)\s*\("#)
        var calls: [(line: Int, text: String)] = []
        for match in regex.matches(in: source, range: NSRange(location: 0, length: units.count)) {
            let start = match.range.location + match.range.length
            guard let end = closingParen(in: units, from: start) else { continue }
            let line = units[..<match.range.location].filter { $0 == 10 }.count + 1
            calls.append((line, String(decoding: units[start..<end], as: UTF16.self)))
        }
        return calls
    }

    /// Every interpolation in a DebugLog call of `source` that puts one of the named text expressions in the line.
    static func rawTextExpressions(in source: String) -> [(line: Int, expression: String)] {
        debugLogCalls(in: source).flatMap { call in
            interpolations(in: call.text)
                .filter { isRawText($0, callText: call.text) }
                .map { (line: call.line, expression: $0) }
        }
    }

    /// A call whose text mentions `keyCode`, other than the key monitor's own `keyPressLine(…)` call.
    static func carriesKeyCode(_ callText: String) -> Bool {
        callText.range(of: #"\bkeyCode\b"#, options: .regularExpression) != nil && !callText.contains("keyPressLine(")
    }

    /// Every `let/var <name containing message, msg or log> = "…"` statement, with its `+` continuation lines, as (line, text).
    static func hoistedLogMessages(in source: String) -> [(line: Int, text: String)] {
        let lines = source.components(separatedBy: "\n")
        // swiftlint:disable:next force_try
        let start = try! NSRegularExpression(
            pattern: #"^\s*(?:let|var)\s+\w*(?:[Mm]essage|[Mm]sg|[Ll]og)\w*\s*(?::\s*String\s*)?=\s*"#)
        var found: [(line: Int, text: String)] = []
        var index = 0
        while index < lines.count {
            let first = lines[index]
            guard start.firstMatch(in: first, range: NSRange(location: 0, length: first.utf16.count)) != nil else {
                index += 1
                continue
            }
            var text = first
            var next = index + 1
            while text.trimmingCharacters(in: .whitespaces).hasSuffix("+"), next < lines.count {
                text += "\n" + lines[next]
                next += 1
            }
            found.append((index + 1, text))
            index = next
        }
        return found
    }

    static func closingParen(in units: [UInt16], from start: Int) -> Int? {
        var depth = 1
        var index = start
        while index < units.count {
            if units[index] == 40 { depth += 1 } else if units[index] == 41 {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    /// The expression inside every `\( … )` in `text`, nested ones included.
    static func interpolations(in text: String) -> [String] {
        let units = Array(text.utf16)
        var result: [String] = []
        var index = 0
        while index + 1 < units.count {
            if units[index] == 92, units[index + 1] == 40, let end = closingParen(in: units, from: index + 2) {
                result.append(String(decoding: units[(index + 2)..<end], as: UTF16.self))
            }
            index += 1
        }
        return result
    }

    /// `expression` with every `DebugLog.docText( … )` call cut out (those are allowed wherever they sit).
    static func withoutDocTextCalls(_ expression: String) -> String {
        var units = Array(expression.utf16)
        let marker = Array("DebugLog.docText(".utf16)
        var index = 0
        while index + marker.count <= units.count {
            if Array(units[index..<(index + marker.count)]) == marker,
               let end = closingParen(in: units, from: index + marker.count) {
                units.removeSubrange(index...end)
            } else {
                index += 1
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// An interpolation that puts document text in the line: it still names a banned expression (one of `bannedPatterns`, or a
    /// label-scoped one when `callText` carries the label) once the `DebugLog.docText(…)` calls are cut out, and that use is
    /// not followed by `.count`, `.utf16.count` or `.isEmpty`.
    static func isRawText(_ expression: String, callText: String = "") -> Bool {
        let rest = withoutDocTextCalls(expression) as NSString
        let patterns = bannedPatterns + labelScopedPatterns.filter { callText.contains($0.label) }.map { $0.pattern }
        for pattern in patterns {
            // swiftlint:disable:next force_try
            let regex = try! NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: rest as String, range: NSRange(location: 0, length: rest.length)) {
                let after = rest.substring(from: match.range.location + match.range.length)
                if after.range(of: #"^(\.utf16)?\.count\b|^\.isEmpty\b"#, options: .regularExpression) == nil { return true }
            }
        }
        return false
    }
}
