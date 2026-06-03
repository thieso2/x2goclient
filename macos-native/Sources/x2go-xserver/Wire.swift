import Foundation

/// Little/big-endian byte writer for the X11 wire protocol.
struct ByteWriter {
    var bytes: [UInt8] = []
    var lsb: Bool = true

    init(lsb: Bool = true) { self.lsb = lsb }

    mutating func u8(_ v: UInt8) { bytes.append(v) }

    mutating func u16(_ v: UInt16) {
        if lsb { bytes.append(UInt8(v & 0xff)); bytes.append(UInt8(v >> 8)) }
        else   { bytes.append(UInt8(v >> 8));   bytes.append(UInt8(v & 0xff)) }
    }

    mutating func u32(_ v: UInt32) {
        if lsb {
            bytes.append(UInt8(v & 0xff)); bytes.append(UInt8((v >> 8) & 0xff))
            bytes.append(UInt8((v >> 16) & 0xff)); bytes.append(UInt8((v >> 24) & 0xff))
        } else {
            bytes.append(UInt8((v >> 24) & 0xff)); bytes.append(UInt8((v >> 16) & 0xff))
            bytes.append(UInt8((v >> 8) & 0xff)); bytes.append(UInt8(v & 0xff))
        }
    }

    mutating func pad(_ n: Int) { for _ in 0..<n { bytes.append(0) } }
    mutating func raw(_ b: [UInt8]) { bytes.append(contentsOf: b) }

    mutating func string(_ s: String) {
        let d = Array(s.utf8); bytes.append(contentsOf: d)
        let p = (4 - (d.count % 4)) % 4
        pad(p)
    }
}

/// Reads X11 integers out of a request body with a fixed byte order.
struct ByteReader {
    let data: [UInt8]
    let lsb: Bool
    var off: Int = 0
    init(_ data: [UInt8], lsb: Bool) { self.data = data; self.lsb = lsb }

    mutating func u8() -> UInt8 { defer { off += 1 }; return off < data.count ? data[off] : 0 }
    mutating func u16() -> UInt16 {
        let a = UInt16(u8()), b = UInt16(u8()); return lsb ? (a | b << 8) : (a << 8 | b)
    }
    mutating func u32() -> UInt32 {
        let a = UInt32(u8()), b = UInt32(u8()), c = UInt32(u8()), d = UInt32(u8())
        return lsb ? (a | b << 8 | c << 16 | d << 24) : (a << 24 | b << 16 | c << 8 | d)
    }
    mutating func skip(_ n: Int) { off += n }
}
