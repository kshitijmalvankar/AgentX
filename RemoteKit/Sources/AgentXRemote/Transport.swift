import CryptoKit
import Foundation
import Network

/// Length-prefixed messages over a TCP `NWConnection`: a 4-byte big-endian
/// length, then that many bytes.
final class FramedConnection: @unchecked Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "agentx.remote.connection")

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    /// Wait until the connection is ready (or fails).
    func start(timeout: Duration = .seconds(10)) async throws {
        let once = Once()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    self.connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if once.take() { cont.resume() }
                        case .failed(let error):
                            if once.take() { cont.resume(throwing: error) }
                        case .cancelled:
                            if once.take() { cont.resume(throwing: ChannelError.closed) }
                        case .waiting(let error):
                            // No route (e.g. not on the same network): give up rather than wait forever.
                            if once.take() { cont.resume(throwing: error) }
                        default:
                            break
                        }
                    }
                    self.connection.start(queue: self.queue)
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ChannelError.timedOut
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    func send(_ payload: Data) async throws {
        guard payload.count <= SecureChannel.maxFrame + 64 else { throw ChannelError.frameTooLarge }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    func receive() async throws -> Data {
        let header = try await read(4)
        let length = header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard Int(length) <= SecureChannel.maxFrame + 64 else { throw ChannelError.frameTooLarge }
        return length == 0 ? Data() : try await read(Int(length))
    }

    private func read(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error) }
                else if let data, data.count == count { cont.resume(returning: data) }
                else if isComplete { cont.resume(throwing: ChannelError.closed) }
                else { cont.resume(throwing: ChannelError.badMessage) }
            }
        }
    }

    func cancel() { connection.cancel() }

    /// The other side's IP address, if known (for throttling failed handshakes).
    var remoteHost: String? {
        if case .hostPort(let host, _) = connection.endpoint { return "\(host)" }
        return nil
    }
}

/// Resumes a continuation at most once.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// An authenticated, encrypted connection between the phone and the Mac.
/// Messages are JSON values sealed with `FrameSealer`.
public actor SecureSession {
    public nonisolated let deviceID: UUID
    private let framed: FramedConnection
    private var sealer: FrameSealer
    private var opener: FrameOpener

    init(deviceID: UUID, framed: FramedConnection, keys: SecureChannel.Keys) {
        self.deviceID = deviceID
        self.framed = framed
        self.sealer = FrameSealer(key: keys.send)
        self.opener = FrameOpener(key: keys.receive)
    }

    public nonisolated var remoteHost: String? { framed.remoteHost }

    public func send<T: Encodable & Sendable>(_ value: T) async throws {
        let frame = try sealer.seal(try RemoteCoding.encoder.encode(value))
        try await framed.send(frame)
    }

    /// The next message. Only one receive loop may run per session.
    public func receive<T: Decodable & Sendable>(_ type: T.Type) async throws -> T {
        try RemoteCoding.decoder.decode(T.self, from: try await receiveData())
    }

    /// The next message, decrypted but not decoded: lets a receive loop skip
    /// a message it doesn't understand (from a newer app) and keep going.
    public func receiveData() async throws -> Data {
        let frame = try await framed.receive()
        return try opener.open(frame)
    }

    public nonisolated func close() { framed.cancel() }

    /// The phone's side: connect and run the handshake.
    public static func connect(to endpoint: NWEndpoint, deviceID: UUID, psk: SymmetricKey,
                               timeout: Duration = .seconds(8)) async throws -> SecureSession {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let framed = FramedConnection(NWConnection(to: endpoint, using: parameters))
        do {
            try await framed.start(timeout: timeout)
            let client = SecureChannel.Client(deviceID: deviceID, psk: psk)
            try await framed.send(client.hello)
            let reply = try await withTimeout(timeout) { try await framed.receive() }
            let (finished, keys) = try client.finish(reply: reply)
            try await framed.send(finished)
            return SecureSession(deviceID: deviceID, framed: framed, keys: keys)
        } catch {
            framed.cancel()
            throw error
        }
    }

    /// The Mac's side: run the handshake on an incoming connection.
    static func accept(_ connection: NWConnection, psk lookup: @Sendable (UUID) -> SymmetricKey?,
                       timeout: Duration = .seconds(10)) async throws -> SecureSession {
        let framed = FramedConnection(connection)
        do {
            try await framed.start(timeout: timeout)
            let hello = try await withTimeout(timeout) { try await framed.receive() }
            let (reply, pending) = try SecureChannel.Server.respond(to: hello, psk: lookup)
            try await framed.send(reply)
            let finished = try await withTimeout(timeout) { try await framed.receive() }
            let keys = try pending.verify(finished: finished)
            return SecureSession(deviceID: pending.deviceID, framed: framed, keys: keys)
        } catch {
            framed.cancel()
            throw error
        }
    }
}

