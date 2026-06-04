# Remove the XQuartz path; macOS is unconditionally native

## Context

On macOS, `getXDisplay()` (`onmainwindow.cpp`) auto-launched **XQuartz** whenever
`DISPLAY` was unset — launching the app via `open -a XQuartz`, waiting for its `:0`
socket, running `xhost +`, and pointing nxproxy at XQuartz's `~/.serverauth.<pid>`
cookie. With the native per-session Xvfb + viewer ([[0001-per-session-xvfb-and-viewer]])
this becomes a second, redundant display path and a heavy external dependency.

## Decision

macOS has exactly **one** display path: the per-session Xvfb + viewer.
`getXDisplay()` returns the session's private display (`:N`); the XQuartz launch,
`xhost +`, and serverauth-cookie logic are removed, along with the
`X2GO_NATIVE_METAL` gate flag that briefly existed to choose between paths. There
is nothing left to gate. The Xvfb binary is resolved bundle-first
(`Contents/Resources/x11/bin/Xvfb`) with a `/opt/X11/bin/Xvfb` fallback for raw
dev builds.

## Consequences

- No fallback if the native path regresses — the native display becomes
  load-bearing on macOS.
- No external XQuartz install required for end users; one code path to maintain.
- Removes the `Q_OS_DARWIN` XQuartz branch and its auth-cookie handling from the
  nxproxy setup.
