# AnyRemote

Mac-to-Mac remote control where the unit of sharing is a **window**, not a
display. The viewer lists every window on the host, opens any of them as a
local window and resizes it freely; the host window is resized to match, so
frames are presented pixel-for-pixel, like a native window. Menus, popovers
and other child windows appear as local child windows, and the host app's
menu bar becomes the viewer's native menu bar. The host's whole desktop is
one click away too.

- **Windows, not screens** — each remote window is a real local window with
  its own Dock icon, ⌘Tab entry and menu bar; remote apps are in Spotlight
  and can be kept in the Dock.
- **Full desktop** — the whole screen, sized to your window (dynamic
  resolution) or scaled, with system shortcuts forwarded.
- **Low latency, sharp text** — HEVC 4:4:4, hardware encode and decode,
  Metal presentation on arrival; about 10 ms behind the host's own screen on
  a wired LAN.
- **Several viewers** — up to four Macs can view and control one Mac at
  once.
- **Encrypted, paired once** — a 100-bit pairing code and AES-256-GCM for
  everything; pairing works both ways.
- **Sound** — with a window open you hear that app, and only that app; with
  the full desktop, the whole Mac.
- **Microphone** — apps on the other Mac record from your microphone, as if
  it were theirs: calls, voice messages, dictation.
- **Drag and drop** — files, images and text between Macs, from a remote
  window, out of the full desktop, or from this Mac into the other.
- **Notifications and badges** — the other Mac's notifications appear here,
  and a click opens them there; remote apps' Dock icons carry their badges.
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
   **Accessibility**, and allow **Local Network** when asked. The first time
   another Mac listens, macOS asks to let AnyRemote record this Mac's
   audio (*System Audio Recording*); allow it for sound. Updates keep
   the grants, since every release is signed with the same certificate.
4. For the microphone, install the *AnyRemote Microphone* on the Macs to be
   controlled (Settings → Microphone → *Install…*, administrator password).
   The controlling Mac asks for *Microphone* access the first time an app
   on the other Mac records.

### Updates

From 0.26.0 on, AnyRemote updates itself. It checks its GitHub releases
shortly after launch and then daily, downloads a new version in the
background and offers **Install and Relaunch**; one put off with *Later*
installs when AnyRemote quits. Settings → Updates turns the checks off;
AnyRemote › *Check for Updates…* checks right away. An update is installed
only if it is signed with the same certificate as the running app, so
privacy permissions stay granted.

Macs connected to each other must run the same protocol. When the other Mac
runs an older AnyRemote, connecting to it offers **Update “…”**: that Mac
downloads and checks the release itself, relaunches, and this Mac
reconnects. A connected Mac with an older version on the same protocol can
be updated from its context menu in the sidebar. Macs on 0.25 or earlier
have to be updated by hand once.

## Getting started

1. On the Mac to be controlled, the menu bar panel shows whether it can be
   controlled and who is controlling it (each viewer with **Disconnect**);
   its ⋯ menu shows or copies the pairing code (`XXXXX-XXXXX-XXXXX-XXXXX`).
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

macOS's own prompts on the other Mac (a keychain or administrator password,
Touch ID, a privacy permission, an app downloaded from the internet) belong
to no opened window, and they often open on the virtual display nobody looks
at. AnyRemote brings them over the window in use and shows them with it, so
they can be answered from here; while one is open, clicks and typing in that
window leave the focus with the prompt.

### Menu bar

Clicking the menu bar icon opens a panel for the moments between remote
windows, without making AnyRemote the active app: the search field has
focus, so typing an app's name and pressing Return opens it on the chosen
Mac (the panel stays with a spinner until its window arrives). Before
anything is typed it lists the apps recently opened on that Mac, then the
ones running there; a search also finds windows. Paired Macs are tabs along the
top, each with its connection state (⌘1…⌘9 switch, + pairs another); the
chosen one is remembered and connected on opening, and each Mac keeps its
own recent apps. Buttons beside the search field open that Mac's full
desktop and the window picker. *Open on This Mac* lists remote windows shown here,
to bring one forward or close it here. The footer is this Mac as a host:
sharing on or off, who is controlling it with **Disconnect**, and a ⋯ menu
with the pairing code, Settings and Quit. A right click gives a short
classic menu.

A mirror behaves like a local window. Dragging it moves only the mirror:
the host window stays where it is, so it never ends up partly off its
display. Its title bar buttons act on it: close closes the host window (a
save sheet appears as usual), minimize minimizes the mirror only, green
enters full screen on this Mac (the host window is resized to this screen)
and ⌥-green zooms. ⌘M and ⌃⌘F act on the mirror too. If the host window gets
minimized on the host, the host undoes it and the mirror minimizes instead.
If the host app makes its window full screen itself (a web page's video in
Chrome, which ends when the window leaves full screen), it stays so and the
mirror follows it in and out; leaving full screen on the mirror takes the
host window out too. With the virtual display (below) the full-screen
window's Space is on that display only, so the host's own windows stay where
they are.

These are the mirror's own, native buttons, drawn where the host window has
its buttons: macOS covers a shared window's buttons with a purple sharing
indicator, also in the captured picture, so the host paints over the
indicator before encoding and the viewer shows real buttons there (symbols
on hover, the tiling menu on green, gray while inactive). In full screen
they appear when the pointer reaches them.

