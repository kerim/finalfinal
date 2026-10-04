//
//  LifecycleEntry.swift
//  final final
//
//  t-94369a83 Phase 3a-1b, round C2 (slice-3a-1b-everyday.md sections 2.1 and 5.2): the command-layer entry
//  every close / open / new / import / repair / Getting Started call will go through. Round C2 built the
//  skeleton; round C7a wired the first three call sites (Cmd-W, Cmd-O, Open Recent: `ProjectCommands`, Commands/
//  ProjectCommands.swift). What exists in the skeleton:
//
//    - `LifecycleEntry.run(kind:perform:)`: pass-through when there is nothing to protect, otherwise arm a
//      token, run `perform`, then run the tail `perform` asked for, all inside ONE task
//      (`LifecycleEntry.current.task`);
//    - `LifecycleEntry.current`: the single global busy slot (N25), holding everything the lifecycle needs
//      captured at arm, so it survives the editor's view being swapped out from under it (#8, N26);
//    - `LifecycleHost`: the closures ContentView installs for the lifecycle to call back into the view layer;
//    - `LifecycleEnvironment`: what `run` reads from the app (is a project open, which editor state, ...),
//      injectable so tests install their own (item 32).
//
//  Round C3b wired the save sequence in: `execute` runs `EditorViewState.runLifecycleFlush` (steps 0-8) BEFORE
//  `perform`, with the host and controller captured at arm. A cancelled sequence means `perform` is NOT called
//  and `run` returns `.cancelled` with the cancel notice. The writer barrier the sequence leaves held is
//  released by `finish` after every outcome (N9) unless a quit joined, which holds it to exit.
//
//  Round C5a: every exit that does not reach a tail (the section-operation wait giving up, the writer refusing
//  the barrier, a `perform` that throws) goes through ONE routine, `EditorViewState.abortLifecycle`
//  (EditorViewState+LifecycleAbort.swift), which restores the editor: re-push block ids when FB applied, restart
//  polling, resume the sync services, re-post deferred rebuilds, release the barrier, show the cancel notice.
//
//  Round C5b: the tails behind the host's `runOpenTail` / `runCreateTail` / `runCloseTail` are real (ContentView+
//  LifecycleTails.swift): the automatic version, the service stops and resets, the undo-history invalidation, the
//  writer's retire-then-release (P6, `EditorViewState.retireForLifecycle`), then the close or the open. A token armed
//  while Getting Started was open runs the CLOSE tail even when `perform` opened a regular project (N2: the swap
//  builds a new ContentView that opens that project itself). `finish` below is the safety net for the barrier.
//  Keyed posts: a `.projectDidOpen` / `.projectDidCreate` / `.projectDidClose` post made by a managed `perform`
//  carries `userInfo["lifecycleToken"]` (`tokenUserInfoKey`); the old ContentView handlers ignore it
//  (`LegacyProjectNotifications`), because the managed path has already run (or will run) the tail.
//
//  Round C8b: Repair and Open Anyway (E6), Help > Getting Started (E9) and the N2 reverse swap are wired
//  (`ProjectCommands`), so every project open, create and close goes through `run` except the Getting Started close
//  and Getting Started to Getting Started, which have nothing to save. The old ContentView handlers
//  (`handleProjectOpened`, `performProjectClose`) are gone: a keyed post is ignored, the Getting Started close carries
//  its own marker (`gettingStartedCloseUserInfo`), and any other post is UNKEYED -- a missed call site -- which does
//  nothing and hits `noteUnkeyedPost` (a log line and a DEBUG counter, never an assertion).
//
//  Round C6: a QUIT joins the lifecycle running in `current` (`AppDelegate.runQuitSequence`,
//  App/AppDelegate+QuitSequence.swift). `execute` then does not call `perform` when the quit joined before it ran
//  (N6: the other project is not opened, a Save As copy is not made; logged `alwaysPersisted`), and
//  `LifecycleHost.backupForQuit` hands the quit the backup service this lifecycle CAPTURED (N4), never the weak
//  `AppDelegate.autoBackupService`, which the next ContentView overwrites.
//
//  Route to the editor state (item 11). The command layer (menu commands, the Finder-open handler, the
//  quit hook) has no view hierarchy to ask, so `LifecycleEnvironment.production` reads
//  `AppDelegate.shared?.editorState`: the state of the app's MAIN window, resolved from the states every
//  ContentView registered WITH ITS OWN WINDOW (`EditorStateRegistry`, `AppDelegate+EditorState.swift`; the view
//  registers through `HostWindowReader`). It is deliberately not "the last ContentView to mount": opening a project
//  from Finder while one is open makes macOS create an extra main-window scene, whose ContentView mounts, installs
//  a host and goes away again within moments, and a last-writer-wins pointer left the lifecycle on that closed
//  window's state (no host, or freed): `run` passed through, so the old project was not saved and the editor never
//  reloaded. `run` resolves the state ONCE at entry and holds it strongly in `current` until the lifecycle ends.
//  That matters because the registration does move: Help > Getting Started with a project open swaps the app's
//  root view from `.editor` to `.gettingStarted` in the SAME window, which builds a NEW ContentView with a NEW
//  `EditorViewState` that registers in that window and so becomes the app's editor state, while the old state's
//  tail is still running. The old ContentView's `.onDisappear` sets the old state's `lifecycleHost` to nil at the
//  same moment, so the host is captured into `current` at arm and never re-read from the editor state (N26).
//

