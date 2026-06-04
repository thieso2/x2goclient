// x2go-probe — headless verification CLI for the pure-Swift SSH engine.
//
//   x2go-probe exec    [--host H --port P --user U --key PATH] [--cmd "..."]
//   x2go-probe forward [--host H --port P --user U --key PATH]
//                      [--local L --remote-host RH --remote-port RP]
//
// Defaults target the live test server (10.248.1.20 / thies / id_x2go_test).
import Foundation
import Darwin
import X2GoSSH

func flag(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

/// Connect a plain TCP socket and read up to maxBytes (used to prove the tunnel).
func readSome(host: String, port: Int, maxBytes: Int, timeoutSec: Int) -> [UInt8]? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    inet_pton(AF_INET, host, &addr.sin_addr)
    var tv = timeval(tv_sec: timeoutSec, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: maxBytes)
    let n = recv(fd, &buf, maxBytes, 0)
    guard n > 0 else { return [] }
    return Array(buf[0..<n])
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: x2go-probe <exec|forward> [flags]")
    exit(2)
}
let sub = args[1]
let host = flag("--host") ?? "10.248.1.20"
let port = Int(flag("--port") ?? "22") ?? 22
let user = flag("--user") ?? "thies"
let keyPath = flag("--key") ?? "\(NSHomeDirectory())/.ssh/id_x2go_test"

let conn = SSHConnection(
    endpoint: SSHEndpoint(host: host, port: port, username: user),
    credentials: [.privateKeyFile(URL(fileURLWithPath: keyPath))])

do {
    FileHandle.standardError.write("connecting \(user)@\(host):\(port) …\n".data(using: .utf8)!)
    try await conn.connect()

    switch sub {
    case "exec":
        let command = flag("--cmd") ?? "export HOSTNAME && x2golistsessions"
        let r = try await conn.exec(command)
        print("exit=\(r.exitStatus)")
        print("--- stdout ---")
        print(r.stdoutString)
        if !r.stderrString.isEmpty { print("--- stderr ---"); print(r.stderrString) }

    case "forward":
        let local = Int(flag("--local") ?? "30022") ?? 30022
        let rhost = flag("--remote-host") ?? "localhost"
        let rport = Int(flag("--remote-port") ?? "22") ?? 22
        let fwd = try await conn.openLocalForward(localPort: local, remoteHost: rhost, remotePort: rport)
        print("forwarding 127.0.0.1:\(fwd.localPort) -> \(rhost):\(rport)")
        if let bytes = readSome(host: "127.0.0.1", port: fwd.localPort, maxBytes: 256, timeoutSec: 5) {
            print("read \(bytes.count) bytes through the tunnel:")
            print(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            if bytes.isEmpty {
                FileHandle.standardError.write("WARN: 0 bytes — tunnel opened but no data\n".data(using: .utf8)!)
                await fwd.close(); await conn.disconnect(); exit(1)
            }
        } else {
            FileHandle.standardError.write("ERROR: could not connect to local forward port\n".data(using: .utf8)!)
            await fwd.close(); await conn.disconnect(); exit(1)
        }
        await fwd.close()

    default:
        print("unknown subcommand: \(sub)"); exit(2)
    }

    await conn.disconnect()
    print("OK")
} catch {
    FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
    exit(1)
}
