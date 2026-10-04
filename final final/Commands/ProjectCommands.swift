//
//  ProjectCommands.swift
//  final final
//
//  t-94369a83 Phase 3a-1b, rounds C7a and C8a (slice-3a-1b-everyday.md sections 2.1, 5.4 and 5.5): the command layer
//  for the lifecycle entry points, pulled out of the menu code so it can be unit-tested with injected collaborators
//  (item 32):
//
//    E1  Close Project (Cmd-W, the window's red button, File > Close Project)  -> `close`
//    E2  Open Project (Cmd-O)                                                    -> `open(url:)`
//    E3  Open Recent                                                             -> `openRecent`
//    E4  Save As                                                                 -> `saveAs(from:to:)`
//    E5  Finder open / the app's open-URL                                        -> `openFromFinder(url:)`
//    E7  New Project                                                             -> `newProject(at:title:)`
//    E8  Import Markdown                                                         -> `importMarkdown(_:to:)`
//
//  Each wraps what it does (`perform`) in `LifecycleEntry.run`, so a project that is open and mounted is first saved
//  through the ordered write queue and only then closed or replaced. `perform` is the SAME work the command did
//  before the entry existed (`DocumentManager.closeProject()` / `openProject(at:)` / `openRecentProject(_:)`, then the
//  `.projectDidClose` / `.projectDidOpen` post), with ONE difference: the post carries the running lifecycle's token
//  id (`LifecycleEntry.keyedUserInfo`), which tells ContentView's old handlers to stand down because the managed tail
//  does the job. With no open project, no editor or no mounted host `run` passes `perform` straight through, the post
//  has no token, and the old handlers do it all, as before.
//
//  Round C8a: Save As, Finder open, New Project and Import follow the same shape. Each runs in `run(.projectSwitch)`:
//
//    - Save As: `perform` = checkpoint and copy the package, open the copy, give it the new name, post. The copy is
//      made AFTER the save sequence (the old direct flush is gone), so it contains the typing made just before. A
//      title update that fails AFTER the copy was opened is NON-fatal (must-fix #23): `perform` logs it and still
//      posts and returns `.open`. Throwing there would run the abort routine, which re-pushes block ids to the OLD
//      project's editor while `DocumentManager` already has the copy open.
//    - Finder open: a different project goes through the lifecycle with no flush of its own in front of it
//      (obligation 18). Opening the project that is ALREADY open arms nothing, for Open, Open Recent and Finder alike
//      (A6: the guard sits in `switchProject`, above `run`).
//    - Save As onto the open project's OWN path (the save panel defaults to the project's name in its folder, so
//      Replace picks it) is refused before anything is armed (A3): `copyProjectPackage` removes the destination first,
//      which would delete the open project.
//    - New Project and Import: `perform` returns `.create(content:)`, so the create tail seeds the new project
//      (nil for New Project, the Markdown for Import); the post is `.projectDidCreate`, and Import's also carries the
//      content, which the old handler seeds when the post is unkeyed (the picker, nothing to save).
//
//  N2 for Import from Getting Started: a token armed while Getting Started was open runs the CLOSE tail on the
//  old state (`LifecycleEntry.runTail`), which does NOT seed the imported content, because the new regular project
//  is opened by a NEW ContentView. The content reaches it anyway: `perform` saves it into the new project's database
//  before it posts (see `importMarkdown`).
//
//  Round C8b: Repair and Open Anyway (E6: `repair`, `openAnyway`) and Help > Getting Started (E9:
//  `openGettingStarted`) follow the same shape, so every project open, create and close in the app goes through
//  `LifecycleEntry.run` except the Getting Started close and Getting Started to Getting Started, which have nothing
//  to save. The Getting Started close is the one project post that is not keyed; it carries
//  `LifecycleEntry.gettingStartedCloseUserInfo` instead.
//
//  Order inside E1: the Getting Started branch first (nothing to save, so NO lifecycle, no token, no automatic version
//  and no "Getting Started isn't saved" toast: it closes unconditionally, as it always did), then the Save / Don't
//  Save / Cancel alert, and only then `LifecycleEntry.run(.close)`. Cancel returns before `run`, so no token is ever
//  armed and the close tail never runs on a project that stays open (judge obligation E3). The alert is unreachable
//  today (`DocumentManager.markDirty()` has no caller) but stays.
//
//  What the entry reports is handled here, exhaustively: `.performed`, `.cancelled` (a section operation that never
//  cleared: the abort routine already showed the cancel notice and the project is as it was), `.refusedBusy` (the
//  entry already showed the busy notice), `.duplicate` (a repeated Cmd-W: silent) and `.skippedForQuit` (a quit joined
//  first: nothing happened, show nothing). A `perform` that throws (a moved recent project, an integrity failure) has
//  already been through the abort routine, which restored the editor; the command then reports the failure to the
//  user exactly as it did before (`ProjectOpenErrorState.report`).
//

