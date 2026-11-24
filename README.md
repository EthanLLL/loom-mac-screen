# loom-mac-screen

A Mac's screen as H.264, and its mouse and keyboard, on one TCP port on
loopback (127.0.0.1:5960), for [Loom](https://github.com/EthanLLL/loom)'s
Connect. Loom reaches the port through loom-node — directly over WebRTC when
the networks allow, relayed by Loom otherwise — and knows nothing about video;
the page decodes it with WebCodecs.

- ScreenCaptureKit → VideoToolbox H.264 (real time, low-latency rate control,
  no B-frames, keyframes on request). An idle screen sends nothing.
- Input as CGEvents, keys by position (`KeyboardEvent.code`), so the Mac's own
  input source makes the text.
- With the lid shut and no monitor, the Mac has no display to show: a
  virtual one is made (CoreGraphics' private `CGVirtualDisplay`, as DeskPad
  and BetterDisplay use) for as long as the process runs, and the Mac is
  brought out of its dark wake and kept from display sleep while someone
  watches.
- Started by launchd when something connects (socket activation), gone 30 s
  after the last viewer.

The protocol is in `Sources/loom-mac-screen/Wire.swift`.

## Install

On the Mac, with Xcode and an Apple Development identity in the keychain:

```sh
./install.sh
```

It builds, wraps the binary as `~/Applications/LoomMacScreen.app` signed with
that identity, and loads the LaunchAgent `cloud.loom.mac-screen`. The stable
signature is what lets macOS keep its grants across rebuilds. Grant it once in
System Settings → Privacy & Security: Screen & System Audio Recording, and
Accessibility.

Logs: `~/Library/Logs/loom-mac-screen.log`.
