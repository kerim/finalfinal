#!/bin/bash
# vmtest configuration. Sourced by `vmtest` and its lib scripts. Not executable
# on its own.

VMTEST_SCHEME="final final"
VMTEST_DESTINATION='platform=macOS'

# Extra xcodebuild flags the engine splices into every guest test invocation
# (scalar — see scripts/vmtest engine's guest/run.sh; a bash array would
# silently never arrive over the guest-config.sh serialization). Pins the
# same "no parallel UI testing" behaviour the host-side xcodebuild call
# sites pin on their own command lines, now that the scheme itself is
# untracked and Xcode-rewritten on load.
VMTEST_XCODEBUILD_ARGS="-parallel-testing-enabled NO"

# In-guest prep run from the copied checkout root before xcodebuild (web
# bundle, xcodegen). Project-relative path.
VMTEST_GUEST_PREP="scripts/vmtest/guest-prep.sh"

# Paths the engine's copy of the checkout into the guest leaves out. Each entry
# is an rsync --exclude pattern relative to the project root; a leading / pins
# it to the root (see the engine README, section "VMTEST_SYNC_EXCLUDES"). The
# sync-model checker (docs/architecture/tla/run_tlc.py) rewrites these two
# folders for over an hour on the host. A guest copy that runs meanwhile fails
# with rsync exit 23 ("files vanished"), so no test runs, and two such failures
# in a row lock that test's key behind the diagnosis gate. The guest build and
# the tests need neither folder (guest-prep.sh and the app build do not read
# them; the sync-model docs are only named in comments), so leaving them out of
# the copy costs nothing. A plain array of strings: nothing here runs at source
# time.
#
# The third entry is the host's Package.resolved. It is an untracked file that
# records whichever package versions the host's Xcode last resolved, so it
# differs per machine and per worktree. When it pins a package version newer
# than the one the golden VM image has cached, the guest downloads and builds
# that version from GitHub at run time, and every VM run then depends on
# GitHub's release servers being up. (Live experiment 2026-11-19: a host pin of
# Sparkle 2.10.1 made the guest fetch and build 2.10.1; without the file the
# guest used the image's cached 2.9.1 and fetched nothing. Runs ended with
# xcodebuild exit 74 on 2026-11-02 and 2026-11-08; board t-e52ef9b8.) Leaving
# the file out of the copy makes the guest use the versions its image already
# holds, and it still re-resolves normally if project.yml needs something
# newer. The pattern contains a space; the engine quotes each entry.
VMTEST_SYNC_EXCLUDES=("/docs/architecture/tla/.run/" "/docs/architecture/tla/results/" "/final final.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")

# Host-side cache-warm script sourced by the engine's provision.sh while the
# candidate image is booted ($ip, ssh_guest, PROJECT_ROOT in scope).
VMTEST_PROVISION_WARM_SCRIPT="provision-warm.sh"

# Extra VAR=value pairs for the xcodebuild invocation. TEST_RUNNER_ prefix
# required for anything the XCUITest runner process must see — xcodebuild
# forwards only that prefix, stripping it on arrival. Absolute path under
# /tmp/ (per E2EShotDir's documented contract in UITestHelpers.swift, an
# absolute value is used as-is), the same convention the video-recording
# feature already uses — this path and its wiring below are still correct
# and unchanged. As of 2026-09-12 a diagnosis found this path coming back
# empty for screenshot evidence because Xcode's own XCUITest runner process
# was sandboxed (app-sandbox=true, read-only "/", per Xcode's shipped
# RunnerEntitlements.plist template) and could write ONLY inside its own
# container (NSHomeDirectory(), NSTemporaryDirectory()) — never outside it,
# so a write to /tmp/vmtest-e2e-shots (outside that container) failed. That
# runner sandbox has since been turned off for this project's UI-test target
# (see `final finalUITests/final finalUITests.entitlements`, wired via the
# `CODE_SIGN_ENTITLEMENTS` build setting in `project.yml`), so a direct write
# to /tmp/vmtest-e2e-shots from the runner now succeeds. The bare-relative
# convention this project tried even earlier
# (resolving inside NSHomeDirectory()) DID write successfully under the old
# sandboxed runner too — it just produced no usable evidence for a different
# reason, because SSH could not read back into the runner's own sandboxed
# container afterward. Screenshot evidence still comes from `XCTAttachment`
# (see `attachEvidenceScreenshot` in `UITestHelpers.swift`), which goes
# through XCTest's own privileged export path and needs no sandbox
# workaround either way, rather than a plain write to this path from inside
# a test.
VMTEST_GUEST_TEST_ENV="TEST_RUNNER_FF_E2E_SHOT_DIR=/tmp/vmtest-e2e-shots"

# Where the vmtest tool's export side (evidence.sh) looks for exported
# screenshots on the guest. Must match the path in TEST_RUNNER_FF_E2E_SHOT_DIR
# above — evidence.sh defaults to this same value if unset, but stating it
# explicitly here keeps that agreement visible instead of relying on the
# default matching by coincidence.
VMTEST_E2E_SHOT_DIR="/tmp/vmtest-e2e-shots"

