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
let RENDER_OP: UInt8 = 139          // major opcode we advertise for RENDER
let PF_RGB24: UInt32 = 0x0000_0030  // PICTFORMAT ids
let PF_ARGB32: UInt32 = 0x0000_0031

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
    /// True once a meaningful amount of the framebuffer differs from the init
    /// slate color — i.e. the remote desktop has actually drawn.
    func hasContent() -> Bool {
        lock.lock(); defer { lock.unlock() }
        var diff = 0, i = 0
        while i + 2 < px.count {
            if !(px[i] == 0x30 && px[i+1] == 0x28 && px[i+2] == 0x20) {
                diff += 1; if diff > 2000 { return true }
            }
            i += 4 * 37
        }
        return false
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

// Off-screen drawable. Apps render content here then CopyArea/Composite it onto
// a window, so a pixmap must be a real readable/writable BGRA buffer.
final class Pixmap: @unchecked Sendable {
    let w: Int, h: Int
    var px: [UInt8]
    init(_ w: Int, _ h: Int) { self.w = max(1, w); self.h = max(1, h); px = [UInt8](repeating: 0, count: self.w * self.h * 4) }
}

nonisolated(unsafe) let fb = Framebuffer(1280, 800)
nonisolated(unsafe) var gcForeground: [UInt32: (UInt8,UInt8,UInt8)] = [:]
nonisolated(unsafe) var windows: [UInt32: (x: Int, y: Int, w: Int, h: Int, mask: UInt32)] = [:]
nonisolated(unsafe) var winParent: [UInt32: UInt32] = [:]
nonisolated(unsafe) var pixmaps: [UInt32: Pixmap] = [:]
nonisolated(unsafe) var pictures: [UInt32: UInt32] = [:]   // RENDER Picture id -> drawable id
nonisolated(unsafe) var solidPictures: [UInt32: (UInt8,UInt8,UInt8)] = [:]  // CreateSolidFill colour (BGRA)
let drawablesLock = NSLock()
nonisolated(unsafe) let drawLog = ProcessInfo.processInfo.environment["X2GO_DRAWLOG"] != nil
nonisolated(unsafe) var drawLogN = 0
func dlog(_ s: @autoclosure () -> String) {
    if drawLog && drawLogN < 100000 { drawLogN += 1; FileHandle.standardError.write("  \(s())\n".data(using: .utf8)!) }
}
func drwKind(_ d: UInt32) -> String {
    if pixmaps[d] != nil { return "pixmap" }
    if d == ROOT { return "ROOT" }
    if let w = windows[d] { let (ox,oy) = winAbsOrigin(d); return "win@(\(ox),\(oy))[\(w.w)x\(w.h)]" }
    return "unknown(0,0)"
}

/// Absolute on-screen origin of a window, walking the parent chain.
func winAbsOrigin(_ d: UInt32) -> (Int, Int) {
    var ox = 0, oy = 0, cur = d, guardN = 0
    while cur != ROOT, let win = windows[cur], guardN < 64 {
        ox += win.x; oy += win.y; cur = winParent[cur] ?? ROOT; guardN += 1
    }
    return (ox, oy)
}

// Drawing targets a drawable's own buffer: pixmaps -> pixmap buffer, windows ->
// the window's backing surface (window-local coords). The compositor later
// stacks the surfaces into the framebuffer. Callers hold drawablesLock.
@inline(__always) func drwGet(_ d: UInt32, _ x: Int, _ y: Int) -> (UInt8,UInt8,UInt8,UInt8) {
    if let pm = pixmaps[d] {
        if x < 0 || y < 0 || x >= pm.w || y >= pm.h { return (0,0,0,0) }
        let o = (y * pm.w + x) * 4; return (pm.px[o], pm.px[o+1], pm.px[o+2], pm.px[o+3])
    }
    guard let s = surfaceFor(d), x >= 0, y >= 0, x < s.w, y < s.h else { return (0,0,0,0) }
    let o = (y * s.w + x) * 4; return (s.px[o], s.px[o+1], s.px[o+2], s.px[o+3])
}
@inline(__always) func drwSet(_ d: UInt32, _ x: Int, _ y: Int, _ c: (UInt8,UInt8,UInt8,UInt8)) {
    if let pm = pixmaps[d] {
        if x < 0 || y < 0 || x >= pm.w || y >= pm.h { return }
        let o = (y * pm.w + x) * 4; pm.px[o] = c.0; pm.px[o+1] = c.1; pm.px[o+2] = c.2; pm.px[o+3] = c.3
        return
    }
    guard let s = surfaceFor(d), x >= 0, y >= 0, x < s.w, y < s.h else { return }
    let o = (y * s.w + x) * 4; s.px[o] = c.0; s.px[o+1] = c.1; s.px[o+2] = c.2; s.px[o+3] = 0xff
    s.drawn = true
}
func drwFill(_ d: UInt32, _ x: Int, _ y: Int, _ rw: Int, _ rh: Int, _ bgra: (UInt8,UInt8,UInt8)) {
    drawablesLock.lock(); defer { drawablesLock.unlock() }
    for yy in y..<(y+rh) { for xx in x..<(x+rw) { drwSet(d, xx, yy, (bgra.0, bgra.1, bgra.2, 0xff)) } }
}
func drwPutImageZ(_ d: UInt32, _ x: Int, _ y: Int, _ iw: Int, _ ih: Int, _ data: ArraySlice<UInt8>) {
    drawablesLock.lock(); defer { drawablesLock.unlock() }
    let bpr = iw * 4; let base = data.startIndex
    for ry in 0..<ih { for rx in 0..<iw {
        let so = base + ry * bpr + rx * 4
        if so + 3 >= data.endIndex { continue }
        drwSet(d, x + rx, y + ry, (data[so], data[so+1], data[so+2], 0xff))
    } }
}
/// CopyArea/Composite: move a rectangle of pixels between any two drawables.
func drwCopy(_ src: UInt32, _ dst: UInt32, _ sx: Int, _ sy: Int, _ dx: Int, _ dy: Int, _ cw: Int, _ ch: Int) {
    drawablesLock.lock(); defer { drawablesLock.unlock() }
    for ry in 0..<ch { for rx in 0..<cw {
        let p = drwGet(src, sx + rx, sy + ry)
        if p.3 == 0 && pixmaps[src] != nil { continue }   // skip fully-transparent source px
        drwSet(dst, dx + rx, dy + ry, (p.0, p.1, p.2, 0xff))
    } }
}

// X event masks we care about
let ExposureMask: UInt32 = 0x8000
let StructureNotifyMask: UInt32 = 0x20000

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
    // Big buffers BEFORE listen so accepted sockets inherit them. macOS UNIX
    // sockets default to ~8KB, which paces nxproxy's request burst to us 8KB at
    // a time and starves the NX peer/token channel.
    var bsz: Int32 = 4 << 20
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bsz, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bsz, socklen_t(MemoryLayout<Int32>.size))
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

