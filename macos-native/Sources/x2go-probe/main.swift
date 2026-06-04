// x2go-probe — headless verification CLI for the pure-Swift engine.
//
//   x2go-probe exec    [--host H --port P --user U --key PATH] [--cmd "..."]
//   x2go-probe forward [--local L --remote-host RH --remote-port RP] [...]
//   x2go-probe session [--cmd startxfce4 --geom 1280x800 --nxproxy PATH --png OUT]
//
// Defaults target the live test server (10.248.1.20 / thies / id_x2go_test).
import Foundation
import Darwin
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import X2GoSSH
import X2GoProtocol
import X2GoEngine
import X2GoDisplay

func flag(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

func readSome(host: String, port: Int, maxBytes: Int, timeoutSec: Int) -> [UInt8]? {
    let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    inet_pton(AF_INET, host, &addr.sin_addr)
    var tv = timeval(tv_sec: timeoutSec, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard ok == 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: maxBytes)
    let n = recv(fd, &buf, maxBytes, 0)
    return n > 0 ? Array(buf[0..<n]) : []
}

/// Write a BGRA8 buffer to PNG and return the fraction of non-black pixels.
func analyzeAndWritePNG(_ ptr: UnsafeRawPointer, w: Int, h: Int, path: String?) -> Double {
    let px = ptr.assumingMemoryBound(to: UInt8.self)
    var nonBlack = 0
    let total = w * h
    var i = 0
    for _ in 0..<total {
        let b = px[i], g = px[i + 1], r = px[i + 2]
        if Int(b) + Int(g) + Int(r) > 24 { nonBlack += 1 }
        i += 4
    }
    if let path {
        let data = Data(bytes: ptr, count: w * h * 4)
        let provider = CGDataProvider(data: data as CFData)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        if let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                             bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: info, provider: provider, decode: nil,
                             shouldInterpolate: false, intent: .defaultIntent),
           let dest = CGImageDestinationCreateWithURL(
               URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
    }
    return Double(nonBlack) / Double(max(total, 1))
}

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: x2go-probe <exec|forward|session> [flags]"); exit(2) }
let sub = args[1]
let host = flag("--host") ?? "10.248.1.20"
let port = Int(flag("--port") ?? "22") ?? 22
let user = flag("--user") ?? "thies"
let keyPath = flag("--key") ?? "\(NSHomeDirectory())/.ssh/id_x2go_test"
let endpoint = SSHEndpoint(host: host, port: port, username: user)
let creds: [SSHCredential] = [.privateKeyFile(URL(fileURLWithPath: keyPath))]

do {
    switch sub {
    case "exec":
        let conn = CLISSHTransport(endpoint: endpoint, credentials: creds, tag: "probe")
        try await conn.connect()
        let command = flag("--cmd") ?? "export HOSTNAME && x2golistsessions"
        let r = try await conn.exec(command)
        print("exit=\(r.exitStatus)\n--- stdout ---\n\(r.stdoutString)")
        if !r.stderrString.isEmpty { print("--- stderr ---\n\(r.stderrString)") }
        await conn.disconnect()

    case "forward":
        let conn = CLISSHTransport(endpoint: endpoint, credentials: creds, tag: "probe")
        try await conn.connect()
        let local = Int(flag("--local") ?? "30122") ?? 30122
        let rhost = flag("--remote-host") ?? "localhost"
        let rport = Int(flag("--remote-port") ?? "22") ?? 22
        let fwd = try await conn.openLocalForward(localPort: local, remoteHost: rhost, remotePort: rport)
        print("forwarding 127.0.0.1:\(fwd.localPort) -> \(rhost):\(rport)")
        let bytes = readSome(host: "127.0.0.1", port: fwd.localPort, maxBytes: 256, timeoutSec: 5) ?? []
        print("read \(bytes.count) bytes via tunnel: \(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        await fwd.close(); await conn.disconnect()
        if bytes.isEmpty { exit(1) }

    case "session":
        let repo = flag("--repo") ?? "\(FileManager.default.currentDirectoryPath)/.."
        let nxproxy = flag("--nxproxy") ?? "\(repo)/build-mac/x2goclient.app/Contents/exe/nxproxy"
        let nxSystem = (nxproxy as NSString).deletingLastPathComponent
        let tools = ToolPaths(xvfb: flag("--xvfb") ?? "/opt/X11/bin/Xvfb",
                              setxkbmap: "/opt/X11/bin/setxkbmap",
                              nxproxy: nxproxy, nxSystemDir: nxSystem)
        let geomParts = (flag("--geom") ?? "1280x800").split(separator: "x")
        let gw = Int(geomParts.first ?? "1280") ?? 1280
        let gh = Int(geomParts.count > 1 ? geomParts[1] : "800") ?? 800
        let cfg = X2GoSession.Config(
            endpoint: endpoint, credentials: creds,
            command: flag("--cmd") ?? "startxfce4", kind: .desktop,
            displayMode: .custom(width: gw, height: gh), screen: Geometry(width: gw, height: gh),
            tools: tools, preferResume: (flag("--new") == nil))
        let session = X2GoSession(config: cfg)
        print("bringing up session …")
        try await session.start()
        guard let disp = await session.localDisplay else { print("no local display"); exit(1) }
        let sid = await session.sessionId ?? "?"
        print("connected: session=\(sid) localDisplay=\(disp) serverDisplay=\(await session.serverDisplay ?? "?")")

        // Let the desktop draw, then capture the Xvfb root.
        try await Task.sleep(nanoseconds: 6_000_000_000)
        let x = X11Session()
        guard x.connect(displayName: disp, windowPrefix: "") else {
            print("could not connect to \(disp)"); await session.terminate(); exit(1)
        }
        x.start()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        var fraction = 0.0
        let pngPath = flag("--png") ?? "/tmp/x2go-probe-capture.png"
        x.withFrame { ptr, w, h in fraction = analyzeAndWritePNG(ptr, w: w, h: h, path: pngPath) }
        let capturedW = x.width, capturedH = x.height
        if let cur = x.currentCursor() {
            print("cursor: \(cur.width)x\(cur.height) hotspot (\(cur.xhot),\(cur.yhot)) serial \(cur.serial)")
        } else {
            print("cursor: none (XFIXES unavailable?)")
        }
        x.close()   // close our X connection BEFORE killing Xvfb (avoids XIO abort)
        print(String(format: "captured %dx%d, non-black pixels = %.1f%%  -> %@",
                     capturedW, capturedH, fraction * 100, pngPath))
        if flag("--keep") != nil { await session.suspend() } else { await session.terminate() }
        if fraction < 0.02 { print("FAIL: frame essentially black"); exit(1) }
        print("OK: live desktop streamed into the Swift engine, no XQuartz")

    case "bench":
        let conn = CLISSHTransport(endpoint: endpoint, credentials: creds, tag: "probe")
        try await conn.connect()
        let mb = Int(flag("--mb") ?? "200") ?? 200
        let cmd = "dd if=/dev/zero bs=1M count=\(mb) 2>/dev/null"
        let start = DispatchTime.now()
        let r = try await conn.exec(cmd)
        let secs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        let bytes = r.stdout.count
        print(String(format: "swift-nio-ssh: %d bytes in %.2fs = %.1f MB/s",
                     bytes, secs, Double(bytes) / 1e6 / max(secs, 0.001)))
        await conn.disconnect()

    case "lifecycle":
        // Headless e2e of all three disconnect modes: connect (new) -> render ->
        // disconnect[mode] -> verify server state -> reconnect -> verify
        // resume/new + render. No UI needed.
        let geomParts = (flag("--geom") ?? "1280x800").split(separator: "x")
        let gw = Int(geomParts.first ?? "1280") ?? 1280
        let gh = Int(geomParts.count > 1 ? geomParts[1] : "800") ?? 800
        let repo = flag("--repo") ?? "\(FileManager.default.currentDirectoryPath)/.."
        let nxproxy = flag("--nxproxy") ?? "\(repo)/build-mac/x2goclient.app/Contents/exe/nxproxy"
        let tools = ToolPaths(xvfb: flag("--xvfb") ?? "/opt/X11/bin/Xvfb",
                              setxkbmap: "/opt/X11/bin/setxkbmap", nxproxy: nxproxy,
                              nxSystemDir: (nxproxy as NSString).deletingLastPathComponent)
        func cfg(_ resume: Bool) -> X2GoSession.Config {
            X2GoSession.Config(endpoint: endpoint, credentials: creds, command: "startxfce4",
                kind: .desktop, displayMode: .custom(width: gw, height: gh),
                screen: Geometry(width: gw, height: gh), tools: tools, preferResume: resume)
        }
        func capture(_ disp: String) async -> Double {
            let x = X11Session()
            guard x.connect(displayName: disp, windowPrefix: "") else { return 0 }
            x.start(); try? await Task.sleep(nanoseconds: 2_500_000_000)
            var f = 0.0; x.withFrame { p, w, h in f = analyzeAndWritePNG(p, w: w, h: h, path: nil) }
            x.close(); return f
        }
        let ctl = CLISSHTransport(endpoint: endpoint, credentials: creds, tag: "probe-life")
        try await ctl.connect()
        func statusOf(_ sid: String) async -> String {
            let out = (try? await ctl.exec("x2golistsessions").stdoutString) ?? ""
            for r in X2GoParser.sessionList(out) where r.sessionId == sid { return r.status }
            return "GONE"
        }
        func cleanAll() async {
            _ = try? await ctl.exec("for s in $(x2golistsessions 2>/dev/null|cut -d'|' -f2); do x2goterminate-session \"$s\" >/dev/null 2>&1; done")
        }
        let modes = (flag("--mode").map { [$0] }) ?? ["suspend", "keep", "terminate"]
        var allPass = true
        for mode in modes {
            print("\n===== MODE: \(mode) =====")
            await cleanAll(); try? await Task.sleep(nanoseconds: 2_000_000_000)
            let s1 = X2GoSession(config: cfg(false))
            try await s1.start()
            guard let sid1 = await s1.sessionId, let d1 = await s1.localDisplay else {
                print("FAIL: S1 did not start"); allPass = false; continue
            }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            let f1 = await capture(d1)
            print(String(format: "S1: %@ display=%@ rendered=%.0f%%", sid1, d1, f1 * 100))

            if mode == "keep" {
                // Keep running = the connection stays live (proxy/Xvfb up, server
                // session R) and is instantly re-displayable. No disconnect/reconnect.
                let st = await statusOf(sid1)
                let f2 = await capture(d1)   // re-attach to the still-live display
                let pass = (st == "R") && f1 > 0.02 && f2 > 0.02
                print("keep: server status=\(st) (expect R), re-render=\(String(format: "%.0f%%", f2 * 100)) -> \(pass ? "PASS ✅" : "FAIL ❌")")
                allPass = allPass && pass
                await s1.terminate()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }

            switch mode {
            case "suspend": await s1.suspend()
            default:        await s1.terminate()
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let st = await statusOf(sid1)
            let expStatus = (mode == "suspend") ? "S" : "GONE"
            print("after \(mode): server status=\(st) (expect \(expStatus))")

            let s2 = X2GoSession(config: cfg(true))
            try await s2.start()
            guard let sid2 = await s2.sessionId, let d2 = await s2.localDisplay else {
                print("FAIL: S2 did not start"); allPass = false; continue
            }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            let f2 = await capture(d2)
            print(String(format: "S2: %@ display=%@ rendered=%.0f%%", sid2, d2, f2 * 100))
            let resumed = (sid2 == sid1)
            let statusOK = (st == expStatus)
            let idOK = (mode == "terminate") ? !resumed : resumed
            let renderOK = f2 > 0.02
            let pass = statusOK && idOK && renderOK
            print("\(mode): status=\(statusOK ? "ok" : "BAD") reconnect=\(idOK ? "ok" : "BAD")(resumed=\(resumed)) render=\(renderOK ? "ok" : "BAD") -> \(pass ? "PASS ✅" : "FAIL ❌")")
            allPass = allPass && pass
            await s2.terminate()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        await cleanAll(); await ctl.disconnect()
        print("\n===== RESULT: \(allPass ? "ALL MODES PASS ✅" : "FAILURES ❌") =====")
        if !allPass { exit(1) }

    default:
        print("unknown subcommand: \(sub)"); exit(2)
    }
    print("done")
} catch {
    FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
    exit(1)
}