# Guest-side Xcode build cache. provision-warm.sh fills it with a
# build-for-testing of the whole scheme (GRDB and every other dependency
# included) while the golden image is being built; every run clone then
# inherits it and compiles only what its checkout changed. Without this each
# clone built from scratch, and by 2026-09-06 that cold compile alone
# exceeded VMTEST_TIMEOUT_SCOPED — three superdev worktrees timed out on it
# in one batch. Rebuild the image (`vmtest image build`) after a dependency
# change in project.yml / Package.resolved, or the warm cache goes stale and
# the first run afterwards pays the cold build again (it still passes).
VMTEST_GUEST_DERIVED_DATA="~/DerivedData-vmtest"

VMTEST_GOLDEN="ff-golden"
VMTEST_GOLDEN_PREV="ff-golden-prev"
VMTEST_GOLDEN_CANDIDATE="ff-golden-candidate"

VMTEST_STATE_DIR="$HOME/.cache/vmtest"
VMTEST_DEFAULT_OUT_SUBDIR=".claude/vmtest-runs"

# Concurrent VM slots (engine clamps to 2 — the macOS licensing maximum, and
# `vmtest watch`'s viewer clone counts against the same budget). Enabled
# 2026-08-28 per user decision, paired with shrinking the golden image from
# 10 GB to 6 GB per guest (`tart set ff-golden --memory 6144`) so two
# concurrent guests take 12 GB of the host's 24 GB instead of 20. If guest
# builds ever start failing or crawling under memory pressure, suspect the
# 6 GB first: either restore 10 GB and drop back to 1 slot, or tune between.
VMTEST_MAX_SLOTS=2

# Watchdog (changed 2026-09-11). The engine now stops a guest when nothing
# it writes to the shared out volume has changed for VMTEST_STALL_SEC — the
# direct measure of a hang. The VMTEST_TIMEOUT_* values below are only an
# outer HARD CAP on total elapsed time, a backstop against a guest that
# keeps producing output forever. They are no longer calibrated to the
# suite's runtime and must not be: the previous 1560s was measured against
# a 16-class suite on 2026-09-04 and killed two healthy, progressing
# 24-class release runs a week later. Raise the cap only if a run is ever
# stopped with "hard cap ... reached while the guest was still producing
# output"; a "stalled" stop is a real hang, and the cap is irrelevant to it.
VMTEST_STALL_SEC=600
VMTEST_TIMEOUT_FULLSUITE=5400
VMTEST_TIMEOUT_SCOPED=600
VMTEST_TIMEOUT_GUEST_AGENT=120

# --suite smoke|full (test-tiers-ship plan, 2026-09-04). The merge gate runs
# --suite smoke; the full UI suite moves to release time via `/ship`, sharded
# across VMTEST_MAX_SLOTS clones, balanced by a per-class duration ledger
# the engine rebuilds from every previous full-suite run's shard logs.
VMTEST_SMOKE_SCOPES=(
  "final finalUITests/LaunchSmokeTests"
  "final finalUITests/EditorSmokeTests"
  "final finalUITests/ProjectSwitchBibliographyE2ETests"
)
VMTEST_UI_TEST_DIR="final finalUITests"
VMTEST_UI_TEST_MODULE="final_finalUITests"
VMTEST_SCRATCH_CLASS="E2EScratchTests"
VMTEST_LOCK_WAIT_SUITE=900

# Disk headroom floor, in GB. `vmtest run` refuses below this rather than
# filling the volume — see the Risks section of the plan.
VMTEST_DISK_FLOOR_GB=30

# Total size cap for every run folder of this project — the main checkout and
# every worktree together — in bytes. Past it, the oldest runs lose their
# heavy evidence (test report, screenshots, logs of the app) and keep their
# verdict and short logs. 2 GB holds about 20 failed runs. Replaced
# VMTEST_VIDEO_CAP_BYTES on 2026-11-12, which nothing ever read.
VMTEST_RUNS_CAP_BYTES=$((2 * 1024 * 1024 * 1024))

# Age window for run-directory pruning, in days.
VMTEST_PRUNE_AGE_DAYS=7

# The app's own diagnostic log folder inside the guest, relative to the guest
# user's home; copied out to <run>/app-diagnostics/. The app logs with print()
# and to this file, never to unified logging, so app-console.log cannot carry
# its messages. Written only when a test turns diagnostics on
# (FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING=1); the app caps its size itself.
VMTEST_GUEST_APP_DIAG_DIR="Library/Application Support/com.kerim.final-final/Diagnostics"

# ConnectTimeout=10 and ServerAliveInterval/CountMax bound every SSH call to
# the guest. Without this, an SSH call against a VM that's mid-shutdown or
# already gone hangs indefinitely rather than failing — found live,
# repeatedly, during Verification 6: a watchdog-timeout run raced the VM
# actually going down against a "is it still running?" check in the main
# flow, and no amount of getting that check's timing right closes every such
# race. A bounded connect timeout is the general fix — it protects every
# ssh_guest/scp_from_guest call project-wide, not just this one call site.
VMTEST_SSH_OPTS=(-o StrictHostKeyChecking=no -o PubkeyAuthentication=no
  -o PreferredAuthentications=password -o IdentitiesOnly=yes
  -o NumberOfPasswordPrompts=1 -o ConnectTimeout=10
  -o ServerAliveInterval=5 -o ServerAliveCountMax=2)
VMTEST_GUEST_USER="admin"
VMTEST_GUEST_PASS="admin"

VMTEST_KNOWN_FLAKY_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/known-flaky.txt"
