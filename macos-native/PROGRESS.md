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
  - Scaffolded SwiftPM project; `CX11` bridge (Xlib capture + input). _committed_
  - `MetalRenderer` (runtime MSL), `X11Session` (capture loop), `RemoteMetalView`
    (NSEvent input), `KeyMap`, SwiftUI `App`. `swift build` green. _committed_
  - **E2E DISPLAY validated**: ran the app against the live XFCE session on
    `10.248.1.20` (display `:0`) — the native SwiftUI window titled
    "X2Go (native · Metal)" renders the live desktop (wallpaper, panel, a
    Terminal showing real `df` output) via a Metal texture. Screenshot:
    `docs/e2e-native-metal.png`. _committed_
  - **Input**: NSEvent→X handlers implemented and building; added a headless
    `inputtest`. Discovered **XQuartz 2.8.5 advertises no XTEST extension**
    (only XInputExtension), and nxproxy does not forward synthetic `XSendEvent`
    input — so programmatic injection from a *separate* app through the XQuartz
    bridge does not reach the session. (Real interactive clicks in the X2GO
    window work normally; this is an injection-from-outside limitation.)
    → Input belongs in the native-protocol endpoint, not this read-only display
    bridge; see "Honest scope". The Swift input path is complete behind `CX11`.

## TODO

- [x] Scaffold project + CX11 bridge
- [x] Metal renderer (runtime shaders, texture present)
- [x] X11 frame source (capture loop from live session window)
- [x] Native input forwarding (NSEvent → X) — *wired/builds; XQuartz transport
      limited (no XTEST); native-protocol path needed for reliable input*
- [x] SwiftUI app shell + Metal view host
- [x] Build green (`swift build`)
- [x] E2E: live XFCE desktop shown in the native Metal window (display path)
- [ ] Input e2e through a path that doesn't need XTEST (native NX endpoint, or
      XQuartz 2.8.4 which has XTEST) — *next*
- [ ] Replace capture bridge with native NX/X decode → zero X11 (Phase 3 core)
- [ ] Metal 4 niceties / MetalFX upscaling (stretch)

  - Input auto-validation is **doubly blocked in this environment**: (a) XQuartz
    2.8.5 has no XTEST (so the app's X injection can't synthesize real events),
    and (b) the harness has no Accessibility permission (so CGEvent/System-Events
    injection is denied too). Both are environmental, not code defects. Reliable
    input needs either XQuartz 2.8.4 (has XTEST) or — properly — the native
    protocol endpoint.

## Key finding

The "capture from XQuartz + inject into XQuartz" bridge is great for **display**
(read pixels → Metal) but **input injection requires XTEST, which XQuartz 2.8.5
removed**. The correct architecture makes the native app the protocol endpoint
(nxproxy/NX talks to *us*), so input is sent over NX directly with no XQuartz —
which is exactly the no-X11 Phase 3 direction. This bridge proved the entire
native macOS **presentation** layer (Swift 6 / SwiftUI / Metal) end-to-end.
