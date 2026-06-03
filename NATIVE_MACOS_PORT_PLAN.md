# Native macOS Port — Plan

> Goal (decided): a **fully native macOS client** — SwiftUI/AppKit UI on top of a
> native connection engine, rendering remote windows directly as Cocoa surfaces,
> with **zero X11 / no XQuartz**.
> Targets: **Apple Silicon first**, universal2 (arm64 + x86_64), **macOS 12+**.

This is the most ambitious of the options we discussed. It is, realistically, a
multi-quarter effort because it ends in replacing the local X server with native
code. The plan below is structured to **de-risk early, ship something native-feeling
fast, and defer the hardest piece (native display) until its scope is proven** — so
we are never one giant leap away from a usable build.

---

## 1. How X2Go works today (and where macOS hurts)

The client is three concerns fused into a 25k-line Qt 4 app (`onmainwindow.cpp`
alone is 12.5k lines):

```
┌─────────────────────────────────────────────────────────────┐
│  x2goclient (Qt4 widgets)                                     │
│                                                               │
│  ① Session manager UI      ② Session orchestration           │
│     - session list/profiles   - SSH master conn (libssh)      │
│     - settings, broker, LDAP  - x2gostartagent over SSH       │
│     - printing/sharing UI     - tunnels, sftp, sound, print   │
│                                                               │
│                            ③ Display pipeline                 │
│                               - launches `nxproxy`            │
│                               - nxproxy = NX decoder          │
│                                 → talks X11 to DISPLAY        │
└─────────────────────────────────────────────────────────────┘
                                     │  X11 protocol
                                     ▼
                            ┌──────────────────┐
                            │  XQuartz (X11)   │  ← the macOS pain
                            │  renders windows │
                            └──────────────────┘
```

Server side runs `x2goagent` (an `nxagent`, i.e. an X server that compresses the X
protocol into **NX**). Over an SSH tunnel, the client's **`nxproxy`** decompresses
NX back into the **X11 wire protocol** and **connects as an X client** to the local
`DISPLAY`, replaying all drawing. On Linux that DISPLAY is the user's X server; on
macOS it is **XQuartz**.

**The exact seam (verified in code):**
- `onmainwindow.cpp:5491` builds `nxproxy -S nx/nx,options=<dir>/options:<display>`
  and launches it with `DISPLAY` pointing at the local X server
  (`getXDisplay()`, the `Q_OS_DARWIN` branch at `onmainwindow.cpp:8977`).
- `getXDisplay()` today locates/launches **XQuartz** and returns its socket.
- The UI uses Qt4-only X11 APIs: `QX11EmbedContainer` (`onmainwindow.h:1223`),
  `QX11Info`, `Q_WS_*` — present in **17 files**. These were **removed in Qt5/6**,
  so "just upgrade Qt" is not available to us.

**Why the current macOS build is unshippable today:**
- Qt **4** (EOL), qmake-only, no CMake.
- Built against **MacPorts**, deployment target **10.7**.
- **No code signing / notarization** → Gatekeeper blocks it on modern macOS.
- Hard dependency on **XQuartz** (a separate, heavy, un-native install).

### The single most important architectural fact
Everything the user sees of the *remote session* is X11 windows drawn by `nxproxy`
into a local X server. **"Native display" means replacing that local X server with a
Cocoa-backed one.** The UI rewrite is large but routine; the display engine is the
real research risk. The whole plan is sequenced around that.

---

## 2. Target architecture

```
┌──────────────────────────────────────────────────────────┐
│  X2Go.app  (Swift / SwiftUI + AppKit)                      │
│                                                            │
│  UI layer (new, native)                                    │
│   - SessionManager, Settings, Broker, Printing views       │
│       │  Swift  ↔  C/C++ bridge                            │
│  Engine layer (extracted from Qt, kept as C++/C library)   │
│   - SSH master connection (libssh)                         │
│   - session start/resume orchestration (x2gostartagent)    │
│   - tunnels, sftp, sound, printing, folder sharing         │
│       │ launches + feeds                                   │
│  Display layer (the hard part)                             │
│   - nxproxy (kept: NX codec)                               │
│        │ X11 wire protocol over private socket             │
│   - NATIVE X SERVER CORE  ──renders──►  NSWindows / Metal  │
│        (rootless: 1 remote window → 1 NSWindow)            │
└──────────────────────────────────────────────────────────┘
            no XQuartz · no MacPorts · signed · universal2
```

