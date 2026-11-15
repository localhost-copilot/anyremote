# AnyRemote

Mac-to-Mac remote control where the unit of sharing is a **window**, not a
display. The viewer lists every window on the host, opens any of them as a
local window and resizes it freely; the host window is resized to match, so
frames are presented pixel-for-pixel, like a native window. Menus, popovers
and other child windows appear as local child windows, and the host app's
menu bar becomes the viewer's native menu bar.

Latency and image quality target Apple's Screen Sharing high-performance mode
(see the sibling `iScreenSharing` client): HEVC 4:4:4, real-time hardware
encode/decode, Metal presentation on arrival. Full-desktop sessions hand off
to `iScreenSharing` (or Screen Sharing) via `vnc://`; Apple's protocol has no
window-level mode, so window streaming uses our own host agent and protocol.

Every AnyRemote instance is both a host (others may control this Mac) and a
viewer. One viewer controls a host at a time; a second one may take over.

## Using it

1. On each Mac: open AnyRemote. If permissions are missing, Settings opens
   with a checklist: grant **Screen Recording** and **Accessibility**, allow
   **Local Network** when asked. Settings shows the exact app copy that
   needs the grants; macOS keys them to that copy's signature.
2. The menu bar icon shows whether this Mac can be controlled, who controls
   it right now (with **Disconnect**) and the pairing code
   (`XXXXX-XXXXX-XXXXX-XXXXX`).
3. On the controlling Mac, the window picker (⌃⌥⌘0 from anywhere) lists
   *My Macs* (paired) and *Nearby* (unpaired, Bonjour); **Add by address**
   covers other networks. Selecting an unpaired Mac asks for its code once.
4. The picker selects and connects the last used Mac, focuses the search
   field and groups windows by app. Type to filter, arrows to select,
   Return or double-click to open; the picker stays open behind the new
   window (the AnyRemote Dock icon or ⌃⌥⌘0 brings it forward). An already
   open window is brought forward instead of opened twice.
5. **Apps** (next to **Windows** above the grid) lists the host's apps
   (`/Applications`, `/System/Applications`, their Utilities, `~/Applications`
   and anything running). Opening one launches it there, or brings it
   forward if it's running, and its front window opens here as a mirror; an
   app with no window gets a new one, as if its Dock icon was clicked.

If the host lacks Accessibility, mirrors show a banner saying input won't
work; the picker shows the same, live, until it is granted.

"This Mac" is not listed: controlling a Mac from itself feeds the injected
clicks back into the mirror. `ANYREMOTE_LOOPBACK=1` lists it for
development. There, `ANYREMOTE_NO_HOST_FOCUS=1` also stops the host from
activating the mirrored app, so the remote menu bar can be tried out.

A mirror behaves like a local window. Dragging it (by the title bar,
toolbar or any area the app treats as draggable) moves only the mirror: the
host window stays where it is, so it never ends up partly off its display.
Its title bar buttons act on it:
close closes the host window (and with it the mirror; a save sheet appears
as usual), minimize minimizes the mirror only, green enters full screen on
this Mac (the host window is resized to this screen) and ⌥-green zooms. ⌘M
and ⌃⌘F act on the mirror too. If the host window gets minimized or goes
full screen on the host (Window menu, a title bar double-click), the host
undoes it and the mirror does it instead.

A window that appears on the host within 3 s of a click, key or menu
command in a mirror opens as a new mirror: a new document, a Settings
window, or another app's window such as Finder revealing a file. Windows
that appear on their own stay on the host and can be opened from the
picker.

Each remote app with windows open here gets its own Dock icon and ⌘Tab
entry, like Parallels' Coherence mode: a small stand-in app (`DockProxy/`)
generated under `~/Library/Application Support/<bundle ID>/Dock/` with the
app's icon (badged with a display) and the name "App (Mac)". Clicking it
brings that app's windows forward, its Dock menu lists them, and Quit closes
them on this Mac only. Settings → General → *Show Remote Apps in the Dock*.

