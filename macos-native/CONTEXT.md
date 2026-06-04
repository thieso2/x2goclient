# Native macOS display (x2goclient ↔ viewer)

The macOS display path on the `macos-native-metal` branch: how the Qt client
presents a remote X2Go session as a native Metal window, with no XQuartz.
See `docs/adr/` for the decisions behind it.

## Language

**Viewer**:
The native macOS display application (`X2GoNative`) — a SwiftUI/Metal window that
presents one session display's framebuffer and forwards macOS input into it. One
viewer per connection.
_Avoid_: window, X2GoNative (in prose), Metal client

**x2goclient**:
The Qt client (`x2goclient.real`) that orchestrates the connection and owns the
lifecycle of each session display and viewer.
_Avoid_: the app, the client, x2goapp

**Session display**:
A private, headless X server (`Xvfb`) that one connection renders into via
nxproxy. Its root size equals the session geometry; a mismatch corrupts the
nxproxy replay. One per connection.
_Avoid_: X server, Xvfb (in prose), display

**Connection**:
One active X2Go session started in x2goclient. Single concurrent connection
today; the per-connection shape is what makes multiple possible later.
_Avoid_: session (when the local trio is meant), tab

**Session geometry**:
The pixel size the remote session renders at, resolved by x2goclient from the
connection's profile (explicit `WxH`, or the Mac screen's logical points for
`fullscreen`/`maxdim`). May exceed the Mac screen, in which case the viewer
scales and/or scrolls.
_Avoid_: resolution, screen size, window size
