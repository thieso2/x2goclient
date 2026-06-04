# x2goclient owns a per-session Xvfb + viewer

## Context

Originally `launcher.c` started **one** shared Xvfb sized to the Mac screen and
**autostarted one** viewer before any session existed, forcing every session to
fullscreen so its geometry matched that fixed Xvfb root (a mismatch corrupts the
nxproxy replay). That made it impossible to honor a session's own geometry, to
present a session larger than the screen, or to support more than one connection.

## Decision

The Qt client (`x2goclient`), not `launcher.c`, owns the display lifecycle. On
connect it resolves the session geometry, starts a **session display** (a private
Xvfb at that exact size), points that connection's nxproxy at it, and launches a
dedicated **viewer** (`X2GoNative`) for it. The viewer launches as soon as the
Xvfb is up. The launcher is reduced to `execv(x2goclient.real)`.

The same concrete `WxH` is used for both the Xvfb `-screen` and the nxagent
session geometry, so they always match. `fullscreen`/`maxdim` profiles resolve to
the Mac screen's logical points; explicit `WxH` is used verbatim and may exceed
the screen (the viewer scales/scrolls).

## Considered Options

- **Keep the shared Xvfb and resize it via RANDR** — smaller change but inherently
  single-display and exposes live-RANDR edge cases.
- **Keep `X2GO_FORCE_FULLSCREEN`** — can't present a session at its own (or a
  larger-than-screen) geometry, so the scaling/scrollbar feature is moot.

## Consequences

- **Lifecycle is bound both ways.** Closing the viewer (clean exit) **suspends**
  the session (resumable). An unexpected viewer exit while the session is still up
  **relaunches** the viewer on the same Xvfb (cap ~3 retries / 10s). Stopping the
  session (suspend/terminate/crash, via `slotProxyFinished`) **kills the viewer**.
  To avoid a suspend-loop, the viewer's `finished` signal is disconnected before
  the client kills it.
- **Encapsulated for multi-session.** The trio (display number + Xvfb + viewer +
  geometry) lives in one `SessionDisplay` unit. Single concurrent connection today;
  multi-session later becomes a `QMap<SessionId, SessionDisplay>` rather than a
  rewrite.
- A `fullscreen` profile makes the viewer enter true macOS fullscreen (passed as a
  `--fullscreen` hint); `maxdim`/`WxH` open a normal resizable window.