The connection stays out of sight while it's good. When frames arrive more
than 80 ms after the host shows them, or keep getting lost, a small
*Slow connection* / *Unstable connection* label fades in at the bottom of
the window until it recovers. The Remote menu always shows the host,
latency and frame rate of the key remote window.

A window that appears on the host within 3 s of a click, key or menu command
in a mirror opens as a new mirror: a new document, a Settings window, or
another app's window such as Finder revealing a file. Windows that appear on
their own stay on the host and can be opened from the picker. Sheets are
captured with their parent window.

Each remote app with windows open here gets its own Dock icon and ⌘Tab entry,
like Parallels' Coherence mode: a small stand-in app (`DockProxy/`) named
"App (Mac)" with the app's icon. Clicking it brings that app's windows
forward, its Dock menu lists them, and Quit closes them on this Mac only
(Settings → General → *Show Remote Apps in the Dock*). Its icon carries the
badge the app shows in the other Mac's Dock (unread mail, messages).

These stand-ins are real apps in `~/Applications/AnyRemote/<Mac>/`, kept
after their windows close, so a remote app you have used is an app like any
other here: type its name in Spotlight ("Xcode (Mac mini)"), find it in the
Apps launcher, or choose *Options › Keep in Dock* on its Dock icon. Opening
it starts AnyRemote if needed (without the window picker), connects to that
Mac, opens the app there and brings its windows here. Forgetting a Mac
removes its apps; turning *Show Remote Apps in the Dock* off removes all.

### Notifications

While connected, notifications that appear on the other Mac appear here too
(Settings → General → *Show Notifications from Other Macs*, on by default),
titled with the app and the Mac, "Mail (Mac mini)", with the app's icon.
Clicking one does what clicking it there would (opens the message, the
conversation) and brings that app's window here. The first one asks for
permission to show notifications; Settings says when it is turned off.

### The other Mac's menu bar items

The icons on the right of the other Mac's menu bar (a VPN, iStat Menus,
Amphetamine, its input menu) can be used from here, like Parallels brings
Windows' notification area over (Settings → General → *Show Other Macs’
Menu Bar Items*, off by default). While a Mac has windows open here, a
display icon for it sits in this Mac's menu bar; its menu lists that Mac's
items. Choosing one clicks it there: a menu it opens opens from the icon
here as a native menu, a popover or panel (iStat's graphs) appears below the
icon and closes when clicked outside, and a window it opens comes as a
mirror.

### Apps

**Apps** (next to **Windows** above the grid) lists the host's apps
(`/Applications`, `/System/Applications`, their Utilities, `~/Applications`
and anything running). Opening one launches it there, or brings it forward,
and its windows open here, the front one in front, as clicking its Dock icon
brings them all forward (minimized ones and those on another Space stay
there); an app with no window gets a new one, as if its Dock icon was
clicked. A window picked under **Windows** opens alone. The list is grouped: *Recent* (opened from this
Mac lately, newest first), then the others *Running*, then *Not Running*;
the arrow keys move between groups by column. A running app's context menu
has *Quit* and *Force Quit* (on the host).

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
| ⌃⌥⌘I | Statistics panel on every remote window and desktop (also in **Video Quality**) |

**Trackpad**: scrolling (with momentum), pinch to zoom, rotate, smart zoom
(double-tap with two fingers) and two-finger swipes between pages act on the
remote app as they would there.

Keys are sent as virtual key codes, so the host's keyboard layout applies.

**Input methods** (Pinyin, WeChat, Sogou, Kotoeri…) are this Mac's by
default (Settings › Typing › Input Method): switch
them here as usual (menu bar, 🌐, ⌃Space — also while a desktop captures
system shortcuts), compose here, and the host gets the text. The candidates
show next to the host's caret, in any window. Keys the input method passes
through unchanged (letters in its English mode, Return, arrows outside a
composition, every ⌘-shortcut) still go as key codes. While a viewer types,
the host is switched to a plain keyboard layout, and gets its own input
source back when the viewer leaves.

With **The Other Mac's** input method, keys go to the host as key codes
and its own input method composes, inline in the app, with its own
candidate window (streamed next to the window, whichever input method it
is). While a remote window is in front, this Mac's input methods stay out
of the way (only keyboard layouts are allowed here, as in a password field),
and ⌃Space / ⌃⌥Space switch the other Mac's input source instead of this
Mac's.

### Sound

The host's sound plays on the viewer (Settings → Sound → *Play Sound from
Other Macs*, on by default). With windows open you hear their apps and
nothing else: sound has no window in macOS, so a window's sound is its
app's, including what the app plays through helper processes (a browser's
tabs, WebKit views). With a full desktop open you hear everything except
AnyRemote itself. *Mute This Mac While Its Sound Plays Elsewhere* (on the
host) silences the shared apps there meanwhile. Sound is about 35–45 ms
behind the host on loopback, close enough to the picture for lip sync.

### Microphone

Apps on the host can record from the viewer's microphone (Settings →
Microphone → *Use This Mac's Microphone on Other Macs*, on by default). The
host needs the *AnyRemote Microphone*, a small audio driver installed from
its Settings (it needs an administrator password, and the Mac's sound
pauses for a moment while Core Audio restarts). While a viewer is
connected, the AnyRemote Microphone is the host's default input, so apps
use it without being told; the previous input comes back afterwards. The
viewer's microphone is open only while an app on the host actually records,
so its recording indicator means what it says. With several viewers, the
one that clicked or typed last is heard. The sound reaches the recording
app about 45 ms after it was spoken (loopback).

