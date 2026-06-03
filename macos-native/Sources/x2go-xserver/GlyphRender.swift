import Foundation

// RENDER glyph (text) support. GTK/Qt draw text via CompositeGlyphs: the client
// uploads glyph bitmaps (AddGlyphs) into a glyphset, then composites runs of
// them. Without this, menus/labels render as empty boxes. We store each glyph's
// A8 alpha coverage and blit it as dark text (the common menu/label case),
// alpha-blended over whatever is already in the destination drawable.

struct Glyph {
    let w: Int, h: Int
    let originX: Int, originY: Int   // bearing: origin relative to bitmap top-left
    let advance: Int                 // x advance
    let alpha: [UInt8]               // w*h coverage
}

nonisolated(unsafe) var glyphSets: [UInt32: [UInt32: Glyph]] = [:]

func renderCreateGlyphSet(_ gsid: UInt32) {
    drawablesLock.lock(); glyphSets[gsid] = [:]; drawablesLock.unlock()
}
func renderFreeGlyphSet(_ gsid: UInt32) {
    drawablesLock.lock(); glyphSets[gsid] = nil; drawablesLock.unlock()
}

/// AddGlyphs: glyphset, nglyphs, [glyph-id], [GLYPHINFO(12)], image-data (A8,
/// each glyph's rows padded to a 4-byte scanline).
func renderAddGlyphs(_ body: [UInt8], lsb: Bool) {
    var r = ByteReader(body, lsb: lsb)
    let gsid = r.u32()
    let n = Int(r.u32())
    guard n > 0, n < 100000 else { return }
    var ids = [UInt32](); ids.reserveCapacity(n)
    for _ in 0..<n { ids.append(r.u32()) }
    var infos = [(w: Int, h: Int, x: Int, y: Int, dx: Int)]()
    infos.reserveCapacity(n)
    for _ in 0..<n {
        let w = Int(r.u16()), h = Int(r.u16())
        let x = si16(r.u16()), y = si16(r.u16())
        let dx = si16(r.u16()); _ = r.u16()   // yOff ignored
        infos.append((w, h, x, y, dx))
    }
    drawablesLock.lock(); defer { drawablesLock.unlock() }
    if glyphSets[gsid] == nil { glyphSets[gsid] = [:] }
    for i in 0..<n {
        let gi = infos[i]
        let stride = (gi.w + 3) & ~3            // A8 scanline pad to 4 bytes
        var a = [UInt8](repeating: 0, count: max(0, gi.w * gi.h))
        for row in 0..<gi.h {
            for col in 0..<gi.w {
                let v = r.u8()
                if col < gi.w { a[row * gi.w + col] = v }
            }
            for _ in gi.w..<stride { _ = r.u8() }   // row padding
        }
        glyphSets[gsid]?[ids[i]] = Glyph(w: gi.w, h: gi.h, originX: gi.x, originY: gi.y,
                                         advance: gi.dx, alpha: a)
    }
}

/// CompositeGlyphs8/16/32: op, pad, src, dst, mask-format, glyphset, srcX, srcY,
/// then a list of glyph elements. We ignore the source colour and draw dark text
/// (correct for the dominant light-menu case), alpha-blended into the drawable.
func renderCompositeGlyphs(_ body: [UInt8], lsb: Bool, idBytes: Int) {
    var r = ByteReader(body, lsb: lsb)
    _ = r.u8(); r.skip(3)                       // op + pad
    _ = r.u32()                                 // src picture
    let dstP = r.u32()
    _ = r.u32()                                 // mask format
    var gsid = r.u32()
    _ = r.u16(); _ = r.u16()                    // srcX, srcY
    guard let dst = pictures[dstP] else { return }

    var penX = 0, penY = 0
    fb.lock.lock(); drawablesLock.lock()
    defer { drawablesLock.unlock(); fb.lock.unlock() }
    while r.remaining >= 8 {
        let count = Int(r.u8())
        if count == 255 {                       // glyphset change: next 4 bytes = new gsid
            r.skip(3); gsid = r.u32(); continue
        }
        r.skip(3)
        penX += si16(r.u16())                   // element dx
        penY += si16(r.u16())                   // element dy
        guard let set = glyphSets[gsid] else { break }
        for _ in 0..<count {
            let gid: UInt32
            switch idBytes {
            case 1: gid = UInt32(r.u8())
            case 2: gid = UInt32(r.u16())
            default: gid = r.u32()
            }
            if let g = set[gid] {
                let bx = penX - g.originX, by = penY - g.originY
                for yy in 0..<g.h {
                    for xx in 0..<g.w {
                        let a = g.alpha[yy * g.w + xx]
                        if a == 0 { continue }
                        let p = drwGet(dst, bx + xx, by + yy)
                        // blend toward black by coverage
                        let inv = 255 - Int(a)
                        let nr = UInt8(Int(p.0) * inv / 255)
                        let ng = UInt8(Int(p.1) * inv / 255)
                        let nb = UInt8(Int(p.2) * inv / 255)
                        drwSet(dst, bx + xx, by + yy, (nr, ng, nb, 0xff))
                    }
                }
                penX += g.advance
            }
        }
        if idBytes == 1 {                        // pad glyph-id run to 4 bytes
            let pad = (4 - (count % 4)) % 4; r.skip(pad)
        } else if idBytes == 2 {
            let pad = (count * 2) % 4; r.skip(pad == 0 ? 0 : 4 - pad)
        }
    }
}
