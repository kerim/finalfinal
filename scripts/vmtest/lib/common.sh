#!/bin/bash
# Shared helpers for vmtest. Sourced, not executed directly.

VMTEST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMTEST_ROOT="$(cd "$VMTEST_LIB_DIR/.." && pwd)"
# shellcheck source=../config.sh
source "$VMTEST_ROOT/config.sh"

log() { printf '%s\n' "$*" >&2; }
die() { log "vmtest: $*"; exit 1; }

mkdir -p "$VMTEST_STATE_DIR"

# ---------------------------------------------------------------------------
# tart wrapper — every call goes through here so a future change to how tart
# is invoked (e.g. an explicit --no-sandbox marker) has one place to land.
# ---------------------------------------------------------------------------
_tart() { command tart "$@"; }

ssh_guest() {
  local ip="$1"; shift
  sshpass -p "$VMTEST_GUEST_PASS" ssh "${VMTEST_SSH_OPTS[@]}" \
    "$VMTEST_GUEST_USER@$ip" "$@"
}

scp_from_guest() {
  local ip="$1" remote="$2" local_dest="$3"
  sshpass -p "$VMTEST_GUEST_PASS" scp "${VMTEST_SSH_OPTS[@]}" \
    "$VMTEST_GUEST_USER@$ip:$remote" "$local_dest"
}

# ---------------------------------------------------------------------------
# Lock. mkdir is atomic on APFS; there is no flock(1) on macOS.
# ---------------------------------------------------------------------------
VMTEST_LOCK_DIR="$VMTEST_STATE_DIR/run.lock"

lock_meta_file() { printf '%s/meta' "$VMTEST_LOCK_DIR"; }

lock_is_stale() {
  local meta pid boot
  meta="$(lock_meta_file)"
  [ -f "$meta" ] || return 0
  pid="$(sed -n '1p' "$meta")"
  boot="$(sed -n '2p' "$meta")"
  # kill -0 and `who -b` are the only liveness primitives available inside the
  # sandbox; ps and sysctl are both denied there. Hooks run unsandboxed, but
  # vmtest itself is invoked from sandboxed and unsandboxed callers alike, so
  # keep to the lowest common denominator everywhere.
  if ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  local current_boot
  current_boot="$(who -b 2>/dev/null | awk '{print $3, $4}')"
  if [ -n "$boot" ] && [ "$boot" != "$current_boot" ]; then
    # Same PID number, but the machine rebooted since — a recycled PID.
    return 0
  fi
  return 1
}

lock_holder_desc() {
  local meta
  meta="$(lock_meta_file)"
  [ -f "$meta" ] || { echo "unknown"; return; }
  sed -n '3p' "$meta"
}

# Acquire the run lock. Blocks up to $1 seconds (default 0 = one attempt),
# reporting rather than killing the holder — another session's run is that
# session's work.
acquire_lock() {
  local budget="${1:-0}" waited=0
  while true; do
    if mkdir "$VMTEST_LOCK_DIR" 2>/dev/null; then
      {
        echo "$$"
        who -b 2>/dev/null | awk '{print $3, $4}'
        echo "${VMTEST_RUN_ID:-unknown} (pid $$)"
      } > "$(lock_meta_file)"
      return 0
    fi
    if lock_is_stale; then
      log "vmtest: reclaiming stale lock"
      release_lock_force
      continue
    fi
    if [ "$waited" -ge "$budget" ]; then
      die "run lock held by $(lock_holder_desc) — another vmtest run is in progress. Wait and retry, or check \`vmtest status\`."
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

release_lock() { rm -rf "$VMTEST_LOCK_DIR"; }
release_lock_force() {
  rm -rf "$VMTEST_LOCK_DIR"
  # An orphaned lock usually means an orphaned VM too — locate by name
  # pattern, never by pgrep (denied in the sandbox, and unreliable anyway).
  for vm in $(_tart list --quiet 2>/dev/null | grep '^ff-run-'); do
    log "vmtest: killing orphaned VM $vm"
    _tart stop --timeout 10 "$vm" >/dev/null 2>&1 || true
    _tart delete "$vm" >/dev/null 2>&1 || true
  done
}

# ---------------------------------------------------------------------------
# Disk headroom
# ---------------------------------------------------------------------------
disk_free_gb() {
  df -g "$HOME" | awk 'NR==2 {print $4}'
}

check_disk_floor() {
  local free
  free="$(disk_free_gb)"
  if [ "$free" -lt "$VMTEST_DISK_FLOOR_GB" ]; then
    die "only ${free}GB free, below the ${VMTEST_DISK_FLOOR_GB}GB floor — refusing to clone. Free up space or run \`vmtest prune\`."
  fi
}

# ---------------------------------------------------------------------------
# Sentinels
# ---------------------------------------------------------------------------
sentinel_allow_reset() { printf '%s/allow-reset' "$VMTEST_STATE_DIR"; }
sentinel_allow_host()  { printf '%s/allow-host'  "$VMTEST_STATE_DIR"; }

now_epoch() { date +%s; }