import AppKit
import Foundation

/// The answer to "Do you want to save changes before closing?".
enum UnsavedChangesChoice: Equatable {
    case save
    case dontSave
    case cancel
}

/// What a project command did, for the tests and the log. The lifecycle outcomes are passed through unchanged.
enum ProjectCommandResult: Equatable {
    /// The command went through `LifecycleEntry.run`; this is what it returned.
    case lifecycle(LifecycleRunOutcome)
    /// Getting Started was closed directly: no lifecycle, nothing to save.
    case gettingStartedClosed
    /// The user answered Cancel to the unsaved-changes alert: nothing ran, no token was armed.
    case cancelledByUser
    /// The open failed (the failure was reported to the user) or a close could not run.
    case failed
    /// Open, Open Recent or Finder asked for the project that is already open: nothing was armed, opened or posted
    /// (E5; shared by all three since A6, because a switch onto itself would save, make a version, wipe the undo
    /// history and reload the project that is already on screen).
    case sameProjectAlreadyOpen
    /// Help > Getting Started while Getting Started is already open (E9): no lifecycle, nothing to save (round C8b).
    case gettingStartedPassedThrough
}

/// Everything the project commands read from or do to the rest of the app, injectable so a test needs neither the real
/// `DocumentManager`, nor a modal alert, nor a notification observer (item 32). `LifecycleEntry` has its own
/// environment for the things it reads (`LifecycleEnvironment`).
@MainActor
struct ProjectCommandEnvironment {
    /// `DocumentManager.isGettingStartedProject`.
    var isGettingStartedProject: @MainActor () -> Bool
    /// `DocumentManager.hasUnsavedChanges`.
    var hasUnsavedChanges: @MainActor () -> Bool
    /// Shows the Save / Don't Save / Cancel alert.
    var confirmUnsavedChanges: @MainActor () -> UnsavedChangesChoice
    /// `FileOperations.handleSaveProject()`.
    var saveProject: @MainActor () -> Void
    /// `DocumentManager.closeProject()`.
    var closeProject: @MainActor () -> Void
    /// `DocumentManager.openProject(at:)`.
    var openProject: @MainActor (URL) throws -> Void
    /// `DocumentManager.openRecentProject(_:)`.
    var openRecentProject: @MainActor (DocumentManager.RecentProjectEntry) throws -> Void
    /// The URL to show in the failure sheet for a recent project: the resolved bookmark, or the synthesized path when
    /// resolution itself failed (there is then no resolved URL to use).
    var displayURL: @MainActor (DocumentManager.RecentProjectEntry) -> URL
    /// `NotificationCenter.default.post(name:object:userInfo:)` with a nil object.
    var post: @MainActor (Notification.Name, [AnyHashable: Any]?) -> Void
    /// `ProjectOpenErrorState.shared.report(_:url:)`.
    var reportOpenError: @MainActor (Error, URL) -> Void
    /// `DocumentManager.projectURL`: Finder open compares the incoming file with it (E5).
    var currentProjectURL: @MainActor () -> URL?
    /// Save As's file work (E4): checkpoint the open project's WAL (a failure is only logged), replace an existing
    /// destination, copy the whole `.ff` package.
    var copyProjectPackage: @MainActor (_ source: URL, _ destination: URL) throws -> Void
    /// Names the freshly opened Save As copy: the project title in its database and `DocumentManager.projectTitle`.
    var renameOpenedProject: @MainActor (_ title: String) throws -> Void
    /// `DocumentManager.newProject(at:title:)` (E7, E8).
    var newProject: @MainActor (_ url: URL, _ title: String) throws -> Void
    /// `DocumentManager.saveContent(_:)` (E8).
    var saveContent: @MainActor (_ markdown: String) throws -> Void
    /// The modal error alert (`FileOperations.showErrorAlert`) Save As, New Project and Import show on failure.
    var showErrorAlert: @MainActor (_ title: String, _ error: Error) -> Void
    /// `IntegrityResolution.repair(report:url:)` (E6): repairs the broken project and opens it.
    var repair: @MainActor (_ report: IntegrityReport, _ url: URL) async -> IntegrityResolution.Outcome
    /// `IntegrityResolution.openAnyway(url:)` (E6): opens the broken project with the integrity checks skipped.
    var openAnyway: @MainActor (_ url: URL) -> IntegrityResolution.Outcome
    /// `DocumentManager.openGettingStarted()` (E9): closes the open project and opens a fresh copy of Getting Started.
    var openGettingStarted: @MainActor () throws -> Void

