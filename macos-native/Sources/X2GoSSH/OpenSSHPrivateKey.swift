import Foundation
import Crypto
import NIOSSH

/// Minimal parser for unencrypted OpenSSH private keys (`-----BEGIN OPENSSH
/// PRIVATE KEY-----`). v1 supports ed25519 (the modern default); other types
/// throw `unsupported`. Encrypted keys throw `encryptedNotSupported` (passphrase
/// handling is a later addition).
public enum OpenSSHPrivateKey {
    public enum ParseError: Error, CustomStringConvertible, LocalizedError {
        case notOpenSSHFormat
        case encryptedNotSupported
        case unsupported(String)
        case malformed

        public var description: String {
            switch self {
            case .notOpenSSHFormat:
                return "Not an OpenSSH key. RSA/DSA keys in the old PEM format aren't supported — convert to ed25519/ECDSA, or use password auth."
            case .encryptedNotSupported:
                return "This private key is passphrase-encrypted, which isn't supported yet. Use an unencrypted key, ssh-agent isn't available, or use password auth."
            case .unsupported(let t):
                return "Unsupported key type '\(t)'. Supported: ed25519 and ECDSA (nistp256/384/521). RSA/DSA aren't supported by the SSH library — use an ed25519/ECDSA key or password auth."
            case .malformed:
                return "Malformed OpenSSH private key."
            }
        }
        public var errorDescription: String? { description }
    }

    /// Load a private key file and return a NIOSSHPrivateKey for SSH auth.
    public static func load(contentsOf url: URL) throws -> NIOSSHPrivateKey {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(pem: text)
    }

    public static func parse(pem: String) throws -> NIOSSHPrivateKey {
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let end = "-----END OPENSSH PRIVATE KEY-----"
        guard let b = pem.range(of: begin), let e = pem.range(of: end) else {
            throw ParseError.notOpenSSHFormat
        }
        let body = pem[b.upperBound..<e.lowerBound]
            .split(whereSeparator: \.isNewline)
            .joined()
        guard let blob = Data(base64Encoded: body) else { throw ParseError.malformed }

        var r = Reader(blob)
        // magic: "openssh-key-v1\0"
        guard r.readBytes(15) == Array("openssh-key-v1\u{0}".utf8) else { throw ParseError.notOpenSSHFormat }
        let cipher = try r.readString()      // "none" if unencrypted
        _ = try r.readString()               // kdfname
        _ = try r.readSSHString()            // kdfoptions
        guard cipher == "none" else { throw ParseError.encryptedNotSupported }
        let nKeys = try r.readUInt32()
        guard nKeys == 1 else { throw ParseError.malformed }
        _ = try r.readSSHString()            // public key blob (skip)
        var priv = Reader(try r.readSSHString())   // private section
        _ = try priv.readUInt32()            // checkint1
        _ = try priv.readUInt32()            // checkint2
        let keyType = try priv.readString()
        switch keyType {
        case "ssh-ed25519":
            _ = try priv.readSSHString()           // public key (32 bytes)
            let secret = try priv.readSSHString()  // 64 bytes: seed(32) + pub(32)
            guard secret.count >= 32 else { throw ParseError.malformed }
            let seed = secret.prefix(32)
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            return NIOSSHPrivateKey(ed25519Key: key)

        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            _ = try priv.readSSHString()              // curve name
            _ = try priv.readSSHString()              // public EC point
            let scalar = try priv.readSSHString()     // private scalar (mpint)
            let size = keyType.hasSuffix("256") ? 32 : (keyType.hasSuffix("384") ? 48 : 66)
            let raw = fixedWidth(scalar, size)
            switch size {
            case 32: return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: raw))
            case 48: return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: raw))
            default: return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: raw))
            }

        default:
            throw ParseError.unsupported(keyType)
        }
    }

    /// Normalise an SSH mpint to exactly `size` big-endian bytes (strip a leading
    /// sign byte, left-pad with zeros) for Crypto's `rawRepresentation`.
    private static func fixedWidth(_ data: Data, _ size: Int) -> Data {
        var bytes = [UInt8](data)
        while bytes.count > size, bytes.first == 0 { bytes.removeFirst() }
        if bytes.count < size { bytes = [UInt8](repeating: 0, count: size - bytes.count) + bytes }
        return Data(bytes)
    }

    /// Cursor over an SSH wire-format buffer (uint32-length-prefixed strings).
    private struct Reader {
        private let data: Data
        private var i: Int
        init(_ d: Data) { data = d; i = d.startIndex }

        mutating func readBytes(_ n: Int) -> [UInt8]? {
            guard i + n <= data.endIndex else { return nil }
            defer { i += n }
            return Array(data[i..<(i + n)])
        }
        mutating func readUInt32() throws -> UInt32 {
            guard let b = readBytes(4) else { throw ParseError.malformed }
            return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
        }
        mutating func readSSHString() throws -> Data {
            let n = Int(try readUInt32())
            guard i + n <= data.endIndex else { throw ParseError.malformed }
            defer { i += n }
            return data.subdata(in: i..<(i + n))
        }
        mutating func readString() throws -> String {
            String(decoding: try readSSHString(), as: UTF8.self)
        }
    }
}
