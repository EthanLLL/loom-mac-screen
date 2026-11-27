# loom-mac-screen

A Mac's screen as H.264, and its mouse and keyboard, on one TCP port on
loopback (127.0.0.1:5960), for [Loom](https://github.com/EthanLLL/loom)'s
Connect. Loom reaches the port through loom-node — directly over WebRTC when
the networks allow, relayed by Loom otherwise — and knows nothing about video;
the page decodes it with WebCodecs.

- ScreenCaptureKit → VideoToolbox H.264 (real time, low-latency rate control,
  no B-frames, keyframes on request). An idle screen sends nothing.
- The viewer says what its line is (`line` in its settings), and each has
  fixed steps, gone down one at a time when the viewer falls behind twice
  within half a minute (once is a stall, as when the line moves from a
  relay to a direct path), and never back up: on the Mac's own network (`lan`) its own pixels at
  12 Mbit/s and 60 frames a second, then 30 frames at 6, 3 and 1.5;
  across the internet or through a TURN relay (`wan`) its own pixels at
  3 Mbit/s, then a pixel a point at 1.5; round by Loom, or a viewer that
  doesn't say (`narrow`), a pixel a point at 1.5 Mbit/s. All but the first
  step run at 30 frames a second.
- Input as CGEvents, keys by position (`KeyboardEvent.code`), so the Mac's own
  input source makes the text.
- With the lid shut and no monitor, the Mac has no display to show: a
  virtual one is made (CoreGraphics' private `CGVirtualDisplay`, as DeskPad
  and BetterDisplay use), laid out at 1.5 of the viewer's pixels a point,
  for as long as the process runs (never two at once), and the Mac is
  brought out of its dark wake and kept from display sleep while someone
  watches.
- Started by launchd when something connects (socket activation), gone 5 s
  after the last viewer, which is what takes the virtual display away.

The protocol is in `Sources/loom-mac-screen/Wire.swift`.

## Install

On the Mac, with Xcode and an Apple Development identity in the keychain:

```sh
./install.sh
```

It builds (`./build.sh`), wraps the binary as `LoomMacScreen.app` signed with
that identity, puts it in `~/Applications`, and loads the LaunchAgent
`cloud.loom.mac-screen`. The stable signature is what lets macOS keep its
grants across rebuilds. Grant it once in System Settings → Privacy & Security:
Screen & System Audio Recording, and Accessibility.

Another Mac (Apple silicon, macOS 14 or later) needs no Xcode: copy it
`build/LoomMacScreen.app` and `install.sh`, and run

```sh
./install.sh LoomMacScreen.app
```

The app is signed for development, not notarized, so copy it in a way that
leaves no quarantine mark (loom-node, scp); a downloaded copy is stopped by
Gatekeeper.

Logs: `~/Library/Logs/loom-mac-screen.log`.
