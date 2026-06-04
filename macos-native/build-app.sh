#!/bin/bash
# Build a FULLY SELF-CONTAINED, Qt-free X2Go.app from the SwiftUI app target.
#
# Bundles, into a fresh .app skeleton around Contents/MacOS/X2GoApp:
#   - Xvfb + xkbcomp + setxkbmap        -> Contents/Resources/x11/bin
#   - nxproxy (+ .real) + libXcomp      -> Contents/exe   (NX codec; the only C)
#   - the full /opt dylib closure        -> Contents/x11libs   (X11 + jpeg/zlib/png)
#   - minimal fonts + xkb data           -> Contents/Resources/x11/{fonts,xkb}
# All /opt Mach-O references are rewritten to @rpath. Asserts the bundle has
# ZERO /opt refs and ZERO Qt (no Qt*.framework, no Qt* linkage).
#
# Output: macos-native/dist/X2Go.app
#   SIGN_ID="Developer ID Application: …" NOTARY_PROFILE=… ./build-app.sh  (distribute)
#   (no SIGN_ID -> ad-hoc, runs on this machine only)
set -uo pipefail   # not -e: many install_name_tool steps are best-effort

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OPT=/opt/X11
NXSRC="$REPO/build-mac/x2goclient.app/Contents/exe"   # working nxproxy + libXcomp
OUT="$HERE/dist/X2Go.app"
C="$OUT/Contents"
LIBS="$C/x11libs"
X11BIN="$C/Resources/x11/bin"
X11FONTS="$C/Resources/x11/fonts"
X11XKB="$C/Resources/x11/xkb"

[ -x "$OPT/bin/Xvfb" ] || { echo "missing $OPT/bin/Xvfb (XQuartz needed to BUILD the bundle)"; exit 1; }
[ -f "$NXSRC/nxproxy" ] || { echo "missing nxproxy at $NXSRC"; exit 1; }

echo ">> building X2GoApp (release, arm64)..."
( cd "$HERE" && swift build -c release --product X2GoApp --arch arm64 ) || { echo "build failed"; exit 1; }
APP_BIN="$HERE/.build/release/X2GoApp"

echo ">> scaffolding $OUT ..."
rm -rf "$OUT"
mkdir -p "$C/MacOS" "$LIBS" "$X11BIN" "$X11FONTS/misc" "$X11XKB" "$C/exe" "$C/Resources"
cp "$APP_BIN" "$C/MacOS/X2GoApp"

cat > "$C/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>X2Go</string>
  <key>CFBundleDisplayName</key><string>X2Go</string>
  <key>CFBundleIdentifier</key><string>org.x2go.X2GoMac</string>
  <key>CFBundleExecutable</key><string>X2GoApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

cp "$OPT/bin/Xvfb"      "$X11BIN/Xvfb"
cp "$OPT/bin/xkbcomp"   "$X11BIN/xkbcomp"
cp "$OPT/bin/setxkbmap" "$X11BIN/setxkbmap"
cp "$NXSRC/nxproxy"      "$C/exe/nxproxy"
[ -f "$NXSRC/nxproxy.real" ] && cp "$NXSRC/nxproxy.real" "$C/exe/nxproxy.real"
[ -f "$NXSRC/libXcomp.3.dylib" ] && cp "$NXSRC/libXcomp.3.dylib" "$C/exe/libXcomp.3.dylib"
[ -f "$NXSRC/nxauth" ] && cp "$NXSRC/nxauth" "$C/exe/nxauth"

# --- gather the full /opt dylib closure (X11 + homebrew jpeg/zlib/png) ---
echo ">> gathering dylib closure..."
add_closure() {
  otool -L "$1" 2>/dev/null | awk 'NR>1{print $1}' | grep "^/opt/" | while read -r d; do
    b="$(basename "$d")"
    [ -f "$LIBS/$b" ] || { cp "$d" "$LIBS/$b" 2>/dev/null && chmod u+w "$LIBS/$b"; }
  done
}
for f in "$X11BIN/Xvfb" "$X11BIN/xkbcomp" "$X11BIN/setxkbmap" "$C/MacOS/X2GoApp" \
         "$C/exe/nxproxy" "$C/exe/nxproxy.real" "$C/exe/libXcomp.3.dylib" "$C/exe/nxauth"; do
  [ -f "$f" ] && add_closure "$f"
