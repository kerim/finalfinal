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
# forwards only that prefix, stripping it on arrival. The relative value
# resolves against the runner's sandboxed home (the one writable location).
VMTEST_GUEST_TEST_ENV="TEST_RUNNER_FF_E2E_SHOT_DIR=e2e-shots"

VMTEST_GOLDEN="ff-golden"
VMTEST_GOLDEN_PREV="ff-golden-prev"
VMTEST_GOLDEN_CANDIDATE="ff-golden-candidate"

VMTEST_STATE_DIR="$HOME/.cache/vmtest"
VMTEST_DEFAULT_OUT_SUBDIR=".claude/vmtest-runs"

VMTEST_TIMEOUT_FULLSUITE=1800
VMTEST_TIMEOUT_SCOPED=600
VMTEST_TIMEOUT_GUEST_AGENT=120

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
