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

## Native NX endpoint (the no-X11 core) — in progress

New direction: instead of capturing from XQuartz, **be the X server that nxproxy
connects to**. nxproxy decodes the NX stream into the X11 wire protocol and
connects (as an X client) to `DISPLAY`; if that display is *our* Swift server,
we own both display (→ Metal) and input (→ X events to nxproxy), with **no
XQuartz / no X11 server dependency**.

Plan + validation ladder (commit each rung):
1. X11 socket `/tmp/.X11-unix/X77` + connection handshake/setup reply.
   Validate: `DISPLAY=:77 xdpyinfo` connects and prints screen info.
2. Core request dispatch (QueryExtension, InternAtom, GetProperty, Create*,
   Map*, …). Validate: xdpyinfo completes; a trivial client maps a window.
3. Drawing requests (PutImage/CopyArea/PolyFillRectangle/PolyText) → framebuffer
   → reuse `MetalRenderer`. Validate: `xeyes`/`xterm` pixels appear in Metal.
4. Input: native NSEvent → X events delivered to nxproxy. Validate: e2e typing.
5. Point a real session's nxproxy at `:77` → XFCE desktop in the native window,
   no XQuartz.

Honest note: a complete X server is huge; the goal here is a *minimal* one
sufficient for nxagent/nxproxy, proven rung-by-rung against real X clients.

  - **2026-06-03 (NX endpoint)**
    - Rung 1 ✓ — Swift X server handshake: `xdpyinfo` + `XOpenDisplay(":77")`
      connect and read our setup (1280x800, depth-24 TrueColor). _committed_
    - Rung 2/3 ✓ — framebuffer + drawing: handled CreateGC/ChangeGC,
      PolyFillRectangle, PutImage(ZPixmap), ClearArea. A real X client drew
      three colored rects + an image and our server rendered them pixel-correct
      (docs/e2e-xserver-framebuffer.png). This framebuffer is the Metal surface.
    - Rung "Metal" ✓ — the X server now presents its framebuffer in a **native
      macOS window via Metal** (CAMetalLayer + runtime MSL, in x2go-xserver).
      A real X client drew into our server and the rectangles appear in the
      native Metal window with **no XQuartz** (docs/e2e-xserver-metal-window.png).
    - Remaining for full XFCE via nxproxy: implement the RENDER (Xrender) request
      subset nxagent uses, more core requests (CreatePixmap/CopyArea/PolyText),
      and input events back to nxproxy. Architecture + display path proven.


## Full protocol + events (drive a real session) — in progress

Goal escalated: make it a *fully working* native macOS/Metal client — implement
the X protocol + event handling our endpoint needs so a real nxproxy session
renders into the Metal window, with input.

Approach (data-driven): point a real session's nxproxy at our `:77` server,
capture the exact request/opcode usage, implement core + the RENDER subset
nxagent uses, push input/Expose events back to nxproxy. Safe-reply unknown
reply-expecting requests so nxproxy never deadlocks while we expand coverage.


## Milestone: real nxproxy session into our native X server

A real X2Go session's **nxproxy connected to our `:77` Swift X server and
"Established X server connection"**; `x2goruncommand` (startxfce4) ran; nxagent
pushed initial content (the X11 logo bitmap) via PutImage which our server
rendered to the framebuffer (docs/e2e-nxproxy-into-xserver.png). End-to-end:
**x2goagent → nxproxy → our hand-written X server → framebuffer (→ Metal)**,
no XQuartz.

Implemented to get here: thread-per-client (so the getXDisplay probe can't block
accept), AllocColor, GetGeometry, QueryPointer, TranslateCoordinates, QueryTree,
GetSelectionOwner — on top of rung-1/2/3. RENDER reported absent so nxagent uses
core drawing (PutImage), which we handle.

Open issue (next): after establishing + initial content, the **NX peer link
(nxproxy↔remote nxagent) breaks** ("Failure reading from the peer proxy") before
the full XFCE desktop streams. Needs: complete the request/reply coverage
(GetWindowAttributes len-3, GetImage, ListFonts/QueryFont, colormaps), send
window/Expose/Map events nxagent expects, and harden the read/write loop so the
NX stream stays in sync. Then input events (KeyPress/ButtonPress/Motion) → nxproxy.