### Drag and drop

Drag as you would on one Mac:

- **Out of a remote window** — start a drag in the app (a file in Finder, a
  photo, selected text) and drop it on this Mac: on Finder, the Desktop or
  any app. Files arrive as copies; Finder shows their progress.
- **Out of the full desktop** — the drag stays on the other Mac while the
  pointer is over its screen, and comes to this Mac at the window's edge.
- **Into the other Mac** — drag files, images or text from this Mac onto a
  remote window or the full desktop and drop it on the app there.
- Between two windows of the same Mac, the drag happens on that Mac (moving
  a file between its folders moves it).

Small drags (64 MB or less) are copied while the pointer is still moving,
so apps that only take finished files get them at once; larger ones are
copied after the drop. Folders keep their contents, links and attributes.
A drag that is cancelled, or dropped where nothing takes it, leaves
nothing behind.

### Clipboard, displays, language

- The clipboard is shared both ways while connected (Settings → General →
  *Share Clipboard*): text, rich text, HTML, images and links, up to 64 MB
  each. Short text arrives at once; anything larger crosses only when
  something pastes it, so copying a large image never slows clicks and
  typing. Concealed or transient contents (password managers) and copied
  files stay on their Mac.
- Settings → *Match the Other Mac's Screens* (on by default): while a
  viewer is connected, the windows it
  opens move to virtual displays rendered at 2x, one per viewer screen its
  windows are on, that screen's size. They are sharp even on a headless Mac
  mini, can be as large as the screen their mirror is on, and go full screen
  in a Space of their display only, so the host's own windows (and the
  viewer's windows on its other screens) stay put. A mirror moved to another
  screen takes its host window to that screen's display when focused. The
  displays touch the host's screens only at a corner, chained one after
  another, and the host's own pointer is turned back from them; when macOS
  rearranges displays (one plugged in, waking) they are put back. A display
  is made when a window first needs it and they all go away when the viewer
  disconnects, after the windows left full screen and moved back. macOS
  first mirrors a new display with the host's screen, so the host's windows
  shift for about a second each time one appears. Turned off, the windows
  stay on the host's screens, no larger than them. A viewer that doesn't
  tell its screens (0.22.2) gets one 1920×1200 display.
- The interface is in English; Settings → General → Language switches to
  Simplified Chinese (or the system language) after a restart.

## Troubleshooting

- **Input doesn't work.** The host lacks Accessibility; mirrors and the
  picker say so until it is granted.
- **"Couldn't connect" across subnets.** Use **Add by address** or **Edit
  Address…** with the other Mac's own IP (port 47800 by default).
- **Connected but black.** The statistics panel (⌃⌥⌘I) shows *Video: Not
  arriving* (`ANYREMOTE_STATS_STDOUT=1` prints `udp in 0 · … · host sends
  video to none`): the video's UDP does not get through (a firewall, or security software filtering local UDP), while the
  TCP control connection does.
- **"This Mac" is not in the list.** Controlling a Mac from itself feeds
  injected clicks back into the mirror; see Development for the loopback
  mode.

## Limitations

- Trackpad gestures reach the remote app's frontmost window (as on the
  Mac itself, where they go to the active app): a pinch on a background
  mirror brings its app forward on the other Mac first. Three- and
  four-finger swipes (Mission Control, Spaces) and Force Touch stay on this
  Mac.
- Dragged items are copied, never moved, between Macs. Apps that offer a
  drag only to their own windows (a drag that never appears on the system
  drag pasteboard) cannot drag out.
- Windows hidden behind others still stream, but macOS throttles occluded
  windows' rendering.
- On the host, macOS covers each shared window's close/minimize/zoom buttons
  with a purple sharing indicator. It is a system privacy indicator with no
  API to turn it off. The viewer shows its own buttons in its place (see
  above); a viewer older than 0.14 shows an empty spot there.
- Input methods: text being composed is drawn by the viewer over the
  host's caret, in the host text's font and on its baseline, not inside the
  host's text field, so text after the caret is covered rather than pushed
  aside. Apps that don't report their caret through Accessibility get the
  candidates at the last click.
  Composed text arrives as typed characters, so an app that reads key codes
  only (some games) sees no keys for it.
- Full desktop: keys outside the window server's hot keys (Touch ID, the
  power key) still act on this Mac. Dynamic resolution rearranges the host's
  windows like any resolution change.
- The microphone has no echo cancellation of its own: with speakers rather
  than headphones, the host's sound playing here reaches the microphone,
  and only the recording app's own echo cancellation (meeting apps have
  one) removes it.
- Sound is per app, not per window: two windows of one app (or two browser
  tabs) share their sound, and an open window plays its app's sound even
  from its other windows.
- Notifications arrive only as the host shows them as banners: none while
  a Focus is on there or for apps whose notifications are off or set to
  *None*, and only while connected. Notification Center's buttons (*Reply*,
  *Mark as Read*) aren't offered here; a click opens the notification.
  Badges show while the app has windows open here (that's when it has a
  Dock icon).
