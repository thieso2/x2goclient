import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Minimal X11 server — the native NX endpoint. nxproxy (or any X client)
// connects here; we own the framebuffer (→ Metal, later) and input.
// Rung 1: connection handshake + the core round-trip requests so real X
// clients (xdpyinfo) connect and query us.

let displayNum = CommandLine.arguments.count > 1 ? (Int(CommandLine.arguments[1]) ?? 77) : 77
let FB_W = 1280, FB_H = 800

// Server-owned resource IDs (kept below the client id-base 0x04000000).
let ROOT: UInt32 = 0x0000_0001
let CMAP: UInt32 = 0x0000_0020
let VISUAL: UInt32 = 0x0000_0021

signal(SIGPIPE, SIG_IGN)

// MARK: - framebuffer (the surface we'll hand to Metal)

final class Framebuffer: @unchecked Sendable {
    let w: Int, h: Int
    var px: [UInt8]            // BGRA8, w*h*4
    let lock = NSLock()
    init(_ w: Int, _ h: Int) {
        self.w = w; self.h = h
        px = [UInt8](repeating: 0, count: w * h * 4)
        // init to a dark slate so "nothing drawn yet" is visibly distinct from black
        for i in stride(from: 0, to: px.count, by: 4) {
            px[i] = 0x30; px[i+1] = 0x28; px[i+2] = 0x20; px[i+3] = 0xff
        }
    }
    func fillRect(_ x: Int, _ y: Int, _ rw: Int, _ rh: Int, _ bgra: (UInt8,UInt8,UInt8)) {
        lock.lock(); defer { lock.unlock() }
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(w, x + rw), y1 = min(h, y + rh)
        var yy = y0
        while yy < y1 {
            var xx = x0
            let row = yy * w * 4
            while xx < x1 {
                let o = row + xx * 4
                px[o] = bgra.0; px[o+1] = bgra.1; px[o+2] = bgra.2; px[o+3] = 0xff
                xx += 1
            }
            yy += 1
        }
    }
    /// Blit a ZPixmap (BGRA/BGRX, 32bpp) region into the framebuffer.
    func putImageZ(_ dstX: Int, _ dstY: Int, _ iw: Int, _ ih: Int, _ data: ArraySlice<UInt8>) {
        lock.lock(); defer { lock.unlock() }
        let bytesPerRow = iw * 4
        data.withUnsafeBytes { src in
            for ry in 0..<ih {
                let dy = dstY + ry
                if dy < 0 || dy >= h { continue }
                for rx in 0..<iw {
                    let dx = dstX + rx
                    if dx < 0 || dx >= w { continue }
                    let so = ry * bytesPerRow + rx * 4
                    if so + 3 >= src.count { continue }
                    let o = (dy * w + dx) * 4
                    px[o]   = src[so]
                    px[o+1] = src[so+1]
                    px[o+2] = src[so+2]
                    px[o+3] = 0xff
                }
            }
        }
    }
    func snapshotPPM(to path: String) {
        lock.lock(); let copy = px; lock.unlock()
        var out = Data("P6\n\(w) \(h)\n255\n".utf8)
        out.reserveCapacity(out.count + w*h*3)
        var rgb = [UInt8](repeating: 0, count: w*h*3)
        for i in 0..<(w*h) {
            rgb[i*3]   = copy[i*4+2]  // R
            rgb[i*3+1] = copy[i*4+1]  // G
            rgb[i*3+2] = copy[i*4]    // B
        }
        out.append(contentsOf: rgb)
        try? out.write(to: URL(fileURLWithPath: path))
    }
}

nonisolated(unsafe) let fb = Framebuffer(1280, 800)
nonisolated(unsafe) var gcForeground: [UInt32: (UInt8,UInt8,UInt8)] = [:]

func pixelToBGRA(_ v: UInt32) -> (UInt8,UInt8,UInt8) {
    (UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff))
}

// MARK: - socket

func listenUnix(_ path: String) -> Int32 {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    precondition(fd >= 0, "socket() failed")
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in
        path.withCString { c in strcpy(UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self), c) }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let r = withUnsafePointer(to: &addr) { ap in
        ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
    }
    precondition(r == 0, "bind(\(path)) failed errno=\(errno)")
    precondition(listen(fd, 4) == 0, "listen failed")
    return fd
}