Status: native endpoint proven at the protocol level (real session connects +
streams initial content); full desktop streaming is the remaining work.


## Honest status (end of session)

**Achieved (committed, with evidence):** a hand-written native **Swift X server**
(`x2go-xserver`) that:
- completes the X11 connection handshake (xdpyinfo / XOpenDisplay) — rung 1;
- renders core drawing (PolyFillRectangle, PutImage, GC colors) to a framebuffer
  presented via **Metal** in a native window, no XQuartz — rungs 2/3 + Metal;
- has a **real X2Go session's nxproxy connect and "Establish"**, run
  x2goruncommand, and stream **initial content (X11 logo via PutImage)** into our
  framebuffer (docs/e2e-nxproxy-into-xserver.png).

**Not yet working:** the **full XFCE desktop does not stream** — after the initial
content the **NX peer link (nxproxy↔remote nxagent) breaks consistently**
("Failure reading from the peer proxy") during/after nxagent's atom-intern flood.
All reply-expecting requests we received were answered; the break is on the
remote NX/SSH side. Resolving it requires: (a) complete X request/reply coverage
with correct lengths (GetWindowAttributes len-3, GetImage, QueryColors,
font/colormap queries) so nxproxy never blocks; (b) send the window/Map/Expose
events nxagent expects; (c) harden the socket read/write loop; possibly (d) rule
out the intermittent SSH-NX-tunnel instability seen independently. Then **input
events** (KeyPress/ButtonPress/MotionNotify → nxproxy) for interactivity.

So: the native NX endpoint is proven **at the protocol level** (real session
connects + initial render via Metal, zero X11), but it is **not a fully working
desktop client yet** — that's the remaining (substantial) work above.

### Note: a fully-working path that already exists
The earlier **capture bridge** (nxproxy → XQuartz → capture → Metal) already
displayed the *complete* live XFCE desktop in a native Metal window
(docs/e2e-native-metal.png); its only gap was input injection (XQuartz 2.8.5
lacks XTEST). That path is "fully working display today, input via XQuartz 2.8.4
or the native endpoint". The native endpoint here is the cleaner long-term
no-X11 architecture, still being completed.


## Diagnosis update — NX tunnel teardown (the blocker)

Implemented since last note: fixed GetKeyboardMapping (return count*kpkc keysyms),
added AllocColor/GetGeometry/QueryPointer/TranslateCoordinates/QueryTree/
GetSelectionOwner, and **event handling**: track windows (CreateWindow/
ChangeWindowAttributes event-mask) and deliver **MapNotify + Expose** on MapWindow.

Discriminating test (same server, same moment):
- via **XQuartz**: full XFCE session, 3 desktop procs, **no break** — session,
  tunnel and nxagent are healthy.