import Foundation
import WebKit

// MARK: - Tail

/// What `perform` did, which tells `run` which tail to run once `perform` returns (plan 3.1 addendum P2).
enum LifecycleTail: Equatable {
    /// `perform` opened a project (and posted `.projectDidOpen`).
    case open
    /// `perform` created a project (and posted `.projectDidCreate`). `content` is the initial Markdown, if any.
    case create(content: String?)
    /// `perform` closed the project (and posted `.projectDidClose`).
    case close
    /// `perform` closed the project and posted nothing (E9, Getting Started): the close tail runs without
    /// `onProjectClosed`, because that would race the app's own view swap.
    case none
}

// MARK: - Host

/// The closures ContentView installs on `EditorViewState.lifecycleHost` in `.task` and removes in
/// `.onDisappear`. Plain closures rather than a protocol: ContentView is a value type, and every one of
/// these reaches `@State` the view owns.
struct LifecycleHost {
    /// The editor's WKWebView, strongly, or nil if none is mounted (`findBarState.activeWebView`).
    var activeWebView: @MainActor () -> WKWebView?
    /// The open tail: stop services, back up, retire the writer, reconfigure for the new project.
    var runOpenTail: @MainActor (LifecycleToken) async -> Void
    /// The create tail: the open tail plus the new project's initial content.
    var runCreateTail: @MainActor (LifecycleToken, String?) async -> Void
    /// The close tail. The `Bool` is whether to call `onProjectClosed` (false for E9).
    var runCloseTail: @MainActor (LifecycleToken, Bool) async -> Void
    /// Re-posts the rebuilds a lifecycle deferred while it was armed (once, through the existing idle drain).
    var repostDeferredRebuilds: @MainActor () -> Void
    /// Schedules the one catch-up Markdown re-parse a cancelled lifecycle owes (`scheduleSourceModeReparse`
    /// is private to the view layer and needs its services).
    var scheduleSourceModeReparse: @MainActor (String) -> Void
    /// The toast center this window's overlay observes (item 38: `editorState.toastCenter`, never `.shared`).
    var toastCenter: @MainActor () -> ToastCenter
    /// Makes the quit's automatic version with the backup service of the ContentView that installed this host
    /// (N4). Captured into `current` with the rest of the host at arm, so a quit that joins later still reaches
    /// the right project's service after the app's weak `autoBackupService` was overwritten. The default does
    /// nothing, for the recording hosts the tests build.
    var backupForQuit: @MainActor () async -> Void = {}
}

