# Developing ClaudeBar

Start with the [README](../README.md) for the app's purpose and first build.

## Source layout

The package has no third-party Swift dependencies and requires Swift 6.2.

| Target | Responsibility |
| --- | --- |
| `ClaudeBarCore` | Provider requests, credentials, transcript parsing, analytics, pricing, and usage projections |
| `ClaudeBarApp` | AppKit and SwiftUI menu bar app, settings, file watching, and refresh scheduling |
| `ClaudeBarCLI` | Internal inspection tool for limits and transcript reports |

Keep parsing and provider requests out of the UI. See [Package.swift](../Package.swift) and [architecture notes](../CLAUDE.md).

## Checks

From the repository root:

```sh
swift build -c release
swift test
```

The tests cover core logic and app behavior through separate targets. A passing suite is separate from checking the menu bar UI and an authenticated provider connection.

## Packaging

```sh
Scripts/bundle.sh
Scripts/make_dmg.sh
```

Both scripts build before packaging. `bundle.sh` replaces the app bundle in the repository root; `make_dmg.sh` also creates a versioned disk image. Neither script performs notarization.

Useful overrides supported by the scripts:

| Variable | Purpose |
| --- | --- |
| `CLBAR_CONFIG` | `release` by default; `debug` creates a separate default bundle identity |
| `CLBAR_VERSION`, `CLBAR_BUILD` | Bundle version and build number |
| `CLBAR_DISPLAY_NAME` | App bundle display name |
| `CLBAR_IDENTITY` | Signing certificate to use |
| `CLBAR_SIGN=1` | Use an ad-hoc signature instead of automatically selecting a certificate |

A stable signing identity helps macOS retain a previously granted Keychain permission. Ad-hoc signing can cause another permission request after rebuilding. Inspect the script's signing summary.

## Provider authentication and privacy

The app registry creates six providers: Claude, Codex, Gemini, Cursor, OpenAI API, and Anthropic API. Each supports different data and authentication; transcript analytics remain specific to local Claude Code records.

Claude credentials may come from the shared Claude Code Keychain item. Normal background refresh does not show permission UI. On an explicit user reconnect, the service can check whether that item is writable, refresh an expired token, and write the new credentials back. It falls back to asking the user to reconnect through Claude Code when it cannot do so. The older claim that the app always reads those credentials without writing is no longer accurate. See [ClaudeLimitsService.swift](../Sources/ClaudeBarCore/Limits/ClaudeLimitsService.swift).

Codex credentials are read from its local authentication file. The registered provider defaults to delegating token renewal to Codex; self-refresh exists as an opt-in code path. See [CodexProvider.swift](../Sources/ClaudeBarCore/Providers/Codex/CodexProvider.swift).

App-owned provider secrets use the Keychain. Analytics caches and pricing overrides use the app's Application Support directory. See [AppPaths.swift](../Sources/ClaudeBarCore/Util/AppPaths.swift). Do not include credentials or private transcripts in bug reports.

## Attribution and contributions

Retain the [license](../LICENSE), the CodexBar design attribution, and Simple Icons attribution when sharing changes. CodexBar is MIT-licensed; the original project records the provider glyphs as CC0.

Before proposing a change, run the relevant tests and describe separately any provider or UI checks you performed. This repository does not have a dedicated contribution guide; its existing architectural notes are in [CLAUDE.md](../CLAUDE.md).
