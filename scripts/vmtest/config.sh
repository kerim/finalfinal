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

# Host-side cache-warm script sourced by the engine's provision.sh while the
# candidate image is booted ($ip, ssh_guest, PROJECT_ROOT in scope).
VMTEST_PROVISION_WARM_SCRIPT="provision-warm.sh"

# Extra VAR=value pairs for the xcodebuild invocation. TEST_RUNNER_ prefix
# required for anything the XCUITest runner process must see — xcodebuild
# forwards only that prefix, stripping it on arrival. Absolute path under
# /tmp/ (per E2EShotDir's documented contract in UITestHelpers.swift, an
# absolute value is used as-is), the same convention the video-recording
# feature already uses — this path and its wiring below are still correct
# and unchanged. As of 2026-09-12 the confirmed reason this path still comes
# back empty for screenshot evidence on this project is narrower than "path
# form doesn't matter": Xcode's own XCUITest runner process is sandboxed
# (app-sandbox=true, read-only "/", per Xcode's shipped RunnerEntitlements.plist
# template) and can write ONLY inside its own container (NSHomeDirectory(),
# NSTemporaryDirectory()) — never outside it. /tmp/vmtest-e2e-shots sits
# outside that container, so the write fails there specifically; an absolute
# path under the container would succeed, and the bare-relative convention
# this project tried earlier (resolving inside NSHomeDirectory()) DID write
# successfully — it just produced no usable evidence for a different reason,
# because SSH could not read back into the runner's own sandboxed container
# afterward. Screenshot evidence now comes from `XCTAttachment` (see
# `attachEvidenceScreenshot` in `UITestHelpers.swift`), which goes through
# XCTest's own privileged export path and is unaffected by the runner
# sandbox, instead of a plain write to this path from inside a test.
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

# Retained-video storage cap, in bytes (default 2 GB). See §3 pruning rules.
VMTEST_VIDEO_CAP_BYTES=$((2 * 1024 * 1024 * 1024))

# Age window for run-directory pruning, in days.
VMTEST_PRUNE_AGE_DAYS=7

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