// MARK: - Environment

/// What `LifecycleEntry.run` reads from the rest of the app. A struct of closures so a test installs its
/// own `DocumentManager` answers and editor state without touching the real singletons (item 32).
struct LifecycleEnvironment {
    /// `DocumentManager.hasOpenProject`.
    var hasOpenProject: @MainActor () -> Bool
    /// `DocumentManager.isGettingStartedProject`, read at arm (N1).
    var isGettingStartedProject: @MainActor () -> Bool
    /// The editor state the command layer should act on: `AppDelegate.shared?.editorState`, the MAIN window's
    /// (see the route note in this file's header).
    var editorState: @MainActor () -> EditorViewState?
    /// The structural-undo controller to capture into `current` (C26): `DocumentManager.shared`'s, which
    /// the next ContentView overwrites, hence the capture.
    var structuralUndoController: @MainActor () -> StructuralUndoController?
    /// The time budget for a lifecycle run.
    var bounds: LifecycleBounds

    static let production = LifecycleEnvironment(
        hasOpenProject: { DocumentManager.shared.hasOpenProject },
        isGettingStartedProject: { DocumentManager.shared.isGettingStartedProject },
        editorState: { AppDelegate.shared?.editorState },
        structuralUndoController: { DocumentManager.shared.structuralUndoController },
        bounds: .production
    )
}

// MARK: - Outcome

/// What `LifecycleEntry.run` did. A `perform` that throws does not appear here: `run` rethrows it.
enum LifecycleRunOutcome: Equatable {
    /// `perform` ran (with or without the guard around it).
    case performed
    /// A different kind of lifecycle holds the editor: nothing ran, the busy notice was shown.
    case refusedBusy(active: LifecycleKind)
    /// The same kind is already running: nothing ran and nothing was shown (a repeated Cmd-W).
    case duplicate
    /// The save sequence gave up (a section operation never cleared, or the writer refused the barrier):
    /// `perform` was NOT called, the cancel notice was shown, and the project is as it was.
    case cancelled
    /// A quit joined before `perform` ran (N6): `perform` was NOT called and nothing is shown. The other project
    /// is not opened, a Save As copy is not made; the quit saves and exits.
    case skippedForQuit
}

// MARK: - Entry

@MainActor
enum LifecycleEntry {

    /// Why `run` called `perform` straight through.
    enum PassThroughReason: Equatable {
        case noOpenProject
        case noEditorState
        case noHost
    }

    /// The single global busy slot (N25): everything one lifecycle needs, captured at arm. Global (not per
    /// editor state) so it survives the E9 view swap and so a request routed to a different editor state
    /// is still refused while this one runs. Cleared, together with the editor's token, when `task` ends.
    struct Current {
        let token: LifecycleToken
        /// Held strongly so the state outlives its view for the length of the tail (item 11).
        let editorState: EditorViewState
        /// Captured at arm; the only host the lifecycle ever uses (N26).
        let host: LifecycleHost
        /// Captured at arm: the global one is overwritten by the next ContentView (C26).
        let structuralUndoController: StructuralUndoController?
        let deadline: LifecycleDeadline
        /// The ONE task the whole lifecycle (save sequence, `perform`, tail) runs in.
        let task: Task<Void, Never>
    }

    private(set) static var current: Current?

    /// Replaced by tests (item 32); `.production` everywhere else.
    static var environment: LifecycleEnvironment = .production

    // MARK: Keyed posts (round C5b)

    /// The `userInfo` key a managed lifecycle's project notification carries; the value is the token's `id`
    /// (`UUID`). The post SITES add it in rounds C7a and C8. A notification that has it was posted by a
    /// `perform` that ran inside `run`, so the lifecycle's own tail is doing what the old ContentView handler
    /// used to do: the handler must not do it a second time.
    nonisolated static let tokenUserInfoKey = "lifecycleToken"

