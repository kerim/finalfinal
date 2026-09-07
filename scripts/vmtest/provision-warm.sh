#!/bin/bash
# final final's host-side cache warm, sourced by the shared engine's
# provision.sh while the candidate image is booted. In scope: $ip,
# ssh_guest/scp helpers, PROJECT_ROOT, VMTEST_* config.
#
# Warms the pnpm store and approves esbuild's postinstall so `pnpm build`
# works on first use inside a fresh run clone (found live, Verification 4:
# pnpm's "ignored build scripts" gate skips esbuild's postinstall by
# default, which makes `pnpm build` fail outright — masked on the main
# checkout by a stale-but-present web bundle, exposed by fresh worktrees).

echo "-- warm the pnpm store, and approve esbuild's postinstall --"
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

# ---------------------------------------------------------------------------
# Warm the Xcode build cache (added 2026-09-06).
#
# Ships the current checkout into the guest (excluding .git, worktrees,
# node_modules, build products and run evidence), runs the same guest-prep
# the runner uses, then build-for-testing into VMTEST_GUEST_DERIVED_DATA —
# the path guest/run.sh passes as -derivedDataPath on every run. SPM
# checkouts land in the same tree, so a run clone resolves nothing from the
# network either. Failure here is a WARNING, not fatal: the image still
# works, every run just builds cold as before.
# ---------------------------------------------------------------------------
if [ -n "${VMTEST_GUEST_DERIVED_DATA:-}" ]; then
  echo "-- warm the Xcode build cache: build-for-testing into $VMTEST_GUEST_DERIVED_DATA --"
  if tar -C "$PROJECT_ROOT" \
       --exclude='./.git' --exclude='./.claude/worktrees' --exclude='./node_modules' \
       --exclude='./web/node_modules' --exclude='./build' --exclude='./releases' \
       --exclude="./${VMTEST_DEFAULT_OUT_SUBDIR:-.claude/vmtest-runs}" --exclude='./.derivedData*' \
       -cf - . | ssh_guest "$ip" 'rm -rf /tmp/warm-src && mkdir -p /tmp/warm-src && tar -xf - -C /tmp/warm-src'; then
    ssh_guest "$ip" '
      set -o pipefail
      export PATH="/opt/homebrew/bin:$PATH"
      cd /tmp/warm-src || exit 1
      bash '"$VMTEST_GUEST_PREP"' || exit 1
      dd="'"${VMTEST_GUEST_DERIVED_DATA}"'"; dd="${dd/#\~/$HOME}"
      mkdir -p "$dd"
      xcodebuild build-for-testing \
        -scheme "'"$VMTEST_SCHEME"'" -destination "'"$VMTEST_DESTINATION"'" \
        -derivedDataPath "$dd" \
        CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual 2>&1 | tail -20
      status=${PIPESTATUS[0]}
      du -sh "$dd" 2>/dev/null
      exit "$status"
    ' && echo "   Xcode build cache warmed" || echo "   WARNING: build-for-testing warm failed — runs will build cold (see above)"
    ssh_guest "$ip" 'rm -rf /tmp/warm-src' || true
  else
    echo "   WARNING: could not ship the checkout into the guest — skipping the Xcode cache warm"
  fi
fi
