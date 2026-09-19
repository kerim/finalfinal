//
//  TestDatabaseTeardown.swift
//  final finalTests
//
//  Deterministic teardown order for tests that clean up a temp .ff package:
//  close every SQLite connection to it FIRST, before the existing directory
//  cleanup call runs.
//
//  DocumentManager.closeProject() only drops its reference and lets ARC close
//  the DatabasePool whenever dealloc happens -- there is no deterministic close
//  on the app side. Running the directory cleanup while a GRDB connection's
//  WAL/SHM files are still mapped is what trips libsqlite3's "vnode unlinked
//  while in use" API-violation guard (same hazard class documented in
//  TestFixtureCleanup.swift and FixtureGeneratorTests.swift).
//

import Foundation
import GRDB
@testable import final_final

enum TestDatabaseTeardown {

    /// Closes any GRDB `DatabaseWriter` -- a bare `DatabaseQueue`/`DatabasePool` a test
    /// wired up directly, not just a `ProjectDatabase`'s own `dbWriter` -- and logs, via
    /// `DebugLog.always` (see final final/Utilities/DebugLog.swift, reserved for "truly
    /// critical errors where silence risks data corruption"), rather than silently
    /// swallowing a close failure the way a bare `try? writer.close()` does. Distinctive
    /// marker so a swallowed close failure is visible in the test log rather than
    /// indistinguishable from "there was nothing to close".
    static func close(_ writer: any DatabaseWriter, site: String = #function) {
        do {
            try writer.close()
        } catch {
            DebugLog.always("[TestDatabaseTeardown] CLOSE-FAILED site=\(site) path=\(writer.path) error=\(error)")
        }
    }

    private static func close(_ db: ProjectDatabase, site: String) {
        close(db.dbWriter, site: site)
    }

    /// Closes the given databases, then runs the same cleanup the caller already had.
    /// Use from non-MainActor tests that never opened a project through DocumentManager.
    static func closeThenCleanUp(_ dir: URL, _ databases: ProjectDatabase..., site: String = #function) {
        for db in databases { close(db, site: site) }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Closes DocumentManager.shared's open project (plus any extra databases the
    /// test holds directly), then runs the same cleanup the caller already had.
    /// Order matters: every pool must be closed before cleanup runs.
    @MainActor
    static func closeProjectThenCleanUp(_ dir: URL, extra databases: [ProjectDatabase] = [], site: String = #function) {
        let open = DocumentManager.shared.projectDatabase
        DocumentManager.shared.closeProject()
        for db in ([open].compactMap { $0 } + databases) { close(db, site: site) }
        try? FileManager.default.removeItem(at: dir)
    }
}