    /// True when `notification` was posted by a managed lifecycle (see `tokenUserInfoKey`).
    nonisolated static func isKeyed(_ notification: Notification) -> Bool {
        notification.userInfo?[tokenUserInfoKey] != nil
    }

    /// The `userInfo` a `perform` puts on its `.projectDidOpen` / `.projectDidCreate` / `.projectDidClose` post
    /// (round C7a): `["lifecycleToken": <the running lifecycle's token id>]`, merged with `extra`. Read INSIDE
    /// `perform`, which always runs while `current` is set. nil when nothing is running (the pass-through: no open
    /// project, no editor, no mounted host) and `extra` is empty, so that post stays UNKEYED. Since round C8b no
    /// ContentView handler does anything with an unkeyed post: on that path there is nothing mounted to receive it
    /// (FinalFinalApp swaps the root view and the NEW ContentView opens the project on mount).
    static func keyedUserInfo(adding extra: [AnyHashable: Any] = [:]) -> [AnyHashable: Any]? {
        var info = extra
        if let id = current?.token.id { info[tokenUserInfoKey] = id }
        return info.isEmpty ? nil : info
    }

    // MARK: Getting Started close (round C8b)

    /// The `userInfo` key of the ONE project post that is deliberately not keyed: the Getting Started close
    /// (`ProjectCommands.close`). Getting Started is an ephemeral playground with nothing to save, so its close runs
    /// no lifecycle and has no token; the post is instead MARKED with this key, which tells ContentView's handler to
    /// run the (token-less) Getting Started close (`ContentView.closeGettingStartedProject`). A `.projectDidClose`
    /// that carries neither this key nor a token is an unkeyed post (`noteUnkeyedPost`).
    nonisolated static let gettingStartedCloseUserInfoKey = "gettingStartedClose"

    /// The `userInfo` of the Getting Started close post.
    nonisolated static var gettingStartedCloseUserInfo: [AnyHashable: Any] {
        [gettingStartedCloseUserInfoKey: true]
    }

    /// True when `notification` is the Getting Started close (see `gettingStartedCloseUserInfoKey`).
    nonisolated static func isGettingStartedClose(_ notification: Notification) -> Bool {
        notification.userInfo?[gettingStartedCloseUserInfoKey] as? Bool == true
    }

    // MARK: The unkeyed-post hook (round C8b)

    /// Called by the old ContentView handlers (`LegacyProjectNotifications`) for a `.projectDidOpen`,
    /// `.projectDidCreate` or `.projectDidClose` that carries NEITHER a lifecycle token nor the Getting Started
    /// marker. Every production post site is keyed (`ProjectPostSitesKeyedTests` scans for it), and the managed tails
    /// do what those handlers used to do, so reaching here means a call site was missed: the handler does nothing
    /// (no flush, no backup, no reconfigure: that would run a managed lifecycle's work a second time, or an
    /// unprotected one), the post is logged where the diagnostics keep it, and DEBUG builds count it so a test or the
    /// e2e can prove none is left. It is a counter, never an assertion: an assertion would trap the whole process.
    static func noteUnkeyedPost(_ name: String) {
        DebugLog.alwaysPersisted(
            "[Lifecycle] UNKEYED \(name) post reached a ContentView handler: no lifecycle token, so the handler did "
                + "nothing. A post site was missed (every production post must use LifecycleEntry.keyedUserInfo()).")
        #if DEBUG
        testUnkeyedPosts.append(name)
        #endif
    }

    // MARK: Run

