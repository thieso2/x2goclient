import Foundation

// Per-window compositor. Each window owns a BGRA backing surface; drawing goes
// into the owning window's surface (window-local coords), and the framebuffer is
// rebuilt by compositing all mapped windows in stacking (z) order. This is what
// makes menus/popups/new windows appear and persist: a background (root) redraw
// only touches the root surface, so windows stacked above it are no longer
// clobbered — they are re-composited on top every frame.

final class Surface: @unchecked Sendable {
    var w: Int, h: Int
    var px: [UInt8]                       // BGRA, w*h*4
    var drawn = false                     // has anything been rendered into it?
    init(_ w: Int, _ h: Int) {
        self.w = max(1, w); self.h = max(1, h)
        px = [UInt8](repeating: 0, count: self.w * self.h * 4)
    }
    func resize(_ nw: Int, _ nh: Int) {
        let a = max(1, nw), b = max(1, nh)
        if a == w && b == h { return }
        var np = [UInt8](repeating: 0, count: a * b * 4)
        let cw = min(w, a), ch = min(h, b)
        for y in 0..<ch {
            let s = y * w * 4, d = y * a * 4
            for i in 0..<(cw * 4) { np[d + i] = px[s + i] }
        }
        w = a; h = b; px = np
    }
}

nonisolated(unsafe) var winSurface: [UInt32: Surface] = [:]
nonisolated(unsafe) var winMapped: [UInt32: Bool] = [:]
nonisolated(unsafe) var stackOrder: [UInt32] = []   // bottom -> top

// Caller must hold drawablesLock.
func surfaceFor(_ d: UInt32) -> Surface? {
    if let s = winSurface[d] { return s }
    if d == ROOT {
        let s = Surface(fb.w, fb.h); winSurface[ROOT] = s; winMapped[ROOT] = true
        if !stackOrder.contains(ROOT) { stackOrder.insert(ROOT, at: 0) }
        return s
    }
    if let win = windows[d] {
        let s = Surface(win.w, win.h); winSurface[d] = s
        if !stackOrder.contains(d) { stackOrder.append(d) }
        return s
    }
    return nil
}

func compEnsureSurface(_ wid: UInt32, _ w: Int, _ h: Int) {
    drawablesLock.lock(); defer { drawablesLock.unlock() }
    if let s = winSurface[wid] { s.resize(w, h) }
    else { winSurface[wid] = Surface(w, h); if !stackOrder.contains(wid) { stackOrder.append(wid) } }
}
func compMapWindow(_ wid: UInt32) {
    drawablesLock.lock(); defer { drawablesLock.unlock() }
    winMapped[wid] = true
    if let i = stackOrder.firstIndex(of: wid) { stackOrder.remove(at: i) }
    stackOrder.append(wid)                       // raise on map
}
func compUnmapWindow(_ wid: UInt32) {
    drawablesLock.lock(); defer { drawablesLock.unlock() }
    winMapped[wid] = false
}
func compDestroyWindow(_ wid: UInt32) {
    drawablesLock.lock(); defer { drawablesLock.unlock() }
    winSurface[wid] = nil; winMapped[wid] = nil
    if let i = stackOrder.firstIndex(of: wid) { stackOrder.remove(at: i) }
}
func compRaiseWindow(_ wid: UInt32) {
    drawablesLock.lock(); defer { drawablesLock.unlock() }
    if let i = stackOrder.firstIndex(of: wid) { stackOrder.remove(at: i); stackOrder.append(wid) }
}
func compLowerWindow(_ wid: UInt32) {
    drawablesLock.lock(); defer { drawablesLock.unlock() }
    if let i = stackOrder.firstIndex(of: wid) { stackOrder.remove(at: i); stackOrder.insert(wid, at: 0) }
}

/// Desktop is "ready" once a non-full-screen window (panel/icon/app) has been
/// drawn — not just the base full-screen mirror windows.
func compDesktopReady() -> Bool {
    drawablesLock.lock(); defer { drawablesLock.unlock() }
    for wid in stackOrder {
        guard let s = winSurface[wid], winMapped[wid] == true, s.drawn else { continue }
        if s.w < fb.w && s.h < fb.h && s.w > 4 && s.h > 4 { return true }
    }
    return false
}

func compDumpStack(_ tag: String) {
    drawablesLock.lock(); defer { drawablesLock.unlock() }
    let parts = stackOrder.compactMap { wid -> String? in
        guard let s = winSurface[wid], winMapped[wid] == true, s.drawn else { return nil }
        let (ox, oy) = winAbsOrigin(wid)
        return "\(wid)@(\(ox),\(oy))[\(s.w)x\(s.h)]"
    }
    FileHandle.standardError.write("STACK[\(tag)] bottom->top: \(parts.joined(separator: " "))\n".data(using: .utf8)!)
}

nonisolated(unsafe) var compFrame = 0
/// Rebuild the framebuffer from all mapped window surfaces, bottom to top.
func compositeToFramebuffer() {
    drawablesLock.lock(); fb.lock.lock()
    defer { fb.lock.unlock(); drawablesLock.unlock() }
    let W = fb.w, H = fb.h
    compFrame += 1
    if drawLog && compFrame % 30 == 1 {
        let parts = stackOrder.compactMap { wid -> String? in
            guard let s = winSurface[wid] else { return nil }
            let (ox, oy) = winAbsOrigin(wid)
            return "\(wid):m=\(winMapped[wid] == true ? 1 : 0)d=\(s.drawn ? 1 : 0)@(\(ox),\(oy))[\(s.w)x\(s.h)]"
        }
        FileHandle.standardError.write("COMPOSITE \(parts.joined(separator: " "))\n".data(using: .utf8)!)
    }
    for i in 0..<fb.px.count { fb.px[i] = 0 }     // clear to black
    fb.px.withUnsafeMutableBufferPointer { dst in
        for wid in stackOrder {
            // Skip never-drawn windows: empty InputOutput wrappers/overlays use
            // background None/ParentRelative and must be transparent, not black.
            guard winMapped[wid] == true, let s = winSurface[wid], s.drawn else { continue }
            let (ox, oy) = winAbsOrigin(wid)
            let sw = s.w, sh = s.h
            let y0 = max(0, -oy), y1 = min(sh, H - oy)
            let x0 = max(0, -ox), x1 = min(sw, W - ox)
            if y0 >= y1 || x0 >= x1 { continue }
            s.px.withUnsafeBufferPointer { src in
                for y in y0..<y1 {
                    var so = (y * sw + x0) * 4
                    var dp = ((oy + y) * W + (ox + x0)) * 4
                    for _ in x0..<x1 {
                        dst[dp] = src[so]; dst[dp+1] = src[so+1]; dst[dp+2] = src[so+2]; dst[dp+3] = 0xff
                        so += 4; dp += 4
                    }
                }
            }
        }
    }
}