done
for _ in 1 2 3 4 5 6 7 8; do for d in "$LIBS"/*.dylib; do [ -f "$d" ] && add_closure "$d"; done; done
echo "   bundled $(ls "$LIBS" 2>/dev/null | wc -l | tr -d ' ') dylibs"

# --- rewrite install names to @rpath ---
echo ">> relinking to @rpath..."
chmod -R u+w "$LIBS" "$X11BIN" "$C/exe" "$C/MacOS"
relink() {
  otool -L "$1" 2>/dev/null | awk 'NR>1{print $1}' | grep "^/opt/" | while read -r d; do
    install_name_tool -change "$d" "@rpath/$(basename "$d")" "$1" 2>/dev/null || true
  done
}
for d in "$LIBS"/*.dylib; do
  [ -f "$d" ] || continue
  install_name_tool -id "@rpath/$(basename "$d")" "$d" 2>/dev/null || true
  relink "$d"
done
relink "$X11BIN/Xvfb";       install_name_tool -add_rpath "@executable_path/../../../x11libs" "$X11BIN/Xvfb" 2>/dev/null || true
relink "$X11BIN/xkbcomp";    install_name_tool -add_rpath "@executable_path/../../../x11libs" "$X11BIN/xkbcomp" 2>/dev/null || true
relink "$X11BIN/setxkbmap";  install_name_tool -add_rpath "@executable_path/../../../x11libs" "$X11BIN/setxkbmap" 2>/dev/null || true
relink "$C/MacOS/X2GoApp";   install_name_tool -add_rpath "@executable_path/../x11libs" "$C/MacOS/X2GoApp" 2>/dev/null || true
for nx in "$C/exe/nxproxy" "$C/exe/nxproxy.real" "$C/exe/libXcomp.3.dylib" "$C/exe/nxauth"; do
  [ -f "$nx" ] || continue
  relink "$nx"; install_name_tool -add_rpath "@executable_path/../x11libs" "$nx" 2>/dev/null || true
done

# --- fonts + xkb ---
echo ">> bundling fonts + xkb..."
cp -R "$OPT/share/fonts/misc/." "$X11FONTS/misc/" 2>/dev/null || true
cp -R "$OPT/share/X11/xkb/."    "$X11XKB/"        2>/dev/null || true

# --- assertions: no /opt refs, and ZERO Qt anywhere ---
echo ">> verifying self-contained + Qt-free..."
LEFT=0
while IFS= read -r f; do
  n=$(otool -L "$f" 2>/dev/null | awk 'NR>1{print $1}' | grep -c "^/opt/" || true); LEFT=$((LEFT+n))
done < <(find "$OUT" -type f \( -name '*.dylib' -o -perm -u+x \) 2>/dev/null)
echo "   remaining /opt references: $LEFT (want 0)"
QTLINK=0
while IFS= read -r f; do
  n=$(otool -L "$f" 2>/dev/null | grep -ci "Qt" || true); QTLINK=$((QTLINK+n))
done < <(find "$OUT" -type f \( -name '*.dylib' -o -perm -u+x \) 2>/dev/null)
QTFW=$(find "$OUT" -iname 'Qt*.framework' 2>/dev/null | wc -l | tr -d ' ')
echo "   Qt linkage: $QTLINK, Qt frameworks: $QTFW (want 0/0)"
if [ "$QTLINK" != 0 ] || [ "$QTFW" != 0 ]; then
  echo "!! Qt detected in the bundle — failing the build (this app must be Qt-free)."; exit 1
fi

# --- codesign (+ optional notarize) ---
SIGN_ID="${SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)".*/\1/')
  [ -n "$SIGN_ID" ] && echo ">> auto-detected signing identity: $SIGN_ID"
fi
ENT="$HERE/entitlements.plist"
if [ -n "$SIGN_ID" ]; then
  echo ">> codesigning with '$SIGN_ID' (hardened runtime)..."
  SIGN=(codesign --force --options runtime --timestamp --entitlements "$ENT" -s "$SIGN_ID")
else
  echo ">> codesigning ad-hoc (NOT distributable)..."
  SIGN=(codesign --force -s -)
fi
while IFS= read -r f; do "${SIGN[@]}" "$f" >/dev/null 2>&1; done < <(
  find "$OUT" -type f \( -name '*.dylib' -o -path '*/Resources/x11/bin/*' -o -path '*/Contents/exe/*' \) 2>/dev/null)
"${SIGN[@]}" "$C/MacOS/X2GoApp" >/dev/null 2>&1
if [ -n "$SIGN_ID" ]; then codesign --force --deep --options runtime --timestamp --entitlements "$ENT" -s "$SIGN_ID" "$OUT" >/dev/null 2>&1
else codesign --force --deep -s - "$OUT" >/dev/null 2>&1; fi

if [ -n "$SIGN_ID" ] && { [ -n "${NOTARY_PROFILE:-}" ] || [ -n "${AC_APPLE_ID:-}" ]; }; then
  echo ">> notarizing..."
  ZIP="$HERE/dist/X2Go.zip"; rm -f "$ZIP"; ditto -c -k --keepParent "$OUT" "$ZIP"
  if [ -n "${NOTARY_PROFILE:-}" ]; then xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  else xcrun notarytool submit "$ZIP" --apple-id "$AC_APPLE_ID" --team-id "$AC_TEAM_ID" --password "$AC_PASSWORD" --wait; fi
  xcrun stapler staple "$OUT" && xcrun stapler validate "$OUT"; rm -f "$ZIP"
fi
echo ">> done: $OUT"
