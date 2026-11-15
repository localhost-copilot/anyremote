# AnyRemote

Mac-to-Mac remote control where the unit of sharing is a **window**, not a
display. The viewer lists every window on the host, opens any of them as a
local window and resizes it freely; the host window is resized to match, so
frames are presented pixel-for-pixel, like a native window. Menus, popovers
and other child windows appear as local child windows, and the host app's
menu bar becomes the viewer's native menu bar. The host's whole desktop is
one click away too.

- **Windows, not screens** — each remote window is a real local window with
  its own Dock icon, ⌘Tab entry and menu bar.
- **Full desktop** — the whole screen, sized to your window (dynamic
  resolution) or scaled, with system shortcuts forwarded.
- **Low latency, sharp text** — HEVC 4:4:4, hardware encode and decode,
  Metal presentation on arrival; about 10 ms behind the host's own screen on
  a wired LAN.
- **Several viewers** — up to four Macs can view and control one Mac at
  once.
- **Encrypted, paired once** — a 100-bit pairing code and AES-256-GCM for
  everything; pairing works both ways.
- **Shared clipboard**, English or Simplified Chinese interface.

Latency and image quality target Apple's Screen Sharing high-performance
mode. Apple's protocol has no window-level mode, so AnyRemote uses its own
host agent and protocol for windows and the full desktop alike. Every
AnyRemote instance is both a host (others may control this Mac) and a
viewer.

## Install

Requires macOS 15 or later, Apple silicon or Intel.

