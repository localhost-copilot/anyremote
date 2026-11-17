# Performance

How fast AnyRemote is, and the VideoToolbox, ScreenCaptureKit and window
server behavior behind its settings. Every finding was measured before and
after the change. Re-measure before changing an encoder or presentation
setting; `anyremote-bench` and `ANYREMOTE_STATS_STDOUT=1` (see the README)
are the tools.

## Window mirror (M6 Mac18,5, macOS 27, 60 Hz display, network loopback)

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

~48–58 fps at 5–15 Mbps for this workload, no loss.

Full desktop, 1920×1080 pt @2x (3840×2160 px, 4:4:4), shown scaled in a
1612×907 pt window, loopback with a 60 Hz workload: 51–61 fps (as many as
the workload drew), encode 11.5–13 ms, total p50 18–22 ms at 30–55 Mbps
(viewer and host share one media engine here; across two Macs each has its
own). Across a real network add
one-way network latency to *receive*.

## Several windows at once

Opening an app from **Apps** opens all its windows, so several mirrors
stream at once. On macOS 27 ScreenCaptureKit hands over a complete frame of
*every* captured window, its whole area marked dirty, whenever anything on
the host's screen changes; even when that window is unchanged, belongs to
another process and overlaps nothing. The frames are byte-identical to the
previous one. Encoding them all saturated the media engine.
`UnchangedFrameFilter` compares each window frame with the last one (≈1 ms
for a 2400×1600 frame that matches; it stops at the first difference
otherwise) and drops it once the window has been still for 0.5 s (the
encoder sharpens a picture that stopped moving over ~30 frames). After 1 s
still, it compares only every third frame.

`anyremote-bench --windows 6 --busy 1` against `--host` in its own process
(M6, loopback): six 1200×800 pt (2400×1600 px) windows, one scrolling, two
interleaved rounds; `ANYREMOTE_UNCHANGED_FRAMES=1` is the "before":

| | Scrolling window receive p50 / p95 | its fps | Encode p50 | Video, all windows | Host CPU |
|---|---|---|---|---|---|
| Every frame encoded | 24–27 / 34–37 ms | 54–55 | 17.4 ms | 54–88 Mbps | 16–18% |
| Unchanged frames dropped | 7.2–7.7 / 9–12 ms | 60–62 | 5.5 ms | 15–51 Mbps | 20–24% |

Each still window now sends nothing (it sent ~8 Mbps at the full frame
rate), and windows that do change are as fast as alone (1 scrolling: 7.6–7.8
ms either way; 3 scrolling: 6.7–7.5 ms, ~45 Mbps each). Comparing every
frame of five still windows cost 13% of a core before the every-third-frame
rule. A still window's first change reaches the viewer up to two frames
later.

## Full desktop between two Macs

Full desktop between two Macs (M4 Mac mini host running testufo, M6 viewer
on a 60 Hz 4K screen, wired LAN, RTT ~1 ms), 60 fps, no loss. "Behind the
host" is from the host showing a frame on its own screen to this Mac
showing it:

| Viewer | Host pixels | Encode | Decode → glass | Behind the host p50 / p95 | Stutters |
|---|---|---|---|---|---|
| Window (1618×910 pt) | 3236×1820 | 8.3 ms | 8.0 ms | 10.2 / 18.1 ms | 0.4/s |
| Full screen | 3840×2160 | 12.2 ms | 3.5 ms | 9.8 / 16.2 ms | 1.0/s |

Full screen skips WindowServer's composition (decode → glass 8 → 3.5 ms),
but dynamic resolution then makes the host's desktop the whole screen, and
the larger frame takes 4 ms longer to encode.

## Strips

Desktops go out as four horizontal strips, like Apple Screen Sharing's
four tiles: one capture, and each strip its own HEVC session and stream ID.
VideoToolbox's encode time follows the frame's pixel count, not how much
changed, so a full 4K frame cost 10–15 ms even for one typed letter. Only
strips that ScreenCaptureKit reports as changed are copied out (a GPU blit)
and encoded, and the strips of a full-screen change encode, travel and
decode overlapped. Every strip carries the host frame's display time and the
set of strips sent with it; the viewer shows a host frame once all of them
are decoded (or after 10 ms, or when a newer one starts), drawing every
strip's latest picture into one drawable, so a frame never shows half old.
Capture → decoded, no network (`anyremote-bench --tiles`, 3840×2160):

