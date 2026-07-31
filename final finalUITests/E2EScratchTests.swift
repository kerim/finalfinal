//
//  E2EScratchTests.swift
//  final finalUITests
//
//  PERMANENT SCRATCH FILE — committed empty, on purpose.
//
//  This is the single scratch pad for run-specific e2e verification (see the
//  project skill `.claude/skills/e2e-verify`). An e2e run OVERWRITES this
//  file's contents with a disposable XCUITest class, runs it via
//  `test_macos -only-testing "final finalUITests/E2EScratchTests"`, captures
//  its screenshot evidence into the run-notes folder, and then resets the
//  file with:
//
//      git restore -- "final finalUITests/E2EScratchTests.swift"
//
//  Why a committed placeholder instead of a disposable new file: creating and
//  deleting a file required `git clean` (every form of `rm` is in this
//  project's permission deny list), and `git clean` matches an `ask`
//  permission rule — so every autonomous run stopped for a prompt. Permission
//  rules resolve deny > ask > allow, so no `allow` entry and no PreToolUse
//  hook can override that ask. Keeping the file permanently in the target
//  removes the delete entirely, and `git restore` is already this workflow's
//  sanctioned, prompt-free reset primitive.
//
//  Two consequences worth knowing:
//    - `git restore` DISCARDS whatever is in here without confirmation. Never
//      leave anything here you want to keep. A class worth keeping gets
//      copied to its own named file and `git add`ed BEFORE the reset.
//    - It must stay free of `test`-prefixed methods when committed, so the
//      full UI suite never pays for it. Leaving a real test method committed
//      here would silently add it to every future suite run.
//
//  `final finalUITests` is included in the Xcode project as a whole directory
//  (project.yml `sources: - path: final finalUITests`), so this file is
//  already a member of the test target and an e2e run needs no
//  `xcodegen generate` at all.
//

import XCTest

/// Intentionally empty. See the file header — an e2e run replaces this whole
/// file, then `git restore` puts this back.
final class E2EScratchTests: XCTestCase {}
