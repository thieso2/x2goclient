#!/bin/bash
# Build a FULLY SELF-CONTAINED x2goclient.app that needs NO XQuartz.
#
# It bundles, into a copy of the Qt x2goclient.app:
#   - Xvfb + xkbcomp          (the framebuffer X server) -> Contents/Resources/x11/bin
#   - X2GoNative              (native Metal capture/input/clipboard) -> Contents/exe
#   - the full X11 dylib closure (+ libpng16 for nxproxy) -> Contents/x11libs
#   - minimal fonts + xkb data -> Contents/Resources/x11/{fonts,xkb}
#   - a launcher that starts Xvfb + the Metal window, then runs the Qt client.
# All Mach-O references to /opt/X11 are rewritten to @rpath/@loader_path.
#
# Output: macos-native/dist/x2goclient.app
set -uo pipefail   # not -e: many otool/install_name_tool steps are best-effort

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OPT=/opt/X11
SRC="$REPO/build-mac/x2goclient.app"
OUT="$HERE/dist/x2goclient.app"
C="$OUT/Contents"
LIBS="$C/x11libs"
X11BIN="$C/Resources/x11/bin"
X11FONTS="$C/Resources/x11/fonts"
X11XKB="$C/Resources/x11/xkb"

[ -d "$SRC" ]        || { echo "missing $SRC (build the Qt client first)"; exit 1; }
[ -x "$OPT/bin/Xvfb" ] || { echo "missing $OPT/bin/Xvfb (XQuartz needed to BUILD the bundle)"; exit 1; }

echo ">> building X2GoNative (release, arm64)..."
( cd "$HERE" && swift build -c release --product X2GoNative --arch arm64 ) || { echo "build failed"; exit 1; }
NATIVE_BIN="$HERE/.build/release/X2GoNative"

echo ">> copying $SRC -> $OUT ..."
rm -rf "$OUT"; mkdir -p "$HERE/dist"; cp -R "$SRC" "$OUT"
mkdir -p "$LIBS" "$X11BIN" "$X11FONTS/misc" "$X11XKB" "$C/exe"

cp "$OPT/bin/Xvfb"     "$X11BIN/Xvfb"
cp "$OPT/bin/xkbcomp"  "$X11BIN/xkbcomp"
cp "$NATIVE_BIN"       "$C/exe/X2GoNative"

