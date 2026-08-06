#!/bin/bash
# Evidence export: screenshots, video, .xcresult, from a live guest to the
# host's --out directory. Sourced, not executed directly.

# Finalize an armed recording: SIGINT (the only signal Step 0 proved
# finalizes cleanly — SIGTERM writes nothing, and stopping the VM under a
# live recording writes nothing), wait for the process to exit, then copy the
# .mov out. Guest /tmp does not survive a VM stop, so this MUST run before
# any `tart stop`.
finalize_and_copy_video() {
  local vm="$1" ip="$2" guest_pid="$3" out_dir="$4"
  [ -n "$guest_pid" ] || return 1
  ssh_guest "$ip" "kill -INT $guest_pid 2>/dev/null; for i in \$(seq 1 10); do kill -0 $guest_pid 2>/dev/null || exit 0; sleep 1; done" || true
  if scp_from_guest "$ip" "/tmp/vmtest-recording.mov" "$out_dir/recording.mov" 2>/dev/null; then
    echo "$out_dir/recording.mov"
    return 0
  fi
  return 1
}

start_recording() {
  local ip="$1"
  # `screencapture -v ... &` alone is NOT enough to detach over SSH: the
  # backgrounded process inherits the SSH session's stdout/stderr, so the
  # ssh client blocks waiting for those file descriptors to close — which
  # never happens until the recording is stopped. Found live during
  # Verification 6: `start_recording`'s ssh_guest call hung indefinitely,
  # wedging the whole run (the watchdog never even started, since arming
  # happens before it). Redirect the backgrounded process's own stdio away
  # so the shell command returns — and therefore the ssh client exits —
  # immediately, regardless of whether screencapture is still running.
  ssh_guest "$ip" "rm -f /tmp/vmtest-recording.mov; screencapture -v /tmp/vmtest-recording.mov </dev/null >/tmp/vmtest-recording.out 2>&1 & echo \$!" 2>/dev/null | tr -d '\r'
}

# Checks PROCESS LIVENESS, not the recording file. `screencapture` buffers
# and does not create/grow /tmp/vmtest-recording.mov until it is finalized
# (SIGINT) — confirmed directly during Step 0 and reconfirmed here: the file
# stayed 0 bytes for a screencapture process verified alive and recording via
# `ps`. A file-size check therefore ALWAYS reports "did not start" even when
# recording is working perfectly, a false negative found live during
# Verification 6 ("WARNING: recording did not start" on a run whose watchdog
# then had no video to finalize). `kill -0` is the correct, cheap liveness
# check.
verify_recording_started() {
  local ip="$1" pid="$2" tries=0
  [ -n "$pid" ] || return 1
  while [ "$tries" -lt 6 ]; do
    if ssh_guest "$ip" "kill -0 $pid 2>/dev/null"; then
      return 0
    fi
    sleep 1
    tries=$((tries + 1))
  done
  return 1
}

export_stills() {
  local vm="$1" ip="$2" out_dir="$3"
  local container
  container=$(ssh_guest "$ip" "ls -d \$HOME/Library/Containers/*xctrunner/Data/e2e-shots 2>/dev/null | head -1" 2>/dev/null | tr -d '\r')
  [ -n "$container" ] || { log "vmtest: no e2e-shots container found for stills export"; return 1; }
  mkdir -p "$out_dir/screenshots"
  ssh_guest "$ip" "cp -f '$container'/*.png /tmp/vmtest-stills/ 2>/dev/null || (mkdir -p /tmp/vmtest-stills && cp -f '$container'/*.png /tmp/vmtest-stills/)" 2>/dev/null || true
  scp_from_guest "$ip" "/tmp/vmtest-stills/*.png" "$out_dir/screenshots/" 2>/dev/null || true
}

export_xcresult_failure_attachments() {
  local xcresult="$1" out_dir="$2"
  [ -d "$xcresult" ] || return 1
  mkdir -p "$out_dir/attachments"
  xcrun xcresulttool export attachments --path "$xcresult" --output-path "$out_dir/attachments" 2>/dev/null || true
}

# Verified against a real xcresult bundle (POC's FullUISuite.xcresult):
# `xcrun xcresulttool get test-results tests --format json` nests
# Test Plan > UI test bundle > Test Suite (class) > Test Case, each node
# carrying "nodeType" and "result" ("Passed" / "Failed" / etc), and each
# Test Case carrying "nodeIdentifier" as "ClassName/testMethod()" — no
# bundle-name prefix, and a trailing "()". The plan's key convention
# (§3) has no trailing parens, e.g.
# "final finalUITests/ListNumberingE2ETests/testDeliberateNewListRestartsAtOne"
# — so the bundle name (the nearest "UI test bundle"/"Unit test bundle"
# ancestor) is prepended and the parens are stripped here.
parse_failing_test_ids() {
  local xcresult="$1"
  [ -d "$xcresult" ] || return 0
  xcrun xcresulttool get test-results tests --path "$xcresult" --format json 2>/dev/null \
    | python3 -c '
import json, sys
def walk(node, bundle):
    nt = node.get("nodeType")
    if nt in ("UI test bundle", "Unit test bundle"):
        bundle = node.get("name", bundle)
    if nt == "Test Case":
        result = node.get("result", "")
        if result not in ("Passed", "Expected Failure", "Skipped"):
            ident = node.get("nodeIdentifier", "").rstrip("()")
            print(f"{bundle}/{ident}" if bundle else ident)
    for c in node.get("children", []):
        walk(c, bundle)
try:
    data = json.load(sys.stdin)
    for root in data.get("testNodes", []):
        walk(root, None)
except Exception:
    pass
' 2>/dev/null || true
}
