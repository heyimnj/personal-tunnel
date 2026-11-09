# Personal Tunnel — working notes

iOS VPN client on the sing-box core (sing-box-lx fork, pinned in `Core/VERSION`). Version 2.0 was written from
scratch; keep it that way: do not import code from the 1.x fork (VPN Direct / sing-box for Apple).

## Layout

- `Packages/TunnelKit` — everything that does not need Apple frameworks (importers, sing-box configuration
  builder, subscriptions, backups, latency runner, shared container keys). Must keep building on Linux:
  `swift test --package-path Packages/TunnelKit`. Add a test for every importer or builder change.
- `App` — SwiftUI app (iOS 17+). `AppModel` owns state and actions; screens live in `App/Sources/Screens`.
- `PacketTunnel` — the Network Extension. Keep it small: iOS limits it to about 50 MiB.
- `Widgets` + `Shared` — WidgetKit extension (iOS 18+) and App Intents shared with the app.
- `project.yml` — XcodeGen spec; the `.xcodeproj` is generated, never committed.

## Rules

- Every interface string goes through `L("Русский текст")`; add the English translation to
  `App/Sources/Core/English.swift`. TunnelKit messages are Russian and are translated by `localizedMessage`.
- Every shared setting appears once and works in all three styles (Classic, Modern, Material You). Only
  style-specific visuals belong to one style. Default accents: Classic `#3478F6`, Modern `#FA243C`,
  Material You seed `#3478F6`. Connection colours are semantic and never follow the accent.
- `UserDefaults` keys of 1.x (`personal.*`, `hapticsEnabled`, the HWID Keychain item) are kept on purpose so
  updates preserve the user's choices. Do not rename them.
- Never put subscription URLs, server credentials or keys in code, logs, tests or commits. Logs and copied
  text go through `Redactor`.
- The app makes requests on its own only for subscription refreshes, the connection check and latency
  tests, and records each in `NetworkActivityLog`. Do not add other outgoing requests silently.
- Do not claim a change is device-verified because CI compiled it.
- Swift 5 language mode; avoid long `??` chains and implicit-member ternaries inside generic modifiers —
  they break the type checker.

## Releases

- `scripts/version.py bump patch|minor|major` (or `set X.Y.Z` when asked); the build number always grows.
- Update `CHANGELOG.md` with every release.
- CI (`.github/workflows/build.yml`) produces the unsigned IPA as an artifact.
