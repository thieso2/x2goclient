# Implementation Plan — Native X2Go client via embedded Xvfb + Metal

**Decision:** drop the hand-written X11 server and use a real, complete X server
(**Xvfb**) as nxproxy's display, presenting its framebuffer in the native Metal
window and feeding input back via XTEST. Trade incompleteness for completeness;
keep the native-app feel; performance ≈ XQuartz (both are software 2D + GPU
present — see NATIVE_MACOS_PORT_PLAN notes).

## Why this works (feasibility already confirmed)
- `/opt/X11/bin/Xvfb` exists (ships with XQuartz) — **no X server to build**.
- Xvfb supports `-fbdir` (mmap'ed framebuffer file) and `-shmem` (SysV shared
  memory) for direct pixel access, plus `-screen WxHxD`.
- `/opt/X11/lib/libXtst` present → **XTEST input injection works** (this is the
  thing XQuartz 2.8.5 lacked; a real Xvfb has it).
- The original capture-bridge already exists and is reusable:
  `Sources/X2GoNative/{X11Session,MetalRenderer,RemoteMetalView,KeyMap,App}.swift`
  + `Sources/CX11/{shim.c,include}`. It already captured XQuartz; we just point
  it at a private Xvfb.

## Architecture
```
app ──full X11──> nxagent ──NX──> nxproxy ──full X11──> Xvfb :99  (complete X.org server)
                                                          │ framebuffer (XShmGetImage / -fbdir mmap)
                                                          ▼
                                            read pixels → Metal texture
                                                          ▼
                                   CAMetalDisplayLink → native macOS window
                                                          ▲ input
                                   NSEvents → XTEST (libXtst) → Xvfb
```
One real X server, owned by us, headless, presented in our window.

## Keep / drop / add
- **Keep:** `MetalRenderer`, `RemoteMetalView` (NSEvent capture), `KeyMap`,
  `X11Session` (XShm capture loop), `CX11` shim. The Metal presentation + input
  mapping are done.
- **Drop:** the `x2go-xserver` target entirely — `main.swift`, `Wire.swift`,
  `Compositor.swift`, `GlyphRender.swift`, `Input.swift`, `MetalPresenter.swift`
  (≈1,570 lines of hand-written protocol). Keep on git history (branch
  `macos-native-metal`) for reference.
- **Add:** Xvfb process manager; framebuffer reader; XTEST input path; client
  wiring (DISPLAY → Xvfb); XDAMAGE-driven updates; cursor + clipboard.

## Phases

### Phase 1 — Xvfb + capture (display only)
- `XvfbServer.swift`: pick a free display (e.g. :99), launch
  `Xvfb :99 -screen 0 1280x800x24 -shmem -ac -noreset` (own XAUTHORITY or `-ac`),
  monitor/restart, clean shutdown.
- Capture: reuse `X11Session` (XOpenDisplay :99 + XShmGetImage of the root each
  frame) → BGRA → `MetalRenderer` texture. (Optimization later: `-fbdir` mmap or
  `-shmem` attach for zero round-trip reads.)
- **Validate:** `DISPLAY=:99 xterm` / `xclock` / `mousepad` → fully rendered in
  the Metal window (xclock's PolyArc face now draws — it's a real X server).

### Phase 2 — Input via XTEST
- In `CX11/shim.c`, replace the XSendEvent hacks with XTEST:
  `XTestFakeMotionEvent`, `XTestFakeButtonEvent`, `XTestFakeKeyEvent` (link
  `-lXtst`, already in Package.swift).
- `RemoteMetalView` NSEvents → framebuffer coords → XTEST into :99. Keymap:
  query Xvfb's keymap (`XKeysymToKeycode`) instead of a hand-rolled table — Xvfb
  has a full XKB map.
- **Validate:** click a launcher / type in an app → reaches the session.

### Phase 3 — Client wiring
- Launcher (`run-native.sh` / the app): start Xvfb, export `DISPLAY=:99`, run
  `x2goclient --session=… --autologin`; tear down Xvfb on exit.
- Keep server-side `helpers.rc` (preferred apps) so launchers start apps.
- **Validate:** full X2Go session → complete XFCE desktop + apps + input, end to
  end, in the native window.

### Phase 4 — Polish / efficiency
- **XDAMAGE**: subscribe to damage on the root; re-read only changed rectangles
  instead of full-frame polling → big efficiency win and lower latency.
- **Cursor**: XFIXES `XFixesGetCursorImage` to composite the real cursor (Xvfb's
  software cursor may already be in the fb; verify).
- **Resize**: Xvfb supports RANDR — `XRRSetScreenSize` to match the window size
  on resize (the hand-written server couldn't do this).
- **Clipboard**: bridge X PRIMARY/CLIPBOARD selections ↔ `NSPasteboard`.
- **Bundling decision** (see Risks).

## Risks / open decisions
1. **Dependency on XQuartz.** Xvfb + libX11/libXtst live in `/opt/X11`, so this
   approach **requires XQuartz installed** — unlike the hand-written server
   (zero deps). Decision:
   - *Simple:* require XQuartz (document it; the app checks for `/opt/X11/bin/Xvfb`).
   - *Self-contained:* bundle `Xvfb` + its dylibs + fonts/keymaps into the `.app`
     and rewrite paths — non-trivial (X server needs font dirs + xkb data).
   Recommend starting with "require XQuartz", revisit bundling later.
2. **Framebuffer pixel format.** XShmGetImage gives a known visual/format; depth
   24 → 32bpp, server byte order — confirm BGRA vs RGBA swizzle for Metal.
   `-fbdir` writes XWD-format (header + pixels) if we switch to mmap.
3. **Capture cost.** Full-frame XShmGetImage at 30–60fps for 1280×800 is fine,
   but XDAMAGE partial reads are the proper solution (Phase 4).
4. **Cursor visibility** in a headless server — verify software cursor lands in
   the captured framebuffer, else composite via XFIXES.

## Validation matrix
- `xdpyinfo :99` lists a complete server (RANDR, RENDER, XTEST, DAMAGE, XFIXES).
- `xclock` (PolyArc), `mousepad` (full UI), a terminal — all render *completely*
  (the gaps that broke the hand-written server are gone).
- Full session: desktop + dock + launched apps + mouse/keyboard, in the Metal
  window, no XQuartz windows on screen.
- Perf: steady 30–60fps; subjectively indistinguishable from XQuartz.

## Effort
Small relative to completing the hand-written server: most code exists
(capture-bridge), Xvfb is prebuilt, XTEST is standard. Estimate ~1–2 focused
days to a working Phase 1–3; Phase 4 incremental.
