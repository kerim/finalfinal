# Deferred: Support for Alternative Proofing Services

## Motivation

LanguageTool is the current grammar/style backend, but users may prefer other services such as Grammarly, ProWritingAid, or Sapling. Supporting multiple backends would give users more choice.

## Challenges

### Grammarly
- No public API — Grammarly's API is not available for third-party integration outside their own apps and browser extensions.
- Their SDK is limited to web-based text editors and requires a Grammarly account.
- Would need to reverse-engineer or wait for them to open an API.

### ProWritingAid
- Has a public API with plans starting at $20/month.
- REST API similar to LanguageTool's structure (submit text, receive suggestions).
- Would be the most straightforward to add.

### Sapling
- Has an API for grammar/style checking.
- Free tier available with rate limits.

## Architecture

The `ProofingProvider` protocol already supports this:

```swift
@MainActor
protocol ProofingProvider {
    func check(segments: [SpellCheckService.TextSegment]) async -> [SpellCheckService.SpellCheckResult]
    func learnWord(_ word: String)
    func ignoreWord(_ word: String)
}
```

Adding a new service would require:
1. A new provider class implementing `ProofingProvider`
2. A new `ProofingMode` case with the service's base URL
3. UI in `ProofingPreferencesPane` for the service's credentials
4. Response parsing to map the service's output to `SpellCheckResult`

The `SpellCheckResult` struct already has fields that generalize across services: `type`, `message`, `shortMessage`, `ruleId`, `suggestions`.

## Status

Deferred — Grammarly has no public API; ProWritingAid and Sapling are possible but low priority given LanguageTool's coverage.
