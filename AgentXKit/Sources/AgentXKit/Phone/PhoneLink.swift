import AgentXRemote
import CryptoKit
import Foundation
import Observation

/// The link to the AgentX iPhone app.
///
/// - AgentX listens on the network **only while a phone is paired or being
///   paired** (and the link is on in Settings → iPhone).
/// - Pairing: a QR code with a fresh key, good once, for 5 minutes. A phone
///   that uses it still has to be confirmed here before it gets anything.
/// - Every connection runs SecureChannel's handshake (mutual authentication,
///   forward secrecy) before any data flows; see RemoteKit.
/// - The phone can: watch (snapshots), answer approvals, stop everything, and
///   message Mac conversations. Each of those is logged in the activity log,
///   and approving and messaging can be turned off here.
@MainActor
@Observable
public final class PhoneLink {
    public enum Status: Equatable {
        case off
        /// Nothing paired, so nothing is listening.
        case idle
        case listening(port: UInt16)
        case failed(String)
    }

    public private(set) var devices: [PairedDevice] = []
    public private(set) var status: Status = .off
    /// The QR code being shown (nil when not pairing).
    public private(set) var pairing: PairingCode?
    /// A phone that used the pairing code and is waiting for your OK.
    public private(set) var awaitingConfirmation: PairedDevice?
    /// Devices with an open, confirmed connection.
    public private(set) var connected: Set<UUID> = []
    public private(set) var lastError: String?

