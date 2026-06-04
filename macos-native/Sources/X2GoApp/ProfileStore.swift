import Foundation
import SwiftUI
import X2GoProtocol

/// Persists session profiles as JSON in the app's Application Support dir.
@MainActor
@Observable
final class ProfileStore {
    private(set) var profiles: [SessionProfile] = []
    private let url: URL

    init() {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)) ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = base.appendingPathComponent("X2Go", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("profiles.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SessionProfile].self, from: data) else { return }
        profiles = decoded
    }

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(profiles) { try? data.write(to: url, options: .atomic) }
    }

    func add(_ p: SessionProfile) { profiles.append(p); save() }

    func update(_ p: SessionProfile) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p; save() }
    }

    func delete(_ p: SessionProfile) { profiles.removeAll { $0.id == p.id }; save() }

    /// One-time import from the legacy Qt client's ~/.x2goclient/sessions INI.
    /// Adds profiles whose name isn't already present. Returns the count added.
    @discardableResult
    func importLegacy() -> Int {
        let path = NSHomeDirectory() + "/.x2goclient/sessions"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        let imported = LegacyINI.parseProfiles(text)
        let existing = Set(profiles.map { $0.name })
        let fresh = imported.filter { !existing.contains($0.name) }
        profiles.append(contentsOf: fresh)
        if !fresh.isEmpty { save() }
        return fresh.count
    }
}

/// Minimal INI parser for the legacy sessions file (sections `[id]`, `key=value`).
enum LegacyINI {
    static func parseProfiles(_ text: String) -> [SessionProfile] {
        var sections: [(String, [String: String])] = []
        var current: String? = nil
        var kv: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                if let c = current { sections.append((c, kv)) }
                current = String(line.dropFirst().dropLast()); kv = [:]
            } else if let eq = line.firstIndex(of: "=") {
                let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                let v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                kv[k] = v
            }
        }
        if let c = current { sections.append((c, kv)) }

        return sections.compactMap { id, kv in
            guard let host = kv["host"], !host.isEmpty else { return nil }
            var p = SessionProfile()
            p.name = kv["name"].flatMap { $0.isEmpty ? nil : $0 } ?? id
            p.host = host
            p.user = kv["user"] ?? ""
            p.sshPort = kv["sshport"].flatMap { Int($0) } ?? 22
            if let key = kv["key"], !key.isEmpty { p.keyPath = key }
            if let cmd = kv["command"], !cmd.isEmpty { p.command = cmd }
            p.rootless = (kv["rootless"] == "true" || kv["rootless"] == "1")
            if kv["fullscreen"] == "true" || kv["fullscreen"] == "1" { p.displayKind = .fullscreen }
            else if kv["maxdim"] == "true" || kv["maxdim"] == "1" { p.displayKind = .maxAvailable }
            else { p.displayKind = .custom }
            p.width = kv["width"].flatMap { Int($0) } ?? 1280
            p.height = kv["height"].flatMap { Int($0) } ?? 800
            if let pk = kv["pack"], !pk.isEmpty {
                // legacy pack may already include a "-N" quality suffix
                p.pack = pk.contains("-") ? String(pk.split(separator: "-").first!) : pk
            }
            p.quality = kv["quality"].flatMap { Int($0) } ?? 9
            if let sp = kv["speed"], let idx = Int(sp),
               idx >= 0, idx < LinkSpeed.allCases.count {
                p.speed = LinkSpeed.allCases[idx]
            } else if let sp = kv["speed"], let ls = LinkSpeed(rawValue: sp) {
                p.speed = ls
            }
            if let cm = kv["clipboard"], let mode = ClipboardMode(rawValue: cm) { p.clipboard = mode }
            return p
        }
    }
}