1. Download `AnyRemote-<version>.zip` from
   [Releases](https://github.com/localhost-copilot/anyremote/releases) and
   unzip it into `/Applications`.
2. The app is signed with a self-signed certificate, not notarized, so
   macOS refuses to open the download. Clear the quarantine flag once:

   ```sh
   xattr -dr com.apple.quarantine /Applications/AnyRemote.app
   ```

3. Open AnyRemote on **every** Mac involved. If permissions are missing,
   Settings opens with a checklist: grant **Screen Recording** and
   **Accessibility**, and allow **Local Network** when asked. Updates keep
   the grants, since every release is signed with the same certificate.

## Getting started

1. On the Mac to be controlled, the menu bar icon shows its pairing code
   (`XXXXX-XXXXX-XXXXX-XXXXX`), whether it can be controlled and who is
   controlling it (each viewer with **Disconnect**).
2. On the controlling Mac, open the window picker (⌃⌥⌘0 from anywhere). It
   lists *My Macs* (paired) and *Nearby* (unpaired, found with Bonjour).
   Select a Mac and enter its code once. **Add by address** covers Macs on
   other networks; **Edit Address…** in a Mac's context menu changes it
   later (for instance when the other Mac is on another subnet and was
   added under its router's address).
3. Pairing works both ways: unless *Also let … control this Mac* is turned
   off, the Mac that entered the code hands its own code to the other over
   the encrypted connection, and appears there in *My Macs* (with a
   notification). A reset code follows on the next connection; turning
   *Let … Control This Mac* off in a Mac's context menu withdraws it.
4. Pick a window. Type to filter, arrows to select, Return or double-click
   to open.

## Using it

### Windows

The picker connects to the last used Mac, groups windows by app and stays
open behind a new window (the AnyRemote Dock icon or ⌃⌥⌘0 brings it back).
An already open window is brought forward instead of opened twice.

A mirror behaves like a local window. Dragging it moves only the mirror:
the host window stays where it is, so it never ends up partly off its
display. Its title bar buttons act on it: close closes the host window (a
save sheet appears as usual), minimize minimizes the mirror only, green
enters full screen on this Mac (the host window is resized to this screen)
and ⌥-green zooms. ⌘M and ⌃⌘F act on the mirror too. If the host window gets
minimized or goes full screen on the host, the host undoes it and the mirror
does it instead.

A window that appears on the host within 3 s of a click, key or menu command
in a mirror opens as a new mirror: a new document, a Settings window, or
another app's window such as Finder revealing a file. Windows that appear on
their own stay on the host and can be opened from the picker. Sheets are
captured with their parent window.

Each remote app with windows open here gets its own Dock icon and ⌘Tab entry,
like Parallels' Coherence mode: a small stand-in app (`DockProxy/`) named
"App (Mac)" with the app's icon. Clicking it brings that app's windows
forward, its Dock menu lists them, and Quit closes them on this Mac only
(Settings → General → *Show Remote Apps in the Dock*).

### Apps

**Apps** (next to **Windows** above the grid) lists the host's apps
(`/Applications`, `/System/Applications`, their Utilities, `~/Applications`
and anything running). Opening one launches it there, or brings it forward,
and its front window opens here; an app with no window gets a new one, as if
its Dock icon was clicked. *All | Running* narrows the list; a running app's
context menu has *Quit* and *Force Quit* (on the host).

### Full desktop

**Full Desktop** (toolbar, or ⌃⌥⌘D) shows the host's whole screen: the main
display, or another one from the button's menu. From a mirror, ⌃⌥⌘D opens
the display that window is on.

- **Fit Desktop to Window** (⌃⌥⌘R, on by default): the host's desktop takes
  the window's size — resize it, zoom it or make it full screen and the host
  rearranges for it, always 1:1 at 2x — and gets its own resolution back
  when the window closes. Turned off, the window keeps the display's aspect
  ratio and scales the picture (area-filtered, so text stays crisp).
- Every key goes to the host (⌘M and ⌃⌘F included), except ⌃⌥⌘ shortcuts.
  With **Send System Shortcuts to Desktop** (⌃⌥⌘K, on by default) so do
  ⌘Tab, ⌘Space, Mission Control and screenshots while the desktop window is
  in front.

Mirrors and desktops can be open at the same time.

### Several viewers

Up to four Macs can be connected to one Mac at once, and each can see and
control it. Viewers of the same display share one capture and one encode,
so a second viewer costs the host almost nothing. The first viewer leads:
its window size sets the dynamic resolution (the others see it scaled), and
the stream runs at the bit rate the slowest viewer's network allows. A fifth
viewer can only get in by taking over, which ends the longest-connected
session.

### Keyboard

While a mirror or desktop is in front, every key goes to the host (⌘Q quits
the *remote* app). AnyRemote's own commands use ⌃⌥⌘:

| Shortcut | Command |
|---|---|
| ⌃⌥⌘0 | Window picker |
| ⌃⌥⌘D | Full desktop |
| ⌃⌥⌘R | Fit desktop to window |
| ⌃⌥⌘K | Send system shortcuts to desktop |
| ⌃⌥⌘W | Close on this Mac (the host window stays open) |
| ⌃⌥⌘I | Statistics overlay |

Keys are sent as virtual key codes, so the host's keyboard layout and input
method apply.

### Clipboard, displays, language

- The clipboard is shared both ways while connected (Settings → General →
  *Share Clipboard*): text, rich text, HTML, images and links, up to 16 MB.
  Concealed or transient contents (password managers) and copied files stay
  on their Mac.
- Settings → *HiDPI virtual display*: on a headless Mac mini (or one with a
  1x monitor) shared windows move to a 1920×1200 pt virtual display rendered
  at 2x, so they are sharp and can be larger than the physical screen. They
  move back when the mirror closes.
- The interface is in English; Settings → General → Language switches to
  Simplified Chinese (or the system language) after a restart.

## Troubleshooting

- **Input doesn't work.** The host lacks Accessibility; mirrors and the
  picker say so until it is granted.
- **"Couldn't connect" across subnets.** Use **Add by address** or **Edit
  Address…** with the other Mac's own IP (port 47800 by default).
- **Connected but black.** The statistics overlay (⌃⌥⌘I) shows a line like
  `udp in 0 · … · host sends video to none`: the video's UDP does not get
  through (a firewall, or security software filtering local UDP), while the
  TCP control connection does.
- **"This Mac" is not in the list.** Controlling a Mac from itself feeds
  injected clicks back into the mirror; see Development for the loopback
  mode.

## Limitations

- Trackpad gestures (pinch, rotate, swipe) are not forwarded; scrolling is.
- Drag and drop between Macs is not implemented.
- Windows hidden behind others still stream, but macOS throttles occluded
  windows' rendering.
- On the host, macOS covers each shared window's close/minimize/zoom buttons
  with a purple sharing indicator. It is a system privacy indicator with no
  API to turn it off; the viewer sees the normal buttons.
- Full desktop: keys outside the window server's hot keys (Touch ID, the
  power key) still act on this Mac. Dynamic resolution rearranges the host's
  windows like any resolution change.
- Two viewers opening the same *window* each get their own capture, and
  resizing it from both fights; only desktops are shared.
- Video is sent unpaced; on lossy Wi-Fi the bitrate controller backs off but
  there is no FEC.
- The virtual display sits right of the main display; on a Mac with a real
  monitor the pointer can wander onto it while a mirror is open.

## How it works

```
host                                                viewer
SCK window or display capture (444f / BGRA+alpha)
 → VTCompressionSession HEVC RExt 4:4:4 or HEVC+alpha
   (desktops: four strips, one session each)
 → EncodedVideoFrame → fragments
 → AES-GCM datagram envelope ──── UDP ────→ replay check → VideoReassembler
   (one per viewer)                         → KeyframeGate → VTDecompressionSession
                                            → VideoFrameLayer (CAMetalLayer)
AX geometry / focus / menus  ←── TCP control (AES-GCM) ──  input, resize, focus,
CGEvent injection                                          menu picks, reports
cursor (CGSCurrentCursorSeed) ─────────────────────────→  local NSCursor
```

- **Control** — TCP (Network.framework, no-delay, keepalive,
  `interactiveVideo` service class), length-prefixed JSON messages
  (`ControlMessage`). Ordered and reliable: input, resize, menus, cursor.
- **Video** — a plain UDP socket (8 MB buffers, `SO_TRAFFIC_CLASS` video
  interactive). The viewer sends a sealed keepalive every 500 ms; the host
  learns the viewer's address from it (NAT-safe). Fragments are dropped,
  never retransmitted; the reassembler keeps only the newest frame, and an
  abandoned frame triggers a rate-limited keyframe request for that stream
  (for a desktop, that strip).
- **Strips** — a desktop goes out as four horizontal strips, like Apple
  Screen Sharing's tiles: one capture, a GPU blit of the strips
  ScreenCaptureKit reports as changed, one HEVC session and stream ID per
  strip. Typing costs a quarter of a full-screen encode. The viewer shows a
  host frame once all its strips are decoded (or after 10 ms), so a frame
  never shows half old.
- **Sessions** — each viewer has its own session and keys. A display
  stream is shared: one capture and encode, an audience of sessions, each
  sealing the same datagrams with its own key. Stream IDs are unique across
  sessions.
- **Clock sync** — ping/pong; the minimum-RTT sample gives the host↔viewer
  clock offset, so latency is measured across machines.
- **Bitrate** — receiver reports every second; ×0.75 on loss, +10% after
  four clean seconds; windows 6–80 Mbps, desktops up to 120 Mbps, child
  windows ≤20 Mbps. A shared stream runs at its viewers' lowest rate.
- **Input** — mouse, scroll and keys as `CGEvent`s posted at the HID tap, at
  points relative to the window's top-left (frozen during a press so
  title-bar drags work). Focus via AX `AXFrontmost` + `AXMain` + `AXRaise`.
