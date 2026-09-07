# vmtest (project side)

The vmtest **engine** is shared and lives in
`~/Code/Claude Code Meta /vmtest/` — see the README there for the full
design, the per-key retry gate, sharding, and the residual risks.
`scripts/vmtest/vmtest` here is a thin shim that execs the shared engine
with this directory as `VMTEST_PROJECT_DIR`.

**Two suites, since the test-tiers-ship plan (2026-09-04):** `vmtest run
--suite smoke` (a handful of golden-path classes, the merge gate, under 5
min) and `vmtest run --suite full` (the whole scheme, sharded across two
VM clones, the release gate — driven by the `ship` skill, not run ad hoc).
A bare `vmtest run` or a bare-target `--scope` is a hard error now; name
`--suite` or a `Target/Class[/method]` scope.

This directory carries only what is final-final-specific:

- `config.sh` — scheme, destination, golden-image names, timeouts,
  `VMTEST_SMOKE_SCOPES`, `VMTEST_UI_TEST_DIR`/`MODULE`,
  `VMTEST_SCRATCH_CLASS`, and the pointers below
- `guest-prep.sh` — in-guest build steps before xcodebuild (web bundle,
  xcodegen, scheme verification)
- `provision-warm.sh` — host-side pnpm-store warm during golden-image builds
- `known-flaky.txt` — test ids allowed to fail without accruing a retry-gate
  streak

Anything touching a live VM needs the Bash sandbox disabled
(`dangerouslyDisableSandbox: true`) — the engine now fails fast with an
explicit message if invoked sandboxed, instead of surfacing Virtualization's
misleading "not available on this hardware".

## Residual risks

- **`NSSavePanel` does not present in the VM guest.** Confirmed 2026-08-29 by
  direct comparison against `PrintE2ETests.invokePrint()` — an identical
  File-menu click sequence that successfully surfaces `NSPrintPanel` in the
  same VM within seconds. `NSSavePanel.begin` depends on an out-of-process
  ViewBridge remote-view-service the guest doesn't provide correctly, so the
  panel silently fails to present: no window, no alert, nothing — a UI test
  driving it just times out with no diagnostic signal. `NSPrintPanel` is
  in-process AppKit and unaffected, so print-flow tests are fine. This blocks
  UI-driving any export route in `FileCommands+Export.swift` (Word,
  Markdown-with-Images, Markdown-Only, TextBundle all call `savePanel.begin`)
  — write those tests around the save panel (DB read-back, or a unit test with
  `@testable import`) rather than through it. See
  `docs/lessons/nssavepanel-vm-guest.md` for the full writeup.