- Menu bar items are listed by their app's icon and name: macOS draws the
  menu bar itself, so an item's own picture can't be captured, and items an
  app doesn't make clickable through Accessibility (Control Center's) are
  missing.
- Two viewers opening the same *window* each get their own capture, and
  resizing it from both fights; only desktops are shared.
- Video is sent unpaced; on lossy Wi-Fi the bitrate controller backs off but
  there is no FEC.
- While a window opened from the viewer is full screen on a virtual
  display, the viewer's other windows on that display (the same viewer
  screen) are on another Space, so their mirrors keep their last picture.

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
Core Audio process taps → AAC-ELD ─────── UDP ────→  jitter buffer → AVAudioEngine
AnyRemote Microphone ← feed ← jitter buffer ←── UDP ── AAC-ELD ← microphone I/O proc
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
- **Sound** — while the viewer asks for it (`audio(enabled:)`) and shows
  something, the host taps the scope's processes with Core Audio process
  taps: one private tap per audio process whose PID, or responsible process
  (`responsibility_get_pid_responsible_for_pid`), belongs to an open
  window's app, or one global tap excluding AnyRemote for a desktop. The
  taps feed a private aggregate device whose tap list follows processes as
  they come and go (a tap's own process list can't be changed). Its input
  is mixed, resampled to 48 kHz and encoded as AAC-ELD stereo, 480 frames
  (10 ms) per packet at 128 kbit/s; each `AudioPacket` datagram also carries
  the previous packet, so a single loss is filled in. The viewer decodes
  into an adaptive jitter buffer (30 ms to start, 20–200 ms) played by an
  `AVAudioSourceNode`.
- **Microphone** — the AnyRemote Microphone (`MicrophoneDriver/`, a Core
  Audio server plug-in) publishes an input device and a hidden output device,
  the feed, on one clock and one ring buffer: what the feed is given for
  sample time T is what the microphone returns for T; frames the feed never
  got read as silence. (A process tap exposed as an aggregate device would
  need no driver, but coreaudiod then refuses every recording app without
  *System Audio Recording*, which ordinary apps never ask for.) While a
  viewer offers its microphone (`microphone(enabled:)`), the host makes it
  the default input and watches `kAudioDevicePropertyDeviceIsRunningSomewhere`;
  when an app starts recording it sends `microphoneWanted(true)` to the
  offering viewer that sent input last. That viewer opens its default input
  with an I/O proc (240 frames; AVAudioEngine taps deliver 100 ms at a time),
  announces `microphoneStream(format)` and sends the same AAC-ELD packets as
  sound, as datagram kind 4. The host decodes into a jitter buffer that its
  own I/O proc plays into the feed. When the recording stops, the viewer
  closes its microphone 1.5 s later (an app that starts again at once keeps
  it).
- **Clock sync** — ping/pong; the minimum-RTT sample gives the host↔viewer
  clock offset, so latency is measured across machines. Six seconds
  without a pong ends the connection; list requests time out on their own
  (10 s, then the Apps list asks once more).
- **Lists and their images** — `windowList` and `applicationList` carry
  names and state only, so a list never holds up input and pings on the
  control connection (all apps' icons came to about 5.6 MB of Base64 in
  one message, enough to miss the pong deadline). The viewer then fetches
  images over the transfer connection (`transfer(.images)`): its windows'
  thumbnails on every refresh, their apps' icons once, and an app's icon
  when its tile first appears. Each image is one binary chunk within a
  1 MB credit window, and the viewer keeps icons for the connection.
- **Clipboard** — one `SharedClipboard` per process, which every
  connection sharing it joins: it polls the pasteboard (on a queue of its
  own, every 0.5 s), reads a copy once and offers it to all of them as
  `pasteboardOffer`: text up to 64 KB inline, every other type by name and
  SHA-256. The receiver writes the inline types and promises the rest; when
  an app pastes one, macOS asks for it on the main thread, which fetches it
  over the transfer connection (`transfer(.pasteboard)`, 256 KB chunks
  within a 4 MB credit window, 15 s at most) and checks the digest. What
  arrives from one Mac is offered on to the others and served from the
  first. Contents equal to the current ones (inline data and digests) are
  not a new copy, which stops a write coming back through Universal
  Clipboard or a viewer of the same Mac; an offer's `origin` and `copy`
  stop one going around a ring of connections.
- **Bitrate** — receiver reports every second; ×0.75 on loss, +10% after
  four clean seconds; windows 6–80 Mbps, desktops up to 120 Mbps, child
  windows ≤20 Mbps. A shared stream runs at its viewers' lowest rate.
  **Video Quality** (the picker's toolbar, or a Mac's context menu) caps
  each stream from that Mac, 6–120 Mbps, for slow or metered networks; it
  is stored per paired Mac and applies to open windows at once.
- **Frame rate** — 60 fps unless the viewer asks for more (**Video
  Quality** › Frame Rate: 60, 90, 120 or 144 Hz, stored per paired Mac;
  `ControlMessage.frameRate`). The host's virtual displays (remote windows,
  and the desktop's dynamic-resolution stand-in) refresh at that rate and
  captures follow it, open ones included. A desktop shown at its own
  resolution stays at its physical screen's refresh rate.
