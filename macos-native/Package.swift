// swift-tools-version: 6.0
import PackageDescription

// Native macOS X2Go display client — Phase 3/4 prototype.
// SwiftUI + Metal presentation/input layer (newest 2026 macOS stack), with an
// X11 bridge (CX11) as the current frame/input transport. macOS 14+ (built on
// the macOS 26 SDK).

let x11Include = "/opt/X11/include"
let x11Lib = "/opt/X11/lib"

let package = Package(
    name: "X2GoNative",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CX11",
            cSettings: [
                .unsafeFlags(["-I\(x11Include)"])
            ]
        ),
        .executableTarget(
            name: "X2GoNative",
            dependencies: ["CX11"],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I\(x11Include)"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(x11Lib)", "-lX11", "-lXext", "-lXtst",
                    "-Xlinker", "-rpath", "-Xlinker", x11Lib
                ])
            ]
        ),
        // Native NX endpoint: a minimal X11 server nxproxy connects to.
        .executableTarget(name: "x2go-xserver"),

        // Headless e2e check of the input bridge (same CX11 calls the GUI uses).
        .executableTarget(
            name: "inputtest",
            dependencies: ["CX11"],
            swiftSettings: [ .unsafeFlags(["-Xcc", "-I\(x11Include)"]) ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(x11Lib)", "-lX11", "-lXext", "-lXtst",
                    "-Xlinker", "-rpath", "-Xlinker", x11Lib
                ])
            ]
        )
    ]
)
