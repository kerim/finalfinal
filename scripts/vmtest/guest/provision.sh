#!/bin/bash
# HOST-side driver for the golden-image lifecycle. Adapted from the POC's
# guest-provision.sh (which ran INSIDE the guest); this version clones,
# boots, copies the provisioning steps in, runs them over `tart exec`, and
# (for `--validate-only`) runs the recorded assertions from the plan's §2.
#
# Usage:
#   provision.sh <candidate-vm-name>                 # build
#   provision.sh --validate-only <candidate-vm-name>  # validate

set -uo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$BIN_DIR/lib/common.sh"
# shellcheck source=../lib/evidence.sh
source "$BIN_DIR/lib/evidence.sh"

VALIDATE_ONLY=0
if [ "${1:-}" = "--validate-only" ]; then VALIDATE_ONLY=1; shift; fi
VM="${1:?usage: provision.sh [--validate-only] <candidate-vm-name>}"

boot_and_wait() {
  local vm="$1"
  # NOTE: must exec the real `tart` binary here, not the `_tart` bash
  # function — perl's `exec @ARGV` execs a real program, and a bash function
  # doesn't exist in the new process image. Passing `_tart` here silently
  # fails (found live, during Verification 2's first run).
  /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' -- \
    tart run --no-graphics "$vm" > /tmp/vmtest-provision-run.log 2>&1 < /dev/null &
  disown
  local ip="" waited=0
  while [ -z "$ip" ] && [ "$waited" -lt 120 ]; do
    ip="$(_tart ip "$vm" 2>/dev/null)"
    [ -n "$ip" ] || { sleep 3; waited=$((waited + 3)); }
  done
  # `die` here would only exit the subshell this function runs in when called
  # as `ip="$(boot_and_wait ...)"` — its `exit 1` would never reach the outer
  # script, which would silently continue with an empty $ip (found live,
  # during Verification 2's first run: every subsequent ssh call failed with
  # "Could not resolve hostname" for an empty host, and the script still
  # reported success). Print to stderr and return nonempty output only when
  # everything actually worked; callers MUST check for an empty result.
  if [ -z "$ip" ]; then
    echo "vmtest: boot timed out waiting for IP" >&2
    return 1
  fi
  # Retry, not a single shot: getting an IP does not mean the guest agent is
  # up yet. A single `_tart exec … true` check failed live during
  # Verification 2 on a candidate that had just been through a first-boot
  # settle after brew installs — the VM was still `running` and answered
  # fine seconds later. Same budget as the IP wait.
  local agent_waited=0
  while [ "$agent_waited" -lt 120 ]; do
    _tart exec "$vm" true >/dev/null 2>&1 && { echo "$ip"; return 0; }
    sleep 3; agent_waited=$((agent_waited + 3))
  done
  echo "vmtest: guest agent did not respond within 120s of getting an IP" >&2
  return 1
}

if [ "$VALIDATE_ONLY" = 0 ]; then
  echo "== building candidate image $VM =="
  _tart list --quiet 2>/dev/null | grep -qx "$VM" && _tart delete "$VM"
  _tart clone "$VMTEST_GOLDEN" "$VM" 2>/dev/null || _tart clone ghcr.io/cirruslabs/macos-tahoe-base:latest "$VM"
  _tart set "$VM" --cpu 6 --memory 10240 --display 1920x1080 --disk-size 100

  ip="$(boot_and_wait "$VM")" || die "boot_and_wait failed — see the message above"

  echo "-- copying Xcode (as a zip, over SSH — no share needed for a one-shot provision) --"
  if ! ssh_guest "$ip" '[ -d /Applications/Xcode.app ]'; then
    ZIP="/tmp/vmtest-xcode-transfer.zip"
    [ -f "$ZIP" ] || ditto -c -k --sequesterRsrc --keepParent /Applications/Xcode.app "$ZIP"
    sshpass -p "$VMTEST_GUEST_PASS" scp "${VMTEST_SSH_OPTS[@]}" "$ZIP" "$VMTEST_GUEST_USER@$ip:/tmp/Xcode.zip"
    ssh_guest "$ip" 'ditto -x -k /tmp/Xcode.zip /tmp/xcode-unpack && sudo mv /tmp/xcode-unpack/Xcode.app /Applications/Xcode.app && rm -rf /tmp/xcode-unpack /tmp/Xcode.zip'
  fi

  echo "-- automation mode, DevToolsSecurity, Xcode license, build toolchain --"
  ssh_guest "$ip" '
    set -e
    sudo automationmodetool enable-automationmode-without-authentication
    sudo DevToolsSecurity -enable
    sudo xcode-select -s /Applications/Xcode.app
    sudo xcodebuild -license accept
    sudo xcodebuild -runFirstLaunch
    export PATH="/opt/homebrew/bin:$PATH"
    brew install pnpm xcodegen pandoc
    for t in pnpm xcodegen pandoc; do
      command -v "$t" >/dev/null || { echo "provision: $t missing after brew install" >&2; exit 1; }
    done
  '

  echo "-- notification-center suppression (Quick Look banner and anything else it would show) --"
  ssh_guest "$ip" '
    launchctl disable gui/501/com.apple.notificationcenterui.agent || true
    launchctl bootout gui/501/com.apple.notificationcenterui.agent 2>/dev/null || true
  '

  echo "-- media-key daemon suppression (rcd auto-launches Music on media-key/audio events) --"
  ssh_guest "$ip" '
    launchctl disable gui/501/com.apple.rcd || true
    launchctl bootout gui/501/com.apple.rcd 2>/dev/null || true
  '

  echo "-- headless hygiene --"
  ssh_guest "$ip" '
    sudo systemsetup -setsleep Off 2>/dev/null || true
    defaults -currentHost write com.apple.screensaver idleTime 0 || true
  '

  echo "-- warm the pnpm store, and approve esbuild's postinstall so pnpm build actually works --"
  echo "   (found live, Verification 4: pnpm's newer \"ignored build scripts\" gate skips esbuild's"
  echo "    postinstall by default, which makes \`pnpm build\` fail outright — every prior run had"
  echo "    masked this because the main checkout already had a stale-but-present web bundle on disk"
  echo "    for rsync to copy over regardless; a fresh worktree has no such fallback and exposed it)"
  PROJECT_ROOT="$(cd "$BIN_DIR/../../.." && pwd)"
  sshpass -p "$VMTEST_GUEST_PASS" scp -r "${VMTEST_SSH_OPTS[@]}" "$PROJECT_ROOT/web" "$VMTEST_GUEST_USER@$ip:/tmp/warm-web" >/dev/null 2>&1 || \
    { echo "   (scp of web/ failed — skipping cache warm; a later vmtest run will hit the same" ; \
      echo "    esbuild issue and needs \`pnpm approve-builds --all\` run by hand as a fallback)"; }
  if ssh_guest "$ip" '[ -d /tmp/warm-web ]'; then
    ssh_guest "$ip" '
      export PATH="/opt/homebrew/bin:$PATH"
      cd /tmp/warm-web && pnpm install --frozen-lockfile && pnpm approve-builds --all && pnpm build
    ' && echo "   pnpm store warmed, esbuild approved" || echo "   WARNING: warm-up build failed — see above"
    ssh_guest "$ip" 'rm -rf /tmp/warm-web' || true
  fi

  _tart stop --timeout 30 "$VM"
  echo "candidate $VM built. Run \`vmtest image validate\` next."
  exit 0
