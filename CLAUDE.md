# CLAUDE.md

## Build Commands

```bash
# Build web editors (required before Xcode build)
cd web && pnpm install && pnpm build

# Regenerate Xcode project (after moving/adding Swift files)
xcodegen generate

# Build macOS app
xcodebuild -scheme "final final" -destination 'platform=macOS' build

# Full rebuild
cd web && pnpm build && cd .. && xcodegen generate && xcodebuild -scheme "final final" -destination 'platform=macOS' build

# Lint web editors
cd web && pnpm lint          # Check for issues
cd web && pnpm lint:fix      # Auto-fix issues
cd web && pnpm format        # Format files
```

Web output goes to `final final/Resources/editor/` which Xcode bundles.

**xcodegen:** This project generates the Xcode project from `project.yml`. Always run `xcodegen generate` after moving or adding Swift files.

**Xcode MCP:** Always use MCP tools (`BuildProject`, `RunAllTests`, etc.) for builds and tests — they run inside Xcode's process, bypassing all sandbox restrictions. Use `XcodeListWindows` first to get `tabIdentifier`. If MCP fails because Xcode is not open, ask the user to launch Xcode and retry. Do not use `dangerouslyDisableSandbox`. For `web/` files and non-project files, use regular filesystem tools.

## Architecture

**SQLite-first hybrid app:** SwiftUI shell + GRDB database + WKWebView editors (Milkdown WYSIWYG, CodeMirror source). macOS 15.0+.

**Core principle:** Database is single source of truth. No file watching, no manifest sync.

Swift ↔ Web communication uses a custom `editor://` URL scheme + 500ms polling via `window.FinalFinal` API.

## Versioning

- **Marketing Version**: `1` (static until release)
- **Project Version**: `0.PHASE.BUILD` format

Increment BUILD with every build. Update in `web/package.json` and `project.yml`.

## Testing

See `docs/guides/running-tests.md` for full details.

- **Before committing Swift changes:** run unit tests (`final finalTests`, ~30s)
- **After logic changes:** run unit tests — outline parsing, database repair, editor bridge
- **Before merging to main:** run full UI suite (`final finalUITests`, ~35s)
- **After schema migrations:** regenerate fixture with `FixtureGeneratorTests/testGenerateCommittedFixture`, then run both suites

Quick smoke test: `xcodebuild test -scheme "final final" -destination 'platform=macOS' -only-testing "final finalUITests/LaunchSmokeTests"` (~7s)

## Debugging

All Swift logging uses `DebugLog.log(.category, "message")` — a category-gated system. Use `DebugLog.log(.category, ...)` for all new logging, never bare `print()`. By default only `.lifecycle` and `.zotero` are enabled; edit `DebugLog.enabled` to enable more. See `docs/guides/debug-logging.md` and `docs/guides/webkit-debug-logging.md` for full details.

### Two-Attempt Rule

After 2 failed fix attempts, STOP. Add `DebugLog.log()` calls to trace actual execution, analyze logs, find verified root cause, then fix.

## Git Commits

1. Always run `git status` first to see ALL modified files
2. Review the full list before committing — ask user if any should be excluded
3. Include all related work from the session, not just the last task

**Commit message format:** Use multiple `-m` flags (heredocs fail in sandbox):
```bash
git commit -m "Title" -m "Body line 1" -m "Body line 2"
```

## Documentation

- `docs/deferred/` - Abandoned approaches that might be revisited
- `docs/LESSONS-LEARNED.md` - Technical patterns discovered
- `docs/design.md` - Master design document
- `KUDOS.md` - Third-party code attribution

When completing a feature phase, update: CLAUDE.md, README.md, `docs/design.md`, and KUDOS.md (if new dependencies).
