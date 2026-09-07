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