| Host | Workload | Whole frame p50 / p95 | 4 strips p50 / p95 |
|---|---|---|---|
| M6 | typing | 15.3 / 32.0 ms | 9.6 / 10.2 ms |
| M6 | full-screen motion | 14.6 / 18.5 ms | 11.3 / 13.9 ms |
| M4 | typing | 21.0 / 32.6 ms | 11.3 / 20.4 ms |
| M4 | full-screen motion | 15.1 / 16.7 ms | 14.0 / 15.1 ms |

Eight strips gave nothing more for full-screen motion. `ANYREMOTE_TILES=1`
on the host sends whole frames (any 2–8 sets the strip count).

## Sound (M6, macOS 27, network loopback)

Full desktop, a steady tone, 12 one-second samples per run, median of the
samples; *transit* is host capture → arrival, *total* adds the jitter buffer
and the output device (3.7 ms).

| capture I/O buffer | transit | total |
|---|---|---|
| device default (512 frames) | 15.8–15.9 ms | 40–47 ms |
| 240 frames (chosen) | 10.3–10.4 ms | 33–45 ms |
| 128 frames | 11.5 ms | 41–44 ms |

- A frame waits for its whole I/O cycle and then for its 10 ms packet, so
  below 240 frames the packet dominates.
- The total swings with the jitter buffer's level at the moment of the
  sample (10–30 ms around a 30 ms target). A 20 ms target played without
  underruns on loopback (total ~30 ms); the buffer starts at 30 ms and
  shrinks toward 20 ms after 20 s without an underrun, to leave room for
  Wi-Fi at the start.
- 5% simulated loss (`ANYREMOTE_DROP=0.05`): 3–5 packets a second came back
  from the next packet's copy, about one a run was played as silence, no
  underruns.
- Core Audio runs a tap's device only while something it taps plays, so the
  host sends nothing while the shared apps are silent; the viewer counts
  such gaps as pauses, not underruns, so they don't grow its buffer.

## Microphone (M6, macOS 27, network loopback)

`anyremote-bench --microphone`: the viewer client sends a test tone with a
click at every whole second of the host clock; this process records the
AnyRemote Microphone like any app (an I/O proc on the device). Host and
viewer share the clock, so a click's arrival past its whole second is the
delay from captured on the viewer to recorded on the host: encode, network,
jitter buffer, the feed's I/O buffer (240 frames, 5 ms) and the
microphone's. Steady to 0.1 ms within a run.

| jitter buffer start | click delay |
|---|---|
| 30 ms (default, as for sound) | 43.3–43.6 ms |
| 20 ms (`ANYREMOTE_AUDIO_BUFFER_MS=20`) | 34.4 ms |

- The jitter buffer is most of it. It starts at 30 ms like the sound's and
  shrinks toward 20 ms after 20 s without an underrun.
- A real microphone adds its own input latency on the viewer, and AAC-ELD
  has a few milliseconds of algorithmic delay either way.
- The driver's two devices count samples from one anchor host time, so the
  feed and the microphone never drift apart; the viewer's and host's clocks
  do, and the jitter buffer absorbs that as it does for sound.

## Frame rates above 60 (M6, macOS 27)

`CGVirtualDisplayMode` takes any refresh rate; a display made at 120 or
144 Hz reports that mode and apps on it draw that often (a `CADisplayLink`
fires 120/143 times a second). `anyremote-bench --refresh-test 60,120,144
--synthetic 1200x800` (2400×1656 px window scrolling text, in-process
capture → encode → decode, no viewer on screen):

| Display | Decoded fps (median) | Encode p50 | Mbps |
|---|---|---|---|
| 60 Hz | 63 | 5.6 ms | 36–45 |
| 120 Hz | 119 | 5.2 ms | 31–63 |
| 144 Hz | 145 | 5.2 ms | 28–62 |

Some seconds dropped to ~83 fps; the window's own redraws dropped with them
(the drawing app fell behind, not the pipeline). The average bit rate stays
at the target, so each frame gets fewer bits at higher rates.

