import AgentXRemote
import Foundation
import LocalAuthentication
import Observation
import Security
import UIKit

/// The iPhone app's state: the pairing (in the Keychain), the connection to
/// AgentX on the Mac, and what the Mac last sent.
@MainActor
@Observable
final class PhoneModel {
    enum Connection: Equatable {
        case unpaired
        case connecting
        case connected
        /// Paired, but the Mac hasn't confirmed this phone yet.
        case awaitingConfirmation
        case offline(String)
        /// The Mac declined or removed this phone.
        case refused
    }

    private(set) var pairing: PairingCode?
    private(set) var connection: Connection
    private(set) var snapshot: RemoteSnapshot?
    private(set) var transcripts: [String: RemoteTranscript] = [:]
    /// Shown briefly after an action fails ("That request isn't waiting any more").
    var notice: String?
    /// Face ID gate: true until you unlock.
    var isLocked = true

    @ObservationIgnored private var session: SecureSession?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private var waiting: [Int: CheckedContinuation<(error: String?, conversationID: String?), Never>] = [:]
    @ObservationIgnored private var backgroundedAt: Date?

    init() {
        let stored = PairingStore.load()
        pairing = stored
        connection = stored == nil ? .unpaired : .offline("Not connected yet.")
    }

    // MARK: Lock

    /// Ask for Face ID (or the passcode). Used to open the app and before actions on the Mac.
    func authenticate(_ reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode set: there's nothing to check against.
            return true
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    func unlock() async {
        if await authenticate("Unlock AgentX") { isLocked = false }
    }

    /// The app went to the background: lock again if it stays away 5 minutes.
    func didEnterBackground() {
        backgroundedAt = Date()
        disconnect()
    }

    func didBecomeActive() async {
        if let since = backgroundedAt, Date().timeIntervalSince(since) > 300 { isLocked = true }
        backgroundedAt = nil
        await connect()
    }

    // MARK: Pairing

    /// Use a scanned or pasted pairing code.
    func pair(with text: String) async -> String? {
        guard let code = PairingCode(url: text) else { return "That isn't an AgentX pairing code." }
        guard !code.isExpired() else { return "That code has expired. Make a new one on your Mac (Settings → iPhone)." }
        disconnect()
        do { try PairingStore.save(code) } catch { return "Couldn't save the pairing on this iPhone." }
        pairing = code
        snapshot = nil
        transcripts = [:]
        await connect()
        return nil
    }

    func unpair() {
        disconnect()
        PairingStore.delete()
        pairing = nil
        snapshot = nil
        transcripts = [:]
        connection = .unpaired
    }

    // MARK: Connection

    func connect() async {
        guard let pairing, session == nil, connection != .connecting else { return }
        connection = .connecting
        do {
            let session = try await RemoteConnector.connect(pairing)
            self.session = session
            receiveTask = Task { [weak self] in await self?.receiveLoop(session) }
            let result = await request(.hello(deviceName: UIDevice.current.name, appVersion: Self.appVersion))
            if result.error == nil, connection == .connecting { connection = .connected }
        } catch ChannelError.authenticationFailed {
            connection = .refused
        } catch {
            connection = .offline("Can't reach \(pairing.macName). Make sure AgentX is open there and you're on the same Wi-Fi (or Tailscale).")
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        session?.close()
        session = nil
        for (_, waiter) in waiting { waiter.resume(returning: ("Disconnected.", nil)) }
        waiting.removeAll()
        if pairing != nil, connection != .refused { connection = .offline("Disconnected.") }
    }

    private func receiveLoop(_ session: SecureSession) async {
        while !Task.isCancelled {
            guard let event = try? await session.receive(ServerEvent.self) else { break }
            handle(event)
        }
        guard self.session === session else { return }
        self.session = nil
        if connection != .refused { connection = .offline("Lost the connection to your Mac.") }
        for (_, waiter) in waiting { waiter.resume(returning: ("Disconnected.", nil)) }
        waiting.removeAll()
    }

    private func handle(_ event: ServerEvent) {
        switch event {
        case .awaitingConfirmation:
            connection = .awaitingConfirmation
        case .refused:
            connection = .refused
        case .snapshot(let s):
            snapshot = s
            connection = .connected
        case .transcript(let t):
            transcripts[t.conversationID] = t
        case .result(let id, let error, let conversationID):
            waiting.removeValue(forKey: id)?.resume(returning: (error, conversationID))
        }
    }

    /// Send a request and wait for the Mac's answer.
    @discardableResult
    func request(_ request: ClientRequest) async -> (error: String?, conversationID: String?) {
        guard let session else { return ("Not connected to your Mac.", nil) }
        let id = nextID
        nextID += 1
        return await withCheckedContinuation { cont in
            waiting[id] = cont
            Task {
                do { try await session.send(ClientEnvelope(id: id, request: request)) } catch {
                    self.waiting.removeValue(forKey: id)?.resume(returning: ("Couldn't send it to your Mac.", nil))
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(30))
                self.waiting.removeValue(forKey: id)?.resume(returning: ("Your Mac didn't answer.", nil))
            }
        }
    }

    // MARK: Actions

    func answer(_ approval: RemoteSnapshot.Approval, allow: Bool) async {
        guard await authenticate(allow ? "Allow: \(approval.summary)" : "Deny: \(approval.summary)") else { return }
        if let error = await request(.answer(approvalID: approval.id, allow: allow)).error { notice = error }
    }

    func stopEverything() async {
        guard await authenticate("Stop everything on your Mac") else { return }
        if let error = await request(.stopEverything).error { notice = error }
    }

    func openTranscript(_ id: String) async {
        if let error = await request(.transcript(conversationID: id)).error { notice = error }
    }

    /// Message a conversation on the Mac (nil: a new one). Returns its id.
    func send(_ text: String, to conversationID: String?) async -> String? {
        let result = await request(.send(conversationID: conversationID, text: text))
        if let error = result.error { notice = error }
        return result.conversationID
    }

    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1" }
}

/// The pairing, in this iPhone's Keychain (never backed up or synced).
enum PairingStore {
    static let service = "AgentX pairing"

    static func load() -> PairingCode? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return PairingCode(url: String(decoding: data, as: UTF8.self))
    }

    static func save(_ code: PairingCode) throws {
        delete()
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                         kSecAttrAccount as String: "mac", kSecValueData as String: Data(code.url.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}