The clipboard is shared both ways while connected (Settings → General →
*Share Clipboard*): text, rich text, HTML, images (TIFF is sent as PNG) and
links, up to 16 MB. Contents marked concealed or transient (password
managers) and copied files stay on their Mac. On connecting, this Mac's
clipboard is sent to the host.

A window attached to another (a sheet) is captured by ScreenCaptureKit
together with its parent; such a capture switches to a display capture of
just that window, cropped to its frame.

The interface is in English; Settings → General → Language switches to
Simplified Chinese (or the system language) after a restart.

While a mirror is key, every key goes to the host (⌘Q quits the *remote*
app). AnyRemote's own commands use ⌃⌥⌘: Hosts ⌃⌥⌘0, Statistics ⌃⌥⌘I,
Full Desktop ⌃⌥⌘D, Close on This Mac ⌃⌥⌘W (the host window stays open; also in
the picker's and the menu bar icon's menus).

Settings → *HiDPI virtual display*: on a headless Mac mini (or one with a 1x
monitor) shared windows move to a 1920×1200 pt virtual display rendered at
2x, so they are sharp and can be larger than the physical screen. They move
back when the mirror closes; the display disappears with the last stream.

## Architecture

```
host                                                viewer
SCK desktopIndependentWindow (444f / BGRA+alpha)
 → VTCompressionSession HEVC RExt 4:4:4 or HEVC+alpha
 → EncodedVideoFrame → 1372-byte fragments
 → AES-GCM datagram envelope ──── UDP ────→ replay check → VideoReassembler
                                            → KeyframeGate → VTDecompressionSession
                                            → VideoFrameLayer (CAMetalLayer)
AX geometry / focus / menus  ←── TCP control (AES-GCM) ──  input, resize, focus,
CGEvent injection                                          menu picks, reports
cursor (CGSCurrentCursorSeed) ─────────────────────────→  local NSCursor
```

- **Control** — TCP (Network.framework, no-delay, keepalive,
  `interactiveVideo` service class), length-prefixed frames, JSON messages
  (`ControlMessage`). Ordered and reliable: input, resize, menus, cursor.
- **Video** — a plain UDP socket (8 MB buffers, `SO_TRAFFIC_CLASS` video
  interactive, non-blocking). The viewer sends a sealed keepalive every
  500 ms; the host learns the viewer's address from it (NAT-safe).
  Fragments are dropped, never retransmitted; the reassembler keeps only the
  newest frame and abandoned frames trigger rate-limited keyframe requests.
- **Clock sync** — ping/pong; the minimum-RTT sample gives the host↔viewer
  clock offset, so `receive` and `total` latency are measured across
  machines.
- **Bitrate** — receiver reports every second; ×0.75 on loss, +10% after four
  clean seconds, 6–80 Mbps (child windows ≤20 Mbps).
- **Input** — mouse/scroll/keys as `CGEvent`s posted at the HID tap, at
  points relative to the window's top-left (the origin is frozen during a
  press so title-bar drags work, and the mirror follows the host window
  while it moves). Focus via AX `AXFrontmost` + `AXMain` + `AXRaise`. Keys
  are virtual key codes, so the host's keyboard layout applies.
- **Child windows** — every 33 ms (8 ms while a button is down) the host
  looks for same-process windows on menu/popup layers, or non-standard
  layer-0 windows near the main window (sheets, popovers), plus the
  Open/Save panel service. Each streams as HEVC with alpha and is shown as a
  borderless, non-activating local child window at the matching offset.
- **New windows** — the host remembers which layer-0 windows were on
  screen. One that appears within 3 s of viewer input, is at least 160×100
  pt and is a standard window to Accessibility (checked again for 1.5 s,
  since new windows reach AX late) is opened like a picked window.
- **Window state** — the host sends the title bar button rects; the viewer
  handles them locally, and a host-side minimize/full screen is reverted
  and forwarded as `windowStateRequest`.
