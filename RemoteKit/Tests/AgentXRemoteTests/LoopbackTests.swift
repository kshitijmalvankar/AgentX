import CryptoKit
import Foundation
import Network
import Testing
@testable import AgentXRemote

/// A real Mac-side listener and phone-side connection over TCP on this machine.
@Suite("Loopback session", .serialized)
struct LoopbackTests {
    final class Box<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    }

    func startServer(psk: SymmetricKey, deviceID: UUID,
                     onSession: @escaping @Sendable (SecureSession) -> Void) async throws -> (RemoteServer, UInt16, Box<Int>) {
        let port = Box<UInt16>(0)
        let rejected = Box<Int>(0)
        let server = RemoteServer(serviceName: nil, preferredPort: 0,
                                  psk: { $0 == deviceID ? psk : nil },
                                  onSession: onSession,
                                  onState: { if case .listening(let p) = $0 { port.set(p) } },
                                  onRejected: { _, _ in rejected.set(rejected.get() + 1) })
        server.start()
        for _ in 0..<200 where port.get() == 0 { try await Task.sleep(for: .milliseconds(10)) }
        try #require(port.get() != 0, "listener didn't start")
        return (server, port.get(), rejected)
    }

    func endpoint(_ port: UInt16) -> NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!) }

    @Test func requestsAndEventsTravelBothWays() async throws {
        let psk = SecureChannel.newPairingKey(), deviceID = UUID()
        let (server, port, _) = try await startServer(psk: psk, deviceID: deviceID) { session in
            Task {
                // Echo: answer the first request, then push a snapshot.
                let envelope = try await session.receive(ClientEnvelope.self)
                try await session.send(ServerEvent.result(id: envelope.id, error: nil, conversationID: "c1"))
                try await session.send(ServerEvent.snapshot(RemoteSnapshot(macName: "Test Mac", appName: "AgentX Dev")))
            }
        }
        defer { server.stop() }

        let phone = try await SecureSession.connect(to: endpoint(port), deviceID: deviceID, psk: psk)
        defer { phone.close() }
        try await phone.send(ClientEnvelope(id: 1, request: .hello(deviceName: "iPhone", appVersion: "1")))
        #expect(try await phone.receive(ServerEvent.self) == .result(id: 1, error: nil, conversationID: "c1"))
        guard case .snapshot(let snapshot) = try await phone.receive(ServerEvent.self) else {
            Issue.record("expected a snapshot"); return
        }
        #expect(snapshot.macName == "Test Mac")
    }

    @Test func aPhoneWithTheWrongKeyNeverGetsASession() async throws {
        let deviceID = UUID()
        let sessions = Box<Int>(0)
        let (server, port, rejected) = try await startServer(psk: SecureChannel.newPairingKey(), deviceID: deviceID) { _ in
            sessions.set(sessions.get() + 1)
        }
        defer { server.stop() }
        await #expect(throws: ChannelError.authenticationFailed) {
            _ = try await SecureSession.connect(to: endpoint(port), deviceID: deviceID, psk: SecureChannel.newPairingKey())
        }
        for _ in 0..<100 where rejected.get() == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sessions.get() == 0)
        #expect(rejected.get() == 1)
    }

    @Test func anUnpairedPhoneIsDropped() async throws {
        let (server, port, rejected) = try await startServer(psk: SecureChannel.newPairingKey(), deviceID: UUID()) { _ in }
        defer { server.stop() }
        await #expect(throws: (any Error).self) {
            _ = try await SecureSession.connect(to: endpoint(port), deviceID: UUID(), psk: SecureChannel.newPairingKey(),
                                                timeout: .seconds(2))
        }
        for _ in 0..<100 where rejected.get() == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(rejected.get() == 1)
    }

    @Test func repeatedFailuresGetAHostIgnored() async throws {
        let deviceID = UUID()
        let (server, port, rejected) = try await startServer(psk: SecureChannel.newPairingKey(), deviceID: deviceID) { _ in }
        defer { server.stop() }
        for _ in 0..<RemoteServer.failureLimit {
            _ = try? await SecureSession.connect(to: endpoint(port), deviceID: deviceID, psk: SecureChannel.newPairingKey(), timeout: .seconds(2))
        }
        for _ in 0..<100 where rejected.get() < RemoteServer.failureLimit { try await Task.sleep(for: .milliseconds(10)) }
        // Now even the right key is turned away for a while (the connection is closed before the handshake).
        let start = Date()
        await #expect(throws: (any Error).self) {
            _ = try await SecureSession.connect(to: endpoint(port), deviceID: deviceID, psk: SecureChannel.newPairingKey(), timeout: .seconds(2))
        }
        #expect(Date().timeIntervalSince(start) < 3)
    }
}
