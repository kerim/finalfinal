//
//  ProjectCommandHarness.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, rounds C7a and C8a: the recording environment for `ProjectCommands` (Close Project, Open
//  Project, Open Recent, and from C8a Save As, Finder open, New Project and Import). It replaces `DocumentManager`,
//  the modal alert, the notification center and the failure sheet with closures that only write down what happened,
//  in order, so a test asserts what the command DID (item 32) without touching a real project, a real alert, or the
//  process-wide notification center.
//
//  Used inside `LifecycleEntryHarness.withWorld` or `LifecycleFlushHarness.withEntry`, which install the matching
//  `LifecycleEnvironment`: the recorder deliberately knows nothing about the lifecycle, so a test can tell "the
//  command never reached `perform`" (`closes == 0`) from "the command never reached the entry" (`LifecycleEntry`'s
//  recorded events).
//

import Foundation
@testable import final_final

@MainActor
final class ProjectCommandRecorder {

    /// One notification the command posted, with the lifecycle token id that was running at that instant.
    struct Post {
        let name: Notification.Name
        let userInfo: [AnyHashable: Any]?
        let tokenIdAtPost: UUID?

        /// The token id the post carries (`LifecycleEntry.tokenUserInfoKey`), nil for an unkeyed post.
        var keyedTokenId: UUID? { userInfo?[LifecycleEntry.tokenUserInfoKey] as? UUID }
    }

    // MARK: What the app answers

    var isGettingStarted = false
    var hasUnsavedChanges = false
    var choice: UnsavedChangesChoice = .dontSave
    /// Thrown by `openProject` / `openRecentProject` when set (a moved project, an integrity failure).
    var openError: Error?
    /// `DocumentManager.projectURL`: what Finder open compares the incoming file with (round C8a).
    var currentProjectURL: URL?
    /// Thrown by `copyProjectPackage` / `renameOpenedProject` / `newProject` / `saveContent` when set (round C8a).
    var copyError: Error?
    var renameError: Error?
    var newProjectError: Error?
    var saveContentError: Error?
    /// Run INSIDE the matching call, before it records: a test reads the old project's database here to prove what
    /// was already saved at that instant (round C8a).
    var onCopy: (() -> Void)?
    var onNewProject: (() -> Void)?
    /// Run INSIDE `openProject`, before it records (round C8b): a test flips "DocumentManager now says a regular
    /// project" here, the way a real open does.
    var onOpen: (() -> Void)?
    /// Round C8b: what the repair and the force-open answer (`IntegrityResolution.Outcome`), the error Help >
    /// Getting Started throws when set, and a hook run INSIDE `repair` / `openGettingStarted` before they record.
    var repairOutcome: IntegrityResolution.Outcome = .opened
    var openAnywayOutcome: IntegrityResolution.Outcome = .opened
    var gettingStartedError: Error?
    var onRepair: (() -> Void)?
    var onOpenGettingStarted: (() -> Void)?

    // MARK: What the command did

    private(set) var alertsShown = 0
    private(set) var saves = 0
    private(set) var closes = 0
    private(set) var openedURLs: [URL] = []
    private(set) var openedRecentIds: [String] = []
    private(set) var posts: [Post] = []
    private(set) var reported: [(error: Error, url: URL)] = []
    /// Round C8a: Save As's copies (source, destination), the new names given to an opened copy, the projects and
    /// contents New Project / Import made, and the modal error alerts shown (title, error).
    private(set) var copies: [(source: URL, destination: URL)] = []
    private(set) var renamedTo: [String] = []
    private(set) var createdProjects: [(url: URL, title: String)] = []
    private(set) var savedContents: [String] = []
    private(set) var errorAlerts: [(title: String, error: Error)] = []
    /// Round C8b: the repairs asked for, the force-opens asked for, and how many times Getting Started was opened.
    private(set) var repairs: [(report: IntegrityReport, url: URL)] = []
    private(set) var openAnywayURLs: [URL] = []
    private(set) var gettingStartedOpens = 0
    /// Every call, in order: "alert", "save", "close", "open", "openRecent", "copy", "rename", "newProject",
    /// "saveContent", "errorAlert", "repair", "openAnyway", "openGettingStarted", "post:<name>", "report".
    private(set) var order: [String] = []

    /// The URL the failure sheet is shown for a recent project.
    var recentDisplayURL = URL(fileURLWithPath: "/tmp/recent-display.ff")

    var environment: ProjectCommandEnvironment {
        ProjectCommandEnvironment(
            isGettingStartedProject: { [unowned self] in self.isGettingStarted },
            hasUnsavedChanges: { [unowned self] in self.hasUnsavedChanges },
            confirmUnsavedChanges: { [unowned self] in
                self.alertsShown += 1
                self.order.append("alert")
                return self.choice
            },
            saveProject: { [unowned self] in
                self.saves += 1
                self.order.append("save")
            },
            closeProject: { [unowned self] in
                self.closes += 1
                self.order.append("close")
            },
            openProject: { [unowned self] url in
                self.onOpen?()
                self.order.append("open")
                if let error = self.openError { throw error }
                self.openedURLs.append(url)
            },
            openRecentProject: { [unowned self] entry in
                self.order.append("openRecent")
                if let error = self.openError { throw error }
                self.openedRecentIds.append(entry.id)
            },
            displayURL: { [unowned self] _ in self.recentDisplayURL },
            post: { [unowned self] name, userInfo in
                self.posts.append(Post(name: name, userInfo: userInfo, tokenIdAtPost: LifecycleEntry.current?.token.id))
                self.order.append("post:\(name.rawValue)")
            },
            reportOpenError: { [unowned self] error, url in
                self.reported.append((error, url))
                self.order.append("report")
            },
            currentProjectURL: { [unowned self] in self.currentProjectURL },
            copyProjectPackage: { [unowned self] source, destination in
                self.onCopy?()
                self.order.append("copy")
                if let error = self.copyError { throw error }
                self.copies.append((source, destination))
            },
            renameOpenedProject: { [unowned self] title in
                self.order.append("rename")
                if let error = self.renameError { throw error }
                self.renamedTo.append(title)
            },
            newProject: { [unowned self] url, title in
                self.onNewProject?()
                self.order.append("newProject")
                if let error = self.newProjectError { throw error }
                self.createdProjects.append((url, title))
            },
            saveContent: { [unowned self] markdown in
                self.order.append("saveContent")
                if let error = self.saveContentError { throw error }
                self.savedContents.append(markdown)
            },
            showErrorAlert: { [unowned self] title, error in
                self.errorAlerts.append((title, error))
                self.order.append("errorAlert")
            },
            repair: { [unowned self] report, url in
                self.onRepair?()
                self.order.append("repair")
                self.repairs.append((report, url))
                return self.repairOutcome
            },
            openAnyway: { [unowned self] url in
                self.order.append("openAnyway")
                self.openAnywayURLs.append(url)
                return self.openAnywayOutcome
            },
            openGettingStarted: { [unowned self] in
                self.onOpenGettingStarted?()
                self.order.append("openGettingStarted")
                self.gettingStartedOpens += 1
                if let error = self.gettingStartedError { throw error }
                // `DocumentManager.openGettingStarted()` closes the old project and now describes Getting Started.
                self.isGettingStarted = true
            }
        )
    }

    /// A recent-projects entry for the tests (the bookmark is never resolved: `openRecentProject` is recorded).
    static func recentEntry(id: String = "recent-1") -> DocumentManager.RecentProjectEntry {
        DocumentManager.RecentProjectEntry(
            id: id, title: "Recent", bookmarkData: Data(), path: "/tmp/recent.ff")
    }
}
