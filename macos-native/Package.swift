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
        "-L\(x11Lib)", "-lX11", "-lXext", "-lXtst",
        "-Xlinker", "-rpath", "-Xlinker", x11Lib,
    ])
]

let package = Package(
    name: "X2Go",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Apple's pure-Swift SSH (current). We use it directly (no Citadel) for
        // connect/auth/exec and the directTCPIP NX tunnel — full control, no
        // version conflicts.
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.13.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.40.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "2.5.0" ..< "4.0.0"),
    ],
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

        // Pure-Swift SSH: connect/auth, exec, and local TCP port-forward.
        .target(
            name: "X2GoSSH",
            dependencies: [
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ],
            // SwiftNIO's Channel/handlers are not Sendable; build this NIO-wrapping
            // layer in Swift 5 mode (the actor still isolates; we expose only
            // Sendable results across its boundary). The rest of the app is Swift 6.
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