func readExact(_ fd: Int32, _ n: Int) -> [UInt8]? {
    if n == 0 { return [] }
    var buf = [UInt8](repeating: 0, count: n)
    var got = 0
    while got < n {
        let r = buf.withUnsafeMutableBytes { p in read(fd, p.baseAddress!.advanced(by: got), n - got) }
        if r <= 0 { return nil }
        got += r
    }
    return buf
}

func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
    var sent = 0
    bytes.withUnsafeBytes { p in
        while sent < bytes.count {
            let r = write(fd, p.baseAddress!.advanced(by: sent), bytes.count - sent)
            if r <= 0 { return }
            sent += r
        }
    }
}

// MARK: - handshake

/// Read the client connection setup; returns (lsb, ok).
func readClientSetup(_ fd: Int32) -> Bool? {
    guard let hdr = readExact(fd, 12) else { return nil }
    let lsb = (hdr[0] == 0x6c /* 'l' */)
    var r = ByteReader(Array(hdr[2...]), lsb: lsb)
    _ = r.u16(); _ = r.u16()                 // proto major/minor
    let nameLen = Int(r.u16()); let dataLen = Int(r.u16())
    _ = r.u16()                              // unused
    let namePad = (4 - (nameLen % 4)) % 4
    let dataPad = (4 - (dataLen % 4)) % 4
    _ = readExact(fd, nameLen + namePad + dataLen + dataPad)  // ignore auth
    return lsb
}

func sendSetup(_ fd: Int32, lsb: Bool) {
    let vendor = "X2GoNative"
    var p = ByteWriter(lsb: lsb)            // payload after the 8-byte header
    p.u32(1)                                // release
    p.u32(0x0400_0000)                      // resource-id-base
    p.u32(0x001f_ffff)                      // resource-id-mask
    p.u32(0)                                // motion-buffer-size
    p.u16(UInt16(vendor.utf8.count))        // vendor length
    p.u16(65535)                            // max-request-length
    p.u8(1)                                 // number of screens
    p.u8(2)                                 // number of pixmap formats
    p.u8(0)                                 // image byte order: LSBFirst
    p.u8(0)                                 // bitmap bit order: LeastSignificant
    p.u8(32)                                // scanline unit
    p.u8(32)                                // scanline pad
    p.u8(8); p.u8(255)                      // min/max keycode
    p.pad(4)
    p.string(vendor)
    // pixmap formats
    p.u8(24); p.u8(32); p.u8(32); p.pad(5)
    p.u8(1);  p.u8(1);  p.u8(32); p.pad(5)
    // screen
    p.u32(ROOT); p.u32(CMAP)
    p.u32(0x00ff_ffff); p.u32(0)            // white / black
    p.u32(0)                                // current input masks
    p.u16(UInt16(FB_W)); p.u16(UInt16(FB_H))
    p.u16(UInt16(Double(FB_W) * 25.4 / 96.0)); p.u16(UInt16(Double(FB_H) * 25.4 / 96.0))
    p.u16(1); p.u16(1)                      // min/max installed maps
    p.u32(VISUAL)
    p.u8(0); p.u8(0)                        // backing-stores / save-unders
    p.u8(24)                                // root depth
    p.u8(1)                                 // number of depths
    // depth 24
    p.u8(24); p.pad(1); p.u16(1); p.pad(4)
    // visual
    p.u32(VISUAL); p.u8(4) /*TrueColor*/; p.u8(8); p.u16(256)
    p.u32(0xff0000); p.u32(0x00ff00); p.u32(0x0000ff); p.pad(4)

    var w = ByteWriter(lsb: lsb)
    w.u8(1)                                 // success
    w.u8(0)
    w.u16(11); w.u16(0)                     // protocol version
    w.u16(UInt16(p.bytes.count / 4))        // additional data length (4-byte units)
    w.raw(p.bytes)
    writeAll(fd, w.bytes)
}

// MARK: - replies

