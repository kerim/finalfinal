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
//  other; Swift Testing runs DIFFERENT suites concurrently by default. Four suites swap
//  `ExportSettings.userDefaults` today — `BibliographyRenameGraceNameTests`,
//  `BlockParserBibliographyHeaderNameTests`, `ExportSettingsResetNotificationTests`, and
//  `ExportSettingsBibliographyRenameTests` — and each already documented this in its own file
//  as a known, previously-latent risk.
//  It stopped being latent: a full-suite run (1184 tests, no class scoping) reproduced a
//  failure in `BibliographyRenameGraceNameTests.staleReparseAfterRenameKeepsBibliographyFlags`
//  that this lock exists to close, while the same 3-test class scoped in isolation (never
//  running alongside the other two files) passed 8/8 times — proof the failure is a genuine
//  cross-suite race over this shared static, not a stale build artifact and not a bug in the
//  feature under test. `BlockParser.parse`/`.isBibliographyHeading` read
//  `ExportSettings.userDefaults` (via `ExportSettings.load()`) on every call, so any test in
//  one of the 4 files above that is mid-swap while a test in another of the 4 runs a parse
//  can observe the wrong (throwaway, or half-restored) settings.
//
//  THE FIX: a single process-wide lock, held for the ENTIRE window from the moment
//  `ExportSettings.userDefaults` is pointed at a throwaway store until it — and any
//  `ExportSettingsManager.shared` in-memory cache swapped alongside it — has been fully
//  restored to the real value, not just around the swap statement itself. Every place in
//  those 4 files that performs this swap acquires this lock immediately before the swap and
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
//  closure, which none of the 4 call sites are shaped for today.
//
//  This lock is not `nonisolated(unsafe)` (see its own doc comment below) and does not need to
//  be: `NSLock` itself is `Sendable`. `@MainActor` on all four suites above answers a DIFFERENT
//  question -- it's what makes touching `ExportSettingsManager.shared` (an actor-isolated
//  singleton) safe from a data-race/Sendable standpoint -- and is NOT, by itself, what makes
//  this lock's own cross-suite exclusion safe. The lock's actual job is serializing access to
//  the process-wide `ExportSettings.userDefaults` static across suites Swift Testing runs
//  concurrently, and that guarantee holds only for as long as nothing inside the locked window
//  ever suspends or pumps a run loop on the same thread. A `RunLoop.main.run(until:)` call
//  inside the locked window used to do exactly that: because `@MainActor` work and
//  `queue: .main` notification delivery share the same underlying main dispatch queue, the
//  pump could service a DIFFERENT `@MainActor` test body nested on the same thread, and if
//  that test was itself a lock user, its `lock()` call would reenter this same (non-recursive)
//  `NSLock` already held by the suspended outer frame -- a permanent deadlock no `defer` could
//  ever recover from. That's why every locked window in these four suites now avoids
//  `queue: .main` in favor of `queue: nil` (synchronous, same-thread delivery) and never pumps
//  the run loop while holding the lock. What still rules out `Mutex`/an actor-based lock in
//  favor of a plain `NSLock` is the acquire/release split from the paragraph above -- `lock()`
//  at the swap site, `unlock()` inside a `defer` after the restore -- which only an
//  explicit-call lock can express across two source locations without collapsing the whole
//  test body into one closure.
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
