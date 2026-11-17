import CryptoKit
import Foundation
import Testing
@testable import AgentXRemote

@Suite("Secure channel")
struct SecureChannelTests {
    let deviceID = UUID()
    let psk = SecureChannel.newPairingKey()

    /// Run a full handshake in memory.
    func handshake(clientPSK: SymmetricKey? = nil) throws -> (client: SecureChannel.Keys, server: SecureChannel.Keys) {
        let client = SecureChannel.Client(deviceID: deviceID, psk: clientPSK ?? psk)
        let (reply, pending) = try SecureChannel.Server.respond(to: client.hello) { $0 == deviceID ? psk : nil }
        let (finished, clientKeys) = try client.finish(reply: reply)
        let serverKeys = try pending.verify(finished: finished)
        #expect(pending.deviceID == deviceID)
        return (clientKeys, serverKeys)
    }

    @Test func bothSidesAgreeOnKeys() throws {
        let (c, s) = try handshake()
        var sealer = FrameSealer(key: c.send)
        var opener = FrameOpener(key: s.receive)
        #expect(try opener.open(sealer.seal(Data("hello Mac".utf8))) == Data("hello Mac".utf8))
        var back = FrameSealer(key: s.send)
        var backOpen = FrameOpener(key: c.receive)
        #expect(try backOpen.open(back.seal(Data("hello phone".utf8))) == Data("hello phone".utf8))
    }

    @Test func eachSessionGetsFreshKeys() throws {
        let a = try handshake(), b = try handshake()
        let ka = a.client.send.withUnsafeBytes { Data($0) }
        let kb = b.client.send.withUnsafeBytes { Data($0) }
        #expect(ka != kb)
        #expect(a.client.send.withUnsafeBytes { Data($0) } != a.client.receive.withUnsafeBytes { Data($0) }, "each direction has its own key")
    }

    @Test func unknownDevicesAreRefused() {
        let client = SecureChannel.Client(deviceID: UUID(), psk: psk)
        #expect(throws: ChannelError.unknownDevice) {
            _ = try SecureChannel.Server.respond(to: client.hello) { $0 == deviceID ? psk : nil }
        }
    }

    @Test func aWrongKeyFailsOnBothSides() throws {
        // The phone has the wrong key: it rejects the Mac's reply.
        #expect(throws: ChannelError.authenticationFailed) { _ = try handshake(clientPSK: SecureChannel.newPairingKey()) }

        // A fake phone that skips checking and sends a forged finished message: the Mac rejects it.
        let client = SecureChannel.Client(deviceID: deviceID, psk: psk)
        let (_, pending) = try SecureChannel.Server.respond(to: client.hello) { _ in psk }
        #expect(throws: ChannelError.authenticationFailed) { _ = try pending.verify(finished: Data(repeating: 7, count: 32)) }
    }

    @Test func aTamperedReplyIsRejected() throws {
        let client = SecureChannel.Client(deviceID: deviceID, psk: psk)
        var (reply, _) = try SecureChannel.Server.respond(to: client.hello) { _ in psk }
        reply[reply.startIndex + 40] ^= 0x01   // flip a bit of the Mac's nonce
        #expect(throws: ChannelError.authenticationFailed) { _ = try client.finish(reply: reply) }
    }

    @Test func malformedHellosAreRefused() {
        #expect(throws: ChannelError.badMessage) { _ = try SecureChannel.Server.respond(to: Data([1, 2, 3])) { _ in psk } }
        var hello = SecureChannel.Client(deviceID: deviceID, psk: psk).hello
        hello[hello.startIndex] = 9   // unknown version
        #expect(throws: ChannelError.badMessage) { _ = try SecureChannel.Server.respond(to: hello) { _ in psk } }
    }

    @Test func framesCantBeAlteredReplayedOrReordered() throws {
        let (c, s) = try handshake()
        var sealer = FrameSealer(key: c.send)
        let first = try sealer.seal(Data("one".utf8))
        let second = try sealer.seal(Data("two".utf8))

        var tampered = first
        tampered[tampered.startIndex] ^= 0xFF
        var o1 = FrameOpener(key: s.receive)
        #expect(throws: ChannelError.decryptionFailed) { _ = try o1.open(tampered) }

        var o2 = FrameOpener(key: s.receive)
        #expect(throws: ChannelError.decryptionFailed) { _ = try o2.open(second) }   // out of order

        var o3 = FrameOpener(key: s.receive)
        #expect(try o3.open(first) == Data("one".utf8))
        #expect(throws: ChannelError.decryptionFailed) { _ = try o3.open(first) }    // replayed
        var o4 = FrameOpener(key: s.receive)
        _ = try o4.open(first)
        #expect(try o4.open(second) == Data("two".utf8))
    }

    @Test func framesFromAnotherSessionDontOpen() throws {
        let a = try handshake(), b = try handshake()
        var sealer = FrameSealer(key: a.client.send)
        var opener = FrameOpener(key: b.server.receive)
        #expect(throws: ChannelError.decryptionFailed) { _ = try opener.open(sealer.seal(Data("x".utf8))) }
    }
}