    static let production = ProjectCommandEnvironment(
        isGettingStartedProject: { DocumentManager.shared.isGettingStartedProject },
        hasUnsavedChanges: { DocumentManager.shared.hasUnsavedChanges },
        confirmUnsavedChanges: { FileOperations.confirmSaveBeforeClosing() },
        saveProject: { FileOperations.handleSaveProject() },
        closeProject: { DocumentManager.shared.closeProject() },
        openProject: { url in try DocumentManager.shared.openProject(at: url) },
        openRecentProject: { entry in try DocumentManager.shared.openRecentProject(entry) },
        displayURL: { entry in
            DocumentManager.shared.resolveBookmark(entry.bookmarkData) ?? URL(fileURLWithPath: entry.path)
        },
        post: { name, userInfo in NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo) },
        reportOpenError: { error, url in ProjectOpenErrorState.shared.report(error, url: url) },
        currentProjectURL: { DocumentManager.shared.projectURL },
        copyProjectPackage: { source, destination in
            try ProjectCommands.copyProjectPackage(from: source, to: destination)
        },
        renameOpenedProject: { title in try ProjectCommands.renameOpenedProject(to: title) },
        newProject: { url, title in try DocumentManager.shared.newProject(at: url, title: title) },
        saveContent: { markdown in try DocumentManager.shared.saveContent(markdown) },
        showErrorAlert: { title, error in FileOperations.showErrorAlert(title, error: error) },
        repair: { report, url in await IntegrityResolution.repair(report: report, url: url) },
        openAnyway: { url in IntegrityResolution.openAnyway(url: url) },
        openGettingStarted: { try DocumentManager.shared.openGettingStarted() }
    )
}

/// What a Repair or Open Anyway did, for the error sheet (round C8b, must-fix #16). The sheet applies it with
/// `ProjectOpenErrorState.apply`: it is dismissed ONLY for `.opened`; the other three keep it up, so a failed
/// Repair is never silent.
enum ProjectRepairOutcome {
    /// The project opened (the lifecycle's tail, if one was armed, has finished).
    case opened
    /// Critical issues remain after the repair pass: the sheet shows this updated report.
    case stillBroken(IntegrityReport)
    /// A repair step or the open itself threw: the sheet shows the error.
    case failed(Error)
    /// The lifecycle did not run `perform` at all (a section operation never cleared and the cancel notice was
    /// shown, another lifecycle was running and the busy notice was shown, a repeated click, a quit took over): the
    /// sheet stays as it was.
    case notRun(LifecycleRunOutcome)
}

/// Why Save As refused to run (A3): shown in the "Could Not Save Project" alert, which prints `localizedDescription`.
struct SaveAsOntoOpenProjectError: LocalizedError, Equatable {
    var errorDescription: String? { "Choose a different name or folder: this is the project that's open." }
}