    /// Master switch (Settings → iPhone).
    public var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.enabled)
            if !isEnabled { cancelPairing(); closeAll() }
            updateListener()
        }
    }
    public var allowApprovals: Bool { didSet { defaults.set(allowApprovals, forKey: Keys.approvals); pushSoon() } }
    public var allowMessages: Bool { didSet { defaults.set(allowMessages, forKey: Keys.messages); pushSoon() } }

    static let pairingLifetime: TimeInterval = 5 * 60

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let keys: PhoneKeyStore
    @ObservationIgnored private let keyTable = PhoneKeyTable()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let preferredPort: UInt16
    @ObservationIgnored private let advertise: Bool
    @ObservationIgnored private var server: RemoteServer?
    @ObservationIgnored private var links: [UUID: Link] = [:]
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    private enum Keys {
        static let enabled = "phoneLinkEnabled"
        static let approvals = "phoneAllowApprovals"
        static let messages = "phoneAllowMessages"
    }

    /// One connected phone.
    private final class Link {
        let session: SecureSession
        var deviceID: UUID { session.deviceID }
        var confirmed = false
        var lastSnapshot: RemoteSnapshot?
        var watchedConversation: String?
        var lastTranscript: RemoteTranscript?
        var receiveTask: Task<Void, Never>?
        init(session: SecureSession) { self.session = session }
    }

    init(keys: PhoneKeyStore = KeychainPhoneKeys(), defaults: UserDefaults = .standard,
         file: URL = AppChannel.current.dataFile("phone-devices.json"),
         preferredPort: UInt16 = RemoteService.preferredPort, advertise: Bool = true) {
        self.keys = keys
        self.defaults = defaults
        self.file = file
        self.preferredPort = preferredPort
        self.advertise = advertise
        defaults.register(defaults: [Keys.enabled: true, Keys.approvals: true, Keys.messages: true])
        isEnabled = defaults.bool(forKey: Keys.enabled)
        allowApprovals = defaults.bool(forKey: Keys.approvals)
        allowMessages = defaults.bool(forKey: Keys.messages)
        load()
    }

    func attach(_ model: AppModel) {
        self.model = model
        updateListener()
    }

    // MARK: Devices

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        devices = ((try? decoder.decode([PairedDevice].self, from: data)) ?? []).filter(\.confirmed)
        refreshKeyTable()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(devices.filter(\.confirmed)) { try? SecureFile.write(data, to: file) }
    }

    private func refreshKeyTable(now: Date = Date()) {
        var table: [UUID: SymmetricKey] = [:]
        for d in devices where d.isUsable(now: now) {
            if let key = keys.key(for: d.id) { table[d.id] = key }
        }
        keyTable.set(table)
    }

    /// Forget a phone: its key is deleted and any connection is closed.
    public func revoke(_ id: UUID) {
        let name = devices.first { $0.id == id }?.name ?? "iPhone"
        devices.removeAll { $0.id == id }
        keys.delete(id)
        refreshKeyTable()
        save()
        if let link = links.removeValue(forKey: id) {
            Task { try? await link.session.send(ServerEvent.refused) ; link.session.close() }
            link.receiveTask?.cancel()
        }
        connected.remove(id)
        if awaitingConfirmation?.id == id { awaitingConfirmation = nil }
        model?.activity.record(.policy, "revoked", detail: "Removed \(name) from paired iPhones.")
        updateListener()
    }

    // MARK: Pairing

    /// Make a new pairing code (and start listening if needed).
    public func startPairing() {
        guard isEnabled else { return }
        cancelPairing()
        let id = UUID()
        let key = SecureChannel.newPairingKey()
        do { try keys.save(key, for: id) } catch {
            lastError = error.localizedDescription
            return
        }
        let expires = Date().addingTimeInterval(Self.pairingLifetime)
        devices.append(PairedDevice(id: id, name: "New iPhone", pairedAt: Date(), lastSeen: nil, confirmed: false, pairingExpires: expires))
        refreshKeyTable()
        updateListener()
        pairing = PairingCode(deviceID: id, key: key.withUnsafeBytes { Data($0) }, serviceName: Self.serviceName,
                              port: currentPort ?? RemoteService.preferredPort, addresses: LocalAddresses.reachable(),
                              macName: RemoteSnapshotBuilder.macName, expires: expires)
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pairingLifetime))
            guard !Task.isCancelled else { return }
            self?.expirePairing(id)
        }
    }

    /// Stop showing the code; an unused code stops working.
    public func cancelPairing() {
        expiryTask?.cancel()
        if let code = pairing, let d = devices.first(where: { $0.id == code.deviceID }), !d.confirmed {
            if awaitingConfirmation?.id == d.id { decline() }
            removeUnconfirmed(d.id)
        }
        pairing = nil
        updateListener()
    }

    private func expirePairing(_ id: UUID) {
        guard let d = devices.first(where: { $0.id == id }), !d.confirmed, awaitingConfirmation?.id != id else { return }
        removeUnconfirmed(id)
        if pairing?.deviceID == id { pairing = nil }
        updateListener()
    }

    private func removeUnconfirmed(_ id: UUID) {
        devices.removeAll { $0.id == id && !$0.confirmed }
        keys.delete(id)
        refreshKeyTable()
    }

    /// You allowed the phone that's waiting.
    public func confirm() {
        guard let pending = awaitingConfirmation, let i = devices.firstIndex(where: { $0.id == pending.id }) else { return }
        devices[i].confirmed = true
        devices[i].pairingExpires = nil
        devices[i].lastSeen = Date()
        awaitingConfirmation = nil
        pairing = nil
        expiryTask?.cancel()
        refreshKeyTable()
        save()
        model?.activity.record(.policy, "paired", detail: "Paired \(devices[i].name). It can now see this Mac's status" +
                               (allowApprovals ? ", answer approvals" : "") + (allowMessages ? " and message Claude" : "") + ".")
        if let link = links[pending.id] {
            link.confirmed = true
            connected.insert(pending.id)
            startWatchingIfNeeded()
            Task { await self.push(to: link, force: true) }
        }
    }

    /// You declined the phone that's waiting.
    public func decline() {
        guard let pending = awaitingConfirmation else { return }
        awaitingConfirmation = nil
        if let link = links.removeValue(forKey: pending.id) {
            Task { try? await link.session.send(ServerEvent.refused); link.session.close() }
            link.receiveTask?.cancel()
        }
        removeUnconfirmed(pending.id)
        pairing = nil
        model?.activity.record(.policy, "declined", detail: "Declined \(pending.name)'s pairing request.")
        updateListener()
    }

    // MARK: Listener

    static var serviceName: String { "\(AppChannel.current.displayName) on \(RemoteSnapshotBuilder.macName)" }

    private var currentPort: UInt16? {
        if case .listening(let port) = status { return port }
        return nil
    }

    /// Listen only while the link is on and a phone is paired or pairing.
    private func updateListener() {
        let needed = isEnabled && model != nil && devices.contains { $0.isUsable() }
        if needed, server == nil {
            let table = keyTable
            let server = RemoteServer(
                serviceName: advertise ? Self.serviceName : nil,
                preferredPort: preferredPort,
                psk: { table.key(for: $0) },
                onSession: { [weak self] session in Task { @MainActor in self?.accept(session) } },
                onState: { [weak self] state in Task { @MainActor in self?.listenerChanged(state) } },
                onRejected: { [weak self] host, error in
                    Task { @MainActor in self?.rejected(host: host, error: error) }
                })
            self.server = server
            server.start()
        } else if !needed, let server {
            server.stop()
            self.server = nil
            status = isEnabled ? .idle : .off
        } else if !needed {
            status = isEnabled ? .idle : .off
        }
    }

    private func listenerChanged(_ state: RemoteServer.State) {
        switch state {
        case .listening(let port):
            status = .listening(port: port)
            // The code was made before the port was known.
            if var code = pairing, code.port != port {
                code.port = port
                pairing = code
            }
        case .failed(let why): status = .failed(why)
        case .stopped: status = isEnabled ? .idle : .off
        }
    }

    private func rejected(host: String?, error: ChannelError?) {
        // Only worth a line when someone presented a key we don't accept.
        guard error == .authenticationFailed || error == .unknownDevice else { return }
        model?.activity.record(.policy, "blocked", detail: "Refused an iPhone connection\(host.map { " from \($0)" } ?? ""): it isn't paired with this Mac.")
    }

    // MARK: Sessions

    private func accept(_ session: SecureSession) {
        guard let device = devices.first(where: { $0.id == session.deviceID }), device.isUsable() else {
            session.close()
            return
        }
        if let old = links.removeValue(forKey: device.id) {   // a reconnect replaces the old connection
            old.receiveTask?.cancel()
            old.session.close()
        }
        let link = Link(session: session)
        links[device.id] = link
        link.receiveTask = Task { [weak self] in await self?.receiveLoop(link) }
    }

    private func receiveLoop(_ link: Link) async {
        defer { disconnected(link) }
        while !Task.isCancelled {
            guard let envelope = try? await link.session.receive(ClientEnvelope.self) else { return }
            await handle(envelope, from: link)
        }
    }

    private func disconnected(_ link: Link) {
        link.session.close()
        guard links[link.deviceID] === link else { return }
        links.removeValue(forKey: link.deviceID)
        connected.remove(link.deviceID)
        if awaitingConfirmation?.id == link.deviceID { awaitingConfirmation = nil }
        stopWatchingIfIdle()
    }

    private func handle(_ envelope: ClientEnvelope, from link: Link) async {
        guard let model, let index = devices.firstIndex(where: { $0.id == link.deviceID }) else { return }
        let name = devices[index].name
        func reply(_ error: String? = nil, conversation: String? = nil) async {
            try? await link.session.send(ServerEvent.result(id: envelope.id, error: error, conversationID: conversation))
        }

        if case .hello(let deviceName, _) = envelope.request {
            let clean = String(deviceName.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { devices[index].name = clean }
            devices[index].lastSeen = Date()
            if devices[index].confirmed {
                link.confirmed = true
                connected.insert(link.deviceID)
                save()
                startWatchingIfNeeded()
                await reply()
                await push(to: link, force: true)
            } else {
                awaitingConfirmation = devices[index]
                NotificationManager.shared.postNotice(title: "\(devices[index].name) wants to connect",
                                                      body: "Allow it in AgentX Settings → iPhone, where the pairing code is.")
                await reply()
                try? await link.session.send(ServerEvent.awaitingConfirmation)
            }
            return
        }

        guard link.confirmed else {
            await reply("Confirm this iPhone on your Mac first.")
            return
        }
        devices[index].lastSeen = Date()

        switch envelope.request {
        case .hello:
            break
        case .refresh:
            await reply()
            await push(to: link, force: true)
        case .answer(let approvalID, let allow):
            guard allowApprovals else { return await reply("Approving from iPhone is turned off on the Mac.") }
            guard let approval = model.sessions.approvals.first(where: { $0.id == approvalID }) else {
                return await reply("That request isn't waiting any more.")
            }
            model.activity.record(.approval, allow ? "allowed on iPhone" : "denied on iPhone", tool: approval.toolName,
                                  detail: "From \(name)", origin: approval.automationName ?? model.sessions.origin(forHandle: approval.handle)?.title,
                                  sessionId: approval.sessionId)
            model.sessions.answer(approval, allow ? .allow : .deny("Denied from \(name)."))
            await reply()
            pushSoon()
        case .stopEverything:
            await model.stopEverything(source: name)
            await reply()
            pushSoon()
        case .transcript(let id):
            guard let c = await conversation(id, in: model) else { return await reply("That conversation isn't on this Mac.") }
            link.watchedConversation = id
            await reply(conversation: id)
            let t = RemoteSnapshotBuilder.transcript(c, id: id)
            link.lastTranscript = t
            try? await link.session.send(ServerEvent.transcript(t))
        case .send(let id, let text):
            guard allowMessages else { return await reply("Messaging from iPhone is turned off on the Mac.") }
            let text = String(text.prefix(20_000)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return await reply("The message is empty.") }
            let c: Conversation
            if let id {
                guard let existing = await conversation(id, in: model), existing.kind == .assistant else {
                    return await reply("Only conversations on this Mac (not coding sessions) take messages from iPhone.")
                }
                c = existing
                await model.askAssistant(text, in: c)
            } else {
                c = await model.askAssistant(text)
            }
            model.activity.record(.tool, "message from iPhone", detail: String(text.prefix(200)), origin: c.title, sessionId: c.sessionId)
            // AgentX's own id: it stays the same after Claude Code assigns a session id.
            let cid = id ?? RemoteSnapshotBuilder.phoneID(c)
            link.watchedConversation = cid
            await reply(conversation: cid)
            pushSoon()
        }
    }

    /// A conversation by session id or AgentX's own id, loading its history if needed.
    private func conversation(_ id: String, in model: AppModel) async -> Conversation? {
        let store = model.sessions
        if let c = store.conversations[id] ?? store.conversation(forSessionId: id) {
            if !c.historyLoaded, !c.isLoadingHistory, c.sessionId != nil { await store.loadHistory(c) }
            return c
        }
        guard let summary = store.sessions.first(where: { $0.sessionId == id }) else { return nil }
        let c = store.open(summary)
        for _ in 0..<100 where !c.historyLoaded { try? await Task.sleep(for: .milliseconds(50)) }
        return c
    }

    // MARK: Pushing updates

    /// Send changes soon (coalesced).
    func pushSoon() {
        guard !connected.isEmpty else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            await self?.pushAll()
        }
    }

    private func pushAll() async {
        for link in links.values where link.confirmed {
            await push(to: link, force: false)
        }
    }

    private func push(to link: Link, force: Bool) async {
        guard let model else { return }
        var snapshot = RemoteSnapshotBuilder.snapshot(model, canApprove: allowApprovals, canMessage: allowMessages)
        if !force, var last = link.lastSnapshot {
            last.date = snapshot.date
            if last == snapshot { return }
        }
        snapshot.date = Date()
        link.lastSnapshot = snapshot
        try? await link.session.send(ServerEvent.snapshot(snapshot))

        if let id = link.watchedConversation, let c = model.sessions.conversations[id] ?? model.sessions.conversation(forSessionId: id) {
            let t = RemoteSnapshotBuilder.transcript(c, id: id)
            if force || t != link.lastTranscript {
                link.lastTranscript = t
                try? await link.session.send(ServerEvent.transcript(t))
            }
        }
    }

    /// While a phone is connected: sample vitals and check for changes once a second.
    private func startWatchingIfNeeded() {
        guard pushTask == nil, !connected.isEmpty, let model else { return }
        model.system.beginWatching()
        model.today.start()
        pushTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                if ticks % 300 == 0 { await self?.model?.today.refresh() }   // every 5 minutes
                await self?.pushAll()
                ticks += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopWatchingIfIdle() {
        guard connected.isEmpty, let task = pushTask else { return }
        task.cancel()
        pushTask = nil
        model?.system.endWatching()
    }

    private func closeAll() {
        for link in links.values {
            link.receiveTask?.cancel()
            link.session.close()
        }
        links.removeAll()
        connected.removeAll()
        awaitingConfirmation = nil
        stopWatchingIfIdle()
    }
}
