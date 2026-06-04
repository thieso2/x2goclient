import Foundation

/// Filesystem locations of the bundled (or dev) helper binaries the engine
/// drives. The app fills these from its .app bundle; the probe points them at
/// /opt/X11 + the build-mac nxproxy.
public struct ToolPaths: Sendable {
    public var xvfb: String
    public var setxkbmap: String
    public var nxproxy: String
    /// Dir containing nxproxy helpers (used as NX_SYSTEM, e.g. for nxauth).
    public var nxSystemDir: String
    /// Optional bundled X font dir (Xvfb -fp). nil -> Xvfb uses its built-in path.
    public var fontsPath: String?
    /// Optional bundled XKB data dir (Xvfb -xkbdir). nil -> Xvfb default.
    public var xkbPath: String?

    public init(xvfb: String, setxkbmap: String, nxproxy: String, nxSystemDir: String,
                fontsPath: String? = nil, xkbPath: String? = nil) {
        self.xvfb = xvfb; self.setxkbmap = setxkbmap; self.nxproxy = nxproxy
        self.nxSystemDir = nxSystemDir; self.fontsPath = fontsPath; self.xkbPath = xkbPath
    }
}
