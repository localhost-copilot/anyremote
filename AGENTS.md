# AGENTS.md

Guidance for coding agents working in this repository. Read `README.md` for
what AnyRemote does and how it works, and `docs/performance.md` before
touching capture, encode or presentation.

## Project

AnyRemote is a Mac-to-Mac remote control app: each remote window opens as a
local window, and the host's full desktop can be shown too. One app is both
host and viewer. macOS 15+, Swift 6, AppKit + SwiftUI.

- `App/` — the app (viewer UI, host settings, menu bar). The Xcode project
  is generated from `project.yml` by XcodeGen and is not committed.
- `Packages/AnyRemoteKit/` — everything else as a Swift package: wire
  format, networking, media pipeline, host agent, viewer client, the
  `anyremote-bench` tool and the tests.
- `DockProxy/` — the stand-in app behind each remote app's Dock icon.

## Build and test

```sh
xcodegen generate -q        # after adding/removing files or editing project.yml
xcodebuild -project AnyRemote.xcodeproj -scheme AnyRemote -configuration Debug \
    -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
swift test --package-path Packages/AnyRemoteKit
```

- Debug builds are **AnyRemote Dev** (`com.localhost-copilot.anyremote.dev`)
  at `build/Build/Products/Debug/AnyRemote Dev.app`. They have their own
  privacy grants and never disturb an installed AnyRemote.
- Run the tests before committing; keep the test count in the README
  (`swift test ... # N tests`) current.
- Exercise changes in the real app, not only in tests. The development
  launch arguments and environment variables in the README drive it from the
  command line, e.g. a viewer against another Mac:

  ```sh
  ANYREMOTE_HOME=/tmp/anyremote-viewer ANYREMOTE_STATS_STDOUT=1 \
    "build/Build/Products/Debug/AnyRemote Dev.app/Contents/MacOS/AnyRemote Dev" \
    --connect <host>:47800 --code "$CODE" --desktop --exit-after 20
  ```

  `anyremote-bench --host --port N` runs a headless host on this Mac
  (`ANYREMOTE_LOOPBACK=1` keeps it from resizing this Mac's display); point
  one or more viewers at `127.0.0.1:N`.
- Check UI changes with a screenshot of the running app.
- Logs: subsystem `com.localhost-copilot.anyremote`. In zsh, call
  `/usr/bin/log`, since `log` is a shell builtin there:
  `/usr/bin/log show --last 2m --predicate 'subsystem == "com.localhost-copilot.anyremote"'`.

## Conventions

- **Interface text** is English. Every user-visible string is localized with
  the English text as the key (`String(localized:)`, SwiftUI `Text("…")`),
  and gets a Simplified Chinese entry in
  `App/Resources/zh-Hans.lproj/Localizable.strings`. Interpolated values use
  format keys (`%@`, `%lld`). Wire and system errors reach users through
  `App/FriendlyText.swift`.
- **Wire compatibility.** Host and viewer must speak the same
  `anyRemoteProtocolVersion` (`AnyRemoteWire/ControlMessage.swift`); a
  mismatch refuses the connection. Bump it for any incompatible change to
  control messages, the handshake, datagram envelopes or the video framing
  (`EncodedVideoFrame`, whose golden-header test then needs updating).
  Adding an optional field to a `Codable` message is compatible.
- **Threading.** All host sessions share the host service's serial queue;
  a session's state is confined to it (so sessions may read each other's
  state there). Video leaves from encoder queues through thread-safe paths
  only. Follow the existing confinement comments (`// Queue-confined.`).
- **Measure performance changes.** Encoder and presentation settings come
  from before/after measurements (see `docs/performance.md`); some
  plausible settings make things worse (`EnableLowLatencyRateControl`
  silently drops to 4:2:0, `RealTime` slows small frames, any view over the
  full-screen video causes stutter). Interleave A/B runs, since the media
  engine's clock varies from run to run, and record new findings there.
- **Comments** explain why, in full sentences; keep them current when the
  code changes. Prefer small, focused types over growing the big
  controllers.

## Versions, commits, releases

- The app version is `MARKETING_VERSION` in `project.yml` (semver: minor for
  features, patch for fixes).
- Commit subjects are imperative sentences describing the user-visible
  change. A commit that bumps the version ends its subject with it:
  `… (v0.9.0)`, and with the protocol when that changes:
  `(v0.8.0, protocol v8)`.
- `scripts/release.sh` builds the universal Release app, signs it with the
  stable local identity from `scripts/signing-identity.sh` and writes
  `build/dist/AnyRemote-<version>.zip`. Only the Mac holding that identity
  can build releases that keep users' privacy grants; never sign releases
  ad hoc, and never commit the identity, its keychain or its password.
- A GitHub release is tagged `v<version>` and carries that zip.

## Never

- Commit pairing codes, keys, tokens or anything from
  `~/Library/Application Support/AnyRemote*`.
- Print a pairing code into logs or test output.
- Commit `build/`, `.build/` or the generated `AnyRemote.xcodeproj`.
