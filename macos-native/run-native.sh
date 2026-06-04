#!/bin/bash
# DEPRECATED dev harness. The shipped app now self-manages everything:
# x2goclient starts a per-session Xvfb sized to the session geometry, launches
# the X2GoNative viewer for it, and tears both down with the session (see
# docs/adr/0001, 0002 + IMPLEMENTATION-viewer-lifecycle.md). To run the real
# flow just launch the bundle:
#   dist/x2goclient.app/Contents/MacOS/x2goclient \
#     --session-conf="$HOME/x2go-test-sessions" --session=tubu \
#     --add-to-known-hosts --autologin
# This script remains only as a manual Xvfb+capture sandbox for the OLD flow.
#
# Native X2Go client via embedded Xvfb (real, complete X server) + Metal.
#   Xvfb :99  <-- x2goclient/nxproxy renders the session here
#   X2GoNative captures Xvfb's root into a Metal window and injects input (XTEST)
set -u

DISP=${1:-99}
W=${W:-1280}; H=${H:-800}
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
APP="$REPO/build-mac/x2goclient.app/Contents/MacOS/x2goclient"
XVFB=/opt/X11/bin/Xvfb
SERVER=10.248.1.20
KEY=~/.ssh/id_x2go_test

[ -x "$XVFB" ] || { echo "Xvfb not found at $XVFB (install XQuartz)"; exit 1; }

echo ">> building native bridge..."
( cd "$HERE" && swift build --product X2GoNative ) || exit 1
NATIVE="$HERE/.build/debug/X2GoNative"

echo ">> cleaning local + server..."
pkill -f "Xvfb :$DISP" 2>/dev/null
pkill -f "X2GoNative" 2>/dev/null
pkill -f "x2goclient.app" 2>/dev/null
ssh -o BatchMode=yes -i "$KEY" "thies@$SERVER" '
  for s in $(x2golistsessions 2>/dev/null|cut -d"|" -f2); do x2goterminate-session "$s">/dev/null 2>&1; done
  P="nxagent|x2goagent|x2goruncommand|dbus|xfce|xfdesktop|xfwm4|xfsettingsd|Thunar|x2goresume"
  for i in 1 2 3 4 5; do n=$(pgrep -c -u thies -f "$P" 2>/dev/null||echo 0); [ "$n" = 0 ] && break; pkill -9 -u thies -f "$P" 2>/dev/null; sleep 1; done
  printf "TerminalEmulator=xfce4-terminal\nFileManager=Thunar\n" > ~/.config/xfce4/helpers.rc
' 2>/dev/null
sleep 2

echo ">> starting Xvfb :$DISP ($W x $H x24)..."
rm -f /tmp/.X${DISP}-lock /tmp/.X11-unix/X${DISP} 2>/dev/null
"$XVFB" :$DISP -screen 0 ${W}x${H}x24 -ac -noreset >/tmp/xvfb.log 2>&1 &
XVFB_PID=$!
sleep 2

# Match the X keyboard layout to the macOS layout BEFORE connecting: nxagent
# copies the client (Xvfb) keymap at session start, and runs "keycode conversion
# off" (so only that keymap matters). This is what makes öäüß etc. type.
maclayout=$(defaults read ~/Library/Preferences/com.apple.HIToolbox.plist AppleCurrentKeyboardLayoutInputSourceID 2>/dev/null)
case "$maclayout" in
  *German*)     XKB="de";;   *Swiss*)      XKB="ch";;
  *British*)    XKB="gb";;   *French*)     XKB="fr";;
  *Spanish*)    XKB="es";;   *Italian*)    XKB="it";;
  *Portuguese*) XKB="pt";;   *Dutch*)      XKB="nl";;
  *Norwegian*)  XKB="no";;   *Swedish*)    XKB="se";;
  *Danish*)     XKB="dk";;   *Finnish*)    XKB="fi";;
  *) XKB="us";;
esac
echo ">> setting X keyboard layout to '$XKB' (macOS: ${maclayout:-unknown})"
DISPLAY=:$DISP /opt/X11/bin/setxkbmap "$XKB" 2>/dev/null

echo ">> connecting x2goclient (DISPLAY=:$DISP) — renders the session onto Xvfb"
DISPLAY=:$DISP "$APP" \
  --session-conf="$HOME/x2go-test-sessions" \
  --session=tubu --add-to-known-hosts --autologin >/tmp/qt-xvfb.log 2>&1 &
CLI_PID=$!

echo ">> opening native Metal window (captures Xvfb :$DISP, XTEST input)"
"$NATIVE" --display ":$DISP"

# teardown when the native window closes
kill "$CLI_PID" "$XVFB_PID" 2>/dev/null
pkill -f "x2goclient.app" 2>/dev/null
