# Implementation Plan — per-session Xvfb + viewer lifecycle

Derived from the grilling session. Authoritative decisions live in
`CONTEXT.md` + `docs/adr/0001`, `docs/adr/0002`. This file is the build plan.

Branch: `macos-native-metal`. Test server: `10.248.1.20` (XFCE, profile `tubu`).
Verify each stage end-to-end before moving on (keep a working build at all times).

---

## Stage 0 — `SessionDisplay` unit (Qt)  *(foundation, no behavior change yet)*

Introduce the encapsulated per-connection trio so later stages have a home.

- `src/onmainwindow.h`, near `QProcess *nxproxy;` (816), inside `#ifdef Q_OS_DARWIN`:
  ```cpp
  struct SessionDisplay {
      int       displayNum = -1;   // :N
      QString   dispStr;           // ":N"
      QString   geometry;          // "WxH"
      bool      wantFullscreen = false;
      QProcess *xvfb   = nullptr;
      QProcess *viewer = nullptr;
      int       viewerRetries = 0;
      bool      tearingDown = false;  // guard against the suspend-loop
  };
  SessionDisplay sessionDisplay_;   // one today; QMap<id,…> later
  ```
- New private slots (Darwin): `slotViewerFinished(int,QProcess::ExitStatus)`,
  helpers `startSessionDisplay(const QString& geom, bool fs)`,
  `launchViewer()`, `teardownSessionDisplay()`, `resolveSessionGeometry()`.

## Stage 1 — Qt owns the per-session Xvfb; drop launcher/XQuartz

Make the client start/stop the Xvfb and return its display, with the **old**
display behavior otherwise intact (viewer still works as before, just spawned by
the client). This is the riskiest plumbing; isolate it.

1. **`macos-native/launcher.c`** → reduce to: resolve `x2goclient.real`, pass args
   through, `execv`. Remove Xvfb start, setxkbmap, viewer spawn, env setup. (Keep
   the file: it stays the Mach-O entry point that carries entitlements.)
2. **Geometry resolution** — `resolveSessionGeometry()`:
   - explicit `WxH` → verbatim; `fullscreen`/`maxdim` → main `QScreen`
     `logicalSize` (points), clamped. Returns `{ "WxH", wantFullscreen }`.
   - Replace the force-fullscreen blocks at `onmainwindow.cpp:4011` and `:4282`:
     no more `fullscreen=true`; build `geometry` from the resolved concrete `WxH`
     (used for both Xvfb and the nxagent geometry string — they must match).
3. **`startSessionDisplay()`** — allocate a free display (scan `/tmp/.X%d-lock`
   from 99), resolve Xvfb path (bundle `Contents/Resources/x11/bin/Xvfb` →
   `/opt/X11/bin/Xvfb`), spawn `Xvfb :N -screen 0 WxHx24 -ac -noreset -fp <bundle
   fonts> -xkbdir <bundle xkb>` (omit `-fp`/`-xkbdir` for the `/opt/X11` fallback),
   wait for the socket, then `setxkbmap <mac-layout>` on `:N` (port the layout map
   from launcher.c). Store in `sessionDisplay_`.
4. **`getXDisplay()` (`onmainwindow.cpp:9068`)** — on Darwin, return
   `sessionDisplay_.dispStr`. **Delete** the XQuartz launch / `xhost +` /
   `~/.serverauth.*` cookie logic (here and in the nxproxy env block ~5515-5552).
5. **Wire start point** — call `startSessionDisplay()` before the Darwin nxproxy
   start (~5462) so `DISPLAY=:N` is set for the proxy. Call
   `slotDisableServerCompositing()` **unconditionally on Darwin** (was gated on
   `X2GO_FORCE_FULLSCREEN`; replace that gate at `:3176`).
6. **Teardown** — `teardownSessionDisplay()` kills viewer (signal disconnected
   first) then Xvfb, removes the lock; call it from `slotProxyFinished`
   (`:5827`) on Darwin.