    /// Runs `perform`, inside the guard when there is something to protect.
    ///
    /// - A lifecycle is already running: the same kind is a silent `.duplicate`, any other is
    ///   `.refusedBusy` with the busy notice. `perform` does not run.
    /// - No open project, no editor state, or no mounted host: `perform` runs straight through, as it did
    ///   before this entry existed. Nothing is armed.
    /// - Otherwise: arm a token, run `perform`, run the tail it returned, clear. A throw from `perform` is
    ///   rethrown after the token and the slot are cleared.
    @discardableResult
    static func run(
        kind: LifecycleKind,
        perform: @escaping @MainActor () async throws -> LifecycleTail
    ) async throws -> LifecycleRunOutcome {
        if let holder = current {
            return refuse(kind, holder: holder)
        }
        let env = environment
        guard env.hasOpenProject() else { return try await passThrough(.noOpenProject, perform) }
        guard let editorState = env.editorState() else { return try await passThrough(.noEditorState, perform) }
        guard let host = editorState.lifecycleHost else { return try await passThrough(.noHost, perform) }

        let token: LifecycleToken
        switch editorState.armLifecycle(kind, wasGettingStarted: env.isGettingStartedProject()) {
        case .armed(let armed):
            token = armed
        case .joined(let joined):
            // `run` serves close and switch; a quit joins through the quit hook (round C6). If one ever
            // arrives here the token it installed is still ours to clear.
            token = joined
        case .duplicate:
            record(.duplicate(kind))
            return .duplicate
        case .refusedBusy(let active):
            // The editor state's token is held by something that is not a `current` lifecycle.
            record(.refusedBusy(requested: kind, active: active))
            editorState.toastCenter.show(ToastFactory.lifecycleBusy())
            return .refusedBusy(active: active)
        }

        let deadline = LifecycleDeadline(total: kind == .quit ? env.bounds.quitTotal : env.bounds.closeTotal)
        let controller = env.structuralUndoController()
        let bounds = env.bounds
        let result = ResultBox()
        let context = RunContext(
            token: token,
            editorState: editorState,
            host: host,
            structuralUndoController: controller,
            deadline: deadline,
            bounds: bounds
        )
        let task = Task { @MainActor in
            await execute(context, perform: perform, result: result)
        }
        // Set before `run` first suspends, so the task's own clear (and every later request) sees it.
        current = Current(
            token: token,
            editorState: editorState,
            host: host,
            structuralUndoController: controller,
            deadline: deadline,
            task: task
        )
        record(.armed(kind))
        DebugLog.log(
            .lifecycle,
            "[Lifecycle] run \(kind): armed token=\(token.id), state=\(ObjectIdentifier(editorState)), "
                + "deadline \(deadline.remaining)s")

        await task.value
        if let error = result.error { throw error }
        if result.skippedForQuit { return .skippedForQuit }
        return result.cancelled ? .cancelled : .performed
    }

    // MARK: Internals

    /// Everything one lifecycle's task needs, captured at arm (N26).
    private struct RunContext {
        let token: LifecycleToken
        let editorState: EditorViewState
        let host: LifecycleHost
        let structuralUndoController: StructuralUndoController?
        let deadline: LifecycleDeadline
        let bounds: LifecycleBounds
    }

    /// Holds a thrown error across the unstructured task.
    private final class ResultBox {
        var error: Error?
        var cancelled = false
        var skippedForQuit = false
    }