**Keep `nxproxy`.** It is the NX codec — decades of intricate compression work.
Rewriting it buys nothing for "native feel" and is enormous. We keep it as a bundled
helper and instead replace **what it draws into**.

**Two viable routes for the native X server** (decide via Spike A, §6):

- **Route A — Fork a tiny X server + Cocoa backend (recommended, pragmatic).**
  Reuse an existing MIT/BSD-licensed X server core (`kdrive`/`Xephyr`, or the
  **XQuartz rootless `xpr`/`miext` layer itself**, which already does X11→Cocoa) and
  swap its backend to render directly into our app's NSWindows/Metal, stripped of
  launchd/standalone/CLI baggage and embedded app-private. XQuartz proves the
  rootless X11→Cocoa mapping works; we are productizing and embedding it, not
  inventing it.

- **Route B — Write a minimal X server from scratch in Swift/C++.** Purist, fully
  owned, but you re-implement core X11 + likely **RENDER** (Xrender, used heavily by
  GTK/Qt apps), keyboard (XKB), and RANDR. Much larger; only justified if Route A's
  licensing/maintenance proves untenable.

Either way the integration point is identical: **`nxproxy` connects to a private
display socket we own**, and we composite its drawing into Cocoa.

---

## 3. Strategy: de-risk, then ship in layers

We do **not** attempt the native display first. We get a signed, native-shell build
that still uses a bundled X server working end-to-end, then replace the X server last.
Each phase produces a usable artifact.

| Phase | Outcome a user can run | Native display? | XQuartz needed? |
|------:|------------------------|:---------------:|:---------------:|
| 0 | Modern build/CI/signing of *today's* app | no | yes (external) |
| 1 | Engine extracted from Qt, headless-testable | n/a | n/a |
| 2 | **SwiftUI shell** drives engine; sessions still via bundled X server | no | **no (bundled)** |
| 3 | **Native X server core** renders sessions into Cocoa | **yes** | **no** |
| 4 | Native polish: rootless, clipboard, HiDPI, multi-mon, sound, print | yes | no |

After **Phase 2** you already have a native-looking app that needs no external
XQuartz — that alone resolves most "it's not native" complaints and is a shippable
beta. Phase 3 is the moonshot.

---

## 4. Phases in detail

