import Foundation

// Parsers for x2go command output, matching onmainwindow.cpp's field layouts
// (getSessionFromString / getNewSessionFromString / the resume gr_port= lines).

/// One row of `x2golistsessions`.
public struct SessionInfo: Sendable, Equatable {
    public let agentPid: String
    public let sessionId: String
    public let display: String
    public let server: String
    public let status: String        // "S" suspended, "R" running
    public let createTime: String
    public let cookie: String
    public let clientIp: String
    public let grPort: String
    public let sndPort: String
    public let fsPort: String?

    public var isSuspended: Bool { status == "S" }
    public var isRunning: Bool { status == "R" }
    public var displayNumber: Int? { Int(display) }
    public var grPortNumber: Int? { Int(grPort) }
}

/// Reply to `x2gostartagent` (new session).
public struct AgentReply: Sendable, Equatable {
    public let display: String
    public let cookie: String
    public let agentPid: String
    public let sessionId: String
    public let grPort: String
    public let sndPort: String
    public let fsPort: String?
    public var displayNumber: Int? { Int(display) }
    public var grPortNumber: Int? { Int(grPort) }
}

/// Updated ports from `x2goresume-session`.
public struct ResumePorts: Sendable, Equatable {
    public var grPort: String?
    public var sndPort: String?
    public var fsPort: String?
}

public enum X2GoParser {

    /// Parse `x2golistsessions` output into rows, skipping malformed lines
    /// (perl warnings etc. — rows with < 10 fields, per the Qt client).
    public static func sessionList(_ output: String) -> [SessionInfo] {
        output.split(whereSeparator: \.isNewline).compactMap { sessionRow(String($0)) }
    }

    public static func sessionRow(_ line: String) -> SessionInfo? {
        let f = line.components(separatedBy: "|")
        guard f.count >= 10 else { return nil }
        return SessionInfo(
            agentPid: f[0], sessionId: f[1], display: f[2], server: f[3], status: f[4],
            createTime: f[5], cookie: f[6], clientIp: f[7], grPort: f[8], sndPort: f[9],
            fsPort: f.count > 13 ? f[13] : nil)
    }

    /// Parse the `x2gostartagent` reply: `display|cookie|agentPid|sessionId|grPort|sndPort[|fsPort]`
    /// (newlines are normalised to `|`, as the Qt client does).
    public static func newSessionReply(_ output: String) -> AgentReply? {
        let joined = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "|")
        let f = joined.components(separatedBy: "|").filter { !$0.isEmpty }
        guard f.count >= 6 else { return nil }
        return AgentReply(display: f[0], cookie: f[1], agentPid: f[2], sessionId: f[3],
                          grPort: f[4], sndPort: f[5], fsPort: f.count > 6 ? f[6] : nil)
    }

    /// Parse `x2goresume-session` reply (`gr_port=`, `sound_port=`, `fs_port=`).
    public static func resumeReply(_ output: String) -> ResumePorts {
        var ports = ResumePorts()
        for line in output.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("gr_port=") { ports.grPort = String(l.dropFirst("gr_port=".count)) }
            else if l.hasPrefix("sound_port=") { ports.sndPort = String(l.dropFirst("sound_port=".count)) }
            else if l.hasPrefix("fs_port=") { ports.fsPort = String(l.dropFirst("fs_port=".count)) }
        }
        return ports
    }
}