7. Retire `X2GO_FORCE_FULLSCREEN` entirely (launcher no longer sets it; remove the
   three `getenv` checks).

**Verify:** `./macos-native/run-native.sh`-equivalent via the bundled app —
session connects, full XFCE desktop renders, Xvfb is per-session, no XQuartz
launched. Suspend/terminate from the session list kills Xvfb cleanly.

## Stage 2 — viewer launch + bidirectional lifecycle

1. `launchViewer()` — spawn `Contents/exe/X2GoNative --display :N --geometry WxH
   [--fullscreen] --title "<session name>"`. Connect `finished` →
   `slotViewerFinished`. Launch as soon as the Xvfb is up (Stage 1 already has it
   up before nxproxy).
2. `slotViewerFinished` —
   - if `tearingDown` → ignore (we killed it);
   - else clean exit → `suspendSession(currentId)`;
   - else (crash) & session still running & `viewerRetries < 3` within 10s →
     `launchViewer()` again, `++viewerRetries`; otherwise suspend.
3. `teardownSessionDisplay()` sets `tearingDown=true`, `disconnect(viewer,…)`,
   `viewer->terminate()` before killing Xvfb (closes the suspend-loop).

**Verify:** close viewer → session suspends (visible in session list, resumable).
`kill -9` the viewer → it relaunches on the same desktop. Suspend from list →
viewer disappears. No loops, no orphan Xvfb.

## Stage 3 — viewer scaling / scroll / menu / fullscreen (Swift)

Files: `Sources/X2GoNative/{App,RemoteMetalView,MetalRenderer}.swift`.

1. **Args** — parse `--geometry WxH`, `--fullscreen`, `--title`. Drop
   `.windowResizability(.contentSize)`; window is freely resizable. Set title.
2. **Scale state** — `enum ZoomMode { case fit, manual(CGFloat) }`. Default
   `.fit`. Wrap the Metal view in an `NSScrollView` (provides scrollbars when
   content > clip). The Metal view's frame = `sessionSize * scale`.
   - `.fit`: on resize, `scale = min(clipW/sessW, clipH/sessH)` (≤ caps at 1 unless
     zoomed); no scrollbars (content == clip). Uniform aspect.
   - `.manual(s)`: frame = `sessionSize * s`; scrollbars appear when it overflows.
3. **Input mapping** — in `RemoteMetalView`, map `NSEvent.locationInWindow` →
   view-local → divide by current `scale`, add scroll offset → Xvfb pixel coords
   for XTEST. Must hold in both windowed and fullscreen. Keyboard unaffected.
4. **View menu** (the viewer is its own app with a menu bar): Zoom In ⌘=, Zoom
   Out ⌘− (manual, ~10% steps), Actual Size ⌘0 (`.manual(1)`), Fit ⇧⌘F (`.fit`).
5. **Fullscreen** — if `--fullscreen`, `window.toggleFullScreen(nil)` on first
   show; keep View menu working (Fit recomputes against the fullscreen clip).
6. **Sampling** — linear minification (downscale), nearest at >1× for crispness.

**Verify:** profile `2560x1440` on a smaller screen opens fit (whole desktop
visible); Zoom In → scrollbars, panning works, clicks land on the right widget;
Actual Size / Fit toggle correctly; a `fullscreen` profile opens true-fullscreen.

## Stage 4 — cleanup & docs

- Remove dead XQuartz helpers / `getXDarwinDirectory` usage if now unused.
- Update `BUILD.macOS.md` (no XQuartz requirement; Xvfb from bundle/opt).
- `run-native.sh` updated or removed (the app now self-manages Xvfb+viewer).
- Update `PROGRESS.md` status.

---

## Risks to watch
- **No XQuartz fallback** (ADR-2): native Xvfb is load-bearing.
- **Input mapping under scale+scroll**: the one silent-correctness spot — test focus.
- **Display/lock races** if a stale `/tmp/.X*-lock` survives a crash — clean on alloc.