- **Menu bar** — read through AX (`AXUIElementCopyMultipleAttributeValues`)
  as a `MenuNode` tree, rebuilt as native `NSMenu`s while the mirror is key
  and refreshed on every open; choosing an item presses it on the host.
- **Virtual display** — private `CGVirtualDisplay` (hiDPI), forced into an
  extended (non-mirrored) arrangement right of the main display.

### Security

The pairing code is 100 bits (20 Crockford base32 characters). Both sides
derive a pre-shared key from it with HKDF-SHA256; each connection mixes in
two fresh 32-byte nonces to derive four AES-256-GCM keys (control and
datagram, each direction). Control frames use implicit counter nonces; video
datagrams carry an explicit counter (authenticated, 1024-entry replay
window). A wrong code fails at the first sealed frame and the host says so.
Resetting the code in Settings disconnects the current viewer. Settings and
saved hosts are JSON files (mode 0600) in
`~/Library/Application Support/AnyRemote`.

## Measured (M6 Mac18,5, macOS 27, 60 Hz display, network loopback)

Synthetic 940×700 pt window (1880×1400 px) scrolling dense text every
refresh, viewer and host in one app talking over UDP/TCP (127.0.0.1 and the
LAN address). Milliseconds, p50 / p95.

| Stage | |
|---|---|
| Host encode (capture → encoded) | 5.8–6.8 / 6.3–8.2 |
| Receive (capture → reassembled on viewer, clock-synced) | 6.7–7.5 / 7.4–9.7 |
| Decode | 1.2–1.4 |
| Present (decoded → on glass, 60 Hz) | 9–15 |
| **Total (capture → on glass)** | **18–26 / 25–45** |
| Control RTT | 0.3–0.5 |
| Mirror resize → host window applied → new frames | 20–24 |

~48–58 fps at 5–15 Mbps for this workload, no loss. Across a real network add
one-way network latency to *receive*.

VideoToolbox findings behind the encoder settings (each measured
before/after):

- `kVTCompressionPropertyKey_ExpectedFrameRate` acts as a latency budget:
  VT clocks the encoder down until one frame takes ~1/rate. 60 → 120 halved
  encode time (1280×800: 16.8 → 8.6 ms). 240 gave nothing further.
- Removing `kVTDecodeFrame_1xRealTimePlayback` cut decode ~20%.
- Any color-tagging compression property (primaries, transfer, matrix) adds
  ~2.5 ms per 4K frame.
