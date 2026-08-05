#!/bin/bash
# Circuit-breaker accounting: per-key streak files, the known-flaky hash
# snapshot, and the run index that prune/reset use to find artifacts.
# Sourced, not executed directly.

VMTEST_STREAK_PREFIX="$VMTEST_STATE_DIR/streak-"
VMTEST_KNOWN_FLAKY_HASH_FILE="$VMTEST_STATE_DIR/known-flaky.hash"
VMTEST_RUN_INDEX_FILE="$VMTEST_STATE_DIR/run-index.jsonl"

streak_hash() { printf '%s' "$1" | md5 -q 2>/dev/null || printf '%s' "$1" | md5sum | cut -d' ' -f1; }
streak_file() { printf '%s%s.json' "$VMTEST_STREAK_PREFIX" "$(streak_hash "$1")"; }

# Reads "count" via real JSON parsing, not a grep pattern. This is
# LOAD-BEARING: an earlier grep-based version (`grep -o '"count":[0-9]*'`)
# required zero whitespace between the colon and the digits, but the write
# side (streak_bump, below) always writes `"count": $count` WITH a space —
# so the grep never matched, silently returned empty, and every bump reset
# to 1 instead of incrementing. Found live during Verification 7: two
# consecutive failures of the same test both wrote count=1, so the breaker
# could never reach 2, let alone trip at 3 — the entire mechanism this plan
# exists to build was structurally inert. `printf '%s\n'` normalizes any
# stray output (e.g. a trailing empty line) before the integer check below.
streak_read_count() {
  local f="$1"
  [ -f "$f" ] || { echo 0; return; }
  python3 -c "import json,sys
try:
    print(json.load(open(sys.argv[1])).get('count', 0))
except Exception:
    print(0)" "$f" 2>/dev/null || echo 0
}

streak_count() {
  local f; f="$(streak_file "$1")"
  streak_read_count "$f"
}

streak_bump() {
  local key="$1" f count
  f="$(streak_file "$key")"
  count=$(( $(streak_count "$key") + 1 ))
  cat > "$f" <<EOF
{"key": $(printf '%s' "$key" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'), "count": $count, "updated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
  echo "$count"
}

streak_clear() {
  local key="$1" f; f="$(streak_file "$key")"
  rm -f "$f"
}

is_known_flaky() {
  local key="$1"
  [ -f "$VMTEST_KNOWN_FLAKY_FILE" ] || return 1
  grep -Fxq "$key" "$VMTEST_KNOWN_FLAKY_FILE" 2>/dev/null
}

any_streak_nonzero() {
  compgen -G "${VMTEST_STREAK_PREFIX}*.json" > /dev/null 2>&1
}

any_streak_at_three() {
  local f c
  shopt -s nullglob
  for f in "${VMTEST_STREAK_PREFIX}"*.json; do
    c=$(streak_read_count "$f")
    [ "${c:-0}" -ge 3 ] && { shopt -u nullglob; return 0; }
  done
  shopt -u nullglob
  return 1
}

tripped_keys() {
  local f c key
  shopt -s nullglob
  for f in "${VMTEST_STREAK_PREFIX}"*.json; do
    c=$(streak_read_count "$f")
    if [ "${c:-0}" -ge 3 ]; then
      python3 -c "import json; print(json.load(open('$f'))['key'])"
    fi
  done
  shopt -u nullglob
}

any_key_at_streak_ge2() {
  local f c
  shopt -s nullglob
  for f in "${VMTEST_STREAK_PREFIX}"*.json; do
    c=$(streak_read_count "$f")
    [ "${c:-0}" -ge 2 ] && { shopt -u nullglob; return 0; }
  done
  shopt -u nullglob
  return 1
}

# known-flaky.txt hash guard — refuses a widen mid-crisis.
known_flaky_check() {
  local current
  current="$(md5 -q "$VMTEST_KNOWN_FLAKY_FILE" 2>/dev/null || md5sum "$VMTEST_KNOWN_FLAKY_FILE" | cut -d' ' -f1)"
  if any_streak_nonzero; then
    if [ ! -f "$VMTEST_KNOWN_FLAKY_HASH_FILE" ]; then
      die "known-flaky.hash is missing while a streak is active — this is a refusal, not a fresh baseline. Resolve the active streak(s) first (see \`vmtest status\`)."
    fi
    local snapshot; snapshot="$(cat "$VMTEST_KNOWN_FLAKY_HASH_FILE")"
    if [ "$snapshot" != "$current" ]; then
      die "known-flaky.txt changed while a streak is active — refusing to run. known-flaky.txt cannot be widened mid-crisis (see the plan's §3)."
    fi
  else
    echo "$current" > "$VMTEST_KNOWN_FLAKY_HASH_FILE"
  fi
}

# Record a run's outcome in the index so prune/reset can find its artifacts.
# Fields: run_id, out_dir, video_path (or empty), failing_keys (comma-sep).
run_index_append() {
  local run_id="$1" out_dir="$2" video_path="$3" failing_keys="$4"
  python3 - "$run_id" "$out_dir" "$video_path" "$failing_keys" "$VMTEST_RUN_INDEX_FILE" <<'PYEOF'
import json, sys, time
run_id, out_dir, video_path, failing_keys, index_file = sys.argv[1:6]
rec = {
    "run_id": run_id,
    "out_dir": out_dir,
    "video_path": video_path or None,
    "failing_keys": [k for k in failing_keys.split(",") if k],
    "ts": time.time(),
}
with open(index_file, "a") as f:
    f.write(json.dumps(rec) + "\n")
PYEOF
}
