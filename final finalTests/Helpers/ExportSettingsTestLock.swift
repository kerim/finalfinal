//
//  ExportSettingsTestLock.swift
//  final finalTests
//
//  Shared cross-suite mutual exclusion for every test that points
//  `ExportSettings.userDefaults` — a single process-wide `nonisolated(unsafe) static var`
//  (see that property's doc comment in ExportSettings.swift) — at a throwaway per-test
//  `UserDefaults(suiteName:)` instance for the duration of a test body.
//
//  THE RACE: `.serialized` on a `@Suite` only orders that suite's OWN tests against each
//  other; Swift Testing runs DIFFERENT suites concurrently by default. Three suites swap
//  `ExportSettings.userDefaults` today — `BibliographyRenameGraceNameTests`,
//  `BlockParserBibliographyHeaderNameTests`, and `ExportSettingsResetNotificationTests` —
//  and each already documented this in its own file as a known, previously-latent risk.
//  It stopped being latent: a full-suite run (1184 tests, no class scoping) reproduced a
//  failure in `BibliographyRenameGraceNameTests.staleReparseAfterRenameKeepsBibliographyFlags`
//  that this lock exists to close, while the same 3-test class scoped in isolation (never
//  running alongside the other two files) passed 8/8 times — proof the failure is a genuine
//  cross-suite race over this shared static, not a stale build artifact and not a bug in the
//  feature under test. `BlockParser.parse`/`.isBibliographyHeading` read
//  `ExportSettings.userDefaults` (via `ExportSettings.load()`) on every call, so any test in
//  one of the 3 files above that is mid-swap while a test in another of the 3 runs a parse
//  can observe the wrong (throwaway, or half-restored) settings.
//
//  THE FIX: a single process-wide lock, held for the ENTIRE window from the moment
//  `ExportSettings.userDefaults` is pointed at a throwaway store until it — and any
//  `ExportSettingsManager.shared` in-memory cache swapped alongside it — has been fully
//  restored to the real value, not just around the swap statement itself. Every place in
//  those 3 files that performs this swap acquires this lock immediately before the swap and
//  releases it only in the same `defer` that performs the restore, as the LAST thing that
//  defer does (accounting for `defer`'s own LIFO ordering when a function has more than
//  one). Narrowing the held window to just the swap/restore statements would reopen the
//  race for every line of test-body code in between, which is exactly the code path that
//  reads the swapped-in settings.
//
//  `NSLock`, not `Mutex` (Synchronization framework): this project's existing lock idiom
//  throughout is a plain `NSLock`/`OSAllocatedUnfairLock` instance (see
//  `DiagnosticLogFile.swift`'s doc comment: "same idiom as `WriterActivityRecorder`/
//  `PipeDataAccumulator` in `ExportService.swift`"). `NSLock`'s explicit `lock()`/`unlock()`
//  pair — rather than `OSAllocatedUnfairLock.withLock`'s closure — is what lets the acquire
//  live at one source location (right before the swap) and the release live at a different
//  one (inside a `defer`, after the restore), spanning the whole test body in between; a
//  closure-based API can't express that split without wrapping the entire test body in a
//  closure, which none of the 3 call sites are shaped for today.
//
//  `nonisolated(unsafe)` because this lock must be acquirable from both `@MainActor` test
//  bodies (`BibliographyRenameGraceNameTests`, `ExportSettingsResetNotificationTests`) and a
//  non-`@MainActor` one (`BlockParserBibliographyHeaderNameTests`) without an actor hop —
//  `NSLock` itself is thread-safe, mirroring `ExportSettings._userDefaults`'s own
//  `nonisolated(unsafe)` rationale.
//

import Foundation

/// Acquire with `.lock()` immediately before pointing `ExportSettings.userDefaults` at a
/// throwaway store; release with `.unlock()` only after it (and any
/// `ExportSettingsManager.shared` cache swapped alongside it) has been restored to the real
/// value. See this file's doc comment for the full mechanism and which test files must use
/// this and why. No `nonisolated(unsafe)` needed here (unlike `ExportSettings._userDefaults`,
/// a `var`): `NSLock` itself is `Sendable`, and this `let` constant's reference never changes,
/// so the compiler already treats cross-actor access as safe.
let exportSettingsTestLock = NSLock()
