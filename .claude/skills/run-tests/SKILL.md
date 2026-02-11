---
name: run-tests
description: Run and interpret tests for the "final final" macOS app. Use when asked to run tests, debug test failures, or check test status.
---

# Run Tests — final final

## Commands

All commands use the Xcode scheme `"final final"` targeting macOS. Sandbox must be disabled (`dangerouslyDisableSandbox: true`) because xcodebuild needs SPM cache access.

| What | Command |
|------|---------|
| All tests | `xcodebuild test -scheme "final final" -destination 'platform=macOS'` |
| Unit tests only | `xcodebuild test -scheme "final final" -destination 'platform=macOS' -only-testing "final finalTests"` |
| UI tests only | `xcodebuild test -scheme "final final" -destination 'platform=macOS' -only-testing "final finalUITests"` |
| Single test class | `-only-testing "final finalUITests/LaunchSmokeTests"` |
| Single test method | `-only-testing "final finalUITests/LaunchSmokeTests/testAppLaunches"` |

## Test Inventory

### Unit Tests (`final finalTests/`)

| File | Framework | Class | Methods |
|------|-----------|-------|---------|
| FinalFinalTests.swift | XCTest | FinalFinalTests | testExample (placeholder) |
| OutlineParserTests.swift | Swift Testing | OutlineParserTests | 8 tests (parsing, offsets, pseudo-sections, code blocks, preview, word count) |
| ProjectRepairServiceTests.swift | Swift Testing | ProjectRepairServiceTests | 11 tests (repair scenarios, backup, validation, corrupted fixtures) |
| FixtureGeneratorTests.swift | XCTest | FixtureGeneratorTests | testGenerateCommittedFixture, testCommittedFixtureIsValid |
| EditorBridgeTests.swift | XCTest | MilkdownBridgeTests + CodeMirrorBridgeTests | 9 tests (load, roundtrip, stats, snapshot, focus mode) |

### UI Tests (`final finalUITests/`)

| File | Class | Methods |
|------|-------|---------|
| SmokeTests.swift | LaunchSmokeTests | testAppLaunches, testProjectPickerVisible |
| SmokeTests.swift | EditorSmokeTests | testEditorOpensWithFixture, testEditorModeToggle, testSidebarToggles, testFocusModeToggle |

## Interpreting Results

The summary line at the end of xcodebuild output reads:

```
** TEST SUCCEEDED ** — Executed N tests, with M failures (W unexpected) in X.XXXs
```

or `** TEST FAILED **` if any test failed.

### Common Failure Patterns

| Symptom | Cause | Fix |
|---------|-------|-----|
| "0 windows" / no window found | Test mode environment variable not set | Check that `FF_UI_TESTING` is set in the test scheme |
| Fixture not found | Test fixture missing or not committed | Run `FixtureGeneratorTests` first, or verify fixture is committed to the repo |
| SPM resolution failure | Sandbox blocking network/cache access | Retry with `dangerouslyDisableSandbox: true` |
| EditorBridge timeout | WKWebView didn't load | Rebuild web editors: `cd web && pnpm build` |
| "Cannot find X in scope" | Xcode project out of sync with file system | Run `xcodegen generate` first |

## Filtering Output

For quick pass/fail summary:
```bash
xcodebuild test ... 2>&1 | tail -5
```

For per-test results:
```bash
xcodebuild test ... 2>&1 | grep -E "(Test Case|passed|failed|error:)"
```
