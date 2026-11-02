//
//  MdSpeed.swift
//  final final
//
//  Performance job, rounds M1 and M2: MEASUREMENT ONLY. Step timings for the three Markdown section commands (Delete Section, the Outline
//  drag, Duplicate Section) on a book-length document, so the fix round can start from a table of numbers instead of a guess.
//
//  Every span is a `StructuralTrace` span (StructuralTrace.swift), so it is silent unless tracing is on (diagnostics logging, or
//  `FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING=1` in a UI test) and writes the same two lines:
//
//    [STRUCT-TRACE] t=<ms>ms +timeline=<ms>ms <label> op=<id> start md-speed <command> <step>
//    [STRUCT-TRACE] t=<ms>ms +timeline=<ms>ms <label> op=<id> end md-speed <command> <step> took=<n>ms
//
//  `<command>` is `delete`, `drag` or `duplicate`, taken from the timeline's label (a function shared by the three commands is named
//  by whichever one is running; the Restore and undo/redo commands that share them show their own label). `+timeline=` counts from
//  the click: Delete and Duplicate start their timeline at the menu click (`click-start`), the drag at the drop
//  (`md-speed drag drop-received`). A step name never ends in " start" or " performed" (the UI-test parser matches the op's own lines
//  by those suffixes).
//
//  Nothing here changes behaviour or order: a span only reads the clock and writes a line. No span text contains document text. A step
//  name and a detail are built lazily (autoclosures), so while tracing is off a span costs one cached boolean read.
//
//  A span can be written from any thread (the trace's recorder is lock-protected): spans inside a database write run off the main thread.
//

import Foundation

enum MdSpeed {

    /// The command a timeline label stands for, as the step names say it.
    static func command(forLabel label: String) -> String {
        switch label {
        case "sectionDelete": return "delete"
        case "sectionReorder": return "drag"
        case "sectionDuplicate": return "duplicate"
        default: return label
        }
    }

    /// Starts the span `md-speed <command> <step>`; call `end()` on the result. Silent while tracing is off.
    static func span(_ step: @autoclosure () -> String, _ detail: @autoclosure () -> String = "") -> StructuralTraceSpan {
        guard StructuralTrace.isOn else { return StructuralTrace.span("") }
        return StructuralTrace.span("md-speed \(command(forLabel: StructuralTrace.shared.currentLabel)) \(step())", detail())
    }

    /// Runs `body` as the span `md-speed <command> <step>`.
    @discardableResult
    static func timed<T>(_ step: @autoclosure () -> String, _ body: () throws -> T) rethrows -> T {
        let timedSpan = span(step())
        defer { timedSpan.end() }
        return try body()
    }

    /// One plain timeline line `md-speed <command> <note>` (a marker, not a span).
    static func mark(_ note: @autoclosure () -> String) {
        guard StructuralTrace.isOn else { return }
        StructuralTrace.log("md-speed \(command(forLabel: StructuralTrace.shared.currentLabel)) \(note())")
    }
}