- **Child windows** — every 33 ms (8 ms while a button is down) the host
  looks for same-process windows on menu/popup layers, or non-standard
  layer-0 windows near the main window (sheets, popovers). Each streams as
  HEVC with alpha and is shown as a borderless, non-activating child window.
- **Menu bar** — read through AX as a `MenuNode` tree, rebuilt as native
  `NSMenu`s while the mirror is key; choosing an item presses it on the host.
- **Dynamic resolution** — `desktopSize` asks for a desktop of the viewer
  window's size. The host makes a HiDPI `CGVirtualDisplay` of that size,
  puts it in the display's place, has the display mirror it (`.forSession`,
  so macOS undoes it if the app quits) and switches the capture over within
  the same stream. Requests are coalesced and clamped to 640×400–3840×2400
  pt.
- **System shortcuts** — while a desktop window is key, the viewer turns off
  the window server's global hot keys for its connection (private
  `CGSSetGlobalHotKeyOperatingMode`), so ⌘Tab and friends arrive as ordinary
  key events and are forwarded.

### Security

The pairing code is 100 bits (20 Crockford base32 characters). Both sides
derive a pre-shared key from it with HKDF-SHA256; each connection mixes in
two fresh 32-byte nonces to derive four AES-256-GCM keys (control and
datagram, each direction). Control frames use implicit counter nonces; video
datagrams carry an explicit counter (authenticated, 1024-entry replay
window). A wrong code fails at the first sealed frame. Resetting the code in
Settings disconnects every viewer. A code received through two-way pairing is
stored like one typed in; a withdrawal only removes Macs added that way.
Settings and saved hosts are JSON files (mode 0600) in
`~/Library/Application Support/AnyRemote`.

