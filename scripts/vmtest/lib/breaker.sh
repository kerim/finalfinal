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

# known-flaky.txt guard — refuses only a widen that would MASK a live streak.
# The first version refused ANY change to the file while ANY streak was
# active (whole-file hash compare), which wedged every run over unrelated
# edits — found live 2026-08-06: a prior session's committed addition of an
# unrelated test blocked all runs, including the very runs that would have
# cleared the active streaks. The actual risk is narrower: adding a line for
# a test that is currently streaking would silently reclassify its live
# failures as "expected". Refuse exactly that; snapshot content (not a hash)
# so additions are diffable.
known_flaky_check() {
  local snapshot_file="$VMTEST_STATE_DIR/known-flaky.snapshot"
  if ! any_streak_nonzero; then
    cp "$VMTEST_KNOWN_FLAKY_FILE" "$snapshot_file" 2>/dev/null || true
    return 0
  fi
  local line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    if [ -f "$snapshot_file" ] && grep -Fxq "$line" "$snapshot_file" 2>/dev/null; then
      continue
    fi
    if [ "$(streak_count "$line")" -ge 1 ]; then
      die "known-flaky.txt adds '$line' while that test has an active streak — refusing: this would mask a live failure. Let a passing run clear the streak, or use vmtest reset."
    fi
  done < "$VMTEST_KNOWN_FLAKY_FILE"
}

# Auto-clear streaks proven stale by this run: any streaked key whose test
# actually ran here and did not fail. A key "ran" if the run was full-suite
# (no scopes) or the key falls under one of the run's --scope prefixes.
# Pseudo-keys (__TIMEOUT__/__BUILD__) clear when the same scope spec gets
# through build + parse again. Before this, streaks only ever went UP — a
# later pass never cleared them, so every recovery required a human
# `vmtest reset` even when the system had already proven itself healthy.
# $1 = newline-separated failing ids (may be empty); remaining args = scopes.
streaks_clear_passed() {
  local failing="$1"; shift
  local f key spec scope matched
  shopt -s nullglob
  for f in "${VMTEST_STREAK_PREFIX}"*.json; do
    key="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['key'])" "$f" 2>/dev/null)" || continue
    [ -z "$key" ] && continue
    case "$key" in
      __TIMEOUT__:*|__BUILD__:*)
        spec="${key#*:}"
        [ "$spec" = "${*:-fullsuite}" ] && { rm -f "$f"; echo "streak cleared (recovered): $key"; }
        continue ;;
    esac
    printf '%s\n' "$failing" | grep -Fxq "$key" && continue
    if [ "$#" -eq 0 ]; then
      matched=1
    else
      matched=0
      for scope in "$@"; do
        case "$key" in "$scope"|"$scope"/*) matched=1; break ;; esac
      done
    fi
    [ "$matched" = 1 ] && { rm -f "$f"; echo "streak cleared (passed): $key"; }
  done
  shopt -u nullglob
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
