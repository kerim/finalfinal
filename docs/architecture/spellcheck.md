# Spell Check & Proofing Architecture

Dual-provider system: macOS NSSpellChecker for spelling + optional LanguageTool HTTP API for grammar/style. Web editors communicate with Swift via WKWebView message handlers.

---

## Provider Architecture

```
ProofingProvider (protocol)
    ├── BuiltInProvider      → NSSpellChecker (spelling only)
    └── LanguageToolProvider  → HTTP API (grammar + style)

SpellCheckService (dispatcher)
    - Always routes spelling to BuiltInProvider
    - Routes grammar/style to LanguageToolProvider when configured
    - Filters LT results to exclude spelling (avoids duplicates)
```

### ProofingSettings

Singleton `@Observable` class storing user preferences in UserDefaults:

| Key | Default | Purpose |
|-----|---------|---------|
| `proofingMode` | `builtIn` | Provider mode (builtIn / languageToolFree / languageToolPremium) |
| `ltPickyMode` | `false` | Stricter style checks |
| `ltLanguage` | `auto` | Language for LT API |
| `ltDisabledRules` | `[]` | User-suppressed rule IDs |
| `ltUsername` | `""` | LT Premium email |
| `ltApiKey` | `""` | LT Premium API key |

### ProofingMode

Three modes with different capabilities:

| Mode | Spelling | Grammar | Style | API |
|------|----------|---------|-------|-----|
| Built-in | NSSpellChecker | — | — | — |
| LT Free | NSSpellChecker | LT public API | — | `api.languagetool.org` |
| LT Premium | NSSpellChecker | LT premium API | LT premium API | `api.languagetoolplus.com` |

---

## Message Flow

```
Web Editor (400ms debounce)
    │
    │ postMessage("spellcheck", {action:"check", segments, requestId})
    ▼
Swift Coordinator (MilkdownCoordinator / CodeMirrorCoordinator)
    │
    │ SpellCheckService.shared.check(segments:)
    ▼
SpellCheckService (dispatch)
    ├──▶ BuiltInProvider  → NSSpellChecker (spelling results)
    └──▶ LanguageToolProvider → HTTP POST /v2/check (grammar/style results)
    │
    │ Merge results, return via evaluateJavaScript
    ▼
window.FinalFinal.setSpellcheckResults(requestId, results)
    │
    ▼
Web Editor (validates requestId, applies decorations)
```

### Web → Swift Messages

All go through `window.webkit.messageHandlers.spellcheck.postMessage()`:

| Action | Data | Purpose |
|--------|------|---------|
| `check` | `{segments: [{text, from, to, blockId?}], requestId}` | Request proofing for visible text |
| `learn` | `{word}` | Add word to user dictionary |
| `ignore` | `{word}` | Ignore word for this session |
| `disableRule` | `{ruleId}` | Suppress a grammar/style rule |

### Swift → Web Callback

`window.FinalFinal.setSpellcheckResults(requestId, results)` where each result:

```json
{
  "from": 42, "to": 48,
  "word": "teh",
  "type": "spelling",
  "suggestions": ["the"],
  "message": null,
  "shortMessage": null,
  "ruleId": null,
  "isPicky": false
}
```

Result `type` values: `"spelling"`, `"grammar"`, `"style"`.

---

## LanguageTool Integration

### Segment Consolidation

LanguageToolProvider consolidates all text segments into a single string with an offset map. This sends one HTTP request per check cycle instead of one per segment. Response offsets are mapped back to editor positions using the offset map.

Segments include an optional `blockId` (paragraph identifier) that controls joining:
- **Same blockId** → joined with a single space (preserves sentence context within a paragraph)
- **Different blockId or no blockId** → joined with `\n\n` (paragraph break)

### Error Classification

LT responses are classified by category:
- `TYPOS` / `SPELLING` category or `misspelling` issue type → `"spelling"` (filtered out by dispatcher to avoid duplicating BuiltInProvider results)
- `style` / `typographical` issue type → `"style"`
- Everything else → `"grammar"`

### Connection Status

`LTConnectionStatus` enum tracks API state: `.connected`, `.disconnected`, `.authError`, `.rateLimited`, `.checking`. Displayed in the status bar as a colored dot with popover detail.

### Cloud Dictionary Sync

When a Premium user clicks "Learn Spelling", the word is added to both the local macOS dictionary and the LT cloud dictionary via `POST /v2/words/add`.

---

## Race Prevention

- **Request ID**: Monotonically increasing counter; web editors discard stale results
- **Task cancellation**: Swift cancels the previous `spellcheckTask` before starting a new one
- **Debounce**: 400ms delay on the web side prevents spamming during typing

## Segment Extraction

Both editors extract text segments, skipping non-prose content. Each segment includes a `blockId` to identify its parent paragraph.

- **Milkdown**: Walks ProseMirror node tree, skips code blocks, citations, section breaks, bibliography. `blockId` = paragraph node position.
- **CodeMirror**: Uses Lezer syntax tree. Skips code, URLs, HTML (including inline `Comment` nodes for annotations/anchors), and markdown syntax markers. Strips hidden anchor markers and filters bare citation keys (`@citekey`). `blockId` = line number.

### False Positive Filtering

LanguageToolProvider applies post-processing filters to reduce false positives:

- **Cross-segment boundary**: Matches spanning the injected space between same-block segments are discarded (always false positives from joining)
- **Non-Latin script**: Matches targeting CJK, Arabic, Devanagari, or other non-Latin text are skipped (LT only supports Latin-script languages)

## Decoration Types

Three CSS classes for underline decorations:

| Type | Milkdown class | CodeMirror class | Color |
|------|---------------|-----------------|-------|
| Spelling | `.spelling-error` | `.cm-spelling-error` | Red wavy underline |
| Grammar | `.grammar-error` | `.cm-grammar-error` | Blue wavy underline |
| Style | `.style-error` | `.cm-style-error` | Yellow wavy underline |

## Click Interaction

Clicking any decorated word shows an inline UI. The UI type depends on the error:

**Spelling errors** → Spell menu (compact dropdown):
- Replacement suggestions (click to apply)
- "Learn Spelling" (adds to macOS dictionary + LT cloud if Premium)
- "Ignore" (session-only ignore list)

**Grammar/style errors** → Proofing popover (richer panel):
- Error message and short description
- Replacement suggestions (click to apply)
- "Ignore" (session-only ignore list)
- "Disable Rule" (permanently suppresses the rule via ProofingSettings)

Right-clicking a spelling error also opens the spell menu (context menu handler preserved). Cross-dismissal ensures only one menu/popover is visible at a time.

## Notification-Based Communication

Settings changes propagate via NotificationCenter:

| Notification | Trigger | Effect |
|-------------|---------|--------|
| `.proofingModeChanged` | Provider picker changed | Re-runs proofing with new provider |
| `.proofingSettingsChanged` | Language, picky mode, credentials, or disabled rules changed | Re-runs proofing with updated settings |
| `.proofingConnectionStatusChanged` | After each check completes | Status bar updates connection indicator |

Credential fields use a 1.5s debounce before posting `.proofingSettingsChanged` to avoid hammering the API while the user types.

## Preferences Pane

`ProofingPreferencesPane` provides:
- Radio group for provider mode (Built-in / LT Free / LT Premium)
- Credential fields (email + API key) — shown only for Premium
- "Test Connection" button with status indicator
- Picky mode toggle
- Language picker (auto-detect + common languages)
- Disabled rules list with re-enable buttons
