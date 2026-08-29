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