/// Thrown by the Repair / Open Anyway `perform` for the two outcomes that must restore the editor (round C8b): a
/// throw is what makes `LifecycleEntry.run` run the abort routine. The command catches it again and turns it back
/// into the `ProjectRepairOutcome` the sheet applies.
private enum ProjectRepairFailure: Error {
    case stillBroken(IntegrityReport)
    case failed(Error)
}

@MainActor
enum ProjectCommands {

    // MARK: E1 -- Close Project

    /// Closes the open project: through the lifecycle (the save sequence, then the close tail) when one is open and
    /// mounted, or straight through otherwise. See the file header for the order.
    @discardableResult
    static func close(_ environment: ProjectCommandEnvironment? = nil) async -> ProjectCommandResult {
        let env = environment ?? .production
        // Getting Started is an ephemeral playground with nothing to save: close it cleanly, no lifecycle, no
        // confirmation (t-fa000add: edit awareness surfaces as an in-editor toast, via SectionSyncService, while it
        // is open; closing it must not raise that toast).
        if env.isGettingStartedProject() {
            env.closeProject()
            DebugLog.log(.fileOps, "[ProjectCommands] close: Getting Started closed directly (no lifecycle)")
            // Not keyed (there is no token) but MARKED, so ContentView's handler runs the Getting Started close and
            // an unmarked, unkeyed post can still be told apart as a missed call site (round C8b).
            env.post(.projectDidClose, LifecycleEntry.gettingStartedCloseUserInfo)
            return .gettingStartedClosed
        }

        // The alert comes BEFORE `run` (E3): Cancel must never arm a token.
        if env.hasUnsavedChanges() {
            switch env.confirmUnsavedChanges() {
            case .save:
                env.saveProject()
            case .dontSave:
                break
            case .cancel:
                DebugLog.log(.fileOps, "[ProjectCommands] close: the user cancelled the unsaved-changes alert")
                return .cancelledByUser
            }
        }

        do {
            let outcome = try await LifecycleEntry.run(kind: .close) {
                env.closeProject()
                DebugLog.log(.fileOps, "[ProjectCommands] close: posting .projectDidClose")
                env.post(.projectDidClose, LifecycleEntry.keyedUserInfo())
                return .close
            }
            note(outcome, command: "close")
            return .lifecycle(outcome)
        } catch {
            // A close's `perform` cannot throw; kept so a future change cannot lose an error silently.
            DebugLog.log(.fileOps, "[ProjectCommands] close failed: \(error)")
            return .failed
        }
    }

    // MARK: E2 -- Open Project

    /// Opens the project at `url` (the one the user picked in the open panel): through the lifecycle when a project
    /// is open and mounted (save and back up the old one, then open this one), straight through otherwise. The
    /// project that is ALREADY open is a no-op that arms nothing (A6).
    @discardableResult
    static func open(url: URL, _ environment: ProjectCommandEnvironment? = nil) async -> ProjectCommandResult {
        let env = environment ?? .production
        return await switchProject("open", targetURL: { url }, env: env, open: { try env.openProject(url) })
    }

    // MARK: E3 -- Open Recent

    /// Opens a project from File > Open Recent; same handling as `open(url:)`, including the no-op for the project
    /// that is already open (compared by the entry's resolved bookmark).
    @discardableResult
    static func openRecent(
        _ entry: DocumentManager.RecentProjectEntry,
        _ environment: ProjectCommandEnvironment? = nil
    ) async -> ProjectCommandResult {
        let env = environment ?? .production
        return await switchProject(
            "open recent", targetURL: { env.displayURL(entry) }, env: env, open: { try env.openRecentProject(entry) })
    }

    // MARK: E4 -- Save As