    /// The one task body: the save sequence, `perform`, the tail, then the clear. The sequence
    /// (`EditorViewState.runLifecycleFlush`, steps 0-8) runs FIRST, with the host and controller captured at
    /// arm (N26): a cancelled one (a section operation that never cleared, or a writer that refused the
    /// barrier) means `perform` is NOT called.
    private static func execute(
        _ context: RunContext,
        perform: @MainActor () async throws -> LifecycleTail,
        result: ResultBox
    ) async {
        let token = context.token
        let editorState = context.editorState
        defer { finish(token: token, editorState: editorState) }
        let flush = await editorState.runLifecycleFlush(
            token: token,
            host: context.host,
            structuralUndoController: context.structuralUndoController,
            deadline: context.deadline,
            bounds: context.bounds
        )
        let abort: (LifecycleAbortReason) async -> Void = { reason in
            await editorState.abortLifecycle(
                token: token, reason: reason, host: context.host, flush: flush, bounds: context.bounds)
        }
        switch flush.outcome {
        case .flushed:
            break
        case .cancelledSectionOperation:
            DebugLog.log(.lifecycle, "[Lifecycle] \(token.kind) cancelled (section operation) token=\(token.id): perform not called")
            await abort(.sectionOperationRunning)
            result.cancelled = true
            return
        case .cancelledBarrierRefused:
            DebugLog.log(.lifecycle, "[Lifecycle] \(token.kind) cancelled (barrier refused) token=\(token.id): perform not called")
            await abort(.barrierRefused)
            result.cancelled = true
            return
        }
        // N6: a quit joined while the save sequence ran. Its token replaced ours, the project it is saving must not
        // change under it, so `perform` (open another project, make the Save As copy, ...) is not run. The quit
        // owns the barrier and the backup from here.
        if editorState.activeLifecycle?.kind == .quit {
            DebugLog.alwaysPersisted(
                "[Lifecycle] a quit joined the \(token.kind) (token=\(token.id)) before perform ran: "
                    + "perform skipped, the quit saves and exits")
            record(.performSkippedForQuit(token.kind))
            result.skippedForQuit = true
            return
        }
        do {
            let tail = try await perform()
            await runTail(tail, token: token, host: context.host)
        } catch {
            DebugLog.log(.lifecycle, "[Lifecycle] perform threw for \(token.kind) token=\(token.id): \(error)")
            await abort(.performFailed(error))
            result.error = error
        }
    }

    /// Calls the host closure matching what `perform` did. The host is the one captured at arm.
    ///
    /// N2 (the reverse Getting Started swap): a token armed while Getting Started was open whose `perform` opened
    /// or created a REGULAR project flips the app's root view from `.gettingStarted` to `.editor`, which builds a
    /// NEW ContentView (new `EditorViewState`, new services) that opens that project itself on mount
    /// (`ContentView.initializeProject`). The open tail on the OLD state would reconfigure it for the new project
    /// (a second writer for it, a content push into a dead web view). So the old state gets the CLOSE tail, as E9
    /// does, WITHOUT `onProjectClosed` (that would close the project the new view is opening). `wasGettingStarted`
    /// is the value captured at arm (N1): by now `DocumentManager` already describes the new project.
    private static func runTail(_ tail: LifecycleTail, token: LifecycleToken, host: LifecycleHost) async {
        switch tail {
        case .open:
            if token.wasGettingStarted {
                DebugLog.log(.lifecycle, "[Lifecycle] N2: Getting Started -> open: close tail on the old state, token=\(token.id)")
                await host.runCloseTail(token, false)
            } else {
                await host.runOpenTail(token)
            }
        case .create(let content):
            if token.wasGettingStarted {
                DebugLog.log(.lifecycle, "[Lifecycle] N2: Getting Started -> create: close tail on the old state, token=\(token.id)")
                await host.runCloseTail(token, false)
            } else {
                await host.runCreateTail(token, content)
            }
        case .close:
            await host.runCloseTail(token, true)
        case .none:
            await host.runCloseTail(token, false)
        }
    }