- **Input** — mouse, scroll and keys as `CGEvent`s posted at the HID tap, at
  points relative to the window's top-left (frozen during a press so
  title-bar drags work). Focus via AX `AXFrontmost` + `AXMain` + `AXRaise`.
- **Text input** — while the viewer's input source is an input method, its
  keys go to the surface view's `NSTextInputContext` (`TextComposer`):
  committed text travels as `InputEvent.text` and is posted with
  `CGEventKeyboardSetUnicodeString` (≤20 UTF-16 units per event, split
  between characters); keys the input method passes through or turns into
  commands go as key codes. The host keeps a plain keyboard layout selected
  meanwhile and reports the focused element's caret as `caret`, for half a
  second after each key or click (the app may still be opening a field). The
  caret comes from the bounds of the characters beside it
  (`AXBoundsForRange`; an empty range is a line too high in Cocoa text),
  spans a selection that typing replaces, and carries the text's font
  (`AXFont`); `AXManualAccessibility` wakes Chromium's tree. The viewer draws
  the composition there in that font, on the host's baseline, with the
  candidates below.
- Small windows of the app that hold its focused text field (Finder's
  rename field) stream as child windows; other small ones (indicators) don't.
- With the host's input method (`TextInputSettings.composesOnViewer`
  false), the viewer forwards every key. Its surface's input context allows
  only Roman keyboard layouts (`allowedInputSourceLocales`), so AppKit
  selects one while a remote window is key and restores the user's source
  afterwards, and the symbolic hot keys 60/61 (select previous/next input
  source) are turned off meanwhile (`CGSSetSymbolicHotKeyEnabled`; it is
  system-wide, so it is undone on resign, quit and at the next launch), so
  ⌃Space reaches the host, whose window server switches its source. Windows
  of input method processes (anything run from an `Input Methods` folder,
  where macOS loads every input method from) near a streamed window stream
  as its child windows, and so does TextInputUI's input source indicator.
- **Child windows** — every 33 ms (8 ms while a button is down) the host
  looks for same-process windows on menu/popup layers, or non-standard
  layer-0 windows near the main window (sheets, popovers). Each streams as
  HEVC with alpha and is shown as a borderless, non-activating child window.
  Their glass blurs what lies behind them, and a window captured alone comes
  out flat gray, so they are captured from the display together with the
  windows beneath them, cropped to their frame. Their rounded shape is cut
  back out with a mask from one capture of the display with every other
  window excluded (capturing a menu or sheet alone brings its parent along).
  The Accessibility queries this polls run off the host's queue, one queue
  per app, so a busy app can't stall the sessions.
- **Menu bar** — read through AX as a `MenuNode` tree, rebuilt as native
  `NSMenu`s while the mirror is key; choosing an item presses it on the host.
- **Dynamic resolution** — `desktopSize` asks for a desktop of the viewer
  window's size. The host makes a HiDPI `CGVirtualDisplay` of that size,
  puts it in the display's place, has the display mirror it (`.forSession`,
  so macOS undoes it if the app quits) and switches the capture over within
  the same stream. Requests are coalesced and clamped to 640×400–3840×2400
  pt.
- **Drag and drop** — the drag a person sees is always this Mac's own
  `NSDraggingSession`; the host mirrors it invisibly. *Host to viewer:*
  during an injected left press the host polls the drag pasteboard
  (`NSPasteboard(name: .drag)`, change count every 20 ms). A new drag there
  is described as a `DragManifest` (names, types, sizes, icons; small
  inline data such as text and images) and sent as `hostDragBegan`; on the
  next mouse drag the viewer begins a native drag of `NSFilePromiseProvider`
  items (plus a file URL for items copied ahead, and the inline types). A
  mirror window hands over at once, a desktop only once the pointer leaves
  the video. *Viewer to host:* a drag entering a remote surface sends
  `drag(.offer)` and `drag(.over)`; the host starts its own drag of
  promises from an invisible non-activating panel (`.popUpMenu` level:
  drags look through windows at screen saver level) with an injected press,
  and moves it with injected drags, raising the window under the pointer.
  Only `drag(.drop)` releases it there. Whenever the drag is elsewhere, the
  host's drag waits over a small parking panel that refuses drops; there it
  is cancelled with Escape, or, when the viewer took promises, the panel
  takes the drop so the promised files can be received
  (`NSFilePromiseReceiver` works only inside `performDragOperation`).
  Items are named by (drag, item) IDs, never paths. They travel over a
  second sealed TCP connection to the same port (`transfer(.attach)` with a
  per-session token), as `ditto -c` archives in 256 KB chunks with an 8 MB
  credit window, unpacked by `ditto -x` into a staging folder on the
  destination volume and moved into place. A Swift 6 note:
  `NSFilePromiseProviderDelegate` and `NSPasteboardWriting` methods of a
  provider subclass must be `nonisolated`; inferred `@MainActor` isolation
  makes AppKit skip them, and the receiver fails with error 256.
