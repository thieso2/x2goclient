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
#
# Distribution (give the app to others):
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=x2go-notary \           # from: xcrun notarytool store-credentials
#       ./build-app.sh
#   (or AC_APPLE_ID=… AC_TEAM_ID=… AC_PASSWORD=… instead of NOTARY_PROFILE)
# With no SIGN_ID it builds an ad-hoc bundle that runs only on this machine.
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

cp "$OPT/bin/Xvfb"      "$X11BIN/Xvfb"
cp "$OPT/bin/xkbcomp"   "$X11BIN/xkbcomp"
cp "$OPT/bin/setxkbmap" "$X11BIN/setxkbmap"   # to match the macOS keyboard layout
cp "$NATIVE_BIN"        "$C/exe/X2GoNative"

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
for f in "$X11BIN/Xvfb" "$X11BIN/xkbcomp" "$X11BIN/setxkbmap" "$C/exe/X2GoNative"; do add_closure "$f"; done
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
relink "$X11BIN/setxkbmap";  install_name_tool -add_rpath "@executable_path/../../../x11libs" "$X11BIN/setxkbmap"
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

# --- launcher: compiled Mach-O main executable (needed for hardened runtime /
#     notarization). Real Qt binary -> x2goclient.real. ---
echo ">> compiling launcher..."
if [ ! -f "$C/MacOS/x2goclient.real" ]; then mv "$C/MacOS/x2goclient" "$C/MacOS/x2goclient.real"; fi
clang -arch arm64 -O2 "$HERE/launcher.c" -o "$C/MacOS/x2goclient" || { echo "launcher build failed"; exit 1; }

# --- verify self-contained + sign ---
echo ">> verifying no /opt/X11 references remain in bundled Mach-O..."
LEFT=0
for f in "$X11BIN/Xvfb" "$X11BIN/xkbcomp" "$C/exe/X2GoNative" "$C/exe/nxproxy" "$C/exe/nxproxy.real" "$C/exe/libXcomp.3.dylib" "$LIBS"/*.dylib; do
  [ -f "$f" ] || continue
  n=$(otool -L "$f" 2>/dev/null | awk 'NR>1{print $1}' | grep -c "^$OPT/" || true); LEFT=$((LEFT+n))
done
echo "   remaining /opt/X11 references: $LEFT (want 0)"

# --- codesign (+ optional notarize) ---
# Set SIGN_ID="Developer ID Application: Name (TEAMID)" to sign for distribution.
# Also set NOTARY_PROFILE (a `notarytool store-credentials` profile) OR
# AC_APPLE_ID + AC_TEAM_ID + AC_PASSWORD to notarize + staple.
# With SIGN_ID unset, falls back to ad-hoc (runs locally only).
SIGN_ID="${SIGN_ID:-}"
ENT="$HERE/entitlements.plist"
if [ -n "$SIGN_ID" ]; then
  echo ">> codesigning with '$SIGN_ID' (hardened runtime + timestamp)..."
  SIGN=(codesign --force --options runtime --timestamp --entitlements "$ENT" -s "$SIGN_ID")
else
  echo ">> codesigning ad-hoc (no SIGN_ID set => NOT distributable/notarizable)..."
  SIGN=(codesign --force -s -)
fi
# Sign inner Mach-O first (deep doesn't cover Resources/), then nested apps/frameworks, then the bundle.
while IFS= read -r f; do "${SIGN[@]}" "$f" >/dev/null 2>&1; done < <(
  find "$OUT" -type f \( -name '*.dylib' -o -path '*/Resources/x11/bin/*' -o -path '*/Contents/exe/*' \) 2>/dev/null
)
[ -f "$C/MacOS/x2goclient.real" ] && "${SIGN[@]}" "$C/MacOS/x2goclient.real" >/dev/null 2>&1
"${SIGN[@]}" "$C/MacOS/x2goclient" >/dev/null 2>&1            # the launcher (carries entitlements)
if [ -n "$SIGN_ID" ]; then codesign --force --deep --options runtime --timestamp --entitlements "$ENT" -s "$SIGN_ID" "$OUT" >/dev/null 2>&1
else codesign --force --deep -s - "$OUT" >/dev/null 2>&1; fi

# --- notarize + staple ---
if [ -n "$SIGN_ID" ] && { [ -n "${NOTARY_PROFILE:-}" ] || [ -n "${AC_APPLE_ID:-}" ]; }; then
  echo ">> notarizing (this can take a few minutes)..."
  ZIP="$HERE/dist/x2goclient.zip"; rm -f "$ZIP"
  ditto -c -k --keepParent "$OUT" "$ZIP"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$ZIP" --apple-id "$AC_APPLE_ID" --team-id "$AC_TEAM_ID" --password "$AC_PASSWORD" --wait
  fi
  echo ">> stapling ticket..."
  xcrun stapler staple "$OUT" && xcrun stapler validate "$OUT"
  rm -f "$ZIP"
  echo ">> notarized + stapled — give $OUT to anyone."
elif [ -n "$SIGN_ID" ]; then
  echo ">> signed with Developer ID but NOT notarized (set NOTARY_PROFILE to notarize)."
fi
echo ">> done: $OUT"
