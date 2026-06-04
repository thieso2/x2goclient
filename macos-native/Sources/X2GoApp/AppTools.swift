import Foundation
import X2GoEngine

/// Resolves the helper-binary paths the engine needs. Prefers the .app bundle
/// (shipped layout), then env overrides, then a dev fallback (system Xvfb +
/// the build-mac nxproxy) so the app runs straight from `swift build`.
enum AppTools {
    static func resolve() -> ToolPaths {
        let fm = FileManager.default
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        let bundleXvfb = contents.appendingPathComponent("Resources/x11/bin/Xvfb").path
        let bundleNx = contents.appendingPathComponent("exe/nxproxy").path
        if fm.fileExists(atPath: bundleXvfb), fm.fileExists(atPath: bundleNx) {
            return ToolPaths(
                xvfb: bundleXvfb,
                setxkbmap: contents.appendingPathComponent("Resources/x11/bin/setxkbmap").path,
                nxproxy: bundleNx,
                nxSystemDir: contents.appendingPathComponent("exe").path,
                fontsPath: contents.appendingPathComponent("Resources/x11/fonts/misc").path,
                xkbPath: contents.appendingPathComponent("Resources/x11/xkb").path)
        }

        let env = ProcessInfo.processInfo.environment
        // repo root = .../macos-native/Sources/X2GoApp/AppTools.swift -> up 4
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let devNx = env["X2GO_NXPROXY"]
            ?? repo.appendingPathComponent("build-mac/x2goclient.app/Contents/exe/nxproxy").path
        return ToolPaths(
            xvfb: env["X2GO_XVFB"] ?? "/opt/X11/bin/Xvfb",
            setxkbmap: "/opt/X11/bin/setxkbmap",
            nxproxy: devNx,
            nxSystemDir: (devNx as NSString).deletingLastPathComponent)
    }
}
