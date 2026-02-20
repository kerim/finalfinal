# LanguageTool Integration Design

**Date:** 2026-02-20
**Status:** Approved
**Scope:** Core + rule disable (first iteration)

## Context

Phase 2g testing proved that NSSpellChecker's programmatic API cannot reproduce the grammar checking that TextEdit provides. The `checkGrammarOfString` API catches some errors but misses many. Decision: accept built-in spelling-only for the baseline, switch to LanguageTool for grammar+spelling+style when available.

## Modes

| Mode | URL | Auth | Capabilities |
|------|-----|------|-------------|
| Built-in | — | — | Spelling only (NSSpellChecker) |
| LT Free | `api.languagetool.org` | None | Spelling + grammar (rate-limited: 20 req/min) |
| LT Premium | `api.languagetoolplus.com` | API key (Keychain) | Spelling + grammar + style + picky mode |

## Architecture

### Protocol-Based Provider System

```swift
@MainActor
protocol ProofingProvider {
    func check(segments: [SpellCheckService.TextSegment]) async -> [SpellCheckService.SpellCheckResult]
    func learnWord(_ word: String)
    func ignoreWord(_ word: String)
}
```

**BuiltInProvider** — wraps existing NSSpellChecker logic. Returns `type: "spelling"` only.

**LanguageToolProvider** — HTTP POST to `/v2/check`:
- Consolidates segments into a single text blob with offset mapping
- Maps LT `matches` back to editor positions
- Categorizes: `issueType == "misspelling"` → `"spelling"`, grammar category → `"grammar"`, else → `"style"`
- Populates `message`, `ruleId`, `isPicky` fields

**SpellCheckService** becomes a thin dispatcher with `var activeProvider: ProofingProvider`. Coordinators remain untouched.

### SpellCheckResult Struct

```swift
struct SpellCheckResult: Codable, Sendable {
    let from: Int
    let to: Int
    let word: String
    let type: String       // "spelling", "grammar", or "style"
    let suggestions: [String]
    let message: String?   // Grammar/style explanation (nil for spelling)
    let ruleId: String?    // LT rule ID (nil for built-in)
    let isPicky: Bool      // true for picky-mode-only matches
}
```

## Settings (UserDefaults + Keychain)

| Key | Type | Default | Storage |
|-----|------|---------|---------|
| `proofingMode` | `ProofingMode` enum | `.builtIn` | UserDefaults |
| `ltServerPreset` | `"premium"` or `"custom"` | `"premium"` | UserDefaults |
| `ltApiKey` | String | `""` | Keychain |
| `ltCustomURL` | String | `""` | UserDefaults |
| `ltPickyMode` | Bool | `false` | UserDefaults |
| `ltDisabledRules` | `[String]` | `[]` | UserDefaults |
| `ltLanguage` | String | `"auto"` | UserDefaults |

## HTTP Client

**Request:** `URLSession` POST to `/v2/check` with form-encoded body:
```
text=<full text>&language=auto&level=picky&apiKey=<key>&disabledRules=<comma-separated>
```

**Segment consolidation:**
1. Join segments with `\n\n` separators
2. Track cumulative offsets per segment
3. Map LT match `offset` → editor position by finding the containing segment

**Error handling:**
- Connection refused → status bar red dot, popover: "Server unreachable"
- 401/403 → "Invalid API key"
- Timeout (10s) → silently return empty results for that cycle
- Rate limit → "Rate limit exceeded"

**Connection status:** `@Published` property: `.connected`, `.disconnected`, `.authError`, `.rateLimited`

## Preferences UI

New "Proofing" tab in PreferencesView (icon: `textformat.abc`):

```
┌─ Proofing Provider ─────────────────────────────┐
│  ○ Built-in (spelling only)                     │
│  ○ LanguageTool Free (spelling + grammar)       │
│  ○ LanguageTool Premium (spelling + grammar +   │
│    style)                                       │
│                                                 │
│  [Only shown when Premium selected:]            │
│  API Key: [••••••••••••••]  [Test Connection]   │
│  Status: ● Connected                            │
│                                                 │
│  [Only shown when any LT mode selected:]        │
│  ☑ Picky mode (stricter style checks)           │
│  Language: [Auto-detect ▾]                      │
└─────────────────────────────────────────────────┘

┌─ Disabled Rules ────────────────────────────────┐
│  COMMA_BEFORE_AND — Comma before "and"    [✕]   │
│  UPPERCASE_SENTENCE — Sentence starts...  [✕]   │
│  (rules added via context menu — ✕ to re-enable)│
└─────────────────────────────────────────────────┘
```

## Status Bar

When LT mode is active, status bar shows a proofing indicator next to word count:
- Green dot: connected, last check succeeded
- Yellow dot: checking in progress
- Red dot: last request failed
- Click → popover with error details + "Open Proofing Preferences" button

## Web-Side UX

### Two Interaction Patterns

**Spelling errors** — right-click context menu (existing pattern):
- Suggestion list → click to replace
- Learn Spelling / Ignore

**Grammar/style errors** — click-triggered floating popover (inspired by LT in Google Docs):
- Rule name header + disable (⊘) button
- Explanation text from LT `message`
- Suggestion button(s) showing corrected text → click to apply
- Ignore button
- "Picky Suggestion" label when `isPicky` is true, with "Disable here"
- Positions near the underlined text, dismisses on click outside

### Decorations (3 types)

| Type | Milkdown class | CodeMirror class | Style |
|------|---------------|-----------------|-------|
| Spelling | `.spell-error` | `.cm-spell-error` | Red wavy underline |
| Grammar | `.grammar-error` | `.cm-grammar-error` | Blue dashed underline |
| Style | `.style-error` | `.cm-style-error` | Green dotted underline |

### Message Actions (Web → Swift)

| Action | Data | Purpose |
|--------|------|---------|
| `check` | `{segments, requestId}` | Request proofing (unchanged) |
| `learn` | `{word}` | Add to dictionary (unchanged) |
| `ignore` | `{word}` | Session ignore (unchanged) |
| `disableRule` | `{ruleId}` | **New:** store in UserDefaults, re-check |

### Shared Module

New `spellcheck-popover.ts` module shared between both editors for the grammar/style popover component.

## Dictionary Sync

| Action | Built-in | LT Free | LT Premium |
|--------|----------|---------|------------|
| Learn | macOS dictionary | macOS dictionary | macOS dictionary + LT cloud (`/v2/words/add`) |
| Ignore | NSSpellChecker session | Local set | Local set |

## Deferred (Future Iterations)

- Custom server URL field in preferences
- One-click local LT server install from preferences (offline + privacy)
- Per-document language override (stored in GRDB)
- Enabled/disabled rule categories in preferences
- Pull existing LT cloud dictionary on startup

## References

- [LanguageTool Public HTTP API](https://dev.languagetool.org/public-http-api.html)
- [LanguageTool API Swagger](https://languagetool.org/http-api/swagger-ui/)
- [Obsidian LT Plugin](https://github.com/Clemens-E/obsidian-languagetool-plugin) (feature reference)
- [Self-hosted vs Premium differences](https://github.com/languagetool-org/languagetool/issues/6750)