    /// Compare-and-clear on both: if a quit joined, the editor's token is no longer ours and stays. The
    /// writer barrier is released here after EVERY outcome (N9/N12) -- unless the CURRENT token
    /// (`editorState.activeLifecycle`, N32) is a joined quit, which holds it until the process exits (#18). The
    /// abort routine has already released the barrier and cleared the token on every non-tail exit, and a
    /// completed close/switch tail's `retireForLifecycle` has already dropped it (release is then a no-op), so on
    /// every real path this is only the SAFETY NET: if it still finds a barrier held it releases it, records
    /// `.safetyNetReleasedBarrier` and logs `alwaysPersisted`. (The plan also asks for a DEBUG
    /// `assertionFailure` here; it is not added because the recording tail doubles several existing tests use
    /// never retire, so it would trap the whole DEBUG test process. The new tail tests assert the event is
    /// absent instead.) This is also the one place the busy slot (`current`) is freed.
    private static func finish(token: LifecycleToken, editorState: EditorViewState) {
        if editorState.activeLifecycle?.kind != .quit {
            if editorState.lifecycleBarrier != nil {
                record(.safetyNetReleasedBarrier)
                DebugLog.alwaysPersisted(
                    "[Lifecycle] \(token.kind) token=\(token.id): the writer barrier was still held at the end of the "
                        + "lifecycle task -- released by the safety net (a tail should have retired the writer)")
            }
            editorState.releaseLifecycleBarrier()
        }
        editorState.clearLifecycle(token.id)
        if current?.token.id == token.id { current = nil }
    }

    private static func passThrough(
        _ reason: PassThroughReason,
        _ perform: @MainActor () async throws -> LifecycleTail
    ) async throws -> LifecycleRunOutcome {
        if reason == .noOpenProject {
            DebugLog.log(.lifecycle, "[Lifecycle] pass-through (\(reason)): perform runs with no token")
        } else {
            // A project IS open but the lifecycle found no main-window editor state or no host: the old project is not
            // saved first. Persisted (not just logged) so the diagnostic log of a failed switch says so.
            DebugLog.alwaysPersisted(
                "[Lifecycle] pass-through (\(reason)) WITH a project open: perform runs with no token, "
                    + "so nothing is saved first and no tail runs")
        }
        record(.passedThrough(reason))
        _ = try await perform()
        return .performed
    }

    /// A request while `holder` runs. The same kind is silent; anything else gets the busy notice, posted
    /// through the RUNNING lifecycle's editor state (item 38), which is the window the user is looking at.
    private static func refuse(_ kind: LifecycleKind, holder: Current) -> LifecycleRunOutcome {
        let active = holder.editorState.activeLifecycle?.kind ?? holder.token.kind
        switch kind.precedence(whileActive: active) {
        case .duplicate:
            DebugLog.log(.lifecycle, "[Lifecycle] duplicate \(kind) ignored (\(active) is running)")
            record(.duplicate(kind))
            return .duplicate
        case .joins, .refused:
            DebugLog.log(.lifecycle, "[Lifecycle] \(kind) refused: \(active) is running")
            record(.refusedBusy(requested: kind, active: active))
            holder.editorState.toastCenter.show(ToastFactory.lifecycleBusy())
            return .refusedBusy(active: active)
        }
    }

    // MARK: Test seams

    /// What the entry did, in order. Tests use it to prove the guard path actually ran (item 32): a
    /// pass-through records `.passedThrough`, a guarded run records `.armed`.
    enum Event: Equatable {
        case passedThrough(PassThroughReason)
        case armed(LifecycleKind)
        case refusedBusy(requested: LifecycleKind, active: LifecycleKind)
        case duplicate(LifecycleKind)
        /// `finish` found the writer barrier still held at the end of the task and released it (round C5b). On a
        /// real path the tail's `retireForLifecycle` (or the abort routine) has already dropped it, so this
        /// should never appear.
        case safetyNetReleasedBarrier
        /// A quit joined before `perform` ran, so `perform` was not called (round C6, N6).
        case performSkippedForQuit(LifecycleKind)
    }

    #if DEBUG
    static var testEvents: [Event] = []

    /// The names of the unkeyed project posts that reached an old ContentView handler (`noteUnkeyedPost`), in
    /// order. Empty on every production path.
    static var testUnkeyedPosts: [String] = []

    /// Puts the entry's global state back to "nothing running, nothing recorded".
    static func resetForTests() {
        current = nil
        testEvents = []
        testUnkeyedPosts = []
    }

    private static func record(_ event: Event) {
        testEvents.append(event)
    }
    #else
    private static func record(_ event: Event) {}
    #endif
}
