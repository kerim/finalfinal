//
//  DocumentWriter+SystemWrite.swift
//  final final
//
//  Phase 2 (t-94369a83), §1: the "system write" kind -- routes bibliography, Notes,
//  and heading-level writes through the SAME ordered queue Phase 1 built for editor
//  diffs, via ONE public entry point, `BlockSyncService.performSystemWrite`. See
//  docs/architecture/document-writer.md for the full design.
//
//  File-organization note (judgment call, recorded in this dispatch's report): the
//  plan's own §1.2 header says "DocumentWriter+SystemWrite.swift, plus small helpers
//  in DocumentWriter.swift" for the WRITER side. In practice almost everything that
//  touches `WriterState`/`Signal`/the locked helpers had to go directly into
//  DocumentWriter.swift instead, because those types and helpers are declared
//  `private` there -- Swift's `private` at file scope means "this file only", so an
//  extension in a SEPARATE file (this one) cannot see them. This file therefore holds
//  only the free-standing types below (which need no access to that private state)
//  plus the task-local nesting guard. `performSystemWrite` itself lives directly in
//  BlockSyncService.swift for the same reason -- it needs `BlockSyncService.writer`,
//  which is `private` there.
//

import Foundation
import GRDB

// MARK: - Public types

/// The project/database a system write is scoped to, captured by the CALLER from its
/// own properties at entry, before any `await` -- never re-resolved later from
/// `DocumentManager.shared`. Compared against the writer's own `database`/`projectId`
/// with `===` (a `ProjectDatabase` is a reference type), so a write can never land in
/// the wrong project even if the writer was replaced mid-flight.
struct SystemWriteIdentity: Sendable {
    let projectId: String
    let database: ProjectDatabase
}

/// Every way `performSystemWrite`/`DocumentWriter.applySystemWrite` can refuse a
/// system write without ever running its body.
enum SystemRefuseReason: Sendable, Equatable {
    case skipped(SkipReason)
    case outOfTurn
    case identityMismatch
    case writerRetired
    case notWanted
    case nested
    case noWriter
}

/// Outcome of a system write.
enum SystemWriteOutcome<R: Sendable>: Sendable {
    case applied(R)
    case refused(SystemRefuseReason)
    case failed(Error)
}

/// `performSystemWrite`'s full result -- the outcome plus whether `prepare` ran.
/// [M1] `prepareRan` is set by `performSystemWrite` itself, immediately after it
/// calls `prepare?()`, and only when a `prepare` closure was actually supplied.
/// Callers decide recovery from THIS flag, never by pattern-matching the refusal's
/// name -- see the plan's Notes-recovery table (§2.3) for why the two don't coincide
/// one-to-one (a `.nested` refusal is always `prepareRan == false`; a `.refused(.skipped)`
/// after a `prepare` ran is `prepareRan == true`).
struct SystemWriteResult<R: Sendable>: Sendable {
    let outcome: SystemWriteOutcome<R>
    let prepareRan: Bool
}

/// The writer's temp-id -> permanent-id map as it stood when a system write was admitted (a copy,
/// taken under the writer's lock after admission said `.proceed`), handed to a body written against
/// the `(Database, IdMap)` overload of `applySystemWrite`/`performSystemWrite`. A body that has to name
/// rows by an editor id which may still be a temp id (`SectionDeleteJob`: a paragraph typed inside the
/// section a moment before the delete) resolves it through this map. Every ordinary body takes only
/// the `Database` and never sees it.
typealias IdMap = [String: String]

