// swift-tools-version: 6.0
import PackageDescription

// Native macOS X2Go client — a single, modern Swift/SwiftUI app.
// No Qt, no libssh: SSH is pure Swift (SwiftNIO SSH + Citadel). The only native
// code is the bundled nxproxy/Xvfb binaries and the small CX11 Xlib/XTEST bridge
// to the per-connection Xvfb. macOS 14+.

let x11Include = "/opt/X11/include"
let x11Lib = "/opt/X11/lib"

// Linker flags every executable that (transitively) uses CX11 needs.
let x11Link: [LinkerSetting] = [
    .unsafeFlags([
        "-L\(x11Lib)", "-lX11", "-lXext", "-lXtst", "-lXfixes",
        "-Xlinker", "-rpath", "-Xlinker", x11Lib,
    ])
]

let package = Package(
    name: "X2Go",
    platforms: [.macOS(.v14)],
    // No external packages: SSH is the system `ssh` CLI (CLISSHTransport).
    targets: [
        // The only C: Xlib/XTEST/XGetImage bridge to the local Xvfb.
        .target(
            name: "CX11",
            cSettings: [.unsafeFlags(["-I\(x11Include)"])]
        ),

        // Display/input/clipboard against an Xvfb display (per-connection ready).
        .target(
            name: "X2GoDisplay",
            dependencies: ["CX11"]
        ),

        // Pure x2go command-string builders/parsers + geometry. No I/O.
        .target(name: "X2GoProtocol"),

        // SSH via the system `ssh` CLI (agent, ssh_config, all key types).
        // Swift 5 mode: the Process/Pipe terminationHandler captures non-Sendable
        // pipes, which Swift 6 strict concurrency would reject.
        .target(
            name: "X2GoSSH",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // Per-connection session orchestration state machine.
        .target(
            name: "X2GoEngine",
            dependencies: ["X2GoSSH", "X2GoProtocol", "X2GoDisplay"]
        ),

        // The SwiftUI app: Session Manager + window-per-connection.
        .executableTarget(
            name: "X2GoApp",
            dependencies: ["X2GoEngine", "X2GoProtocol", "X2GoDisplay"],
            linkerSettings: x11Link
        ),

        // Headless verification CLI (SSH/forward/engine) against the test server.
        .executableTarget(
            name: "x2go-probe",
            dependencies: ["X2GoSSH", "X2GoEngine", "X2GoProtocol", "X2GoDisplay"],
            linkerSettings: x11Link
        ),

        // Existing headless input bridge smoke test.
        .executableTarget(
            name: "inputtest",
            dependencies: ["CX11"],
            linkerSettings: x11Link
        ),

        .testTarget(name: "X2GoProtocolTests", dependencies: ["X2GoProtocol"]),
    ]
)