    /// Copies the open project to `destinationURL` and opens the copy. The whole thing is `perform`: the save sequence
    /// (the old direct flush is gone) has already written the editor's fresh content through the ordered queue, so the
    /// copy contains it; the copy's package is then checkpointed, copied and opened, and the open tail follows.
    ///
    /// The title update runs AFTER the copy was opened and is non-fatal (must-fix #23): a throw out of `perform` would
    /// run the abort routine, which restores the OLD project's editor (re-pushes its ids, restarts its polling) while
    /// `DocumentManager` already has the copy open. So it is logged and the post is made regardless; at worst the copy
    /// keeps its old title until the user renames it.
    @discardableResult
    static func saveAs(
        from sourceURL: URL,
        to destinationURL: URL,
        _ environment: ProjectCommandEnvironment? = nil
    ) async -> ProjectCommandResult {
        let env = environment ?? .production
        // A3: Save As onto the open project's OWN path would delete it (`copyProjectPackage` removes the destination
        // before copying, and the save panel defaults its name to the project's, in the project's folder, so Replace
        // picks it). Refused ABOVE `runManagedSwitch`: nothing is armed, saved or copied.
        guard !isSamePath(destinationURL, sourceURL) else {
            DebugLog.log(.fileOps, "[ProjectCommands] save as refused: the destination is the open project itself")
            env.showErrorAlert("Could Not Save Project", SaveAsOntoOpenProjectError())
            return .failed
        }
        return await runManagedSwitch("save as", failureTitle: "Could Not Save Project", env: env) {
            try env.copyProjectPackage(sourceURL, destinationURL)
            // Open the copy (this internally closes the current project).
            try env.openProject(destinationURL)
            let newTitle = destinationURL.deletingPathExtension().lastPathComponent
            do {
                try env.renameOpenedProject(newTitle)
            } catch {
                DebugLog.log(
                    .fileOps,
                    "[ProjectCommands] save as: the copy is open but naming it '\(newTitle)' failed (\(error)); "
                        + "continuing, it keeps its old title")
            }
            DebugLog.log(.fileOps, "[ProjectCommands] save as completed: \(destinationURL.path), posting .projectDidOpen")
            env.post(.projectDidOpen, LifecycleEntry.keyedUserInfo())
            return .open
        }
    }

    // MARK: E5 -- Finder open

    /// Opens a `.ff` project Finder (or `open`) handed to the app. The project that is ALREADY open is a no-op that
    /// arms nothing (duplicate Apple Events for the open project are common; the guard itself lives in
    /// `switchProject`, shared with Open and Open Recent, A6). A different project goes through the lifecycle
    /// exactly as Open Project does: the old project is saved and backed up first, with no flush of this command's
    /// own (obligation 18), and a failure is reported on the sheet for the URL Finder handed over.
    @discardableResult
    static func openFromFinder(url: URL, _ environment: ProjectCommandEnvironment? = nil) async -> ProjectCommandResult {
        let env = environment ?? .production
        let currentURL = env.currentProjectURL()?.resolvingSymlinksInPath()
        let incomingURL = url.resolvingSymlinksInPath()
        DebugLog.always("[FINDER-OPEN] open: current=\(currentURL?.path ?? "nil") incoming=\(incomingURL.path)")

        let result = await switchProject("finder open", targetURL: { url }, env: env, open: { try env.openProject(url) })
        if result == .sameProjectAlreadyOpen {
            DebugLog.always("[FINDER-OPEN] BLOCKED: same project already open")
        }
        return result
    }

    // MARK: E7 -- New Project

    /// Creates the project at `url` and opens it. `perform` creates it and returns a create tail with no content;
    /// the old project was saved and backed up before this runs.
    @discardableResult
    static func newProject(
        at url: URL,
        title: String,
        _ environment: ProjectCommandEnvironment? = nil
    ) async -> ProjectCommandResult {
        let env = environment ?? .production
        return await runManagedSwitch("new project", failureTitle: "Could Not Create Project", env: env) {
            try env.newProject(url, title)
            DebugLog.log(.fileOps, "[ProjectCommands] new project created, posting .projectDidCreate")
            env.post(.projectDidCreate, LifecycleEntry.keyedUserInfo())
            return .create(content: nil)
        }
    }

    // MARK: E8 -- Import Markdown

