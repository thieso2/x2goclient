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
ssh -o BatchMode=yes -i "$KEY" "thies@$SERVER" '
  for s in $(x2golistsessions|cut -d"|" -f2); do x2goterminate-session "$s" >/dev/null 2>&1; done
  sleep 1
  pkill -9 -u thies -f "nxagent|x2goagent|x2goruncommand|dbus-run-session|xfce4|xfdesktop|xfwm4|xfsettingsd|x2goresume" 2>/dev/null
  sleep 2
' 2>/dev/null
sleep 3

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
