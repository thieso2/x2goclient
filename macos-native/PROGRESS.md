# Native macOS X2Go client (SwiftUI + Metal) — PROGRESS

Goal: a **native macOS display client** for X2Go using the newest 2026 stack —
**Swift 6 / SwiftUI / Metal** for the presentation + input layer — validated
**end-to-end** against the live server (`10.248.1.20`, XFCE session). This is the
Phase 3/4 work from `NATIVE_MACOS_PORT_PLAN.md`.

Branch: `macos-native-metal` (off `macos-qt6-port`). Commit early and often.

## Honest scope

A *fully* hand-written X server (zero X11 anywhere) is the multi-quarter
moonshot. What this prototype builds and proves **now**:

- The entire **macOS-side presentation + input** is native **Swift 6 / SwiftUI /
  Metal 4**: a native `NSWindow`/SwiftUI scene with a `CAMetalLayer`, the remote
  desktop uploaded to a Metal texture, native `NSEvent` mouse/keyboard forwarded.
- The X protocol decode is still **bridged** underneath (`CX11` → the X display
  nxproxy renders onto). This is the explicit seam where a native NX/X decoder
  lands later to remove X11 entirely.

So: "native Metal on the macOS side, e2e-validated" today; "no X11 at all" is the
remaining decode work, isolated behind one C surface (`CX11.h`).

## Architecture

```
X2Go session (server) ──NX──▶ nxproxy ──▶ X display  ──CX11(capture)──▶ Metal texture ──▶ CAMetalLayer (SwiftUI)
                                              ▲                                                   │
                                              └───────────────── CX11 (XTEST input) ◀── NSEvent ──┘
```

- `CX11` (C target): Xlib + XTEST bridge — find window, capture BGRA frame,
  inject motion/button/scroll/key.
- `MetalRenderer`: runtime-compiled MSL, BGRA texture → fullscreen quad.
- `RemoteMetalView` (NSView + CAMetalLayer): drive capture/draw, handle NSEvents.
- SwiftUI `App`: window chrome + status; hosts the Metal view.

## Status log

- **2026-06-03**
  - Scaffolded SwiftPM project (`macos-native/`): `Package.swift` (macOS 14+,
    Swift 6), `CX11` C bridge (Xlib/XTEST helpers, BGRA capture). _committed_
  - Next: Metal renderer, X11 session, view, SwiftUI app; then build + e2e.

## TODO

- [x] Scaffold project + CX11 bridge
- [ ] Metal renderer (runtime shaders, texture present)
- [ ] X11 frame source (capture loop from live session window)
- [ ] Native input forwarding (NSEvent → XTEST)
- [ ] SwiftUI app shell + Metal view host
- [ ] Build green (`swift build`)
- [ ] E2E: launch, show live XFCE desktop in native Metal window, prove input
- [ ] Metal 4 niceties / MetalFX upscaling (stretch)