- **Notifications and badges** — macOS has no API for another app's
  notifications, so the host reads what Notification Center shows through
  Accessibility, on its own queue, only while a viewer subscribed
  (`notices`). Each banner is an element of subrole
  `AXNotificationCenterBanner` with a UUID identifier, `title`, `subtitle`
  and `body` texts, and a description that starts with the app's name
  (macOS 27). Banners are polled twice a second; ones on screen when
  watching starts are skipped, AnyRemote's own (a viewer's copies, when a
  Mac controls itself) and macOS's "may this app notify" questions are left
  out. A new one goes out as `hostNotification`, with the app's icon the
  first time per session; the viewer posts it with `UNUserNotificationCenter`.
  A click sends `openNotification`: the host notes the windows on screen
  (as for launching an app, so a window the click opens comes to the
  viewer), presses the banner if it is still shown and activates the app.
  Badges are the Dock items' `AXStatusLabel`, polled every 2 s and sent as
  the whole list (`badges`) when it changes; the viewer gives each Dock
  stand-in its app's badge.
- **Trackpad gestures** — the viewer forwards AppKit's magnify, rotate and
  smartMagnify events (`InputEvent.gesture`). There is no public API to
  make them, so the host posts what the window server's trackpad driver
  posts: CGEvents of type 29 whose private fields hold the IOHIDEventType
  (110: 8 zoom, 5 rotation, 22 smart zoom, 6 scroll), the amount (113 zoom,
  114 rotation; they share storage, so set one) and a CGScrollPhase (132).
  They go to the frontmost app, so a gesture's first event focuses the
  window like a key. Every trackpad scroll with a phase is preceded by a
  scroll gesture event (118/119 deltas): swipe tracking
  (`trackSwipeEvent`, two-finger swipes between pages) follows those and
  stands still without them.
- **Menu bar items** — the right side of the menu bar is each app's
  `AXExtrasMenuBar`; the host lists the pressable items on a display's top
  edge (`listStatusItems`) on a queue of its own, since a press waits for
  an app that opens a menu (until a 0.25 s messaging timeout). On
  `openStatusItem` it presses the item: an `AXMenu` that opened is read
  like the app menus and sent as `statusItemMenu`, and the viewer's choice
  (`performStatusItemMenu`) is performed or the menu cancelled. Otherwise a
  new window of that app within 1.2 s is streamed as a `popup` stream (with
  alpha and the glass backdrop, input relative to its own corner) when it
  isn't at the normal level, or opened as a mirror when it is. Closing the
  popup on the viewer presses the item again, which is how popovers close.
  The viewer shows the menu by giving it to its status item and clicking
  it, so it opens from the icon. In loopback the host's real menu and the
  viewer's copy compete for the one menu tracking session; use
  `--status-menu-demo` there.
- **System shortcuts** — while a desktop window is key, the viewer turns off
  the window server's global hot keys for its connection (private
  `CGSSetGlobalHotKeyOperatingMode`), so ⌘Tab and friends arrive as ordinary
  key events and are forwarded.

### Security

