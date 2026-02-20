# Spell Check Architecture

Spell checking bridges macOS NSSpellChecker to web editors via WKWebView message handlers.

---

## Message Flow

```
Web Editor (400ms debounce)
    |
    | postMessage("spellcheck", {action:"check", segments, requestId})
    v
Swift Coordinator (MilkdownCoordinator / CodeMirrorCoordinator)
    |
    | SpellCheckService.shared.check(segments:)
    v
NSSpellChecker (spelling only)
    |
    | evaluateJavaScript: window.FinalFinal.setSpellcheckResults(requestId, results)
    v
Web Editor (validates requestId, applies decorations)
```

### Web → Swift Messages

All go through `window.webkit.messageHandlers.spellcheck.postMessage()`:

| Action | Data | Purpose |
|--------|------|---------|
| `check` | `{segments: [{text, from, to}], requestId}` | Request spellcheck for visible text |
| `learn` | `{word}` | Add word to user dictionary |
| `ignore` | `{word}` | Ignore word for this session |

### Swift → Web Callback

`window.FinalFinal.setSpellcheckResults(requestId, results)` where each result:

```json
{ "from": 42, "to": 48, "word": "teh", "type": "spelling", "suggestions": ["the"], "message": null }
```

## Race Prevention

- **Request ID**: Monotonically increasing counter; web editors discard stale results
- **Task cancellation**: Swift cancels the previous `spellcheckTask` before starting a new one
- **Debounce**: 400ms delay on the web side prevents spamming during typing

## Segment Extraction

Both editors extract text segments, skipping non-prose content:

- **Milkdown**: Walks ProseMirror node tree, skips code blocks, citations, bibliography
- **CodeMirror**: Uses Lezer syntax tree, strips hidden anchor markers to avoid false positives

## Current Scope: Spelling Only

`SpellCheckService` uses `NSSpellChecker.check()` and filters for `.spelling` results only. Testing showed that `checkGrammarOfString` does not reliably reproduce the grammar checking that TextEdit provides programmatically.

Grammar and style checking are deferred to **LanguageTool** (optional, via local HTTP server). The web plugins already support `type: "grammar"` decorations (`.cm-grammar-error` / `.grammar-error` CSS classes) and will display grammar results when a LanguageTool backend is connected.

## Context Menu

Right-clicking a decorated word shows a native-style menu with:
- Replacement suggestions (click to apply)
- "Learn Spelling" (adds to macOS user dictionary)
- "Ignore" (session-only ignore list)
