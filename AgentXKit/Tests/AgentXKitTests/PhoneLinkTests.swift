import AgentXRemote
import CryptoKit
import Foundation
import Network
import Testing
@testable import AgentXKit

/// Pairing keys in memory (tests never touch the Keychain).
final class MemoryPhoneKeys: PhoneKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: SymmetricKey] = [:]
    func key(for id: UUID) -> SymmetricKey? { lock.lock(); defer { lock.unlock() }; return keys[id] }
    func save(_ key: SymmetricKey, for id: UUID) throws { lock.lock(); keys[id] = key; lock.unlock() }
    func delete(_ id: UUID) { lock.lock(); keys[id] = nil; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return keys.count }
}

@Suite("iPhone link", .serialized)
@MainActor
struct PhoneLinkTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("phonelink-\(UUID().uuidString)")
    let keys = MemoryPhoneKeys()
    let scratch = ScratchDefaults("agentx-phone-tests")

    /// Remove this test's files and settings (after the link and its log finish writing).
    func cleanUp(_ model: AppModel? = nil) {
        model?.phone.isEnabled = false
        model?.activity.flush()
        try? FileManager.default.removeItem(at: dir)
        scratch.remove()
    }

    func makeLink() -> (PhoneLink, AppModel) {
        let link = PhoneLink(keys: keys, defaults: scratch.defaults, file: dir.appendingPathComponent("phone-devices.json"),
                             preferredPort: testListenerPort(), advertise: false)
        let model = AppModel(activity: ActivityLog(fileURL: dir.appendingPathComponent("activity.jsonl")), phone: link)
        link.attach(model)
        return (link, model)
    }

    func port(_ link: PhoneLink) async throws -> UInt16 {
        for _ in 0..<300 {
            if case .listening(let port) = link.status { return port }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the listener didn't start")
        return 0
    }

    func connect(_ code: PairingCode, port: UInt16) async throws -> SecureSession {
        try await SecureSession.connect(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                        deviceID: code.deviceID, psk: code.symmetricKey, timeout: .seconds(3))
    }

    /// Next event that isn't a snapshot of no interest, with a time limit.
    func next(_ session: SecureSession) async throws -> ServerEvent {
        try await session.receive(ServerEvent.self)
    }

    @Test func listensOnlyWhilePairingOrPaired() async throws {
        let (link, model) = makeLink()
        // The link holds the app model weakly (as in the app): keep it alive.
        defer { cleanUp(model) }
        #expect(link.status == .idle, "nothing paired: nothing listening")
        link.startPairing()
        _ = try await port(link)
        #expect(link.pairing != nil)
        link.cancelPairing()
        #expect(link.status == .idle)
        #expect(keys.count == 0, "an unused code's key is deleted")
        link.isEnabled = false
        link.startPairing()
        #expect(link.pairing == nil, "no pairing while the link is off")
    }

    @Test func aNewPhoneWaitsForYourOKThenGetsSnapshots() async throws {
        let (link, model) = makeLink()
        // The link holds the app model weakly (as in the app): keep it alive.
        defer { cleanUp(model) }
        link.startPairing()
        let code = try #require(link.pairing)
        let phone = try await connect(code, port: try await port(link))
        defer { phone.close() }

        try await phone.send(ClientEnvelope(id: 1, request: .hello(deviceName: "Test iPhone", appVersion: "1")))
        #expect(try await next(phone) == .result(id: 1, error: nil, conversationID: nil))
        #expect(try await next(phone) == .awaitingConfirmation)
        #expect(link.awaitingConfirmation?.name == "Test iPhone")

        // Nothing but "confirm first" until you allow it.
        try await phone.send(ClientEnvelope(id: 2, request: .refresh))
        #expect(try await next(phone) == .result(id: 2, error: "Confirm this iPhone on your Mac first.", conversationID: nil))

        link.confirm()
        guard case .snapshot(let snapshot) = try await next(phone) else { Issue.record("expected a snapshot"); return }
        #expect(snapshot.appName == AppChannel.current.displayName)
        #expect(link.pairing == nil, "the code is used up")
        #expect(link.devices.map(\.name) == ["Test iPhone"])
        #expect(link.devices.first?.confirmed == true)
        #expect(link.connected.count == 1)

        // Saved: a new link reading the same file knows the phone.
        let saved = try Data(contentsOf: dir.appendingPathComponent("phone-devices.json"))
        #expect(String(decoding: saved, as: UTF8.self).contains("Test iPhone"))
    }

    @Test func decliningDropsThePhoneAndItsKey() async throws {
        let (link, model) = makeLink()
        // The link holds the app model weakly (as in the app): keep it alive.
        defer { cleanUp(model) }
        link.startPairing()
        let code = try #require(link.pairing)
        let phone = try await connect(code, port: try await port(link))
        defer { phone.close() }
        try await phone.send(ClientEnvelope(id: 1, request: .hello(deviceName: "Someone's iPhone", appVersion: "1")))
        _ = try await next(phone)
        _ = try await next(phone)
        link.decline()
        #expect(try await next(phone) == .refused)
        #expect(link.devices.isEmpty)
        #expect(keys.count == 0)
        #expect(link.status == .idle)
    }

    @Test func approvalsCanBeAnsweredFromThePhoneWhenAllowed() async throws {
        let (link, model) = makeLink()
        defer { cleanUp(model) }
        // A Mac conversation waiting for approval.
        let c = Conversation(id: "m", kind: .assistant, sessionId: "s-m", cwd: "/tmp", title: "Send the report")
        c.liveHandle = "hm"
        model.sessions.insert(c)
        let answered = Task { try await model.sessions.handleRequest("permission.request", params: [
            "handle": "hm", "toolName": "mcp__agentx__mail_send", "input": ["to": ["boss@example.com"], "subject": "Report"],
        ], id: "a1") }
        for _ in 0..<100 where model.sessions.approvals.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        link.startPairing()
        let code = try #require(link.pairing)
        let phone = try await connect(code, port: try await port(link))
        defer { phone.close() }
        try await phone.send(ClientEnvelope(id: 1, request: .hello(deviceName: "iPhone", appVersion: "1")))
        _ = try await next(phone); _ = try await next(phone)
        link.confirm()
        guard case .snapshot(let snapshot) = try await next(phone) else { Issue.record("expected a snapshot"); return }
        let approval = try #require(snapshot.approvals.first)
        #expect(approval.detail.contains("boss@example.com"), "the phone sees exactly what it approves")
        #expect(approval.origin == "Send the report")

        link.allowApprovals = false
        try await phone.send(ClientEnvelope(id: 2, request: .answer(approvalID: approval.id, allow: true)))
        var event = try await next(phone)
        while case .snapshot = event { event = try await next(phone) }
        #expect(event == .result(id: 2, error: "Approving from iPhone is turned off on the Mac.", conversationID: nil))
        #expect(model.sessions.approvals.count == 1)

        link.allowApprovals = true
        try await phone.send(ClientEnvelope(id: 3, request: .answer(approvalID: approval.id, allow: false)))
        event = try await next(phone)
        while case .snapshot = event { event = try await next(phone) }
        #expect(event == .result(id: 3, error: nil, conversationID: nil))
        let result = try await answered.value
        #expect(result["behavior"]?.string == "deny")
        #expect(model.activity.recent.contains { $0.action == "denied on iPhone" })
    }

    @Test func revokingCutsThePhoneOff() async throws {
        let (link, model) = makeLink()
        // The link holds the app model weakly (as in the app): keep it alive.
        defer { cleanUp(model) }
        link.startPairing()
        let code = try #require(link.pairing)
        let p = try await port(link)
        let phone = try await connect(code, port: p)
        try await phone.send(ClientEnvelope(id: 1, request: .hello(deviceName: "Old iPhone", appVersion: "1")))
        _ = try await next(phone); _ = try await next(phone)
        link.confirm()
        _ = try await next(phone)
        let id = try #require(link.devices.first?.id)

        link.revoke(id)
        var sawRefused = false
        while let event = try? await next(phone) { if event == .refused { sawRefused = true; break } }
        #expect(sawRefused)
        phone.close()
        #expect(link.devices.isEmpty)
        #expect(keys.count == 0)
        #expect(link.status == .idle, "nothing paired any more: the listener stops")
    }

    /// Pair a phone and confirm it; returns the session after the first snapshot.
    func pairedPhone(_ link: PhoneLink) async throws -> SecureSession {
        link.startPairing()
        let code = try #require(link.pairing)
        let phone = try await connect(code, port: try await port(link))
        try await phone.send(ClientEnvelope(id: 1, request: .hello(deviceName: "iPhone", appVersion: "1")))
        _ = try await next(phone); _ = try await next(phone)
        link.confirm()
        _ = try await next(phone)
        return phone
    }

    /// The next transcript event (skipping snapshots and results).
    func nextTranscript(_ phone: SecureSession) async throws -> RemoteTranscript {
        while true {
            if case .transcript(let t) = try await next(phone) { return t }
        }
    }

    @Test func aNewConversationKeepsItsIdWhenItGetsASessionId() async throws {
        let (link, model) = makeLink()
        defer { cleanUp(model) }
        // A conversation started from the phone: AgentX's id first, Claude Code's session id later.
        let c = Conversation(id: "new-1", kind: .assistant, sessionId: nil, cwd: "/tmp", title: "Turn on dark mode")
        c.liveHandle = "h1"
        c.liveState = .running
        model.sessions.insert(c)

        let phone = try await pairedPhone(link)
        defer { phone.close() }
        try await phone.send(ClientEnvelope(id: 2, request: .transcript(conversationID: "new-1")))
        let first = try await nextTranscript(phone)
        #expect(first.conversationID == "new-1")
        #expect(first.isWorking)

        // Claude Code names the session and finishes the turn.
        c.sessionId = "session-abc"
        c.liveState = .idle
        let done = try await nextTranscript(phone)
        #expect(done.conversationID == "new-1", "updates keep the id the phone is watching")
        #expect(!done.isWorking, "the phone's spinner stops")

        let snapshot = RemoteSnapshotBuilder.snapshot(model, canApprove: true, canMessage: true)
        #expect(snapshot.conversations.filter { $0.id == "new-1" }.count == 1)
        #expect(!snapshot.conversations.contains { $0.id == "session-abc" }, "listed once, under the id the phone knows")
    }

    /// The next result event (skipping snapshots and transcripts).
    func nextResult(_ phone: SecureSession) async throws -> ServerEvent {
        while true {
            let event = try await next(phone)
            if case .result = event { return event }
        }
    }

    @Test func remindersFromThePhoneRespectTheSetting() async throws {
        let (link, model) = makeLink()
        defer { cleanUp(model) }
        let phone = try await pairedPhone(link)
        defer { phone.close() }

        link.allowReminders = false
        try await phone.send(ClientEnvelope(id: 5, request: .setReminder(id: "r1", completed: true)))
        #expect(try await nextResult(phone) == .result(id: 5, error: "Ticking off reminders from iPhone is turned off on the Mac.", conversationID: nil))

        link.allowReminders = true
        try await phone.send(ClientEnvelope(id: 6, request: .setReminder(id: "nope", completed: true)))
        #expect(try await nextResult(phone) == .result(id: 6, error: "That reminder isn't on today's list any more.", conversationID: nil))
    }

    /// What a newer iPhone app might send.
    struct FutureEnvelope: Encodable, Sendable {
        var id: Int
        var request: [String: [String: Int]]
    }

    @Test func aRequestFromANewerAppGetsAnAnswerNotADroppedConnection() async throws {
        let (link, model) = makeLink()
        defer { cleanUp(model) }
        let phone = try await pairedPhone(link)
        defer { phone.close() }

        try await phone.send(FutureEnvelope(id: 9, request: ["somethingNew": ["x": 1]]))
        #expect(try await nextResult(phone) == .result(id: 9, error: "Update AgentX on your Mac to do this from your iPhone.", conversationID: nil))
        try await phone.send(ClientEnvelope(id: 10, request: .refresh))
        #expect(try await nextResult(phone) == .result(id: 10, error: nil, conversationID: nil), "still connected")
    }

    @Test func todayListsDoneRemindersSoTheyCanBeUndone() {
        let open = Agenda.Reminder(id: "r1", title: "Call Jayu", due: Date(), hasTime: false, list: "Reminders", color: nil, isOverdue: false)
        let done = Agenda.Reminder(id: "r2", title: "Pay rent", due: Date(), hasTime: false, list: "Home", color: nil, isOverdue: false)
        var agenda = Agenda(start: Date(), end: Date().addingTimeInterval(86_400))
        agenda.reminders = [open]
        let items = RemoteSnapshotBuilder.today(agenda, completed: [done])
        #expect(items.map(\.id) == ["r1", "r2"])
        #expect(items[0].isDone == false && items[0].source == "Reminders")
        #expect(items[1].isDone && items[1].when == "Done")
    }

    @Test func pairingCodesExpire() {
        let used = PairedDevice(id: UUID(), name: "x", pairedAt: Date(), lastSeen: nil, confirmed: false, pairingExpires: Date().addingTimeInterval(-1))
        #expect(!used.isUsable())
        let fresh = PairedDevice(id: UUID(), name: "x", pairedAt: Date(), lastSeen: nil, confirmed: false, pairingExpires: Date().addingTimeInterval(60))
        #expect(fresh.isUsable())
        let paired = PairedDevice(id: UUID(), name: "x", pairedAt: Date(), lastSeen: nil, confirmed: true, pairingExpires: nil)
        #expect(paired.isUsable())
    }

    @Test func onlyPrivateAndTailscaleAddressesGoInTheCode() {
        #expect(LocalAddresses.isReachable("192.168.1.20"))
        #expect(LocalAddresses.isReachable("10.0.0.5"))
        #expect(LocalAddresses.isReachable("172.20.1.1"))
        #expect(LocalAddresses.isReachable("100.101.102.103"))
        #expect(!LocalAddresses.isReachable("8.8.8.8"))
        #expect(!LocalAddresses.isReachable("172.40.1.1"))
        #expect(!LocalAddresses.isReachable("100.200.1.1"))
    }
}