    /// Creates a project at `url` holding `content` (the Markdown the user picked) and opens it. `perform` returns a
    /// create tail carrying the content, which the tail seeds into the new editor. The post carries the content too:
    /// with nothing to protect (the picker) the post is unkeyed and the old handler seeds from it.
    @discardableResult
    static func importMarkdown(
        _ content: String,
        to url: URL,
        _ environment: ProjectCommandEnvironment? = nil
    ) async -> ProjectCommandResult {
        let env = environment ?? .production
        return await runManagedSwitch("import markdown", failureTitle: "Could Not Import File", env: env) {
            let title = url.deletingPathExtension().lastPathComponent
            try env.newProject(url, title)
            try env.saveContent(content)
            DebugLog.log(.fileOps, "[ProjectCommands] import: project created, posting .projectDidCreate")
            env.post(.projectDidCreate, LifecycleEntry.keyedUserInfo(adding: ["content": content]))
            // N2 (round C8b): when Getting Started was open, `LifecycleEntry.runTail` runs the CLOSE tail on the old
            // state for a `.create`, which does not seed `content`, and the root view swaps to a NEW ContentView that
            // opens the new project on mount. The content still reaches it: `saveContent` above wrote it into the new
            // project's database BEFORE the post, so that ContentView's initial load finds a project with a content
            // row and no blocks and parses the content into blocks (`ContentView.loadInitialContent`). When a regular
            // project was open, the create tail seeds the same content into the reused editor instead.
            return .create(content: content)
        }
    }

    // MARK: E6 -- Repair and Open Anyway

    /// Repairs the broken project at `url` and opens it (the sheet's Repair button). The whole repair loop runs INSIDE
    /// `perform` (`IntegrityResolution.repair` is `async`; `perform` is too), so with a project open and mounted it is
    /// saved and backed up first, and only then repaired and replaced. Three outcomes, none silent:
    ///
    ///   - `.opened`: the keyed `.projectDidOpen` is posted and the open tail runs (or, from Getting Started, the close
    ///     tail: N2). The sheet is dismissed, by the caller, ONLY now (must-fix #16).
    ///   - `.stillBroken` and `.failed`: `perform` THROWS, so the abort routine restores the editor (block ids
    ///     re-pushed, polling restarted, services resumed, barrier released) and the project that was open stays open.
    ///     The outcome goes back to the sheet, which keeps showing the updated report or the error.
    ///   - not run at all (cancelled, busy, duplicate, quit): the sheet stays; the entry already showed its notice.
    ///
    /// With nothing open (the picker) `run` passes straight through and the post is unkeyed: no ContentView is mounted
    /// to receive it, FinalFinalApp swaps the root view and the new ContentView opens the project on mount.
    @discardableResult
    static func repair(
        report: IntegrityReport,
        url: URL,
        _ environment: ProjectCommandEnvironment? = nil
    ) async -> ProjectRepairOutcome {
        let env = environment ?? .production
        return await resolveIntegrity("repair", env: env) { await env.repair(report, url) }
    }

    /// Opens the broken project at `url` with the integrity checks skipped (the sheet's Open Anyway button); the same
    /// three outcomes as `repair`, `.stillBroken` never occurring.
    @discardableResult
    static func openAnyway(url: URL, _ environment: ProjectCommandEnvironment? = nil) async -> ProjectRepairOutcome {
        let env = environment ?? .production
        return await resolveIntegrity("open anyway", env: env) { env.openAnyway(url) }
    }

    private static func resolveIntegrity(
        _ command: String,
        env: ProjectCommandEnvironment,
        resolve: @escaping @MainActor () async -> IntegrityResolution.Outcome
    ) async -> ProjectRepairOutcome {
        do {
            let outcome = try await LifecycleEntry.run(kind: .projectSwitch) {
                switch await resolve() {
                case .opened:
                    DebugLog.log(.fileOps, "[ProjectCommands] \(command): project opened, posting .projectDidOpen")
                    env.post(.projectDidOpen, LifecycleEntry.keyedUserInfo())
                    return .open
                case .stillBroken(let newReport):
                    throw ProjectRepairFailure.stillBroken(newReport)
                case .failed(let error):
                    throw ProjectRepairFailure.failed(error)
                }
            }
            note(outcome, command: command)
            return outcome == .performed ? .opened : .notRun(outcome)
        } catch ProjectRepairFailure.stillBroken(let newReport) {
            DebugLog.log(.fileOps, "[ProjectCommands] \(command): still broken (the abort routine restored the editor)")
            return .stillBroken(newReport)
        } catch ProjectRepairFailure.failed(let error) {
            DebugLog.log(.fileOps, "[ProjectCommands] \(command) failed: \(error) (the abort routine restored the editor)")
            return .failed(error)
        } catch {
            // `perform` throws only the two cases above; kept so a future change cannot lose an error silently.
            DebugLog.log(.fileOps, "[ProjectCommands] \(command) failed: \(error)")
            return .failed(error)
        }
    }

