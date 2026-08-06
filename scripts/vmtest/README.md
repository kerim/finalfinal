# vmtest (project side)

The vmtest **engine** is shared and lives in
`~/Code/Claude Code Meta /vmtest/` — see the README there for the full
design, the circuit breaker, and the residual risks. `scripts/vmtest/vmtest`
here is a thin shim that execs the shared engine with this directory as
`VMTEST_PROJECT_DIR`.

This directory carries only what is final-final-specific:

- `config.sh` — scheme, destination, golden-image names, timeouts, and the
  pointers below
- `guest-prep.sh` — in-guest build steps before xcodebuild (web bundle,
  xcodegen, scheme verification)
- `provision-warm.sh` — host-side pnpm-store warm during golden-image builds
- `known-flaky.txt` — test ids allowed to fail without accruing a breaker
  streak

Anything touching a live VM needs the Bash sandbox disabled
(`dangerouslyDisableSandbox: true`) — the engine now fails fast with an
explicit message if invoked sandboxed, instead of surfacing Virtualization's
misleading "not available on this hardware".
