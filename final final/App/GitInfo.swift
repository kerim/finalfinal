import Foundation

/// Reads git branch/commit/worktree from `GitInfo.plist`, written into the app
/// bundle by the app target's "Stamp Git Info into GitInfo.plist" post-build
/// phase. A separate plist rather than Info.plist keys because declaring the
/// generated Info.plist as a script-phase output conflicts with the build
/// system's ProcessInfoPlist step, and an undeclared write to it is denied
/// under ENABLE_USER_SCRIPT_SANDBOXING. The branch/commit values themselves
/// come from the unsandboxed `GitStamp` aggregate target, which runs first.
enum GitInfo {
    /// Returned when the plist itself is missing or unreadable — a build-wiring
    /// failure, distinct from "git-unavailable" (plist written, git failed).
    static let missingStampSentinel = "no-git-stamp"

    private static let stamp: [String: Any] = {
        guard let url = Bundle.main.url(forResource: "GitInfo", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: Any]
        else { return [:] }
        return dict
    }()

    static let branch: String = stamp["GitBranch"] as? String ?? missingStampSentinel
    static let commit: String = stamp["GitCommit"] as? String ?? missingStampSentinel

    /// Worktree folder name this build came from, or empty for the main checkout.
    /// Stamped only when SRCROOT is under `.claude/worktrees/` (see project.yml's
    /// "Stamp Git Info into GitInfo.plist" phase).
    static let worktree: String = stamp["DevWorktree"] as? String ?? ""

    /// Short human label identifying which tree produced this build, used by
    /// `DevBuildBadge` for the Dock icon, window subtitle, and titlebar pill.
    /// Prefers the worktree name (what distinguishes one parallel superdev build
    /// from another) and falls back to the branch for main-checkout builds.
    static let devLabel: String = worktree.isEmpty ? branch : worktree
}