Through the real host and viewer in loopback (`--frame-rates 144,60,120`),
a change applies to the open window within a second, and the window then
redraws at the new rate. The viewer received more frames than the window
drew (60 Hz: ~82 fps, 120 Hz: ~160): ScreenCaptureKit also hands over a
window frame whenever something else on the screen changes (here the
viewer's own mirror window on the 60 Hz main display), and
`UnchangedFrameFilter` lets unchanged frames through while the window keeps
changing (its settle time). The capture interval of 1/(1.5 × rate) caps
them. A host whose screen is otherwise still sends about the refresh rate.

## Findings behind the settings

- `RealTime` is off and `PrioritizeEncodingSpeedOverQuality` on. In
  real-time mode VT runs the engine just fast enough for the expected rate,
  so a frame takes ~9–12 ms however small: a 3840×528 strip took 11.6 ms,
  as long as a whole 4K frame, and an idle M4 host took 22–35 ms per strip.
  Without it time follows the pixels (M6: strip 3.7 ms, four strips at once
  7.8 ms, 4K frame 8.7 ms), and the 4K frame decodes at 46.4 dB PSNR
  instead of 45.4 (with ~13% more bits than asked for). `RealTime` off
  without the speed priority encodes best (53.5 dB) but takes 14.5 ms.
  Capture → decoded with four strips (`anyremote-bench --tiles` vs
  `--realtime`): typing 16.2 → 9.8 ms, scrolling 13.2 → 8.7 ms,
  full-screen motion 16.0 → 10.3 ms.
- In real-time mode, `kVTCompressionPropertyKey_ExpectedFrameRate` acts as a latency budget:
  VT clocks the encoder down until one frame takes ~1/rate. 60 → 120 halved
  encode time (1280×800: 16.8 → 8.6 ms). 240 gave nothing further.
- Removing `kVTDecodeFrame_1xRealTimePlayback` cut decode ~20%.
- Any color-tagging compression property (primaries, transfer, matrix) adds
  ~2.5 ms per 4K frame.
- `EnableLowLatencyRateControl` silently downgrades to 4:2:0. Don't use it.
- In full screen, any view over the video (the statistics overlay was an
  `NSTextField`) made the window server composite instead of showing the
  video directly each time it changed: one stutter a second (1.05/s → 0.10/s
  once the text was drawn into the video frames themselves).
- The mirror's window buttons, drawn over the windowed video, cost nothing
  measurable (synthetic 940×700 pt, four interleaved 25 s runs each: hitches
  2.08/s with vs 1.78/s without, run-to-run 1.53–2.33; total p50 20.8 vs
  20.9 ms). In full screen they are hidden until the pointer reaches them.
- `displaySyncEnabled = false` on the windowed layer: decode → glass 25 → 7 ms.
  `ANYREMOTE_DISPLAY_SYNC=1` restores vsync for comparison.
- ScreenCaptureKit's `minimumFrameInterval` at exactly the refresh period
  (1/60) drops frames whose timestamps arrive slightly early: only ~49 of
  ~58 drawn frames were delivered (35–50 fps). 1/90 delivers every one;
  1/120 also lets some duplicates through on window capture.
- ScreenCaptureKit stamps each frame with the time the host shows it, and
  hands it over before that: 9 ms on average, up to 15 ms. Frames carry that
  lead (`captureLeadMicros`), so latency counts from the handover while the
  stamps, exactly one refresh apart, still give the host's cadence.
- In real-time mode, 3236×1820 4:4:4 takes 9.7 ms on M6, 4:2:0 8.8 ms;
  `PrioritizeEncodingSpeedOverQuality`, `MaximizePowerEfficiency = false`
  and an expected rate of 240 change nothing there. Two parallel half-height sessions take 8.8 ms, four 8.9 ms: one
  encode engine, so tiles only overlap a little. Chips with two engines
  (Max) may differ.
- Frame pacing on the viewer (hold each frame until its host display time
  plus the 95th-percentile arrival, `ANYREMOTE_PACING=1`) added 5–6 ms and
  did not reliably cut stutters (windowed 0.41 → 0.61/s, full screen
  1.00 → 0.44/s), so frames are shown on arrival.
- Sparse updates (e.g. typing) were slow for the same reason (real-time
  mode): 800×600 took ~10 ms instead of ~4.5 ms.

