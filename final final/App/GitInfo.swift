import Foundation

// Reads git branch/commit stamped into Info.plist by the post-build script
enum GitInfo {
    static let branch: String = {
        Bundle.main.infoDictionary?["GitBranch"] as? String ?? "unknown"
    }()
    static let commit: String = {
        Bundle.main.infoDictionary?["GitCommit"] as? String ?? "unknown"
    }()
}