    // MARK: E9 -- Help > Getting Started

    /// Opens a fresh copy of Getting Started. With a REGULAR project open and mounted it goes through
    /// `run(.projectSwitch)`, which until round C8b it did not: the project is now saved and backed up first (it used
    /// to be closed unsaved and never backed up). `perform` opens Getting Started and swaps the root view (the
    /// caller's `showGettingStarted`), and returns `.none`: the old state gets the CLOSE tail without
    /// `onProjectClosed` (that would send the app to the picker, racing the swap) and WITH the old project's automatic
    /// version, because the token's `wasGettingStarted` was captured at arm (N1), when it was still false: by the time
    /// the tail runs, `DocumentManager` already says Getting Started. The tail leaves no token and no barrier.
    ///
    /// Getting Started to Getting Started passes through: it is already open, there is nothing to save, so nothing is
    /// armed. (It re-copies and reopens the playground as it always did; that is t-d844594f, deliberately not fixed
    /// here.) With nothing open (the picker, the first launch) `run` passes straight through as well.
    ///
    /// If opening Getting Started throws (the bundled template is missing or cannot be copied) the open project was
    /// already closed by `DocumentManager.openGettingStarted()`, so the app falls back to the picker, as it always
    /// did, and the old project's close tail still runs.
    @discardableResult
    static func openGettingStarted(
        showGettingStarted: @escaping @MainActor () -> Void,
        showPicker: @escaping @MainActor () -> Void,
        _ environment: ProjectCommandEnvironment? = nil
    ) async -> ProjectCommandResult {
        let env = environment ?? .production
        let perform: @MainActor () -> LifecycleTail = {
            do {
                try env.openGettingStarted()
                showGettingStarted()
            } catch {
                DebugLog.log(.fileOps, "[ProjectCommands] Failed to open Getting Started: \(error); falling back to the picker")
                showPicker()
            }
            return .none
        }

        if env.isGettingStartedProject() {
            DebugLog.log(.fileOps, "[ProjectCommands] Getting Started is already open: no lifecycle, nothing to save")
            _ = perform()
            return .gettingStartedPassedThrough
        }
        do {
            let outcome = try await LifecycleEntry.run(kind: .projectSwitch) { perform() }
            note(outcome, command: "getting started")
            return .lifecycle(outcome)
        } catch {
            // `perform` cannot throw; kept so a future change cannot lose an error silently.
            DebugLog.log(.fileOps, "[ProjectCommands] getting started failed: \(error)")
            return .failed
        }
    }

    // MARK: Shared

    /// E4, E7 and E8: a project switch whose failure is the modal alert the command always showed (rather than the
    /// open-error sheet E2, E3 and E5 use). A throw is rethrown by `run` AFTER the abort routine restored the editor.
    private static func runManagedSwitch(
        _ command: String,
        failureTitle: String,
        env: ProjectCommandEnvironment,
        perform: @escaping @MainActor () throws -> LifecycleTail
    ) async -> ProjectCommandResult {
        do {
            let outcome = try await LifecycleEntry.run(kind: .projectSwitch) { try perform() }
            note(outcome, command: command)
            return .lifecycle(outcome)
        } catch {
            DebugLog.log(.fileOps, "[ProjectCommands] \(command) failed: \(error)")
            env.showErrorAlert(failureTitle, error)
            return .failed
        }
    }