### Performance

Full desktop between two Macs (M4 Mac mini host, M6 viewer, wired LAN, RTT
~1 ms), 3840×2160, 60 fps, no loss: about 10 ms p50 behind the host showing
the frame on its own screen. Measurements, strip timings and the
VideoToolbox findings behind the encoder settings are in
[docs/performance.md](docs/performance.md).

## Development

```
App/                        AppKit + SwiftUI app
  AppDelegate               host service + viewer, menus, ⌃⌥⌘ commands
  HostsView / ViewerModel   window picker: My Macs / Nearby, grouped searchable grid, pairing
  StatusMenu                menu bar icon (sharing state, viewers, pairing code), ⌃⌥⌘0 hot key
  FriendlyText              user-facing wording for wire/system errors
  AppLanguage               interface language (English default; Simplified Chinese in Settings › General)
  Resources/*.lproj         string tables; keys are the English source strings
  HostConnection            one connection: mirrors, desktops, child windows, cursor
  DesktopWindowController   full desktop window: dynamic resolution, scaling, input mapping, stats
  DesktopPreferences        desktop options; system shortcut capture
  MirrorWindowController    mirror window: geometry, input mapping, resize, stats
  ChildWindowController     menus/popovers/sheets as local child windows
  RemoteSurfaceView         Metal surface + mouse/scroll; KeyForwarder
  RemoteMenuBar             host menu bar as native NSMenus
  HostSettingsView          sharing + viewers, permission checklist, pairing code, display
  DevelopmentLaunch         test/measurement launch modes
DockProxy/                  stand-in app behind each remote app's Dock icon
Packages/AnyRemoteKit/
  AnyRemoteWire             messages, framing, pairing, AES-GCM channel, reassembly
  AnyRemoteNetwork          TCP control connection, UDP socket, Bonjour, storage
  AnyRemoteMedia            capture, encoder (whole/strips), decoder, Metal layer, stats, clocks
  AnyRemoteWindowControl    AX window geometry/focus, menu bar reader
  AnyRemoteHost             host service + sessions, input, cursor, virtual display
  AnyRemoteClient           viewer-side connection, paired-host store
  CGVirtualDisplayPrivate   private CGVirtualDisplay declarations
  AnyRemoteDiagnostics      synthetic workload window
  anyremote-bench           headless benchmark (loopback, --network, --host, --connect, --tiles)
docs/performance.md         measurements and encoder findings
project.yml                 XcodeGen spec (AnyRemote.xcodeproj is generated, not committed)
scripts/                    release, signing identity, icons
```

### Build and test

