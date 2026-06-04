import Foundation

// Pure value types + enums shared by the protocol builders/parsers and the
// engine. No I/O. These mirror the x2go wire vocabulary used by the Qt client
// (the authoritative reference: src/onmainwindow.cpp).

public enum LinkSpeed: String, Sendable, Codable, CaseIterable {
    case modem, isdn, adsl, wan, lan
}

/// x2go session-type token (the leading letter in startagent / runcommand).
public enum SessionKind: String, Sendable, Codable {
    case desktop = "D"
    case rootless = "R"
    case shadow = "S"
    case published = "P"
}

public enum ClipboardMode: String, Sendable, Codable, CaseIterable {
    case both, client, server, none
}

/// Server-side graphics backend. nxagent is the classic NX path (what this client
/// renders via nxproxy); kdrive is X2Go's newer x2gokdrive server.
public enum AgentBackend: String, Sendable, Codable, CaseIterable {
    case nxagent, kdrive
}

/// How a profile asks for its display size.
public enum DisplayMode: Sendable, Codable, Equatable, Hashable {
    case fullscreen
    case maxAvailable
    case custom(width: Int, height: Int)
}

public struct Geometry: Sendable, Equatable, Hashable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    /// "WxH" — the token used for both `Xvfb -screen` and the agent geometry.
    public var token: String { "\(width)x\(height)" }
}

/// Resolve a profile's display mode to a concrete pixel geometry.
/// fullscreen/maxAvailable -> the screen size (clamped); custom -> as given
/// (may exceed the screen — the viewer then scales/scrolls). `wantFullscreen`
/// is true only for `.fullscreen` so the viewer can present true-fullscreen.
public func resolveGeometry(_ mode: DisplayMode, screen: Geometry)
    -> (geometry: Geometry, wantFullscreen: Bool) {
    func clamp(_ g: Geometry) -> Geometry {
        let w = (g.width >= 320 && g.width <= 8192) ? g.width : 1280
        let h = (g.height >= 240 && g.height <= 8192) ? g.height : 800
        return Geometry(width: w, height: h)
    }
    switch mode {
    case .fullscreen:   return (clamp(screen), true)
    case .maxAvailable: return (clamp(screen), false)
    case .custom(let w, let h): return (clamp(Geometry(width: w, height: h)), false)
    }
}