// Per-client output queue: the reader thread enqueues replies/events (never
// blocks on the socket), a dedicated writer thread drains to the socket. This
// breaks the full-duplex deadlock with nxproxy (it writes a big request burst
// to us while we'd be blocked writing replies it isn't reading yet).
final class OutQueue: @unchecked Sendable {
    private var buf = [UInt8]()
    private let cond = NSCondition()
    private var closed = false
    func push(_ b: [UInt8]) { cond.lock(); buf.append(contentsOf: b); cond.signal(); cond.unlock() }
    func close() { cond.lock(); closed = true; cond.signal(); cond.unlock() }
    func take() -> [UInt8]? {
        cond.lock(); defer { cond.unlock() }
        while buf.isEmpty && !closed { cond.wait() }
        if buf.isEmpty { return nil }
        let b = buf; buf.removeAll(keepingCapacity: true); return b
    }
}
nonisolated(unsafe) var outQueues: [Int32: OutQueue] = [:]
let outQueuesLock = NSLock()
func enqueue(_ fd: Int32, _ bytes: [UInt8]) {
    outQueuesLock.lock(); let q = outQueues[fd]; outQueuesLock.unlock()
    q?.push(bytes)
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
    enqueue(fd, w.bytes)
}

// MARK: - replies

// Per-connection X11 sequence numbers. MUST be per-fd: multiple clients
// (nxproxy main + auxiliary + the client's xmodmap probes) run concurrently on
// their own threads, and a shared counter corrupts each connection's reply
// sequence numbers — which makes nxproxy unable to match replies to requests and
// stop relaying them to nxagent.
nonisolated(unsafe) var seqMap: [Int32: UInt16] = [:]
let seqLock = NSLock()
func curSeq(_ fd: Int32) -> UInt16 { seqLock.lock(); defer { seqLock.unlock() }; return seqMap[fd] ?? 0 }
func setSeq(_ fd: Int32, _ v: UInt16) { seqLock.lock(); seqMap[fd] = v; seqLock.unlock() }
@discardableResult
func bumpSeq(_ fd: Int32) -> UInt16 { seqLock.lock(); defer { seqLock.unlock() }; let n = (seqMap[fd] ?? 0) &+ 1; seqMap[fd] = n; return n }
nonisolated(unsafe) var nextAtom: UInt32 = 1000
nonisolated(unsafe) var atoms: [String: UInt32] = [:]