- via **our :77 server**: nxproxy "Establishes", we answer every request
  (incl. the atom-intern flood) and send Map/Expose events, but **~2s later the
  NX peer link drops** ("Failure reading from the peer proxy"; "No shutdown of
  proxy link performed by remote proxy"). Server-side nxagent log shows it
  started cleanly ("Screen resized to 1280x800") — **no crash logged**; our X
  server also survives (logs the disconnect).

So nxagent is healthy and our server is healthy, yet the nxproxy↔nxagent tunnel
tears down only on our path, ~2s in. Root cause not yet pinpointed; it is a
protocol-conformance/timing gap that makes nxproxy (or the client's session
monitor) abandon the link — needs **NX-level tracing** (nxproxy debug log) to
isolate. This is the remaining blocker to a full desktop via the native endpoint.

### Bottom line
The native NX endpoint is proven at the protocol level (real session connects,
establishes, streams initial content → Metal, no XQuartz) but is **not yet a
fully working desktop client** — the NX-tunnel teardown is an open,
deeper-investigation item. The **capture-bridge** path already renders the full
live XFCE desktop in Metal today (docs/e2e-native-metal.png); its only gap is
input (XTEST on XQuartz 2.8.5).


## Deep diagnosis of the teardown (server source consulted)

Completed the X reply surface: GetWindowAttributes(len-3), QueryKeymap,
GetKeyboardControl(len-5), GetPointerControl/Mapping, GetScreenSaver, and a
correctly-framed length-0 fallback for all other reply-expecting opcodes (so
nxproxy/nxagent round-trips can never stall on us). Plus events (MapNotify/
Expose), AllocColor, geometry/pointer/tree replies, keymap fix.

Result: **unchanged** — deterministic break at ~88 requests / ~2s. Ruled out,
with evidence, each candidate cause:
- Not a blocked reply (nxproxy is async; full reply set didn't help).
- Not a modal-dialog GUI stall (0 dialogs this run; same break).
- Not a client crash (Qt client stays alive `RN` after the break).
- Not our server crashing (it logs the disconnect and keeps serving).
- Not nxagent crashing (server log: clean suspend, no protocol error).
- nxproxy reports **no local X error** — only "Failure reading from the peer
  proxy on FD#5"; nxagent reports the mirror ("...on FD#8"). nxcomp source
  (Loop.cpp HandleShutdown, getShutdown()==0) confirms: the **NX peer TCP was
  severed with no clean shutdown** — i.e. the SSH-tunnelled nxproxy↔nxagent
  channel dies, even though both proxies, the client, and our server live on.

So our X-server protocol is *accepted* by nxproxy; the teardown is in the
nxproxy↔nxagent NX back-channel/tunnel and is triggered only when the local X
server is ours (XQuartz works at the same instant). Isolating it needs
**instrumenting nxproxy** (rebuild nxcomp with logging) or running nxproxy
standalone against our server with a controlled peer — a deeper multi-hour
investigation. This is the open blocker; the native endpoint streams initial
content but not the full desktop yet.


## Full-protocol push: extensive but blocked on NX back-channel (definitive trace)

Implemented this round: per-client async writer + output queue (decouple read/
write to kill any I/O deadlock), 1 MB socket buffers, removed per-request stderr
logging, full reply-expecting request set with correct framing
(GetWindowAttributes len-3, QueryKeymap, GetKeyboardControl len-5, GetPointer*,
GetScreenSaver, fallbacks), event delivery (MapNotify/Expose), keymap fix.

Used the bundled nxproxy as a wrapper with `-d 6 -o /tmp/nxproxy.log` to get
nxproxy's own debug trace. Findings (all reproduced, deterministic):
- nxproxy connects to our :77 server fine (FD#8) and reports **no local X
  error** — our protocol is accepted.
- nxagent sends exactly **~2589 bytes** then goes silent; the peer link (FD#6)
  then fails: "Failure reading from descriptors for proxy FD#6", mirrored on the
  server ("...FD#8"). nxcomp HandleShutdown confirms abrupt close, no clean NX
  shutdown.
- nxproxy logs repeated "Going to flush any data to the proxy" but **sends
  nothing back to the peer** — i.e. it never relays our replies/control to
  nxagent, so nxagent times out.
- **Deterministic at 2589 bytes regardless of**: logging removal, 1 MB buffers,
  async writer (no deadlock), full reply set, Map/Expose events, keymap fix, and
  disabling printing/file-sharing in the profile. So it's a protocol/flow-control
  point, not timing or our write path.
- Also discovered the client's local sshd for printing/file-sharing fails
  ("unknown key type dsa") and pops a modal dialog — a real separate bug, but
  not the teardown cause (disabling it didn't change the 2589-byte break).

Conclusion: our hand-written X server is **accepted by nxproxy**, but the
nxproxy↔nxagent NX back-channel doesn't progress (nxproxy isn't relaying to the
peer), so nxagent times out after its initial ~2.6 KB. Why nxproxy doesn't
forward to the peer in agent mode with our server is the open question; isolating
it needs tracing nxcomp's agent-mode read/relay path (ClientChannel/ServerChannel
in nxcomp) — a deeper investigation than this session allows.

Net: native X server proven (handshake + drawing + Metal + real session connects
and renders initial content); a **full streaming desktop is not yet achieved**
and is gated on the NX back-channel issue above.


## Final conclusion (source-informed) — native endpoint hits an NX flow-control wall

Confirmed from nx-libs source (nxcomp/src/Proxy.cpp): NX uses **token flow
control** (control/split/data tokens). nxagent spends data tokens as it sends,
stops at its initial budget (~2.6 KB), and waits for nxproxy to grant more.
nxproxy grants tokens while servicing the peer channel.

With our :77 X server the exchange stalls **deterministically at ~2588 bytes**
and never recovers. Tried (no effect on the 2588 number): per-request log
removal, async writer (no I/O deadlock), 1 MB then 4 MB socket buffers
(macOS ignores SO_RCVBUF on AF_UNIX — pacing stayed 8 KB), full reply surface
with correct framing, Map/Expose events, keymap fix, disabling printing/
file-sharing. nxproxy reports **no local X protocol error**; it simply has
"nothing to flush to the proxy" and the peer link then closes.

Assessment: our hand-written X server is *accepted* by nxproxy at the protocol
level, but driving a real nxagent session to a full desktop requires matching
nxcomp's agent-mode expectations closely enough that its token/relay loop keeps
progressing — effectively implementing a much more complete X server (likely incl.
RENDER, since nxagent uses "alpha channel in render extension") and understanding
the agent-mode channel/token handling. That is genuine multi-session research.

### Bottom line for the native client
- **Achieved & e2e-validated:** native Swift/SwiftUI/**Metal** X server; real X
  clients (xdpyinfo) connect; core drawing renders to Metal (no XQuartz); a real
  X2Go session connects, establishes, and streams initial content (X11 logo).
- **Not achieved:** a full streaming XFCE desktop through the native endpoint —
  blocked by the NX token/flow-control negotiation above.
- **Already works (other path):** the capture-bridge renders the *complete* live
  XFCE desktop in a native Metal window (docs/e2e-native-metal.png); only input
  is missing (XTEST absent on XQuartz 2.8.5 → use 2.8.4 or the native endpoint).


## DEFINITIVE localization (instrumented every layer)

Instrumented the x2goclient's libssh tunnel (sshmasterconnection.cpp channelLoop)
with runtime close-reason logging. Result for the NX data channel
(sock 18, fwd localhost:<nxport>):
  CHANNELCLOSE reason: channel SSH_EOF (remote/nxagent closed)
So **nxagent closes the NX connection first** (the neutral middle — the
x2goclient's forwarder — sees the *remote* end EOF). nxagent's own log confirms:
"Display failure detected" → it gives up on the real X server (us, via nxproxy).

Why: nxagent never receives our X server's replies/events relayed back. nxproxy
logs "Going to flush any data to the proxy" but flushes nothing — it is **not
relaying our X server output back to nxagent**, so nxagent times out
(agent params 5000/...) and declares display failure. Our server is fine and
keeps serving; nxproxy accepts our protocol (no local X error).

Root cause (was thought to be final — **WRONG**, see below): suspected nxcomp's
agent-mode relay loop wasn't forwarding our responses. It actually was; the real
cause was missing X-server capabilities that stalled nxagent's screen init.

## ✅ SOLVED — full native XFCE desktop streams into the Metal X server

The "nxcomp relay won't forward our responses" conclusion was **wrong**. nxcomp/
nxagent were fine; our hand-written X server was **missing capabilities nxagent
requires to finish screen initialization**. Once provided, nxagent maps its
windows and streams the full session. The fix chain:

1. **RENDER extension** — session negotiates `render=1`; nxagent logs "Using
   alpha channel in render extension". With RENDER absent, once GTK apps start
   nxagent's Xlib I/O-errors mirroring RENDER → `nxagentDisplayErrorPredicate`
   sets `ioError` → "Display failure detected". Advertising RENDER (QueryExtension
   present, RenderQueryVersion 0.11, RenderQueryPictFormats RGB24+ARGB32) made
   the session **sustain** (state R, no failure).
2. **QueryColors** — we returned an empty/malformed reply; apps stalled at ~99
   requests. Deriving RGB from the TrueColor pixel unblocked drawing (99 → 162).
3. **Drawable layer** — pixmap-backed buffers + parent-aware window origins +
   CopyArea + RENDER Composite/FillRectangles, so off-screen content blits out.
4. **Core fonts** — ListFonts(fixed/cursor) + OpenFont + QueryFont (6x13) +
   QueryTextExtents. **The final unlock**: without a usable font nxagent can't
   complete screen init, so it never mapped windows or streamed. With fonts:
   op8 MapWindow×28, op1 CreateWindow×101, op72 PutImage×206, CopyArea + RENDER —
   the **full XFCE desktop renders** (~24.7k distinct colors).

Also required: **server-side session hygiene** — leftover xfce/D-Bus processes
from repeated test runs steal the `org.xfce.Panel` dbus name and kill new
sessions ("Another instance took over"). Clean stale xfce/nxagent processes
before each run.

### End state
- ✅ **Native Swift / SwiftUI / Metal X server** (`x2go-xserver`): a real
  nxproxy/nxagent X2Go session against 10.248.1.20 streams the **complete XFCE
  desktop** (Greybird wallpaper + mouse logo, panel with menu/tray/clock,
  Home/File System/Trash icons, readable labels) into a native Metal framebuffer.
  **No XQuartz, no capture-bridge.** See `docs-native-desktop.png`.
- ✅ **Mouse + keyboard input** (`Input.swift`): NSEvents from the Metal window
  → X input events delivered to nxagent's nested window (or active grab window);
  US-layout keymap via GetKeyboardMapping/GetModifierMapping; macOS-vkc → X
  keycode table; buttons, motion, drag, scroll, modifiers. Verified: injected
  events reach nxagent and the apps react (a panel-menu click makes nxagent
  render the applications menu, draw ops 39 → 105). GrabPointer/GrabKeyboard +
  ConfigureWindow(op12) track the input target and popup geometry.
- ✅ **Per-window compositor** (`Compositor.swift`): each window has its own BGRA
  backing surface; the framebuffer is rebuilt by stacking all mapped, drawn
  windows in z-order each frame (ConfigureWindow stack-mode honoured; InputOnly
  and never-drawn wrapper windows skipped). Background redraws no longer clobber
  popups, so menus/dialogs appear and persist. RENDER glyph text +
  CreateSolidFill backgrounds render. `CAMetalDisplayLink` (macOS 14+) drives
  presentation. Clicking the panel opens the Applications menu as a stacked
  window; double/right-click stable.
- ✅ **App windows open and render**: clicking a dock launcher starts the app and
  its window now appears. Key fixes: ReparentWindow (op7) so the dock/panel and
  WM-decorated windows position correctly; VisibilityNotify(Unobscured) on map
  (nxagent skips drawing windows it thinks are obscured — without it app windows
  were created but never drawn); SetSelectionOwner/GetSelectionOwner tracking
  (apps were spinning re-claiming the selection).
- 🔜 Remaining polish: GTK/Qt window **content fidelity** (window frames appear
  but interior is currently sparse for some apps — more RENDER draw-op coverage
  needed); old-style primitives (PolyArc/PolyText/PolyLine); alpha-blended ARGB
  compositing; incremental damage updates.

## Key finding

The "capture from XQuartz + inject into XQuartz" bridge is great for **display**
(read pixels → Metal) but **input injection requires XTEST, which XQuartz 2.8.5
removed**. The correct architecture makes the native app the protocol endpoint
(nxproxy/NX talks to *us*), so input is sent over NX directly with no XQuartz —
which is exactly the no-X11 Phase 3 direction. This bridge proved the entire
native macOS **presentation** layer (Swift 6 / SwiftUI / Metal) end-to-end.
