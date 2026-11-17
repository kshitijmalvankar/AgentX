import CryptoKit
import Foundation

/// What the Mac's pairing QR code carries, and what the phone keeps
/// afterwards (in its Keychain): which Mac, how to reach it, and the
/// pairing key. The code works once, for a few minutes, and the Mac still
/// asks you to confirm the phone before it shares anything.
public struct PairingCode: Equatable, Sendable {
    /// The id the Mac gave this phone (sent in every hello).
    public var deviceID: UUID
    /// 32-byte pairing key.
    public var key: Data
    /// Bonjour name the Mac advertises ("AgentX on Kshitij's Mac").
    public var serviceName: String
    /// The Mac's port, for reaching it by address (e.g. over Tailscale).
    public var port: UInt16
    /// The Mac's addresses when the code was made (Wi-Fi, Tailscale).
    public var addresses: [String]
    /// The Mac's name, for display.
    public var macName: String
    /// The code stops working after this.
    public var expires: Date

    public static let scheme = "agentx-pair"

    public init(deviceID: UUID, key: Data, serviceName: String, port: UInt16, addresses: [String], macName: String, expires: Date) {
        self.deviceID = deviceID
        self.key = key
        self.serviceName = serviceName
        self.port = port
        self.addresses = addresses
        self.macName = macName
        self.expires = expires
    }

    public var symmetricKey: SymmetricKey { SymmetricKey(data: key) }

    /// `agentx-pair://v1?d=…&k=…&n=…&p=…&a=…&m=…&e=…`
    public var url: String {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "v1"
        c.queryItems = [
            URLQueryItem(name: "d", value: deviceID.uuidString),
            URLQueryItem(name: "k", value: Self.base64url(key)),
            URLQueryItem(name: "n", value: serviceName),
            URLQueryItem(name: "p", value: String(port)),
            URLQueryItem(name: "a", value: addresses.joined(separator: ",")),
            URLQueryItem(name: "m", value: macName),
            URLQueryItem(name: "e", value: String(Int(expires.timeIntervalSince1970))),
        ]
        return c.string ?? ""
    }

    /// Read a scanned or pasted code. Nil if it isn't a valid AgentX pairing code.
    public init?(url text: String) {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == Self.scheme, c.host == "v1" else { return nil }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let id = q["d"].flatMap(UUID.init(uuidString:)),
              let key = q["k"].flatMap(Self.data(base64url:)), key.count == 32,
              let name = q["n"], !name.isEmpty,
              let port = q["p"].flatMap(UInt16.init), port > 0,
              let expires = q["e"].flatMap(TimeInterval.init) else { return nil }
        self.init(deviceID: id, key: key, serviceName: name, port: port,
                  addresses: (q["a"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty },
                  macName: q["m"] ?? name, expires: Date(timeIntervalSince1970: expires))
    }

    public func isExpired(now: Date = Date()) -> Bool { now >= expires }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64url s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}

/// Bonjour service type for AgentX's phone link.
public enum RemoteService {
    public static let type = "_agentx._tcp"
    /// Tried first, so a Mac reachable by address (Tailscale) keeps the same port.
    public static let preferredPort: UInt16 = 47_811
}
