# vmtest

The only sanctioned way to run `final final`'s macOS UI tests. Every run
happens in a disposable Tart macOS guest, headless — no Touch ID prompt, no
host screen/keyboard takeover. See
`/Users/niyaro/.claude/plans/tranquil-humming-phoenix.md` for the full design
rationale; this file is the operational reference.

## Commands

See `vmtest --help`, or the table in the plan's §1.

## Why it needs the sandbox disabled

`tart clone` works fine inside Claude Code's Bash sandbox (pure filesystem,
copy-on-write). `tart run`/`exec`/`stop`/`delete` do not — they need the
Virtualization framework, which the sandbox denies outright ("Virtualization
is not available on this hardware"). `vmtest` therefore runs with
`dangerouslyDisableSandbox: true` for anything touching a live VM. This was
measured directly, not assumed (see the plan's progress ledger, Step 0
Experiment 2).

## Circuit breaker

Recording only arms once a test key has failed twice in a row (or `--record`
is passed). On a third consecutive failure of the same key, `vmtest` refuses
**all further runs of any scope** until the user resets it — see the plan's
§3 for the full mechanism and why per-key keying, not per-scope, is correct.

`vmtest reset` needs a sentinel the user creates themselves:

```
touch ~/.cache/vmtest/allow-reset
```

Claude cannot create this sentinel — that is the point.

## known-flaky.txt

Test ids in `known-flaky.txt` never accrue a streak. **It cannot be widened
while any streak is non-zero** — `vmtest` snapshots its hash whenever all
streaks are zero and refuses to run if the file changed underneath a live
streak. This exists because "declare it flaky" is the least-friction move
available to a stuck session at strike two.

## Residual risks (accepted, not hardened)

These are known limits of the design, not surprises to route around:

- The guest-access deny in `uitest-ready-gate.sh` is string-matched
  (`tart exec`, `tart ssh`, direct `ssh` to the guest); indirection (an IP in
  a variable, a hand-written wrapper) can walk past it.
- A known-flaky id can never arm recording — if a documented flake hardens
  into a real regression, every run of it reports `pass-with-known-flakes`
  with no video ever produced. Investigate a suspected-worsening flake with
  `vmtest run --record --scope <that test>`, never by waiting for the
  breaker.
- The `.cache/vmtest` Bash deny (in `uitest-ready-gate.sh`) is
  spelling-based: it also refuses read-only commands that merely name the
  path. Use the `Read` tool, `vmtest status`, or `vmtest doctor` instead —
  this is a known limitation, not a malfunction.
- Strike-1/strike-2 stills can be lost if their `--out` directory (e.g. a
  superdev worktree) is deleted before the streak trips — the tripping run's
  own evidence always survives; earlier strikes' may not.
- A `__BUILD__` streak (a runner/build bug, not a test failure) locks
  `scripts/vmtest/**` against editing along with everything else at
  non-zero streak — the user's reset sentinel is the only way out. This is
  user-contact-by-design.
- `vmtest-result.json` and the exported `.xcresult` are session-writable — a
  session could misreport a result downstream, but this never clears a
  streak (accounting happens upstream at parse time).

## Never allowlist `vmtest reset` as part of a `vmtest:*` wildcard

The seven allowlisted subcommands (`run`, `status`, `wait`, `doctor`,
`image`, `prune`, `watch`) are deliberately listed individually in
`final final/.claude/settings.json`, not as a wildcard — a wildcard would
silently re-include `reset`, defeating the double gate (sentinel + no allow
rule) described above. If you are ever tempted to collapse these into
`vmtest:*` (e.g. via the `fewer-permission-prompts` skill), don't.
