import Foundation

// Reads git branch/commit stamped into Info.plist by the post-build script
enum GitInfo {
    static let branch: String = {
        Bundle.main.infoDictionary?["GitBranch"] as? String ?? "unknown"
    }()
    static let commit: String = {
        Bundle.main.infoDictionary?["GitCommit"] as? String ?? "unknown"
    }()

    /// Worktree folder name this build came from, or empty for the main checkout.
    /// Stamped only when SRCROOT is under `.claude/worktrees/` (see project.yml's
    /// "Stamp Git Info into Info.plist" phase).
    static let worktree: String = {
        Bundle.main.infoDictionary?["DevWorktree"] as? String ?? ""
    }()

    /// Short human label identifying which tree produced this build, used by
    /// `DevBuildBadge` for the Dock icon, window subtitle, and titlebar pill.
    /// Prefers the worktree name (what distinguishes one parallel superdev build
    /// from another) and falls back to the branch for main-checkout builds.
    static let devLabel: String = worktree.isEmpty ? branch : worktree
}