func reply(_ fd: Int32, lsb: Bool, detail: UInt8 = 0, extra: ([UInt8]) = [], build: (inout ByteWriter) -> Void) {
    var w = ByteWriter(lsb: lsb)
    w.u8(1)                                 // reply
    w.u8(detail)
    w.u16(curSeq(fd))
    w.u32(UInt32(extra.count / 4))          // reply length (extra 4-byte units)
    build(&w)                               // 24 bytes of fixed reply data
    while w.bytes.count < 32 { w.u8(0) }
    w.raw(extra)
    enqueue(fd, w.bytes)
}

// Generic reply: `payload` is everything after the 8-byte reply header; length
// is derived. Handles fixed replies of any size (e.g. GetWindowAttributes=len3).
func replyRaw(_ fd: Int32, lsb: Bool, detail: UInt8, _ payload: [UInt8]) {
    var p = payload
    while p.count < 24 { p.append(0) }
    while p.count % 4 != 0 { p.append(0) }
    var w = ByteWriter(lsb: lsb)
    w.u8(1); w.u8(detail); w.u16(curSeq(fd)); w.u32(UInt32((p.count - 24) / 4))
    w.raw(p)
    enqueue(fd, w.bytes)
}

// Reply-expecting opcodes we answer generically (length-0, 32-byte) when not
// specifically modeled — so nxproxy/nxagent round-trips never stall.
let replyExpecting: Set<UInt8> = [
    17, 26, 31, 39, 45, 47, 48, 49, 52, 73, 83, 85, 86, 87, 88, 91, 92,
    104, 110, 116, 118
]

// MARK: - serve

let path = "/tmp/.X11-unix/X\(displayNum)"
let lfd = listenUnix(path)

// Periodically snapshot the framebuffer for headless validation (and as the
// surface Metal will consume once wired into the app).
Thread.detachNewThread {
    while true { compositeToFramebuffer(); fb.snapshotPPM(to: "/tmp/x2go_fb.ppm"); Thread.sleep(forTimeInterval: 0.3) }
}

// Headless input self-test: with no GUI/NSEvents, drive the injection path
// directly to prove events reach nxagent and the apps react. Right-click the
// desktop (xfdesktop context menu), then arrow-key down the menu.
if ProcessInfo.processInfo.environment["X2GO_INPUTTEST"] != nil {
    Thread.detachNewThread {
        var waited = 0.0
        while waited < 90 {                               // wait until desktop fully loads
            Thread.sleep(forTimeInterval: 1.0); waited += 1
            if inputWin != 0 && fb.hasContent() && compDesktopReady() && waited >= 8 { break }
        }
        Thread.sleep(forTimeInterval: 4.0)                // let panel/icons settle
        FileHandle.standardError.write("inputtest: desktop-up=\(fb.hasContent()) target win=\(inputWin) fd=\(inputFd) after \(waited)s\n".data(using: .utf8)!)
        func clickLeft(_ x: Int, _ y: Int) {
            injectMotion(x, y); Thread.sleep(forTimeInterval: 0.15)
            injectButton(1, down: true, fx: x, fy: y); Thread.sleep(forTimeInterval: 0.08)
            injectButton(1, down: false, fx: x, fy: y)
        }
        FileHandle.standardError.write("=== INPUT-BEGIN ===\n".data(using: .utf8)!)
        // 1) application-menu button (top-left of the panel)
        clickLeft(12, 11); Thread.sleep(forTimeInterval: 2.0)
        compDumpStack("appmenu")
        fb.snapshotPPM(to: "/tmp/x2go_fb_appmenu.ppm")
        injectKey(macKeyCode: 53, down: true); injectKey(macKeyCode: 53, down: false) // Escape
        Thread.sleep(forTimeInterval: 0.8)
        // 2) double-click the Home desktop icon
        clickLeft(26, 38); Thread.sleep(forTimeInterval: 0.1); clickLeft(26, 38)
        Thread.sleep(forTimeInterval: 2.5)
        fb.snapshotPPM(to: "/tmp/x2go_fb_dblclick.ppm")
        // 3) right-click the desktop centre
        injectMotion(640, 400); Thread.sleep(forTimeInterval: 0.2)
        injectButton(3, down: true, fx: 640, fy: 400); Thread.sleep(forTimeInterval: 0.08)
        injectButton(3, down: false, fx: 640, fy: 400)
        Thread.sleep(forTimeInterval: 2.0)
        fb.snapshotPPM(to: "/tmp/x2go_fb_rightclick.ppm")
        FileHandle.standardError.write("inputtest: snapshots written\n".data(using: .utf8)!)
    }
}

func si16(_ v: UInt16) -> Int { Int(Int16(bitPattern: v)) }

