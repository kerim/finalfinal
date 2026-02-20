# Deferred: One-Button Install of Self-Hosted LanguageTool

## Motivation

LanguageTool Free uses the public API (`api.languagetool.org`) which has rate limits and sends text to external servers. A self-hosted LanguageTool server would provide unlimited checks with no rate limits and complete privacy — text never leaves the user's machine.

## Approach

Bundle or automate installation of the LanguageTool HTTP server (Java-based) so users can run it locally. The app would connect to `http://localhost:8081` instead of the public API.

### Key Challenges

- **Java dependency**: LT server requires a JRE. Options: bundle a minimal JRE, use Homebrew, or detect an existing installation.
- **Server lifecycle**: Need to start/stop the server with the app. Possible approaches: `Process()` to launch the JAR, or a LaunchAgent for background persistence.
- **Download size**: The LT server with language data is ~200MB. Could download on first use rather than bundling.
- **Port management**: Default port 8081 may conflict. Need configurable port or automatic port selection.

### Possible UX

A "Self-Hosted" option in the proofing provider picker. On first selection:
1. Check for Java
2. Download LT server if not present
3. Start the server
4. Configure the app to use `localhost:PORT`

### Existing Infrastructure

The current `LanguageToolProvider` already supports arbitrary base URLs via `ProofingMode.baseURL`. Adding a self-hosted mode would primarily require a new `ProofingMode` case and a server management service.

## Status

Deferred — evaluate if there is user demand for local-only proofing.