fi

# --------------------------------------------------------------------------
# validate
# --------------------------------------------------------------------------
echo "== validating $VM =="
ip="$(boot_and_wait "$VM")" || die "boot_and_wait failed — see the message above"
FAIL=0

echo "-- screencapture over SSH --"
if ! ssh_guest "$ip" 'rm -f /tmp/v.mov; screencapture -v /tmp/v.mov & echo $! > /tmp/v.pid; sleep 3; kill -INT $(cat /tmp/v.pid); sleep 1; test -s /tmp/v.mov'; then
  echo "FAIL: screencapture over SSH did not produce a file"; FAIL=1
else
  echo "OK"
fi

echo "-- interrupted recording still plays --"
if [ "$FAIL" = 0 ]; then
  scp_from_guest "$ip" /tmp/v.mov /tmp/vmtest-validate.mov 2>/dev/null
  if ffprobe -v error -show_entries stream=codec_name /tmp/vmtest-validate.mov >/dev/null 2>&1; then
    echo "OK"
  else
    echo "FAIL: exported .mov does not open"; FAIL=1
  fi
fi

echo "-- display size matches config --"
size=$(ssh_guest "$ip" 'screencapture -x /tmp/p.png && sips -g pixelWidth -g pixelHeight /tmp/p.png' 2>/dev/null)
echo "$size"
echo "$size" | grep -q pixelWidth && echo "OK (measured — compare against config.sh expectations by eye; the plan found this diverges from --display)" || { echo "FAIL: could not measure display"; FAIL=1; }

echo "-- no notification-banner process running --"
if ssh_guest "$ip" 'pgrep -x NotificationCenter >/dev/null 2>&1'; then
  echo "FAIL: NotificationCenter is running"; FAIL=1
else
  echo "OK"
fi

echo "-- required guest CLI tools present (pandoc gap shipped once: doctor checked the host only) --"
tools_out="$(ssh_guest "$ip" 'export PATH="/opt/homebrew/bin:$PATH"; for t in pandoc pnpm xcodegen; do printf "%s: %s\n" "$t" "$(command -v "$t" || echo MISSING)"; done' 2>/dev/null)"
echo "$tools_out"
if [ -z "$tools_out" ] || echo "$tools_out" | grep -q MISSING; then
  echo "FAIL: required guest tool missing (or check could not run)"; FAIL=1
fi

echo "-- media-key daemon (rcd) disabled, so Music cannot auto-launch mid-run --"
if ssh_guest "$ip" 'launchctl print gui/501/com.apple.rcd >/dev/null 2>&1'; then
  echo "FAIL: rcd is loaded — Music can auto-launch during test runs"; FAIL=1
else
  echo "OK"
fi

echo "-- a deliberately failed test yields exportable attachments --"
echo "   (requires a checkout in the guest — run this by hand against a real scratch-failure class; not auto-checked here)"

if [ "$FAIL" != 0 ]; then
  _tart stop --timeout 30 "$VM"
  die "validation FAILED — see above"
fi

# Collect guest metadata BEFORE stopping the VM — an ssh_guest call against a
# stopped VM's now-dead IP hangs (found live: two provision.sh runs got stuck
# here for minutes each until ssh's own connect timeout finally gave up).
MACOS_BUILD="$(ssh_guest "$ip" sw_vers -buildVersion 2>/dev/null || echo unknown)"
_tart stop --timeout 30 "$VM"
python3 -c "
import json
json.dump({
  'macos_build': '$MACOS_BUILD',
  'display_measured': '''$size''',
  'provisioned': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
}, open('$VMTEST_STATE_DIR/golden.json', 'w'), indent=2)
" 2>/dev/null || true
echo "validation PASSED"