nonisolated(unsafe) var seq: UInt16 = 0
nonisolated(unsafe) var nextAtom: UInt32 = 1000
nonisolated(unsafe) var atoms: [String: UInt32] = [:]

func reply(_ fd: Int32, lsb: Bool, detail: UInt8 = 0, extra: ([UInt8]) = [], build: (inout ByteWriter) -> Void) {
    var w = ByteWriter(lsb: lsb)
    w.u8(1)                                 // reply
    w.u8(detail)
    w.u16(seq)
    w.u32(UInt32(extra.count / 4))          // reply length (extra 4-byte units)
    build(&w)                               // 24 bytes of fixed reply data
    while w.bytes.count < 32 { w.u8(0) }
    w.raw(extra)
    writeAll(fd, w.bytes)
}

// MARK: - serve

let path = "/tmp/.X11-unix/X\(displayNum)"
let lfd = listenUnix(path)

// Periodically snapshot the framebuffer for headless validation (and as the
// surface Metal will consume once wired into the app).
Thread.detachNewThread {
    while true { fb.snapshotPPM(to: "/tmp/x2go_fb.ppm"); Thread.sleep(forTimeInterval: 0.5) }
}

func si16(_ v: UInt16) -> Int { Int(Int16(bitPattern: v)) }
// Extract the GCForeground (bit 0x4) value from a value-mask + value list.
func foregroundFrom(_ r: inout ByteReader, mask: UInt32) -> (UInt8,UInt8,UInt8)? {
    guard (mask & 0x4) != 0 else {
        // still must consume values to stay aligned if caller continues reading
        return nil
    }
    var idx = 0
    var bit: UInt32 = 0x1
    while bit < 0x4 { if (mask & bit) != 0 { idx += 1 }; bit <<= 1 }
    var vals: [UInt32] = []
    let total = (0..<32).reduce(0) { $0 + (((mask >> $1) & 1) != 0 ? 1 : 0) }
    for _ in 0..<total { vals.append(r.u32()) }
    guard idx < vals.count else { return nil }
    return pixelToBGRA(vals[idx])
}
FileHandle.standardError.write("x2go-xserver: listening on \(path) (DISPLAY=:\(displayNum)), \(FB_W)x\(FB_H)\n".data(using: .utf8)!)

func acceptLoop() {
  while true {
    let cfd = accept(lfd, nil, nil)
    if cfd < 0 { continue }
    // One thread per client so a silent probe connection (getXDisplay's
    // QLocalSocket) can't block accepting the real nxproxy connection.
    Thread.detachNewThread { serveClient(cfd) }
  }
}