- `EnableLowLatencyRateControl` silently downgrades to 4:2:0. Don't use it.
- Parallel tile sessions (Apple's four-tile layout) gave no gain on M6.
- `displaySyncEnabled = false` on the windowed layer: decode → glass 25 → 7 ms.
  `ANYREMOTE_DISPLAY_SYNC=1` restores vsync for comparison.
- Sparse updates (e.g. typing) encode on a down-clocked engine: 800×600 takes
  ~10 ms instead of ~4.5 ms.

## Layout

```
App/                        AppKit + SwiftUI app
  AppDelegate               host service + viewer, menus, ⌃⌥⌘ commands
  HostsView / ViewerModel   window picker: My Macs / Nearby, grouped searchable grid, pairing
  StatusMenu                menu bar icon (sharing state, controller, pairing code), ⌃⌥⌘0 hot key
  FriendlyText              user-facing wording for wire/system errors
  AppLanguage               interface language (English default; Simplified Chinese in Settings › General)
  Resources/*.lproj         string tables; keys are the English source strings
  HostConnection            one connection: mirrors, child windows, cursor
  MirrorWindowController    mirror window: geometry, input mapping, resize, stats
  ChildWindowController     menus/popovers/sheets as local child windows
  RemoteSurfaceView         Metal surface + mouse/scroll; KeyForwarder
  RemoteMenuBar             host menu bar as native NSMenus
  HostSettingsView          sharing + controller, permission checklist, pairing code, display
  DevelopmentLaunch         test/measurement launch modes
Packages/AnyRemoteKit/
  AnyRemoteWire             messages, framing, pairing, AES-GCM channel, reassembly
  AnyRemoteNetwork          TCP control connection, UDP socket, Bonjour, storage
  AnyRemoteMedia            capture, encoder, decoder, Metal layer, stats, clocks
  AnyRemoteWindowControl    AX window geometry/focus, menu bar reader
  AnyRemoteHost             host service + sessions, input, cursor, virtual display
  AnyRemoteClient           viewer-side connection, paired-host store
  CGVirtualDisplayPrivate   private CGVirtualDisplay declarations
  AnyRemoteDiagnostics      synthetic workload window
  anyremote-bench           headless benchmark (loopback, --network, --host, --connect)
project.yml                 XcodeGen spec (AnyRemote.xcodeproj is generated)
```

## Build, run, test

```sh
xcodegen generate
open AnyRemote.xcodeproj            # signed build with your team (Developer ID for distribution)

swift test --package-path Packages/AnyRemoteKit     # 32 tests incl. VT round trips and a network session
swift build -c release --package-path Packages/AnyRemoteKit --product anyremote-bench
Packages/AnyRemoteKit/.build/release/anyremote-bench --network --synthetic 940x700 --seconds 6
```

The Debug configuration builds **AnyRemote Dev** (`com.localhost-copilot.anyremote.dev`),
so development builds never take over the installed app's privacy grants.

Distribution zip, and optionally install it here and restart it:

```sh
scripts/release.sh             # build/dist/AnyRemote-<version>.zip
scripts/release.sh --install   # also replace /Applications/AnyRemote.app
```

Screen Recording and Accessibility are keyed by the app's signature. An
ad-hoc signature changes with every build, so each update lost them. The
script signs with a stable local identity instead (`scripts/signing-identity.sh`
creates it once: a self-signed code-signing certificate in its own keychain
under `~/Library/Application Support/AnyRemoteSigning`, never committed), so
permissions survive updates on every Mac that installs the zip. Other Macs
need the zip from the Mac that holds that identity.

Granting them: Settings → *Turn On…* asks macOS for the permission, which
adds AnyRemote to the list switched off, then opens that list in System
Settings with a small card beside it (its icon drags into the list as a
fallback). It notices the switch and moves on. Accessibility also covers
posting events, so that row turns on without a relaunch. At launch, entries
left by an earlier signature, listed as on but without effect, are removed
once per signature (`tccutil reset`), so turning a permission on is always one
switch.

Development launch arguments (see `App/DevelopmentLaunch.swift`), all through
the real network path against this Mac's own host service:

- `--synthetic 940x700 [--resize-test] [--display-test]`
- `--input-test` — clicks, keys, wheel and a context menu into a recorder
  window; prints what arrived and whether the menu showed as a child window
- `--open <app> [--title <text>] [--menu-test [--choose Menu/Item]]`
- `--launch <app>` — opens the app on the host through the Apps list and
  prints when its window arrives
- `--connect host[:port] --code CODE` — another Mac
- `--permission-guide` — Settings with the permission card (kept up)
- `--discovery-test`, `--exit-after <seconds>`
- `ANYREMOTE_STATS_STDOUT=1` prints pipeline statistics every second,
  `ANYREMOTE_HOME=<dir>` uses a separate settings directory

Keep workloads visible when measuring: macOS throttles occluded windows, and
an occluded mirror is never presented.

When mirroring this Mac's own windows, focusing the host window activates
that app, so the mirror stops being key; that only affects this loopback.

## Limitations

- Trackpad gestures (pinch, rotate, swipe) are not forwarded; scrolling is.
- Keys are sent as virtual key codes: the host's input source decides the
  characters. Input-method composition happens on the host.
- Windows hidden behind others still stream (ScreenCaptureKit captures them),
  but macOS throttles occluded windows' rendering.
- Drag and drop between Macs is not implemented.
- Video is sent unpaced; on lossy Wi-Fi the bitrate controller backs off but
  there is no FEC.
- The virtual display sits right of the main display; on a Mac with a real
  monitor the pointer can wander onto it while a mirror is open.