```sh
xcodegen generate
open AnyRemote.xcodeproj            # or build from the command line:
xcodebuild -project AnyRemote.xcodeproj -scheme AnyRemote -configuration Debug \
    -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build

swift test --package-path Packages/AnyRemoteKit     # 48 tests incl. VT round trips and network sessions
swift build -c release --package-path Packages/AnyRemoteKit --product anyremote-bench
Packages/AnyRemoteKit/.build/release/anyremote-bench --network --synthetic 940x700 --seconds 6
Packages/AnyRemoteKit/.build/release/anyremote-bench --tiles [--strips 4]   # full frame vs strips
```

The Debug configuration builds **AnyRemote Dev**
(`com.localhost-copilot.anyremote.dev`, orange icon), so development builds
never take over the installed app's privacy grants. `scripts/make-icon.sh`
redraws both icons into `App/Assets.xcassets`.

### Releases

```sh
scripts/release.sh             # build/dist/AnyRemote-<version>.zip (universal)
scripts/release.sh --install   # also replace /Applications/AnyRemote.app and restart it
```

The version is `MARKETING_VERSION` in `project.yml`. Screen Recording and
Accessibility are keyed by the app's signature, and an ad-hoc signature
changes with every build. The script signs with a stable local identity
instead (`scripts/signing-identity.sh` creates it once: a self-signed
code-signing certificate in its own keychain under
`~/Library/Application Support/AnyRemoteSigning`, never committed), so
permissions survive updates. Releases must be built on the Mac that holds
that identity.

Granting permissions: Settings → *Turn On…* asks macOS, which adds AnyRemote
to the list switched off, then opens that list in System Settings with a
small card beside it. At launch, entries left by an earlier signature are
removed once per signature (`tccutil reset`), so turning a permission on is
always one switch.

### Development launch arguments

See `App/DevelopmentLaunch.swift`. All go through the real network path,
against this Mac's own host service unless `--connect` is given.

- `--connect host[:port] --code CODE` — another Mac
- `--synthetic 940x700 [--resize-test] [--display-test]`
- `--input-test` — clicks, keys, wheel and a context menu into a recorder
  window; prints what arrived and whether the menu showed as a child window
- `--open <app> [--title <text>] [--menu-test [--choose Menu/Item]]`
- `--launch <app>` / `--quit <app>` — through the Apps list
- `--desktop [--display <n>] [--fullscreen]` — the host's full desktop; checks
  that a pointer move lands on the matching display point.
  `--test-display WxH` shows a virtual display made for the test;
  `--desktop-size 1280x720,1600x1000,off` then resizes the window through
  those sizes and prints the display list after each. `--shortcut-test`
  posts ⌘Tab and ⌘Space and prints what was forwarded.
  `-DesktopFitsWindow NO` turns dynamic resolution off for one launch.
- `--permission-guide` — Settings with the permission card
- `--discovery-test`, `--exit-after <seconds>`

Environment:

- `ANYREMOTE_LOOPBACK=1` lists this Mac itself. The host then leaves the
  viewer's own windows out of a desktop (no endless mirror), and dynamic
  resolution only applies to test displays. `ANYREMOTE_NO_HOST_FOCUS=1` also
  stops the host from activating the mirrored app.
- `ANYREMOTE_STATS_STDOUT=1` prints pipeline statistics every second
  (`lead`: how far ahead of its display time SCK delivered a frame; `hold`:
  frame pacing; `capgap`/`pregap`: host and local frame intervals; `hitch`:
  frames shown a refresh late although sent on time).
- `ANYREMOTE_STATS=1` starts with the statistics overlay on.
- `ANYREMOTE_HOME=<dir>` uses a separate settings directory.
- `ANYREMOTE_DROP=0.02` drops that share of the video datagrams arriving at
  the viewer (simulated loss).
- `ANYREMOTE_TILES=1` on the host sends desktops as whole frames (2–8 sets the
  strip count).
- `ANYREMOTE_DISPLAY_SYNC=1` restores vsync on the windowed layer.
- `ANYREMOTE_PACING=1` holds frames until their host display time.

Keep workloads visible when measuring: macOS throttles occluded windows, and
an occluded mirror is never presented.
