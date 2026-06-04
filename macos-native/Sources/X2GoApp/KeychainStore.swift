import Foundation
import Security

/// Stores per-profile SSH passwords in the macOS login Keychain (generic password
/// items keyed by user@host:port).
enum KeychainStore {
    private static let service = "org.x2go.X2GoMac"
    private static func account(_ p: SessionProfile) -> String { "\(p.user)@\(p.host):\(p.sshPort)" }

    static func savePassword(_ password: String, for p: SessionProfile) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(p),
        ]
        SecItemDelete(base as CFDictionary)   // replace any existing
        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func password(for p: SessionProfile) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(p),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    static func deletePassword(for p: SessionProfile) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(p),
        ]
        SecItemDelete(q as CFDictionary)
    }
}
