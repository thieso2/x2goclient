# Building x2goclient on macOS (Qt6 / CMake)

This is the **Phase 0** macOS build of the native-port effort: a modern
**Qt6 + CMake** build replacing the legacy qmake/MacPorts/Qt4 path. It targets
**Apple Silicon (arm64)** on **macOS 12+**. See `NATIVE_MACOS_PORT_PLAN.md` for
the bigger picture.

> The qmake build (`x2goclient.pro`) is still used for Linux/Windows and the
> browser plugin. This CMake build is the macOS client only.

## Prerequisites

```sh
brew install cmake qt libssh openssl@3
```

`qt` is Qt 6. `qt5compat` (pulled in by `qt`) supplies `QRegExp`/`QTextCodec`
shims used by the port.

## Build

```sh
cmake -S . -B build-mac -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_PREFIX_PATH="$(brew --prefix qt)"
cmake --build build-mac -j"$(sysctl -n hw.ncpu)"
```

Result: `build-mac/x2goclient.app`. The binary is **ad-hoc signed by the linker**,
so it runs locally on Apple Silicon without further steps.

```sh
open build-mac/x2goclient.app
```

> Homebrew's Qt is built for a newer macOS than our 12.0 floor, so you'll see
> `ld: warning: ... built for newer version` lines. They're harmless when
> running on your own (current) machine. Shipping a binary that genuinely runs
> on macOS 12 requires a Qt built against the 12 SDK (official Qt online
> installer, or a source build) — out of scope for local dev.

## Distributable (Developer ID signed + notarized)

For a build that runs on other people's Macs you must bundle Qt into the `.app`
and sign/notarize with a Developer ID:

```sh
"$(brew --prefix qt)/bin/macdeployqt" build-mac/x2goclient.app -always-overwrite
codesign --force --deep --options runtime --timestamp \
         --sign "Developer ID Application: <NAME> (<TEAMID>)" build-mac/x2goclient.app
hdiutil create -volname x2goclient -srcfolder build-mac/x2goclient.app \
         -ov -format UDZO build-mac/x2goclient.dmg
xcrun notarytool submit build-mac/x2goclient.dmg \
         --key AuthKey_XXXX.p8 --key-id <KEYID> --issuer <ISSUERID> --wait
xcrun stapler staple build-mac/x2goclient.dmg
```

CI (`.github/workflows/macos.yml`) does all of this automatically on the
GitHub-hosted Apple Silicon runner when the signing secrets are configured;
without secrets it still builds and ad-hoc signs.

## Making sessions actually display (nxproxy + nxauth + XQuartz)

Connecting a session needs three runtime pieces in the bundle plus XQuartz:

1. **nxproxy** (the NX codec) and its **libXcomp** — built from `nx-libs`:
   ```sh
   brew install automake libtool jpeg-turbo libpng   # build deps
   git clone --depth 1 https://github.com/ArcticaProject/nx-libs.git
   # On case-insensitive APFS, the VERSION files shadow C++ <version>; rename them:
   ( cd nx-libs && for f in nxcomp/VERSION nxproxy/VERSION VERSION; do mv "$f" "$f.txt"; done )
   export LIBTOOLIZE=glibtoolize
   export PKG_CONFIG_PATH="$(brew --prefix jpeg-turbo)/lib/pkgconfig:$(brew --prefix libpng)/lib/pkgconfig:$(brew --prefix zlib)/lib/pkgconfig"
   for d in nxcomp nxproxy; do
     ( cd nx-libs/$d && autoreconf -fi && \
       ./configure --prefix=/tmp/nxbuild CPPFLAGS="-I/opt/X11/include -I/tmp/nxbuild/include" \
                   LDFLAGS="-L/opt/X11/lib -L/tmp/nxbuild/lib" && make -j && make install )
   done
   ```
   (nxcomp's `Loop.cpp` socket `bind()` needs qualifying as `::bind()` under
   libc++ — a one-line patch.)

2. **Bundle them**, fixing the libXcomp path and re-signing:
   ```sh
   EXE=build-mac/x2goclient.app/Contents/exe; mkdir -p "$EXE"
   cp /tmp/nxbuild/bin/nxproxy "$EXE/"; cp /tmp/nxbuild/lib/libXcomp.3.dylib "$EXE/"
   install_name_tool -change /tmp/nxbuild/lib/libXcomp.3.dylib @loader_path/libXcomp.3.dylib "$EXE/nxproxy"
   cp /opt/X11/bin/xauth "$EXE/nxauth"           # nxcomp runs $NX_SYSTEM/nxauth on macOS
   codesign --force -s - "$EXE/libXcomp.3.dylib" "$EXE/nxproxy" "$EXE/nxauth"
   ```
   (`-DX2GO_NXPROXY=/tmp/nxbuild/bin/nxproxy` copies nxproxy automatically; the
   dylib/nxauth steps are still manual.)

3. **XQuartz** must be installed. The client auto-launches it and authenticates
   using XQuartz's real cookie (`~/.serverauth.<pid>` via the bundled `nxauth`),
   so a plain double-click works — no terminal, `DISPLAY`, or `xhost` needed.

`screencapture` cannot grab XQuartz windows without Screen-Recording permission,
so a session may *look* black in a screenshot while rendering fine on screen;
dump the real pixels with `xwd -name X2GO-... | xwdtopnm | pnmtopng` to verify.

## Notes on the Qt4 → Qt6 port

The macOS code path never used the Qt4-only X11 APIs (`QX11EmbedContainer`,
`QX11Info`), which are all `#ifdef Q_OS_LINUX`. The port was therefore mechanical:

- `QString::null` → `QString()`, `Qt::WFlags` → `Qt::WindowFlags`, flag default
  `= 0` → `= Qt::WindowFlags()`
- `QString::SkipEmptyParts` → `Qt::SkipEmptyParts`, `toAscii()` → `toLatin1()`,
  `QString::sprintf` → `QString::asprintf`
- `QFontMetrics::width` → `horizontalAdvance`, `QLayout::setMargin` →
  `setContentsMargins`, `qSort` → `std::sort`, `<<endl` → `<< "\n"`
- removed/renamed Qt APIs: `QHttp` (unused include), `QPlastiqueStyle` →
  `QStyleFactory::create("Fusion")`, `QTime` stopwatch → `QElapsedTimer`,
  `QDesktopServices::storageLocation` → `QStandardPaths`,
  `QPlainTextEdit::setTabStopWidth` → `setTabStopDistance`,
  `QSslSocket::addDefaultCaCertificates` → `QSslConfiguration`
- signal renames: `QComboBox::activated(QString)` → `textActivated`,
  `QButtonGroup::buttonClicked(int)` → `idClicked(int)`
- **`QDesktopWidget`** (removed in Qt6) is handled by a small compat shim,
  `src/qdesktopwidget_compat.h` (`x2go::desktop()` / `x2go::DesktopWidget`),
  backed by `QScreen`. This keeps the ~30 multi-monitor call sites unchanged,
  since the Qt UI is slated for replacement in a later phase.

### Known remaining (non-blocking)
`SessionWidget::directRDP/settingsChanged/slot_emitSettings` are `#ifdef
Q_OS_LINUX`-only members whose `connect()` calls are not similarly guarded, so
macOS logs harmless "No such signal/slot" warnings at startup. Pre-existing
(Linux-only feature); not a Qt6 regression.