/// What a system-write body hands back to the writer: the caller-facing return value,
/// plus (Phase 2's extension of the addendum A2 §2 tombstone mechanism) any rows this
/// write deleted, so a still-in-flight late/abandoned EDITOR insert anchored on one of
/// them can still re-anchor. No `writtenIds`/stamp field -- system writes are never
/// stamped (§1.4): the rows they touch (bibliography, Notes definitions, heading
/// levels) are either already refused-by-guard to a stale editor batch, or a stamp
/// would actively cause harm (see the plan's §1.4 table). A `.sectionDelete` stamps
/// nothing for a simpler reason: the rows it touches are gone when it commits, and the
/// `deletedAnchors` it returns are what a late editor insert anchored inside the section
/// re-anchors through.
///
/// ONE DELIBERATE EXCEPTION (t-94369a83 Phase 3a-1a, plan §2.3; obligation 16): a
/// `.lifecycleWholeDocument` write (FB, the close/quit/switch save) DOES bump the project's
/// block-write epoch and restamp every row to `(E+1, 0)` WHEN IT WRITES (a checked FB, Phase 3a-2, whose
/// stored rows already match what it would write, writes nothing and bumps nothing; see below) --
/// inside its own transaction, through
/// the `replaceBlocks*` statics (`stampWholeProjectForRewrite`), not through anything on this
/// type. A whole-document rewrite is exactly what the epoch exists to invalidate stale batches
/// for: an editor batch reserved before FB's commit carries epoch E and is refused WHOLE (inserts
/// included) by rule 1 of `applyBlockChangesFromEditor`, but only if it applies AFTER FB's commit.
/// A lower-numbered batch that gets its turn before FB applies normally and is then replaced by
/// FB's content.
///
/// Why that is safe: the lifecycle makes FB's content cover every batch that could still apply
/// after it (polling stopped at step 0, F drains the poll in flight and forces one more poll, FB
/// writes a fresh fetch), so the refusal only lands on a late or orphaned batch holding OLDER
/// content than FB's fetch; and because polling is stopped, no editor sequence is reserved between
/// FB's reservation and its commit. Only when the editor does not answer (FB falls back to
/// `editorState.content`) can edits in flight be refused, lost and uncounted
/// (`rejectedWholeBatchForStaleEpoch` feeds no ledger counter): the known hung-editor gap. Every
/// OTHER kind still never stamps or bumps.
///
/// A skipped (unchanged) FB is safe for a different reason than a written one: a clean F does not mean no
/// editor batch can apply after FB (a `.late` sequence still may), but the row comparison inside FB's own
/// transaction means any content not yet applied makes FB write after all, and rows already written by a
/// newer batch are protected by row rule 2 and by the held temp-id ops. See `applySystemWrite`.
struct SystemWriteBody<R: Sendable>: Sendable {
    var value: R
    var deletedAnchors: [String: DeletedAnchor] = [:]
}

/// Which write site a call came from -- carried through for logging/diagnostics, and (since
/// Phase 3a-1a) read by `applySystemWrite` for exactly one thing: the
/// `lifecycleWholeDocumentApplied` counter, bumped when `kind == .lifecycleWholeDocument`.
/// No other branch in `DocumentWriter` reads it. Every case has a real call site:
/// `.bibliographyUpdate`/`.bibliographyRemoval` (`BibliographySyncService`),
/// `.bibliographyRename` (`ContentView+NotificationHandlers.swift`),
/// `.notesUpdate`/`.notesRemoval`/`.notesInsertion` (`FootnoteSyncService`),
/// `.headingLevels` (`ContentView+HierarchyEnforcement.swift`), `.lifecycleWholeDocument` (the
/// queued whole-document save a close/switch/quit takes through the writer, Phase 3a-1b step 6:
/// `EditorViewState.runLifecycleFlush` via `BlockSyncService.performLifecycleWholeDocumentWrite`), and
/// `.sectionDelete` (t-94369a83 Phase 4b, slice 2a: the queued job behind an editor-first section
/// delete, `SectionDeleteJob`; like every kind but FB it never stamps rows or bumps the epoch), and `.sectionReinsert` (slice 2b:
/// the queued job behind a quick undo of that delete, `SectionReinsertJob`; same rules as `.sectionDelete`).
enum SystemWriteKind: Sendable, Equatable {
    case bibliographyUpdate
    case bibliographyRemoval
    case bibliographyRename
    case notesUpdate
    case notesRemoval
    case notesInsertion
    case headingLevels
    case lifecycleWholeDocument
    case sectionDelete
    case sectionReinsert
}

