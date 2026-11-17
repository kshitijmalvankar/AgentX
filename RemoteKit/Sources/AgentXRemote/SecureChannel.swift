import CryptoKit
import Foundation

/// Why a connection was refused or dropped.
public enum ChannelError: Error, Equatable, Sendable {
    /// A handshake message had the wrong size or version.
    case badMessage
    /// The phone isn't paired with this Mac (or was revoked).
    case unknownDevice
    /// The other side doesn't know the pairing key.
    case authenticationFailed
    /// A frame was larger than `SecureChannel.maxFrame`.
    case frameTooLarge
    /// A frame was altered, replayed, reordered or sealed with the wrong key.
    case decryptionFailed
    /// The connection closed.
    case closed
    /// The other side took too long.
    case timedOut
}

/// The phone ↔ Mac channel, version 1.
///
/// Each phone shares a 32-byte pairing key with the Mac (from the QR code).
/// A connection starts with a three-message handshake, in the shape of
/// Noise's NNpsk patterns, built only from CryptoKit primitives:
///
///     phone → Mac   hello:    version · deviceID · phone ephemeral X25519 key · nonce
///     Mac → phone   reply:    Mac ephemeral X25519 key · nonce · HMAC(authKey, "server" · th)
///     phone → Mac   finished: HMAC(authKey, "client" · th)
///
/// `th` is the SHA-256 of everything before the MACs. `authKey` comes from the
/// pairing key and `th` (HKDF), so each side proves it knows the pairing key,
/// bound to this exact exchange. The session keys come from HKDF over the
/// X25519 shared secret *and* the pairing key: an eavesdropper who later
/// learns the pairing key still can't decrypt past sessions (forward
/// secrecy), and someone without the pairing key can't sit in the middle.
///
/// After the handshake, every frame is ChaCha20-Poly1305 with a per-direction
/// key and an implicit counter nonce, so a frame that's altered, replayed,
/// dropped or reordered fails to open and the connection is closed.
public enum SecureChannel {
    public static let version: UInt8 = 1
    static let helloLength = 1 + 16 + 32 + 32
    static let replyLength = 32 + 32 + 32
    static let finishedLength = 32
    /// Largest message either side accepts (a long transcript fits easily).
    public static let maxFrame = 4 << 20

    public struct Keys: Sendable {
        public let send: SymmetricKey
        public let receive: SymmetricKey
    }

    /// The phone's side of the handshake.
    public struct Client: Sendable {
        public let deviceID: UUID
        let psk: SymmetricKey
        let ephemeral: Curve25519.KeyAgreement.PrivateKey
        let nonce: Data

        public init(deviceID: UUID, psk: SymmetricKey) {
            self.deviceID = deviceID
            self.psk = psk
            self.ephemeral = Curve25519.KeyAgreement.PrivateKey()
            self.nonce = SecureChannel.random(32)
        }

        public var hello: Data {
            var d = Data([SecureChannel.version])
            d.append(SecureChannel.bytes(of: deviceID))
            d.append(ephemeral.publicKey.rawRepresentation)
            d.append(nonce)
            return d
        }

