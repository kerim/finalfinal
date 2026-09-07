#!/bin/bash
# vmtest configuration. Sourced by `vmtest` and its lib scripts. Not executable
# on its own.

VMTEST_SCHEME="final final"
VMTEST_DESTINATION='platform=macOS'

# In-guest prep run from the copied checkout root before xcodebuild (web
# bundle, xcodegen, scheme verification). Project-relative path.
VMTEST_GUEST_PREP="scripts/vmtest/guest-prep.sh"

# Host-side cache-warm script sourced by the engine's provision.sh while the
# candidate image is booted ($ip, ssh_guest, PROJECT_ROOT in scope).
VMTEST_PROVISION_WARM_SCRIPT="provision-warm.sh"

# Extra VAR=value pairs for the xcodebuild invocation. TEST_RUNNER_ prefix
# required for anything the XCUITest runner process must see — xcodebuild
# forwards only that prefix, stripping it on arrival. Absolute path under
# /tmp/ (per E2EShotDir's documented contract in UITestHelpers.swift, an
# absolute value is used as-is) so screenshots land outside any app
# sandbox — the same location the video-recording feature already uses and
# reliably reads back over SSH/SCP. A bare relative name used to resolve
# against the runner's own sandboxed home instead, which put screenshots
# inside the XCUITest runner's App Sandbox container that an external SSH
# session generally cannot read into — the root cause of evidence export
# silently finding nothing on every run.
VMTEST_GUEST_TEST_ENV="TEST_RUNNER_FF_E2E_SHOT_DIR=/tmp/vmtest-e2e-shots"

# Where the vmtest tool's export side (evidence.sh) looks for exported
# screenshots on the guest. Must match the path in TEST_RUNNER_FF_E2E_SHOT_DIR
# above — evidence.sh defaults to this same value if unset, but stating it
# explicitly here keeps that agreement visible instead of relying on the
# default matching by coincidence.
VMTEST_E2E_SHOT_DIR="/tmp/vmtest-e2e-shots"

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

# Per-shard watchdog for --suite full (shards each get this full budget, not
# a divided one — see cmd__run_suite_full). Measured live 2026-09-04 on a
# 2-slot sharded run of the real 16-class suite: slowest shard 1186s (19.8
# min), other shard 1162s. 1560s gives that slowest shard ~31% headroom. The
# unscoped whole-scheme legacy path (no --suite, transitional — see
# README.md) also reads this value.
VMTEST_TIMEOUT_FULLSUITE=1560
VMTEST_TIMEOUT_SCOPED=600
VMTEST_TIMEOUT_GUEST_AGENT=120

# --suite smoke|full (test-tiers-ship plan, 2026-09-04). The merge gate runs
# --suite smoke; the full UI suite moves to release time via `/ship`, sharded
# across VMTEST_MAX_SLOTS clones. VMTEST_TIMEOUT_FULLSUITE above is a
# starting guess until Phase 1's measured runs set it with headroom.
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