@Suite("Pairing code")
struct PairingCodeTests {
    @Test func roundTripsThroughAURL() throws {
        let code = PairingCode(deviceID: UUID(), key: SecureChannel.random(32), serviceName: "AgentX on Kshitij's Mac",
                               port: 47_811, addresses: ["192.168.1.20", "100.101.102.103"], macName: "Kshitij's Mac",
                               expires: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(code.url.hasPrefix("agentx-pair://v1?"))
        let parsed = try #require(PairingCode(url: code.url))
        #expect(parsed == code)
    }

    @Test func rejectsAnythingElse() {
        #expect(PairingCode(url: "https://claude.ai") == nil)
        #expect(PairingCode(url: "agentx-pair://v2?d=x") == nil)
        let short = "agentx-pair://v1?d=\(UUID().uuidString)&k=AAAA&n=Mac&p=1&e=1"
        #expect(PairingCode(url: short) == nil, "the key must be 32 bytes")
    }

    @Test func expires() {
        let code = PairingCode(deviceID: UUID(), key: Data(count: 32), serviceName: "Mac", port: 1, addresses: [],
                               macName: "Mac", expires: Date().addingTimeInterval(-1))
        #expect(code.isExpired())
    }
}

@Suite("Protocol compatibility")
struct ProtocolCompatibilityTests {
    @Test func olderSnapshotsStillDecode() throws {
        // A snapshot from a Mac built before reminders could be edited from the phone.
        let json = #"{"macName":"Mac","appName":"AgentX","date":"2026-11-17T10:00:00Z","usage":[],"approvals":[],"conversations":[],"today":[{"id":"r1","title":"Call Jayu","when":"Today","isReminder":true,"isOverdue":false}],"automations":[],"automationsPaused":false,"activity":[],"canApprove":true,"canMessage":true}"#
        let snapshot = try RemoteCoding.decoder.decode(RemoteSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.today.first?.isDone == false)
        #expect(snapshot.canEditReminders == nil)
    }

    @Test func anUnknownRequestStillHasAReadableID() throws {
        let json = #"{"id":7,"request":{"somethingNew":{"x":1}}}"#
        #expect(throws: (any Error).self) { _ = try RemoteCoding.decoder.decode(ClientEnvelope.self, from: Data(json.utf8)) }
        #expect(try RemoteCoding.decoder.decode(RequestID.self, from: Data(json.utf8)).id == 7)
    }

    @Test func reminderRequestsRoundTrip() throws {
        let envelope = ClientEnvelope(id: 3, request: .setReminder(id: "x-1", completed: true))
        let data = try RemoteCoding.encoder.encode(envelope)
        #expect(try RemoteCoding.decoder.decode(ClientEnvelope.self, from: data) == envelope)
    }
}