        /// Check the Mac's reply; returns the last handshake message and the session keys.
        public func finish(reply: Data) throws -> (finished: Data, keys: Keys) {
            guard reply.count == SecureChannel.replyLength else { throw ChannelError.badMessage }
            let r = Data(reply)
            let serverPub = r.prefix(32)
            let serverNonce = r.dropFirst(32).prefix(32)
            let serverMAC = r.suffix(32)
            let transcript = hello + serverPub + serverNonce
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverPub)
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: peer)
            let d = SecureChannel.derive(psk: psk, shared: shared, transcript: transcript)
            guard HMAC<SHA256>.isValidAuthenticationCode(serverMAC, authenticating: Data("server".utf8) + d.th, using: d.authKey) else {
                throw ChannelError.authenticationFailed
            }
            let finished = Data(HMAC<SHA256>.authenticationCode(for: Data("client".utf8) + d.th, using: d.authKey))
            return (finished, Keys(send: d.clientToServer, receive: d.serverToClient))
        }
    }

    /// The Mac's side of the handshake.
    public enum Server {
        /// Waiting for the phone's `finished` message.
        public struct Pending: Sendable {
            public let deviceID: UUID
            let authKey: SymmetricKey
            let th: Data
            let keys: Keys

            public func verify(finished: Data) throws -> Keys {
                guard finished.count == SecureChannel.finishedLength,
                      HMAC<SHA256>.isValidAuthenticationCode(finished, authenticating: Data("client".utf8) + th, using: authKey)
                else { throw ChannelError.authenticationFailed }
                return keys
            }
        }

        /// Answer a phone's hello. `psk` returns the pairing key for a device id, or nil if it isn't paired.
        public static func respond(to hello: Data, psk lookup: (UUID) -> SymmetricKey?) throws -> (reply: Data, pending: Pending) {
            guard hello.count == SecureChannel.helloLength else { throw ChannelError.badMessage }
            let h = Data(hello)
            guard h[h.startIndex] == SecureChannel.version else { throw ChannelError.badMessage }
            let deviceID = SecureChannel.uuid(from: h.dropFirst(1).prefix(16))
            guard let psk = lookup(deviceID) else { throw ChannelError.unknownDevice }
            let clientPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: h.dropFirst(17).prefix(32))
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let nonce = SecureChannel.random(32)
            let transcript = h + ephemeral.publicKey.rawRepresentation + nonce
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: clientPub)
            let d = SecureChannel.derive(psk: psk, shared: shared, transcript: transcript)
            let mac = Data(HMAC<SHA256>.authenticationCode(for: Data("server".utf8) + d.th, using: d.authKey))
            let reply = ephemeral.publicKey.rawRepresentation + nonce + mac
            let pending = Pending(deviceID: deviceID, authKey: d.authKey, th: d.th,
                                  keys: Keys(send: d.serverToClient, receive: d.clientToServer))
            return (reply, pending)
        }
    }

    struct Derived {
        let th: Data
        let authKey: SymmetricKey
        let clientToServer: SymmetricKey
        let serverToClient: SymmetricKey
    }

    static func derive(psk: SymmetricKey, shared: SharedSecret, transcript: Data) -> Derived {
        let th = Data(SHA256.hash(data: transcript))
        let authKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: psk, salt: th,
                                            info: Data("agentx-remote v1 auth".utf8), outputByteCount: 32)
        let ikm = SymmetricKey(data: shared.withUnsafeBytes { Data($0) } + psk.withUnsafeBytes { Data($0) })
        let material = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: th,
                                             info: Data("agentx-remote v1 session".utf8), outputByteCount: 64)
        let bytes = material.withUnsafeBytes { Data($0) }
        return Derived(th: th, authKey: authKey,
                       clientToServer: SymmetricKey(data: bytes.prefix(32)),
                       serverToClient: SymmetricKey(data: bytes.suffix(32)))
    }

    static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "No secure randomness")
        return Data(bytes)
    }

    static func bytes(of id: UUID) -> Data {
        withUnsafeBytes(of: id.uuid) { Data($0) }
    }

    static func uuid(from data: some DataProtocol) -> UUID {
        let d = Data(data)
        return d.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }

    /// A fresh 32-byte pairing key.
    public static func newPairingKey() -> SymmetricKey { SymmetricKey(data: random(32)) }
}

/// Seals outgoing frames: ChaCha20-Poly1305 with a counter nonce.
public struct FrameSealer: Sendable {
    let key: SymmetricKey
    var counter: UInt64 = 0

    public init(key: SymmetricKey) { self.key = key }

    public mutating func seal(_ plaintext: Data) throws -> Data {
        guard plaintext.count <= SecureChannel.maxFrame else { throw ChannelError.frameTooLarge }
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: FrameSealer.nonce(counter))
        counter += 1
        return box.ciphertext + box.tag
    }

    static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}

/// Opens incoming frames in order; anything out of order or altered fails.
public struct FrameOpener: Sendable {
    let key: SymmetricKey
    var counter: UInt64 = 0

    public init(key: SymmetricKey) { self.key = key }

    public mutating func open(_ frame: Data) throws -> Data {
        guard frame.count >= 16 else { throw ChannelError.decryptionFailed }
        let f = Data(frame)
        do {
            let box = try ChaChaPoly.SealedBox(nonce: FrameSealer.nonce(counter), ciphertext: f.dropLast(16), tag: f.suffix(16))
            let plaintext = try ChaChaPoly.open(box, using: key)
            counter += 1
            return plaintext
        } catch {
            throw ChannelError.decryptionFailed
        }
    }
}