    /// Save As's file work: a PASSIVE checkpoint merges as much WAL as possible without exclusive access (the copy
    /// carries the `-wal` and `-shm` files, so SQLite replays whatever remains when the copy is opened), a failure of
    /// which is only logged; then an existing destination is replaced and the whole `.ff` package is copied.
    static func copyProjectPackage(from sourceURL: URL, to destinationURL: URL) throws {
        do {
            _ = try DocumentManager.shared.projectDatabase?.dbWriter.writeWithoutTransaction { db in
                try db.checkpoint(.passive)
            }
        } catch {
            DebugLog.log(.fileOps, "[ProjectCommands] Save As: WAL checkpoint warning: \(error)")
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.copyItem(at: sourceURL, to: destinationURL)
    }

    /// Gives the opened Save As copy its new name in its own database and in `DocumentManager`.
    static func renameOpenedProject(to title: String) throws {
        let dm = DocumentManager.shared
        if let db = dm.projectDatabase, var project = try db.fetchProject() {
            project.title = title
            try db.updateProject(project)
            dm.projectTitle = title
        }
    }

    /// Whether two file URLs name the same place once symlinks are resolved. Compared by path, so a trailing slash
    /// (a package directory's URL may or may not carry one) cannot make the same project look like two.
    private static func isSamePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().path == rhs.resolvingSymlinksInPath().path
    }

    /// E2, E3 and E5: `open` runs inside `perform`; a throw is rethrown by `run` AFTER the abort routine restored the
    /// editor (polling restarted, services resumed, barrier released), and is reported here as it always was.
    ///
    /// `targetURL` is the project this command opens: the URL the user picked, Finder handed over, or the recent
    /// entry's resolved bookmark. It decides the A6 guard and is the URL the failure sheet shows (the actually
    /// resolved one: user-visible, and Repair / Open Anyway act on it).
    private static func switchProject(
        _ command: String,
        targetURL: @MainActor () -> URL,
        env: ProjectCommandEnvironment,
        open: @escaping @MainActor () throws -> Void
    ) async -> ProjectCommandResult {
        // A6: the project that is ALREADY open is a no-op, for Open, Open Recent and Finder alike (duplicate Apple
        // Events for the open project are common). A switch onto itself would save, make an automatic version, wipe
        // the undo history (`invalidateAll`) and reload what is already on screen. The guard is ABOVE `run`: nothing
        // is armed. `targetURL` is only asked for when a project is open (a bookmark is not resolved for nothing).
        if let currentURL = env.currentProjectURL(), isSamePath(currentURL, targetURL()) {
            DebugLog.log(.fileOps, "[ProjectCommands] \(command): that project is already open, nothing armed")
            return .sameProjectAlreadyOpen
        }
        do {
            let outcome = try await LifecycleEntry.run(kind: .projectSwitch) {
                try open()
                DebugLog.log(.fileOps, "[ProjectCommands] \(command): project opened, posting .projectDidOpen")
                env.post(.projectDidOpen, LifecycleEntry.keyedUserInfo())
                return .open
            }
            note(outcome, command: command)
            return .lifecycle(outcome)
        } catch {
            DebugLog.log(.fileOps, "[ProjectCommands] \(command) failed: \(error)")
            env.reportOpenError(error, targetURL())
            return .failed
        }
    }

    /// Every outcome `LifecycleEntry.run` can return, handled on purpose (a new case must be decided here).
    private static func note(_ outcome: LifecycleRunOutcome, command: String) {
        switch outcome {
        case .performed:
            DebugLog.log(.fileOps, "[ProjectCommands] \(command): done")
        case .cancelled:
            // A section operation never cleared: the project is as it was, and the abort routine showed the notice.
            DebugLog.log(.fileOps, "[ProjectCommands] \(command): cancelled (the notice is already shown), project unchanged")
        case .refusedBusy(let active):
            // The entry showed the busy notice.
            DebugLog.log(.fileOps, "[ProjectCommands] \(command): refused, \(active) is running (the notice is already shown)")
        case .duplicate:
            // The same request again (a repeated Cmd-W): silent by design.
            DebugLog.log(.fileOps, "[ProjectCommands] \(command): duplicate request ignored")
        case .skippedForQuit:
            // A quit joined first: nothing happened and nothing is shown; the quit saves and exits.
            DebugLog.log(.fileOps, "[ProjectCommands] \(command): skipped, a quit took over")
        }
    }
}
