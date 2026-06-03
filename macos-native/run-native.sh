#!/bin/bash
# Launch the fully-native X2Go client: our Swift/Metal X server holds the window
# and the Qt x2goclient connects to it over DISPLAY=:77. No XQuartz, no bridge.
set -u

DISP=${1:-77}
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
APP="$REPO/build-mac/x2goclient.app/Contents/MacOS/x2goclient"
SERVER=10.248.1.20
KEY=~/.ssh/id_x2go_test

echo ">> building native X server..."
( cd "$HERE" && swift build --product x2go-xserver ) || exit 1
XSRV="$HERE/.build/debug/x2go-xserver"

echo ">> cleaning stale local + server processes..."
pkill -f x2go-xserver 2>/dev/null
pkill -f "x2goclient.app" 2>/dev/null
# Terminate sessions, then loop-kill all desktop/session processes until the
# server is actually clean. Stale xfce/dbus processes from a prior run otherwise
# steal dbus names and the new session never fully establishes (black window).
ssh -o BatchMode=yes -i "$KEY" "thies@$SERVER" '
  for s in $(x2golistsessions 2>/dev/null | cut -d"|" -f2); do x2goterminate-session "$s" >/dev/null 2>&1; done
  P="nxagent|x2goagent|x2goruncommand|dbus-run-session|xfce4|xfdesktop|xfwm4|xfsettingsd|xfconfd|Thunar|x2goresume|at-spi|notifyd|polkit-gnome|gvfsd"
  for i in 1 2 3 4 5; do
    n=$(pgrep -c -u thies -f "$P" 2>/dev/null || echo 0)
    [ "$n" = "0" ] && break
    pkill -9 -u thies -f "$P" 2>/dev/null
    sleep 1
  done
  pkill -9 -u thies -f "dbus-daemon" 2>/dev/null
  sleep 1
  echo "   server clean; remaining desktop procs: $(pgrep -c -u thies -f "$P" 2>/dev/null || echo 0)"
' 2>/dev/null
sleep 2

echo ">> starting native Metal X server on :$DISP (a window will open)..."
echo "   (X server log -> /tmp/x2go-native.log; input events logged there)"
X2GO_INPUTLOG=1 "$XSRV" "$DISP" >/tmp/x2go-native.log 2>&1 &
XPID=$!
sleep 1.5

echo ">> connecting x2goclient -> the session will stream into the Metal window"
DISPLAY=:$DISP "$APP" \
  --session-conf="$HOME/x2go-test-sessions" \
  --session=tubu --add-to-known-hosts --autologin

# When the client exits, stop the X server window too.
kill "$XPID" 2>/dev/null