### Phase 0 — Foundations (make *today's* code buildable & shippable) — ✅ DONE
*De-risk the toolchain before touching architecture.*
- Replace MacPorts assumptions; pin dependencies reproducibly (vcpkg/Homebrew-in-CI or vendored).
- Add **CMake** alongside qmake (don't fight qmake long-term).
- Get an **arm64** build, raise deployment target to **12.0**, drop 10.4/10.7 compat branches (e.g. the 10.4 paths in `getXDisplay()`).
- **Code signing + notarization + hardened runtime**; produce a Gatekeeper-clean DMG.
- Stand up **CI** (GitHub Actions macOS runners) building + signing on every push.
- *Deliverable:* the current Qt app, signed, running on an M-series Mac with XQuartz.
- *Why first:* signing/notarization/CI are needed by every later phase; prove them on the known-good app.

**Outcome / decisions made during Phase 0:**
- **New Qt was required, and it was feasible.** Qt4 has no Apple Silicon support, so
  modern Qt is a *prerequisite* for an arm64/signable build — not a later concern.
  Crucially, the **macOS code path never used the Qt4-only X11 APIs**
  (`QX11EmbedContainer`/`QX11Info` are all `#ifdef Q_OS_LINUX`), so the port to **Qt6**
  was mechanical, not architectural. **Done:** the app now compiles, links, bundles,
  ad-hoc signs, and launches on Qt 6.11 / arm64 / macOS 12+.
- **arm64-only** for now (Homebrew Qt is single-arch). `CMAKE_OSX_ARCHITECTURES` is a
  switch; universal2 just needs a universal Qt later.
- New files: `CMakeLists.txt`, `cmake/Info.plist.in`, `src/qdesktopwidget_compat.h`
  (a `QScreen`-backed shim for the removed `QDesktopWidget`, keeping ~30 call sites
  untouched since the Qt UI is replaced in Phase 2), `.github/workflows/macos.yml`
  (build + optional Developer-ID sign/notarize), `BUILD.macOS.md`.
- The full list of Qt4→Qt6 fixes is in `BUILD.macOS.md`. Distribution signing +
  notarization are scaffolded in CI and gated on repo secrets (need an Apple
  Developer account to actually run).

### Phase 1 — Extract the engine from the UI
*Turn the monolith into a UI-agnostic library so the Swift app and tests can drive it.*
- Carve a **C/C++ engine library** out of `onmainwindow.cpp`: SSH master connection
  (`sshmasterconnection.*`), session start/resume, tunnels, `sshprocess`, broker
  (`httpbrokerclient`), settings (`x2gosettings`), printing/sharing orchestration.
  These are already mostly Qt-Core (not GUI) — the main job is severing `QWidget`/
  `QX11*` dependencies and defining a clean callback/event interface.
- Define the **engine ↔ UI boundary** as a small C-ABI or Obj-C++ surface (sessions,
  state changes, auth prompts, progress, errors).
- Add **headless integration tests** that connect to a test X2Go server and start/stop
  a session with no UI — this becomes the regression net for everything after.
- *Deliverable:* `libx2goengine` + a CLI/test harness that connects and runs a session
  (rendered via a throwaway X server for now).
- *Risk:* hidden GUI coupling inside the 12.5k-line file. Mitigation: incremental
  extraction behind the test harness.

### Phase 2 — Native SwiftUI shell over the engine (still bundled X server)
*Ship a native-feeling app that needs no external XQuartz.*
- Build the **SwiftUI/AppKit app**: session manager, profile editor, settings, broker
  login, key/agent handling, printing & sharing UI — replacing the Qt widgets 1:1 in
  capability.
- Bridge Swift ↔ `libx2goengine` (Obj-C++ shim).
- **Bundle a private X server** (the stripped fork from Route A, headless for now /
  or even a bundled Xvfb-style server) inside the `.app`; rewrite `getXDisplay()`'s
  job natively so `nxproxy` targets *our* bundled server — **kill the XQuartz
  dependency** even before native rendering exists.
- *Deliverable:* a signed, native-UI app. No MacPorts, no external XQuartz. Sessions
  display via the bundled X server. **This is the first public beta.**
- *Note:* display is "bundled X" not "native Cocoa" yet — acceptable interim, invisible
  to users who just didn't want to install XQuartz.

### Phase 3 — Native display engine (the moonshot)
*Replace the bundled X server's backend with Cocoa rendering.*
- Run **Spike A/B/C** (§6) first; choose Route A vs B.
- Implement the **Cocoa backend**: X drawables → Metal textures / `CALayer`s;
  present remote top-level windows as **NSWindows** (rootless) or one NSView
  (rooted/fullscreen, mirrors the existing `xorgMode` FS/SAPP/WIN/MULTIDISPLAY modes).
- **Input injection**: translate Cocoa key/mouse/scroll/trackpad events into X input
  events back through the server core (keymap/XKB mapping is fiddly — budget for it).
- Wire `nxproxy` to the in-process/private-socket server; remove the external X server.
- *Deliverable:* sessions render as native windows; XQuartz/X11 fully gone.
- *Risk (highest in the project):* the **RENDER (Xrender) subset** and keymap
  fidelity. Scope is bounded by what `nxagent` actually emits — pin it down in Spike A.

### Phase 4 — Native polish & parity
- **Rootless** integration: per-window NSWindows, native shadows/min/zoom, Mission
  Control/Spaces behaviour, menubar handling.
- **HiDPI/Retina** scaling and live **RANDR** resize (resize the NSWindow → reconfigure
  the remote display).
- **Multi-monitor**, **clipboard** sync (X selections ↔ NSPasteboard), **drag-and-drop**.
- Native **sound** (replace pulseaudio plumbing where sensible), **printing** (CUPS is
  native on macOS already), **folder sharing** (sshfs/macFUSE or an SFTP-native path).
- Accessibility, localization (port the existing `.ts` translations), auto-update.

---

## 5. Component disposition (keep / rewrite / replace)

| Component | Today | Plan |
|-----------|-------|------|
| Session manager / settings / broker UI | Qt4 widgets | **Rewrite** in SwiftUI/AppKit (Phase 2) |
| SSH master connection | `sshmasterconnection.cpp` (libssh) | **Keep** — move into engine lib (Phase 1) |
| Session start/resume orchestration | inside `onmainwindow.cpp` | **Extract** into engine lib (Phase 1) |
| Broker (HTTP/SSH), LDAP | `httpbrokerclient`, `LDAPSession` | **Keep** in engine; native UI on top |
| Settings store | `x2gosettings` (QSettings) | **Keep** initially; optionally native `UserDefaults` later |
| NX codec | `nxproxy` (external bin) | **Keep**, bundle as helper |
| Local X server / display | **XQuartz (external)** | **Replace** with native Cocoa-backed X core (Phase 3) |
| Window embedding | `QX11EmbedContainer` (Qt4-only) | **Replace** with NSWindow/NSView rootless mapping |
| Printing | CUPS | **Keep** (already native on macOS) |
| Sound | pulseaudio plumbing | **Keep**, then nativize in Phase 4 |
| Folder sharing | sshfs | **Keep**, revisit (macFUSE/SFTP) in Phase 4 |
| Build | qmake + MacPorts + macbuild.sh | **Replace** with CMake + reproducible deps + signed CI |

---

## 6. Spikes to run *before* committing to Phase 3

These are small, time-boxed investigations that retire the biggest unknowns. Do them
during Phases 0–2 so Phase 3 is planning, not gambling.

- **Spike A — Protocol surface capture (most important).** Run a real GTK and a real
  KDE/Qt session through `nxproxy` against XQuartz and **trace the exact X11 requests
  and extensions** it emits (which RENDER ops, XKB, RANDR, SHM?). This precisely scopes
  the X server subset we must implement and decides Route A vs B. *Without this, Phase 3
  is unbounded.*
- **Spike B — Reuse vs rewrite.** Prototype embedding a stripped `kdrive`/Xephyr (or the
  XQuartz rootless layer) with a trivial Cocoa backend drawing one window. Validates
  Route A's licensing, build, and embedding feasibility.
- **Spike C — Engine severability.** Attempt to compile `sshmasterconnection` + session
  start path **without any Qt GUI** linked. Measures Phase 1 effort.
- **Spike D — Signing/notarization of a bundled helper + private X socket** sandboxing
  (does the hardened runtime / app sandbox permit our IPC and helper exec?).

---

## 7. Risks & unknowns

- **RENDER (Xrender) fidelity** — modern toolkits lean on it; this is the long pole of
  Phase 3. Bounded by Spike A.
- **Keyboard/XKB mapping** — international layouts, modifiers, dead keys. Historically
  fiddly in X-on-Mac; budget real time.
- **License hygiene** if forking an X server (X.Org is MIT; verify every reused file).
  The repo already carries an OpenSSL exception — keep license discipline.
- **Engine extraction surprises** — coupling hidden in a 12.5k-line file. The headless
  test harness (Phase 1) is the safety net.
- **Scope creep into a general X server** — we only need `nxagent`'s subset. Hold that
  line via Spike A's captured trace as the conformance target.
- **Maintaining the Linux/Windows builds** in parallel — keep the engine cross-platform;
  only the UI + display layers fork per-OS.

---

## 8. Recommended immediate next steps

1. **Phase 0 kickoff:** stand up CMake + signed/notarized universal2 CI for the
   *existing* app (proves the toolchain end-to-end on Apple Silicon).
2. **Run Spike C** (compile the SSH/session engine with no Qt GUI) to size Phase 1.
3. **Run Spike A** (capture the real X11 protocol trace from a live session) to size
   Phase 3 — this is the number that determines whether "full native display" is a
   quarter or a year.
4. Reconvene on Spike A/C results to lock the Phase 1 boundary and the Route A vs B
   decision before writing the SwiftUI shell.

---

### One honest note on scale
"Full native including display" is genuinely large — it ends in shipping a Cocoa-backed
X server. The structure above means you are **never far from a working build**: a signed
modern app at Phase 0, an XQuartz-free native-UI beta at Phase 2, and the native-display
moonshot isolated in Phase 3 where its risk is contained and pre-scoped by spikes. If
priorities shift, **Phase 2 is a perfectly respectable place to ship** and revisit the
native display engine later.