// MARK: - No nesting (§1.3)

/// Two task-locals guarding against a system write starting from inside another
/// system write's own wait/apply window, or from inside an editor batch's
/// fetch-to-apply window.
enum SystemWriteScope {
    /// Set around `performSystemWrite`'s steps 5-8 (prepare through apply -- widened
    /// from 6-8 by review finding #11: `prepare` and `apply` both used to run OUTSIDE
    /// this window, so a system write started synchronously from inside `prepare` or
    /// from inside the `body` closure wouldn't have been caught as nested). A
    /// `performSystemWrite` call observing this already `true` (including via task
    /// inheritance) is refused `.nested` before it reserves anything.
    @TaskLocal static var active: Bool = false
    // Set by `doPollBlockChanges` from immediately after `reserveWriterTurn` until
    // `applyAndConfirm` returns (or its `defer` settles) -- wired in (Phase 2,
    // t-94369a83 §1.3): the existing fetch-to-apply body is wrapped verbatim in
    // `SystemWriteScope.$heldEditorSeq.withValue(ticket.seq) { ... }`, a synchronous
    // save/restore around the same `await`s already there, changing nothing about
    // control flow, suspension points, or the "no cancellation-observing await
    // between fetch and apply" invariant documented above `reserveWriterTurn`.
    // `performSystemWrite`'s own check against it (step 1) is live -- see W34
    // (SystemWriteOrderingTests.swift) for the full-stack proof.
    // swiftlint:disable:next implicit_optional_initialization
    @TaskLocal static var heldEditorSeq: UInt64? = nil
}

// MARK: - System reservation (§1.1 step 4)

/// The handle `DocumentWriter.reserveSystem()` returns -- mirrors `WriterTicket`
/// exactly, wrapped by `SystemReservation` below rather than used directly.
struct SystemTicket: Sendable {
    let writer: DocumentWriter
    let seq: UInt64
}

/// "One locked region, wrapped in a self-settling class" (§1.1 step 4): `consume()`
/// marks the reservation as having been properly settled by the writer itself
/// (applied, failed, or a settled/skipped no-longer-wanted); if `performSystemWrite`
/// returns on any OTHER path without calling `consume()` (a refusal `applySystemWrite`
/// itself does not settle -- out-of-turn or retired, mirroring `applyEditorBatch`'s
/// own unsettled out-of-turn refusal), `deinit` settles it via
/// `abandonSystemReservation`, counted in `systemReservationsAbandoned`.
final class SystemReservation {
    let ticket: SystemTicket
    private var consumed = false

    init(_ ticket: SystemTicket) {
        self.ticket = ticket
    }

    func consume() {
        consumed = true
    }

    deinit {
        if !consumed {
            ticket.writer.abandonSystemReservation(ticket.seq)
        }
    }
}

// MARK: - Typed handle (§2.0)

/// §2.0's "Typed handle": lets a sync service (`BibliographySyncService`,
/// `FootnoteSyncService`, ...) call `performSystemWrite` without holding a strong
/// reference to `BlockSyncService` (which itself is `@MainActor` and owns the
/// `DocumentWriter` instance). `weak` so a service outliving `BlockSyncService`
/// (shouldn't normally happen, but matches `weak var editorState` elsewhere in this
/// codebase) degrades to `.noWriter` rather than a dangling reference.
@MainActor
struct SystemWriter {
    weak var blockSync: BlockSyncService?

    func perform<R: Sendable>(
        identity: SystemWriteIdentity,
        kind: SystemWriteKind,
        stillWanted: @escaping () -> Bool,
        prepare: (() -> Void)? = nil,
        body: @escaping @Sendable (Database) throws -> SystemWriteBody<R>
    ) async -> SystemWriteResult<R> {
        guard let blockSync else {
            return SystemWriteResult(outcome: .refused(.noWriter), prepareRan: false)
        }
        return await blockSync.performSystemWrite(
            identity: identity, kind: kind, stillWanted: stillWanted, prepare: prepare, body: body)
    }
}