// Extract one value (by its mask bit) from a value-mask + value list.
func valueFor(_ r: inout ByteReader, mask: UInt32, bit: UInt32) -> UInt32? {
    let total = (0..<32).reduce(0) { $0 + (((mask >> $1) & 1) != 0 ? 1 : 0) }
    var vals: [UInt32] = []; vals.reserveCapacity(total)
    for _ in 0..<total { vals.append(r.u32()) }
    guard (mask & bit) != 0 else { return nil }
    var idx = 0; var b: UInt32 = 1
    while b < bit { if (mask & b) != 0 { idx += 1 }; b <<= 1 }
    return idx < vals.count ? vals[idx] : nil
}

// Send a 32-byte event to the client.
func sendEvent(_ fd: Int32, lsb: Bool, code: UInt8, build: (inout ByteWriter) -> Void) {
    var w = ByteWriter(lsb: lsb)
    w.u8(code); w.u8(0); w.u16(curSeq(fd))
    build(&w)
    while w.bytes.count < 32 { w.u8(0) }
    enqueue(fd, w.bytes)
}
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
    // Large socket buffers so bursts from nxproxy don't back up (FD#8 buffer
    // backpressure was starving the NX peer link).
    var bufsz: Int32 = 1 << 20
    setsockopt(cfd, SOL_SOCKET, SO_RCVBUF, &bufsz, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(cfd, SOL_SOCKET, SO_SNDBUF, &bufsz, socklen_t(MemoryLayout<Int32>.size))
    guard let lsb = readClientSetup(cfd) else { close(cfd); return }
    // Output queue + writer thread (decouples writing from reading).
    let q = OutQueue()
    outQueuesLock.lock(); outQueues[cfd] = q; outQueuesLock.unlock()
    let writer = Thread { while let chunk = q.take() { writeAll(cfd, chunk) } }
    writer.stackSize = 1 << 20; writer.start()
    setSeq(cfd, 0)                              // sequence numbers restart per connection
    sendSetup(cfd, lsb: lsb)
    FileHandle.standardError.write("client connected (lsb=\(lsb))\n".data(using: .utf8)!)

    var unknown: [UInt8: Int] = [:]
    var reqOrder: [(UInt8, UInt8, UInt16)] = []
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
        bumpSeq(cfd)
        if reqOrder.count < 100000 { reqOrder.append((opcode, detail, lenU)) }
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
        case 98: // QueryExtension: present only for RENDER (gtk/xfce need it)
            let nlen = Int(r.u16()); _ = r.u16()
            let name = body.count >= 4 + nlen ? String(decoding: body[4..<4+nlen], as: UTF8.self) : ""
            if name == "RENDER" {
                reply(cfd, lsb: lsb) { $0.u8(1); $0.u8(RENDER_OP); $0.u8(0); $0.u8(128) }
            } else {
                reply(cfd, lsb: lsb) { $0.u8(0); $0.u8(0); $0.u8(0); $0.u8(0) }
            }
        case 99: // ListExtensions -> none
            reply(cfd, lsb: lsb, detail: 0) { _ in }
        case 97: // QueryBestSize -> echo requested size
            _ = r.u32() /*drawable*/; let bw = r.u16(); let bh = r.u16()
            reply(cfd, lsb: lsb) { $0.u16(bw); $0.u16(bh) }
        case 101: // GetKeyboardMapping: body = first-keycode, count, pad
            let first = r.u8(); let count = Int(r.u8())
            let extra = keyboardMappingBytes(first: first, count: max(0, count), lsb: lsb)
            reply(cfd, lsb: lsb, detail: UInt8(KEYSYMS_PER_KEYCODE), extra: extra) { _ in }
        case 119: // GetModifierMapping -> 2 keycodes/modifier (US layout)
            reply(cfd, lsb: lsb, detail: 2, extra: modifierMappingBytes()) { _ in }
        case 84: // AllocColor -> echo for TrueColor
            _ = r.u32() /*cmap*/
            let rd = r.u16(), gn = r.u16(), bl = r.u16()
            let pixel = (UInt32(rd >> 8) << 16) | (UInt32(gn >> 8) << 8) | UInt32(bl >> 8)
            reply(cfd, lsb: lsb) { $0.u16(rd); $0.u16(gn); $0.u16(bl); $0.u16(0); $0.u32(pixel) }
        case 14: // GetGeometry -> root geometry, depth 24
            reply(cfd, lsb: lsb, detail: 24) {
                $0.u32(ROOT); $0.u16(0); $0.u16(0)
                $0.u16(UInt16(fb.w)); $0.u16(UInt16(fb.h)); $0.u16(0)
            }
        case 38: // QueryPointer -> pointer at 0,0 on root
            reply(cfd, lsb: lsb, detail: 1 /*same-screen*/) {
                $0.u32(ROOT); $0.u32(0); $0.u16(0); $0.u16(0); $0.u16(0); $0.u16(0); $0.u16(0)
            }
        case 40: // TranslateCoordinates -> identity
            reply(cfd, lsb: lsb, detail: 1) { $0.u32(0); $0.u16(0); $0.u16(0) }
        case 15: // QueryTree -> root, no parent, 0 children
            reply(cfd, lsb: lsb) { $0.u32(ROOT); $0.u32(0); $0.u16(0); $0.u16(0) }
        case 23: // GetSelectionOwner -> none
            reply(cfd, lsb: lsb) { $0.u32(0) }
        case 3: // GetWindowAttributes (length 3)
            _ = r.u32()
            var p = ByteWriter(lsb: lsb)
            p.u32(VISUAL); p.u16(1); p.u8(0); p.u8(1)
            p.u32(0); p.u32(0); p.u8(0); p.u8(1); p.u8(2); p.u8(0)
            p.u32(CMAP); p.u32(0); p.u32(0); p.u16(0); p.u16(0)
            replyRaw(cfd, lsb: lsb, detail: 0, p.bytes)
        case 44: // QueryKeymap -> all up
            replyRaw(cfd, lsb: lsb, detail: 0, [UInt8](repeating: 0, count: 32))
        case 103: // GetKeyboardControl (length 5)
            var p = ByteWriter(lsb: lsb)
            p.u32(0); p.u8(0); p.u8(0); p.u16(0); p.u16(0); p.u16(0)
            p.raw([UInt8](repeating: 0, count: 32))
            replyRaw(cfd, lsb: lsb, detail: 1, p.bytes)
        case 106: // GetPointerControl
            var p = ByteWriter(lsb: lsb); p.u16(2); p.u16(1); p.u16(4)
            replyRaw(cfd, lsb: lsb, detail: 0, p.bytes)
        case 108: // GetScreenSaver
            replyRaw(cfd, lsb: lsb, detail: 0, [0,0,0,0,0,0])
        case 117: // GetPointerMapping -> 3 buttons
            replyRaw(cfd, lsb: lsb, detail: 3, [1, 2, 3])
        case 91: // QueryColors: cmap, pixels[] -> derive RGB from pixel (TrueColor)
            _ = r.u32()
            let n = (body.count - 4) / 4
            var p = ByteWriter(lsb: lsb)
            p.u16(UInt16(max(0, n))); p.pad(22)
            for _ in 0..<max(0, n) {
                let pix = r.u32()
                let rd = UInt16((pix >> 16) & 0xff), gn = UInt16((pix >> 8) & 0xff), bl = UInt16(pix & 0xff)
                p.u16(rd << 8 | rd); p.u16(gn << 8 | gn); p.u16(bl << 8 | bl); p.u16(0)
            }
            replyRaw(cfd, lsb: lsb, detail: 0, p.bytes)

        case 26: // GrabPointer: detail=owner-events; body: grab-window, ... -> Success
            let gw = r.u32(); dlog("GrabPointer window=\(gw)")
            setInputTarget(cfd, lsb, gw)
            reply(cfd, lsb: lsb, detail: 0) { _ in }      // status = GrabSuccess
        case 31: // GrabKeyboard: detail=owner-events; body: grab-window, ... -> Success
            let gw = r.u32(); dlog("GrabKeyboard window=\(gw)")
            setInputTarget(cfd, lsb, gw)
            reply(cfd, lsb: lsb, detail: 0) { _ in }
        case 45: // OpenFont: fid, name-len, pad, name -> accept (track nothing)
            break
        case 47: // QueryFont -> minimal fixed 6x13 monospace (allCharsExist, no per-char info)
            var p = ByteWriter(lsb: lsb)
            func charinfo() { p.u16(0); p.u16(6); p.u16(6); p.u16(11); p.u16(2); p.u16(0) } // l,r,width,asc,desc,attr
            charinfo(); p.pad(4)            // minBounds
            charinfo(); p.pad(4)            // maxBounds
            p.u16(0); p.u16(255)            // min/max CharOrByte2
            p.u16(0)                        // defaultChar
            p.u16(0)                        // numFontProps
            p.u8(0); p.u8(0); p.u8(0); p.u8(1) // drawDir, minByte1, maxByte1, allCharsExist
            p.u16(11); p.u16(2)             // fontAscent, fontDescent
            p.u32(0)                        // numCharInfos
            replyRaw(cfd, lsb: lsb, detail: 0, p.bytes)
        case 48: // QueryTextExtents -> width = 6px per char
            let nchars = max(0, (body.count) / 2)
            var p = ByteWriter(lsb: lsb)
            p.u16(11); p.u16(2); p.u16(11); p.u16(2)               // font asc/desc, overall asc/desc
            p.u32(UInt32(nchars * 6)); p.u32(0); p.u32(UInt32(nchars * 6)) // width, left, right
            replyRaw(cfd, lsb: lsb, detail: 0, p.bytes)
        case 49: // ListFonts -> advertise the core fonts nxagent expects
            let names = ["fixed", "cursor"]
            var p = ByteWriter(lsb: lsb)
            p.u16(UInt16(names.count)); p.pad(22)
            for n in names { let b = Array(n.utf8); p.u8(UInt8(b.count)); p.raw(b) }
            replyRaw(cfd, lsb: lsb, detail: 0, p.bytes)

        case 1: // CreateWindow: depth(detail), wid, parent, x,y,w,h, border, class, visual, mask, values
            let wid = r.u32(); let parent = r.u32()
            let x = si16(r.u16()), y = si16(r.u16())
            let ww = Int(r.u16()), hh = Int(r.u16())
            _ = r.u16() /*border*/; let wclass = r.u16(); _ = r.u32() /*visual*/
            let mask = r.u32()
            let em = valueFor(&r, mask: mask, bit: 0x800) ?? 0   // CWEventMask
            windows[wid] = (x, y, ww, hh, em); winParent[wid] = parent
            // InputOnly (class 2) windows have no pixels — never give them a
            // surface, or they would composite as opaque black over the desktop.
            if wclass != 2 { compEnsureSurface(wid, ww, hh) }
            if em != 0 { dlog("CreateWindow \(wid) \(ww)x\(hh) eventmask=0x\(String(em, radix: 16))") }
            noteInputWindow(cfd, lsb, wid, em, ww * hh)
        case 2: // ChangeWindowAttributes: window, value-mask, values
            let wid = r.u32(); let mask = r.u32()
            if let em = valueFor(&r, mask: mask, bit: 0x800) {
                var win = windows[wid] ?? (0, 0, fb.w, fb.h, 0); win.mask = em; windows[wid] = win
                dlog("ChangeWindowAttributes \(wid) eventmask=0x\(String(em, radix: 16)) area=\(win.w*win.h)")
                noteInputWindow(cfd, lsb, wid, em, win.w * win.h)
            }
        case 12: // ConfigureWindow: window, mask, pad, values [x,y,w,h,border,sibling,stack]
            let wid = r.u32(); let mask = Int(r.u16()); _ = r.u16()
            var nx: Int?, ny: Int?, nw: Int?, nh: Int?, stackMode: Int?
            if mask & 0x1 != 0 { nx = si16(UInt16(truncatingIfNeeded: r.u32())) }
            if mask & 0x2 != 0 { ny = si16(UInt16(truncatingIfNeeded: r.u32())) }
            if mask & 0x4 != 0 { nw = Int(UInt16(truncatingIfNeeded: r.u32())) }
            if mask & 0x8 != 0 { nh = Int(UInt16(truncatingIfNeeded: r.u32())) }
            if mask & 0x10 != 0 { _ = r.u32() }            // border-width
            if mask & 0x20 != 0 { _ = r.u32() }            // sibling
            if mask & 0x40 != 0 { stackMode = Int(r.u32() & 0xff) }
            var win = windows[wid] ?? (0, 0, fb.w, fb.h, 0)
            if let v = nx { win.x = v }; if let v = ny { win.y = v }
            if let v = nw { win.w = v }; if let v = nh { win.h = v }
            windows[wid] = win
            compEnsureSurface(wid, win.w, win.h)
            if let sm = stackMode {                         // 0=Above 1=Below 2=TopIf 3=BottomIf
                if sm == 1 || sm == 3 { compLowerWindow(wid) } else { compRaiseWindow(wid) }
            }
        case 8: // MapWindow: window -> deliver MapNotify + Expose if selected
            let wid = r.u32()
            compMapWindow(wid)
            let win = windows[wid] ?? (0, 0, fb.w, fb.h, StructureNotifyMask | ExposureMask)
            if (win.mask & StructureNotifyMask) != 0 {
                sendEvent(cfd, lsb: lsb, code: 19) { $0.u32(wid); $0.u32(wid); $0.u8(0) } // MapNotify
            }
            if (win.mask & ExposureMask) != 0 {
                sendEvent(cfd, lsb: lsb, code: 12) {   // Expose (full window, count 0)
                    $0.u32(wid); $0.u16(0); $0.u16(0)
                    $0.u16(UInt16(min(win.w, 0xffff))); $0.u16(UInt16(min(win.h, 0xffff))); $0.u16(0)
                }
            }
        case 10: // UnmapWindow: window -> hide (compositor stops drawing it)
            compUnmapWindow(r.u32())
        case 4:  // DestroyWindow: window -> drop its surface
            let wid = r.u32(); compDestroyWindow(wid)
            drawablesLock.lock(); windows[wid] = nil; winParent[wid] = nil; drawablesLock.unlock()

        case 55: // CreateGC: cid, drawable, value-mask, values
            let cid = r.u32(); _ = r.u32(); let mask = r.u32()
            if let fg = foregroundFrom(&r, mask: mask) { gcForeground[cid] = fg }
        case 56: // ChangeGC: gc, value-mask, values
            let gc = r.u32(); let mask = r.u32()
            if let fg = foregroundFrom(&r, mask: mask) { gcForeground[gc] = fg }
        case 53: // CreatePixmap: depth(detail), pid, drawable, w, h
            let pid = r.u32(); _ = r.u32()
            let pw = Int(r.u16()), ph = Int(r.u16())
            drawablesLock.lock(); pixmaps[pid] = Pixmap(pw, ph); drawablesLock.unlock()
        case 54: // FreePixmap: pixmap
            let pid = r.u32(); drawablesLock.lock(); pixmaps[pid] = nil; drawablesLock.unlock()
        case 62: // CopyArea: src, dst, gc, src-x, src-y, dst-x, dst-y, w, h
            let src = r.u32(); let dst = r.u32(); _ = r.u32()
            let sx = si16(r.u16()), sy = si16(r.u16())
            let dx = si16(r.u16()), dy = si16(r.u16())
            let cw = Int(r.u16()), ch = Int(r.u16())
            dlog("CopyArea \(drwKind(src)) -> \(drwKind(dst)) src(\(sx),\(sy)) dst(\(dx),\(dy)) \(cw)x\(ch)")
            if cw > 0, ch > 0 { drwCopy(src, dst, sx, sy, dx, dy, cw, ch) }
        case 70: // PolyFillRectangle: drawable, gc, rects[x,y,w,h]
            let drw = r.u32(); let gc = r.u32()
            let fg = gcForeground[gc] ?? (0xc0, 0xc0, 0xc0)
            let n = (body.count - 8) / 8
            for _ in 0..<max(0, n) {
                let x = si16(r.u16()), y = si16(r.u16())
                let rw = Int(r.u16()), rh = Int(r.u16())
                drwFill(drw, x, y, rw, rh, fg)
            }
        case 61: // ClearArea: window, x, y, w, h -> paint window background
            let drw = r.u32(); let x = si16(r.u16()), y = si16(r.u16())
            var rw = Int(r.u16()), rh = Int(r.u16())
            if rw == 0 { rw = windows[drw]?.w ?? fb.w }; if rh == 0 { rh = windows[drw]?.h ?? fb.h }
            drwFill(drw, x, y, rw, rh, (0x30, 0x28, 0x20))
        case 72: // PutImage: format(detail), drawable, gc, w,h, dstx,dsty, left-pad, depth, pad2, data
            let format = detail
            let drw = r.u32(); _ = r.u32()
            let iw = Int(r.u16()), ih = Int(r.u16())
            let dx = si16(r.u16()), dy = si16(r.u16())
            if format == 2, iw > 0, ih > 0, body.count >= 20 {   // ZPixmap
                dlog("PutImage -> \(drwKind(drw)) at(\(dx),\(dy)) \(iw)x\(ih)")
                drwPutImageZ(drw, dx, dy, iw, ih, body[20...])
            }

        case RENDER_OP: // RENDER extension — minor opcode is in `detail`
            switch detail {
            case 0: // RenderQueryVersion -> echo client's requested version
                let cmaj = r.u32(); let cmin = r.u32()
                reply(cfd, lsb: lsb) { $0.u32(cmaj); $0.u32(min(cmin, 11)) }
            case 1: // RenderQueryPictFormats
                var pf = ByteWriter(lsb: lsb)
                pf.u32(2); pf.u32(1); pf.u32(2); pf.u32(1); pf.u32(1); pf.pad(4) // counts + unused
                // PICTFORMINFO RGB24
                pf.u32(PF_RGB24); pf.u8(1); pf.u8(24); pf.pad(2)
                pf.u16(16); pf.u16(0xff); pf.u16(8); pf.u16(0xff); pf.u16(0); pf.u16(0xff); pf.u16(0); pf.u16(0)
                pf.u32(0)
                // PICTFORMINFO ARGB32
                pf.u32(PF_ARGB32); pf.u8(1); pf.u8(32); pf.pad(2)
                pf.u16(16); pf.u16(0xff); pf.u16(8); pf.u16(0xff); pf.u16(0); pf.u16(0xff); pf.u16(24); pf.u16(0xff)
                pf.u32(0)
                // PICTSCREEN
                pf.u32(2); pf.u32(PF_RGB24)              // numDepths, fallback
                pf.u8(24); pf.u8(0); pf.u16(1); pf.pad(4) // depth 24, 1 visual
                pf.u32(VISUAL); pf.u32(PF_RGB24)
                pf.u8(32); pf.u8(0); pf.u16(0); pf.pad(4) // depth 32, 0 visuals
                pf.u32(0)                                 // subpixel (1 entry)
                replyRaw(cfd, lsb: lsb, detail: 0, pf.bytes)
            case 2: // RenderQueryPictIndexValues -> none
                reply(cfd, lsb: lsb) { $0.u32(0) }
            case 4: // CreatePicture: pid, drawable, format, mask, values...
                let pid = r.u32(); let drw = r.u32()
                drawablesLock.lock(); pictures[pid] = drw; drawablesLock.unlock()
            case 7: // FreePicture: pid
                let pid = r.u32(); drawablesLock.lock(); pictures[pid] = nil; solidPictures[pid] = nil; drawablesLock.unlock()
            case 33: // CreateSolidFill: pid, color(red,green,blue,alpha u16)
                let pid = r.u32()
                let rd = r.u16(), gn = r.u16(), bl = r.u16(); _ = r.u16()
                drawablesLock.lock()
                solidPictures[pid] = (UInt8(bl >> 8), UInt8(gn >> 8), UInt8(rd >> 8))
                drawablesLock.unlock()
            case 8: // Composite: op, src, mask, dst, src/mask/dst coords, w, h
                _ = r.u8(); r.skip(3)
                let srcP = r.u32(); _ = r.u32(); let dstP = r.u32()
                let sx = si16(r.u16()), sy = si16(r.u16())
                _ = r.u16(); _ = r.u16()                 // mask x,y
                let dx = si16(r.u16()), dy = si16(r.u16())
                let cw = Int(r.u16()), ch = Int(r.u16())
                if cw > 0, ch > 0, let d = pictures[dstP] {
                    if let col = solidPictures[srcP] {     // solid-fill source (menu/popup bg)
                        drwFill(d, dx, dy, cw, ch, col)
                    } else if let s = pictures[srcP] {
                        drwCopy(s, d, sx, sy, dx, dy, cw, ch)
                    }
                }
            case 26: // FillRectangles: op, pad, dst, color(r,g,b,a u16), rects[x,y,w,h]
                _ = r.u8(); r.skip(3)
                let dstP = r.u32()
                let rd = r.u16(), gn = r.u16(), bl = r.u16(); _ = r.u16()
                let col: (UInt8,UInt8,UInt8) = (UInt8(bl >> 8), UInt8(gn >> 8), UInt8(rd >> 8))
                if let d = pictures[dstP] {
                    let n = (body.count - 12) / 8
                    for _ in 0..<max(0, n) {
                        let x = si16(r.u16()), y = si16(r.u16())
                        let rw = Int(r.u16()), rh = Int(r.u16())
                        drwFill(d, x, y, rw, rh, col)
                    }
                }
            case 17: renderCreateGlyphSet(r.u32())               // CreateGlyphSet
            case 19: renderFreeGlyphSet(r.u32())                 // FreeGlyphSet
            case 20: renderAddGlyphs(body, lsb: lsb)             // AddGlyphs
            case 23: renderCompositeGlyphs(body, lsb: lsb, idBytes: 1)  // CompositeGlyphs8
            case 24: renderCompositeGlyphs(body, lsb: lsb, idBytes: 2)  // CompositeGlyphs16
            case 25: renderCompositeGlyphs(body, lsb: lsb, idBytes: 4)  // CompositeGlyphs32
            default:
                break // Trapezoids/Triangles/etc.: accept, no reply
            }

        default:
            if replyExpecting.contains(opcode) {
                // Keep the stream in sync: a correctly-framed empty reply so
                // nxproxy/nxagent round-trips never stall waiting on us.
                replyRaw(cfd, lsb: lsb, detail: 0, [])
            }
            unknown[opcode, default: 0] += 1
        }
    }
    let summary = unknown.sorted { $0.value > $1.value }.prefix(12)
        .map { "op\($0.key)×\($0.value)" }.joined(separator: " ")
    var allHist: [UInt8: Int] = [:]
    for rq in reqOrder { allHist[rq.0, default: 0] += 1 }
    let full = allHist.sorted { $0.value > $1.value }
        .map { "op\($0.key)×\($0.value)" }.joined(separator: " ")
    let tail = reqOrder.suffix(30).map { "op\($0.0)/d\($0.1)/l\($0.2)" }.joined(separator: " ")
    FileHandle.standardError.write("client disconnected. total=\(reqOrder.count) unhandled: \(summary)\nALL: \(full)\nLAST30: \(tail)\n".data(using: .utf8)!)
    q.close()
    outQueuesLock.lock(); outQueues[cfd] = nil; outQueuesLock.unlock()
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