func serveClient(_ cfd: Int32) {
    guard let lsb = readClientSetup(cfd) else { close(cfd); return }
    seq = 0                              // sequence numbers restart per connection
    sendSetup(cfd, lsb: lsb)
    FileHandle.standardError.write("client connected (lsb=\(lsb))\n".data(using: .utf8)!)

    var unknown: [UInt8: Int] = [:]
    requestLoop: while true {
        guard let h = readExact(cfd, 4) else { break }
        let opcode = h[0], detail = h[1]
        var lenU = (lsb ? UInt16(h[2]) | UInt16(h[3]) << 8 : UInt16(h[2]) << 8 | UInt16(h[3]))
        if lenU == 0 { // BIG-REQUESTS: next 4 bytes are the real length
            guard let ext = readExact(cfd, 4) else { break }
            var rr = ByteReader(ext, lsb: lsb); lenU = UInt16(truncatingIfNeeded: rr.u32())
        }
        let bodyLen = Int(lenU) * 4 - 4
        let body = bodyLen > 0 ? (readExact(cfd, bodyLen) ?? []) : []
        seq &+= 1
        FileHandle.standardError.write("req op=\(opcode) detail=\(detail) len=\(lenU)\n".data(using: .utf8)!)
        var r = ByteReader(body, lsb: lsb)

        switch opcode {
        case 16: // InternAtom
            let nameLen = Int(detail == 0 ? r.u16() : r.u16()); _ = r.u16()
            let name = String(decoding: body[4..<min(4 + nameLen, body.count)], as: UTF8.self)
            let a = atoms[name] ?? { nextAtom += 1; atoms[name] = nextAtom; return nextAtom }()
            reply(cfd, lsb: lsb) { $0.u32(a) }
        case 20: // GetProperty -> empty
            reply(cfd, lsb: lsb, detail: 0) { $0.u32(0); $0.u32(0); $0.u32(0) }
        case 43: // GetInputFocus
            reply(cfd, lsb: lsb, detail: 1 /*PointerRoot*/) { $0.u32(ROOT) }
        case 98: // QueryExtension -> not present
            reply(cfd, lsb: lsb) { $0.u8(0); $0.u8(0); $0.u8(0); $0.u8(0) }
        case 99: // ListExtensions -> none
            reply(cfd, lsb: lsb, detail: 0) { _ in }
        case 97: // QueryBestSize -> echo requested size
            _ = r.u32() /*drawable*/; let bw = r.u16(); let bh = r.u16()
            reply(cfd, lsb: lsb) { $0.u16(bw); $0.u16(bh) }
        case 101: // GetKeyboardMapping -> 1 keysym/keycode, all NoSymbol
            let count = Int(detail) // detail isn't count here; body has first+count
            _ = count
            let extra = [UInt8](repeating: 0, count: 4)
            reply(cfd, lsb: lsb, detail: 1, extra: extra) { _ in }
        case 119: // GetModifierMapping -> 2 keycodes/modifier, all 0
            let extra = [UInt8](repeating: 0, count: 8 * 2)
            reply(cfd, lsb: lsb, detail: 2, extra: extra) { _ in }

        case 55: // CreateGC: cid, drawable, value-mask, values
            let cid = r.u32(); _ = r.u32(); let mask = r.u32()
            if let fg = foregroundFrom(&r, mask: mask) { gcForeground[cid] = fg }
        case 56: // ChangeGC: gc, value-mask, values
            let gc = r.u32(); let mask = r.u32()
            if let fg = foregroundFrom(&r, mask: mask) { gcForeground[gc] = fg }
        case 70: // PolyFillRectangle: drawable, gc, rects[x,y,w,h]
            _ = r.u32(); let gc = r.u32()
            let fg = gcForeground[gc] ?? (0xc0, 0xc0, 0xc0)
            let n = (body.count - 8) / 8
            for _ in 0..<max(0, n) {
                let x = si16(r.u16()), y = si16(r.u16())
                let rw = Int(r.u16()), rh = Int(r.u16())
                fb.fillRect(x, y, rw, rh, fg)
            }
        case 61: // ClearArea: window, x, y, w, h
            _ = r.u32(); let x = si16(r.u16()), y = si16(r.u16())
            var rw = Int(r.u16()), rh = Int(r.u16())
            if rw == 0 { rw = fb.w }; if rh == 0 { rh = fb.h }
            fb.fillRect(x, y, rw, rh, (0x30, 0x28, 0x20))
        case 72: // PutImage: format(detail), drawable, gc, w,h, dstx,dsty, left-pad, depth, pad2, data
            let format = detail
            _ = r.u32(); _ = r.u32()
            let iw = Int(r.u16()), ih = Int(r.u16())
            let dx = si16(r.u16()), dy = si16(r.u16())
            if format == 2, iw > 0, ih > 0, body.count >= 20 {   // ZPixmap
                fb.putImageZ(dx, dy, iw, ih, body[20...])
            }

        default:
            unknown[opcode, default: 0] += 1
        }
    }
    let summary = unknown.sorted { $0.value > $1.value }.prefix(12)
        .map { "op\($0.key)×\($0.value)" }.joined(separator: " ")
    FileHandle.standardError.write("client disconnected. unhandled: \(summary)\n".data(using: .utf8)!)
    close(cfd)
}

// Serve on a background thread; present the framebuffer via Metal on the main
// thread. Pass --headless to skip the window (PPM dump only).
let headless = CommandLine.arguments.contains("--headless")
Thread.detachNewThread { acceptLoop() }
if headless {
    FileHandle.standardError.write("headless: framebuffer dumped to /tmp/x2go_fb.ppm\n".data(using: .utf8)!)
    while true { Thread.sleep(forTimeInterval: 60) }
} else {
    runMetalApp(fb)
}