# --- gather the full /opt/X11 dylib closure into Contents/x11libs ---
echo ">> gathering X11 dylib closure..."
seed_libpng=$(otool -L "$C/exe/nxproxy.real" 2>/dev/null | awk 'NR>1{print $1}' | grep "^$OPT/lib/libpng" | head -1)
[ -n "$seed_libpng" ] && cp "$seed_libpng" "$LIBS/$(basename "$seed_libpng")" 2>/dev/null || true
add_closure() {
  local f="$1"
  otool -L "$f" 2>/dev/null | awk 'NR>1{print $1}' | grep "^$OPT/lib/" | while read -r d; do
    local b; b="$(basename "$d")"
    [ -f "$LIBS/$b" ] || { cp "$d" "$LIBS/$b" 2>/dev/null && chmod u+w "$LIBS/$b"; }
  done
}
for f in "$X11BIN/Xvfb" "$X11BIN/xkbcomp" "$C/exe/X2GoNative"; do add_closure "$f"; done
# fixpoint over the bundled libs (deps of deps)
for _ in 1 2 3 4 5 6; do for d in "$LIBS"/*.dylib; do add_closure "$d"; done; done
echo "   bundled $(ls "$LIBS" | wc -l | tr -d ' ') dylibs"

# --- rewrite install names to be relocatable (@rpath) ---
echo ">> relinking to @rpath..."
chmod -R u+w "$LIBS" "$X11BIN" "$C/exe"
relink() { # rewrite every /opt/X11/lib ref in $1 to @rpath
  local f="$1"
  otool -L "$f" 2>/dev/null | awk 'NR>1{print $1}' | grep "^$OPT/lib/" | while read -r d; do
    install_name_tool -change "$d" "@rpath/$(basename "$d")" "$f" 2>/dev/null || true
  done
}
for d in "$LIBS"/*.dylib; do install_name_tool -id "@rpath/$(basename "$d")" "$d" 2>/dev/null || true; relink "$d"; done
relink "$X11BIN/Xvfb";        install_name_tool -add_rpath "@executable_path/../../../x11libs" "$X11BIN/Xvfb"
relink "$X11BIN/xkbcomp";     install_name_tool -add_rpath "@executable_path/../../../x11libs" "$X11BIN/xkbcomp"
relink "$C/exe/X2GoNative";   install_name_tool -add_rpath "@executable_path/../x11libs" "$C/exe/X2GoNative"
# nxproxy (wrapper + real) + libXcomp use only libpng -> point at the bundled copy
for nx in "$C/exe/nxproxy" "$C/exe/nxproxy.real"; do
  [ -f "$nx" ] || continue
  relink "$nx"; install_name_tool -add_rpath "@executable_path/../x11libs" "$nx" 2>/dev/null || true
done
relink "$C/exe/libXcomp.3.dylib" 2>/dev/null || true

# --- minimal fonts + xkb ---
echo ">> bundling fonts + xkb..."
cp -R "$OPT/share/fonts/misc/." "$X11FONTS/misc/" 2>/dev/null || true
cp -R "$OPT/share/X11/xkb/."    "$X11XKB/"        2>/dev/null || true

# --- launcher: MacOS/x2goclient -> wrapper; real binary -> x2goclient.real ---
echo ">> installing launcher..."
if [ ! -f "$C/MacOS/x2goclient.real" ]; then mv "$C/MacOS/x2goclient" "$C/MacOS/x2goclient.real"; fi
cat > "$C/MacOS/x2goclient" <<'LAUNCH'
#!/bin/bash
# Self-contained launcher: start bundled Xvfb + native Metal window, then the
# Qt client (its nxproxy renders the session onto Xvfb). No XQuartz required.
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"            # .../Contents
BIN="$D/Resources/x11/bin"; FONTS="$D/Resources/x11/fonts/misc"; XKB="$D/Resources/x11/xkb"
DISP=99
while [ -e "/tmp/.X${DISP}-lock" ]; do DISP=$((DISP+1)); done
export XKB_BINDIR="$BIN"
"$BIN/Xvfb" :$DISP -screen 0 1280x800x24 -ac -noreset -fp "$FONTS" -xkbdir "$XKB" \
    >/tmp/x2go-xvfb.log 2>&1 &
XVFB=$!
sleep 1.5
export DISPLAY=:$DISP
"$D/exe/X2GoNative" --display ":$DISP" >/tmp/x2go-native.log 2>&1 &
NATIVE=$!
cleanup() { kill "$NATIVE" "$XVFB" 2>/dev/null; rm -f "/tmp/.X${DISP}-lock"; }
trap cleanup EXIT
"$D/MacOS/x2goclient.real" "$@"
LAUNCH
chmod +x "$C/MacOS/x2goclient"

# --- verify self-contained + sign ---
echo ">> verifying no /opt/X11 references remain in bundled Mach-O..."
LEFT=0
for f in "$X11BIN/Xvfb" "$X11BIN/xkbcomp" "$C/exe/X2GoNative" "$C/exe/nxproxy" "$C/exe/nxproxy.real" "$C/exe/libXcomp.3.dylib" "$LIBS"/*.dylib; do
  [ -f "$f" ] || continue
  n=$(otool -L "$f" 2>/dev/null | awk 'NR>1{print $1}' | grep -c "^$OPT/" || true); LEFT=$((LEFT+n))
done
echo "   remaining /opt/X11 references: $LEFT (want 0)"

# install_name_tool invalidated signatures; re-sign every modified Mach-O
# individually (codesign --deep does NOT cover binaries under Resources/), then
# the whole bundle. On Apple Silicon an invalid signature => instant SIGKILL.
echo ">> codesigning bundled binaries..."
for f in "$LIBS"/*.dylib "$X11BIN/Xvfb" "$X11BIN/xkbcomp" "$C/exe/X2GoNative" \
         "$C/exe/nxproxy" "$C/exe/nxproxy.real" "$C/exe/libXcomp.3.dylib"; do
  [ -f "$f" ] && codesign --force -s - "$f" >/dev/null 2>&1
done
codesign --force --deep -s - "$OUT" >/dev/null 2>&1 || true
echo ">> done: $OUT"