/// Run `work`, failing with `ChannelError.timedOut` if it takes longer than `timeout`.
func withTimeout<T: Sendable>(_ timeout: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ChannelError.timedOut
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw ChannelError.closed }
        return result
    }
}

/// The Mac's listener: advertises AgentX over Bonjour, runs the handshake on
/// each connection, and hands authenticated sessions to `onSession`. Unpaired
/// devices and failed handshakes are dropped before any app data flows; an
/// address that fails repeatedly is ignored for a while.
public final class RemoteServer: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case listening(port: UInt16)
        case failed(String)
    }

    private let serviceName: String?
    private let preferredPort: UInt16
    private let lookup: @Sendable (UUID) -> SymmetricKey?
    private let onSession: @Sendable (SecureSession) -> Void
    private let onState: @Sendable (State) -> Void
    private let onRejected: @Sendable (String?, ChannelError?) -> Void
    private let queue = DispatchQueue(label: "agentx.remote.server")
    private let lock = NSLock()
    private var listener: NWListener?
    /// Host → recent failed handshakes (timestamps).
    private var failures: [String: [Date]] = [:]

    /// A host that fails this many handshakes in a minute is ignored for ten.
    static let failureLimit = 5

    /// `serviceName` nil: don't advertise over Bonjour (tests).
    public init(serviceName: String?, preferredPort: UInt16 = RemoteService.preferredPort,
                psk lookup: @escaping @Sendable (UUID) -> SymmetricKey?,
                onSession: @escaping @Sendable (SecureSession) -> Void,
                onState: @escaping @Sendable (State) -> Void = { _ in },
                onRejected: @escaping @Sendable (String?, ChannelError?) -> Void = { _, _ in }) {
        self.serviceName = serviceName
        self.preferredPort = preferredPort
        self.lookup = lookup
        self.onSession = onSession
        self.onState = onState
        self.onRejected = onRejected
    }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let made = (preferredPort > 0 ? try? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: preferredPort)!) : nil)
            ?? (try? NWListener(using: parameters))
        guard let listener = made else {
            onState(.failed("Couldn't open a port for the iPhone link."))
            return
        }
        if let serviceName { listener.service = NWListener.Service(name: serviceName, type: RemoteService.type) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready: self?.onState(.listening(port: listener?.port?.rawValue ?? 0))
            case .failed(let error): self?.onState(.failed(error.localizedDescription))
            case .cancelled: self?.onState(.stopped)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        let host: String? = { if case .hostPort(let h, _) = connection.endpoint { return "\(h)" } else { return nil } }()
        if let host, isThrottled(host) {
            connection.cancel()
            return
        }
        let lookup = self.lookup
        Task { [weak self] in
            do {
                let session = try await SecureSession.accept(connection, psk: lookup)
                self?.onSession(session)
            } catch {
                if let host { self?.noteFailure(host) }
                self?.onRejected(host, error as? ChannelError)
            }
        }
    }

    private func isThrottled(_ host: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let recent = (failures[host] ?? []).filter { now.timeIntervalSince($0) < 600 }
        failures[host] = recent
        return recent.filter { now.timeIntervalSince($0) < 60 }.count >= Self.failureLimit
            || recent.count >= Self.failureLimit * 2
    }

    private func noteFailure(_ host: String) {
        lock.lock(); defer { lock.unlock() }
        failures[host, default: []].append(Date())
    }
}

/// The phone's way in: Bonjour on the local network first, then the
/// addresses from the pairing code (e.g. the Mac's Tailscale address).
public enum RemoteConnector {
    public static func connect(_ pairing: PairingCode, timeout: Duration = .seconds(6)) async throws -> SecureSession {
        var endpoints: [NWEndpoint] = [.service(name: pairing.serviceName, type: RemoteService.type, domain: "local.", interface: nil)]
        endpoints += pairing.addresses.compactMap { address in
            NWEndpoint.Port(rawValue: pairing.port).map { .hostPort(host: NWEndpoint.Host(address), port: $0) }
        }
        var lastError: Error = ChannelError.closed
        for endpoint in endpoints {
            do {
                return try await SecureSession.connect(to: endpoint, deviceID: pairing.deviceID, psk: pairing.symmetricKey, timeout: timeout)
            } catch ChannelError.authenticationFailed {
                throw ChannelError.authenticationFailed   // reached the Mac, but the key is wrong: don't keep trying
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}