The pairing code is 100 bits (20 Crockford base32 characters). Both sides
derive a pre-shared key from it with HKDF-SHA256; each connection mixes in
two fresh 32-byte nonces to derive four AES-256-GCM keys (control and
datagram, each direction). Control frames use implicit counter nonces;
datagrams (video, sound and microphone) carry an explicit counter (authenticated, 1024-entry replay
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
  StatusMenu / StatusPanel  menu bar icon and panel: open apps on a Mac, open windows, sharing state; ⌃⌥⌘0 hot key
  RecentApplications        apps recently opened on each host, for the panel
  FriendlyText              user-facing wording for wire/system errors
  AppLanguage               interface language (English default; Simplified Chinese in Settings › General)
  Resources/*.lproj         string tables; keys are the English source strings
  HostConnection            one connection: mirrors, desktops, child windows, cursor
  DesktopWindowController   full desktop window: dynamic resolution, scaling, input mapping, stats
  DesktopPreferences        desktop options; system shortcut capture; statistics switch
  StatisticsHUD             statistics panel drawn into the video: latency breakdown, bitrate, loss, graph
  VideoQualityView          per-Mac video bitrate cap, statistics switch
  MirrorWindowController    mirror window: geometry, input mapping, resize, stats
  ChildWindowController     menus/popovers/sheets as local child windows
  RemoteSurfaceView         Metal surface + mouse/scroll; KeyForwarder
  RemoteTextInput           this Mac's input method for the host: composer, composition panel, ⌃Space
  RemoteMenuBar             host menu bar as native NSMenus
  HostSettingsView          sharing + viewers, permission checklist, pairing code, display, sound, microphone
  SoundSharing              the viewer's "Play Sound from Other Macs" setting
  MicrophoneSharing         the viewer's microphone setting; notice when macOS denies it
  MicrophoneDriverInstaller installs/updates/removes the AnyRemote Microphone (administrator prompt)
  SoftwareUpdate            checks, downloads and installs releases; updates this Mac for a paired Mac
  UpdateView                Software Update window
  DevelopmentLaunch         test/measurement launch modes
DockProxy/                  stand-in app behind each remote app's Dock icon
MicrophoneDriver/           AnyRemote Microphone: Core Audio server plug-in (C), bundled in the app
Packages/AnyRemoteKit/
  AnyRemoteWire             messages, framing, pairing, AES-GCM channel, reassembly
  AnyRemoteNetwork          TCP control connection, UDP socket, Bonjour, storage
  AnyRemoteMedia            capture, encoder (whole/strips), decoder, Metal layer, stats, clocks;
                            AAC-ELD codec, sound sender/receiver, jitter buffer, microphone capture
  AnyRemoteWindowControl    AX window geometry/focus, menu bar reader, text caret
  AnyRemoteHost             host service + sessions, input, cursor, virtual display, process audio taps,
                            keyboard layout while a viewer types, the viewers' microphone
  AnyRemoteClient           viewer-side connection and microphone, paired-host store, update requests
  AnyRemoteUpdate           release manifest, download, checksum and signature checks, install script
  CGVirtualDisplayPrivate   private CGVirtualDisplay declarations
  AnyRemoteDiagnostics      synthetic workload window
  anyremote-bench           headless benchmark (loopback, --network, --host, --connect, --tiles, --microphone)
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

swift test --package-path Packages/AnyRemoteKit     # 115 tests incl. VT and AAC-ELD round trips and network sessions
swift build -c release --package-path Packages/AnyRemoteKit --product anyremote-bench
Packages/AnyRemoteKit/.build/release/anyremote-bench --network --synthetic 940x700 --seconds 6
Packages/AnyRemoteKit/.build/release/anyremote-bench --tiles [--strips 4]   # full frame vs strips
Packages/AnyRemoteKit/.build/release/anyremote-bench --windows 6 --busy 1    # several windows at once
Packages/AnyRemoteKit/.build/release/anyremote-bench --microphone            # microphone delay (needs the driver)
Packages/AnyRemoteKit/.build/release/anyremote-bench --refresh-test 60,120,144  # fps a virtual display delivers per rate
Packages/AnyRemoteKit/.build/release/anyremote-bench --drag-test offer --file <path> --from x,y --to x,y
```

`--drag-test offer|take|take-cancel|within` plays the viewer's half of a
drag against an in-process host on this Mac (see `DragBench.swift`). It
moves this Mac's pointer and drops for real: use scratch windows as sources
and targets.

The driver is built by the `AnyRemoteMicrophone` target into the app's
Resources. Settings offers to update an installed driver when its
`CURRENT_PROJECT_VERSION` (in `project.yml`) differs, so bump that with
every driver change. To try a driver build without Settings:
`sudo ditto "<app>/Contents/Resources/AnyRemote Microphone.driver"
"/Library/Audio/Plug-Ins/HAL/AnyRemote Microphone.driver" && sudo killall coreaudiod`.

The Debug configuration builds **AnyRemote Dev**
(`com.localhost-copilot.anyremote.dev`, orange icon), so development builds
never take over the installed app's privacy grants. `scripts/make-icon.sh`
redraws both icons into `App/Assets.xcassets`.

### Releases

```sh
scripts/release.sh             # build/dist/AnyRemote-<version>.zip (universal)
scripts/release.sh --install   # also replace /Applications/AnyRemote.app and restart it
scripts/publish-release.sh     # tag v<version> and push it: GitHub Actions publishes the release
```

Releases are built by GitHub Actions. `.github/workflows/ci.yml` tests and
builds every push and pull request on the `xcode-27` runner.
`publish-release.sh` checks the release (notes present, clean tree, commit
on `origin/main`, new tag) and pushes the tag; `.github/workflows/release.yml`
then waits for approval in the `release` environment (deployments from `v*`
tags only, a required reviewer), the only place holding the signing
identity (`SIGNING_P12`, `SIGNING_P12_PASSWORD`; put there by
`scripts/upload-signing-secrets.sh`). It imports the identity into a
keychain of its own, tests, builds with `scripts/release-assets.sh`, attests
the zip's build provenance (`gh attestation verify <zip> -R
localhost-copilot/anyremote`) and creates the release. `publish-release.sh
--local` does the same on the Mac holding the identity.

Every release needs `docs/releases/<version>.md` (the release page) and
`docs/releases/<version>.json` (the few lines the update window shows, by
language: `{"en": […], "zh-Hans": […]}`). It carries the zip and
`AnyRemote-update.json` (version, protocol, minimum macOS, zip URL, size,
SHA-256, notes). The app reads the latest one from
`https://github.com/localhost-copilot/anyremote/releases/latest/download/AnyRemote-update.json`,
which isn't the GitHub API and so has no rate limit. `release.sh` refuses a
signature that doesn't match `scripts/designated-requirement.txt`, since
installed copies would refuse it as an update.

The app installs a download only after checking its size and SHA-256, its
bundle identifier and version, and that its signature (every architecture
and nested helper) satisfies the running app's designated requirement:
`identifier … and certificate leaf = H"…"`, which only the release Mac's
identity can meet. Ad-hoc signed development builds have no such
requirement and don't update. A small script replaces the bundle after the
app quits and opens the new one.

To try an update without publishing, build two Debug copies with
`MARKETING_VERSION=<old|new> ENABLE_DEBUG_DYLIB=NO` (a separate debug dylib
fails library validation once re-signed), sign both like `release.sh`
does, serve the new one's zip and a manifest from 127.0.0.1 and start the
old one with `ANYREMOTE_HOME` and `ANYREMOTE_UPDATE_FEED`.

The version is `MARKETING_VERSION` in `project.yml`. Screen Recording and
Accessibility are keyed by the app's signature, and an ad-hoc signature
changes with every build. The script signs with a stable local identity
instead (`scripts/signing-identity.sh` creates it once: a self-signed
code-signing certificate in its own keychain under
`~/Library/Application Support/AnyRemoteSigning`, never committed), so
permissions survive updates. Only that identity can build releases: the one
on the Mac that created it, and its copy in the `release` environment.

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
- `--video-quality` — the Video Quality popover's content in a window, for
  a screenshot
- `--frame-rates 144,60,120` — asks for the first frame rate before
  anything opens, then the next every 8 s (with `ANYREMOTE_STATS_STDOUT=1`
  the fps shows what arrives)
- `--input-test` — clicks, keys, wheel and a context menu into a recorder
  window; prints what arrived and whether the menu showed as a child window
- `--open <app> [--title <text>] [--menu-test [--choose Menu/Item]]`
- `--open <app> --caret-test x,y [--rename]` — clicks at that window point
  (or `none`), then composes `nihao` through this Mac's input method and
  prints the caret, font and composition panel; `--rename` waits for a Finder
  rename started from outside (`--open Finder --title <folder>`).
- `--open <app> --host-ime-test x,y -ComposesOnThisMac NO` — clicks at that
  window point, types `nihao` for the host's input method, prints the child
  windows that came back (its candidates), then Space, Shift and `as`.
- `--open <app> --text-test` — clicks into the window, sends composed text
  (CJK, more than 20 units, an emoji) and prints the carets the host reports.
  Use a throwaway text app: it types into the window.
- `--open <app> --fullscreen` — makes the mirror full screen after a second
  (prints whether it is). In loopback the host window, resized to this
  screen, ends it again; use two Macs.
- `--launch <app>` / `--quit <app>` — through the Apps list
- `--desktop [--display <n>] [--fullscreen]` — the host's full desktop; checks
  that a pointer move lands on the matching display point.
  `--test-display WxH` shows a virtual display made for the test;
  `--desktop-size 1280x720,1600x1000,off` then resizes the window through
  those sizes and prints the display list after each. `--shortcut-test`
  posts ⌘Tab and ⌘Space and prints what was forwarded. `--ime-test` types
  `nihao`, `,`, Return and ← through this Mac's input method in both of its
  modes and ⌃Space, and prints what would go to the host; `--ime-hold`
  leaves `nihao` composing for a screenshot.
  `-DesktopFitsWindow NO` turns dynamic resolution off for one launch.
- `--permission-guide` — Settings with the permission card
- `--settings` — opens Settings
- `--status-panel` — opens the menu bar panel and prints its frame for `screencapture -R`
- `--open <app> --gesture-test` — hands the mirror pinch, rotate and smart
  zoom events made as the window server makes them; the host app gets them
  (use a scratch app that logs `magnify(with:)`)
- A stand-in opened outside AnyRemote (no `-AnyRemoteLaunched`) starts the
  app found by its `AnyRemoteParentBundleID` with `-AnyRemoteOpenedForApp YES`
  and posts `open` until answered.
- `--open <app> --status-items-test <menu app> [<popup app>]` — lists the
  host's menu bar items (with timing), opens one app's menu and prints it,
  then another's popover and closes it from here after a few seconds
- `--open <app> --status-menu-demo` — shows a sample remote menu from the
  Mac's menu bar icon here and logs the choice
- `--notification-test` — posts a notification on this Mac (from Script
  Editor) and prints what the viewer receives, and the Dock badges
- `--connect <address> --code <code> --update-host` — asks that Mac to
  update itself, waits for it to come back and prints its version
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
- `ANYREMOTE_STATS=1` starts with the statistics panel on (the switch then can't turn it off).
- `ANYREMOTE_HOME=<dir>` uses a separate settings directory.
- `ANYREMOTE_PASTEBOARD=<name>` shares a pasteboard of that name instead of
  the clipboard, so a host and a viewer on one Mac each have their own and
  the real clipboard is left alone.
- `ANYREMOTE_UPDATE_FEED=<url>` reads the update manifest from there (plain
  HTTP is allowed from 127.0.0.1). Development builds only update when
  signed with the release identity; see the Releases section.
- `ANYREMOTE_DROP=0.02` drops that share of the datagrams (video and sound)
  arriving at the viewer (simulated loss).
- `ANYREMOTE_AUDIO_BUFFER_MS=20` on the viewer starts the sound's jitter
  buffer at that size; `ANYREMOTE_AUDIO_IO_FRAMES=512` on the host sets the
  capture device's I/O buffer (240 by default). The `audio …` statistics
  line shows packets, losses filled in or played as silence, underruns,
  pauses, buffer, transit (host capture → arrival), total and peak level.
- `ANYREMOTE_MICROPHONE_TONE=1` on the viewer sends a 440 Hz tone with a
  click at every whole second of its clock instead of the microphone (no
  Microphone permission needed). On the host, `/usr/bin/log show --info`
  shows the feed's `microphone audio …` statistics every 2 s.
- `ANYREMOTE_TILES=1` on the host sends desktops as whole frames (2–8 sets the
  strip count).
- `ANYREMOTE_DISPLAY_SYNC=1` restores vsync on the windowed layer.
- `ANYREMOTE_PACING=1` holds frames until their host display time.
- `ANYREMOTE_UNCHANGED_FRAMES=1` on the host encodes window frames that show
  nothing new too (see `UnchangedFrameFilter`), for before/after runs.

Keep workloads visible when measuring: macOS throttles occluded windows, and
an occluded mirror is never presented.
