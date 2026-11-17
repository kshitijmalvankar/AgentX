import AgentXRemote
import CryptoKit
import Foundation
import Security

/// An iPhone allowed to connect (or being paired).
public struct PairedDevice: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var pairedAt: Date
    public var lastSeen: Date?
    /// You confirmed it on the Mac. Until then it gets nothing but "waiting".
    public var confirmed: Bool
    /// A pairing code that hasn't been used stops working at this time.
    public var pairingExpires: Date?

    public func isUsable(now: Date = Date()) -> Bool {
        confirmed || (pairingExpires.map { now < $0 } ?? false)
    }
}

/// Where pairing keys live. Keychain on the Mac; in memory in tests.
protocol PhoneKeyStore: Sendable {
    func key(for id: UUID) -> SymmetricKey?
    func save(_ key: SymmetricKey, for id: UUID) throws
    func delete(_ id: UUID)
}

/// Pairing keys in your login Keychain, one item per phone. Only AgentX
/// (this signed app) can read them without asking you.
struct KeychainPhoneKeys: PhoneKeyStore {
    let service = "AgentX iPhone link" + (AppChannel.current.isDev ? " (Dev)" : "")

    func key(for id: UUID) -> SymmetricKey? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    func save(_ key: SymmetricKey, for id: UUID) throws {
        delete(id)
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                         kSecAttrAccount as String: id.uuidString, kSecAttrLabel as String: service,
                                         kSecValueData as String: key.withUnsafeBytes { Data($0) },
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw ToolError("Couldn't save the pairing key in the Keychain (error \(status)).") }
    }

    func delete(_ id: UUID) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString]
        SecItemDelete(query as CFDictionary)
    }
}

/// Keys the listener may use, readable from its background queue. Only usable
/// devices (confirmed, or a pairing code still in its 5 minutes) are in here.
final class PhoneKeyTable: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: SymmetricKey] = [:]

    func set(_ keys: [UUID: SymmetricKey]) {
        lock.lock(); self.keys = keys; lock.unlock()
    }

    func key(for id: UUID) -> SymmetricKey? {
        lock.lock(); defer { lock.unlock() }
        return keys[id]
    }
}

/// The Mac's IPv4 addresses a phone can reach: the local network and
/// Tailscale (100.64.0.0/10). Goes into the pairing code as a fallback for
/// when Bonjour can't find the Mac.
enum LocalAddresses {
    static func reachable() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (entry.ifa_flags & UInt32(IFF_UP)) != 0, (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if isReachable(ip), !result.contains(ip) { result.append(ip) }
        }
        return result.sorted { rank($0) < rank($1) }
    }

    /// Private networks and Tailscale; not public addresses.
    static func isReachable(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true   // Tailscale / carrier-grade NAT
        default: return false
        }
    }

    /// Home network first, Tailscale last.
    private static func rank(_ ip: String) -> Int { ip.hasPrefix("100.") ? 1 : 0 }
}
