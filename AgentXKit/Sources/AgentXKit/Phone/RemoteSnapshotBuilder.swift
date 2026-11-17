import AgentXRemote
import Foundation

/// Turns AgentX's state into what the iPhone shows.
@MainActor
enum RemoteSnapshotBuilder {
    static let macName = Host.current().localizedName ?? "Mac"

    static func snapshot(_ model: AppModel, canApprove: Bool, canMessage: Bool, canEditReminders: Bool = false) -> RemoteSnapshot {
        RemoteSnapshot(
            macName: macName,
            appName: AppChannel.current.displayName,
            planLabel: model.account?.account.planLabel,
            vitals: model.system.latest.map(vitals),
            usage: model.usage.usage?.windows.map { .init(label: $0.label, fraction: $0.fraction, resetsAt: $0.resetsAt) } ?? [],
            approvals: model.sessions.approvals.map { approval(model, $0) },
            conversations: conversations(model.sessions),
            today: today(model.today.agenda, completed: model.today.completed),
            automations: model.automations.automations.map { a in
                let last = model.automations.lastRun(of: a)
                return .init(id: a.id.uuidString, name: a.name, next: model.automations.isPaused ? nil : model.automations.nextRun(of: a),
                             lastStatus: last?.status.rawValue, lastSummary: last?.summary, lastRun: last?.startedAt)
            },
            automationsPaused: model.automations.isPaused,
            activity: model.activity.recent.prefix(40).map {
                .init(id: $0.id.uuidString, date: $0.date, kind: $0.kind.rawValue, action: $0.action, tool: $0.toolLabel,
                      detail: $0.detail, origin: $0.origin)
            },
            canApprove: canApprove,
            canMessage: canMessage,
            canEditReminders: canEditReminders
        )
    }

    static func vitals(_ s: SystemSnapshot) -> RemoteSnapshot.Vitals {
        .init(cpu: s.cpu, memoryUsed: s.memory.used, memoryTotal: s.memory.total, memoryPressure: s.memoryPressure.label,
              diskFree: s.disk.available, diskTotal: s.disk.total, batteryLevel: s.battery?.level,
              charging: s.battery?.isCharging, thermal: s.thermal.label)
    }

    static func approval(_ model: AppModel, _ a: ApprovalRequest) -> RemoteSnapshot.Approval {
        let activity = ToolPresentation.activity(name: a.toolName, input: a.input, cwd: a.cwd)
        let summary = activity.detail.isEmpty ? activity.title : "\(activity.title): \(activity.detail)"
        return .init(id: a.id, headline: a.headline, tool: a.toolName.replacingOccurrences(of: "mcp__agentx__", with: ""),
                     summary: summary, detail: a.input.prettyPrinted(), policyReason: a.policyReason,
                     origin: a.automationName ?? model.sessions.origin(forHandle: a.handle)?.title,
                     receivedAt: a.receivedAt, unattended: a.unattended)
    }

    /// The id the phone uses for a conversation. It must not change while the
    /// phone watches it: a new conversation is "new-…" in AgentX and only gets
    /// its Claude Code session id after its first reply, so a conversation
    /// AgentX has open keeps AgentX's own id. Others use their session id.
    static func phoneID(_ c: Conversation) -> String { c.id }

    /// Mac conversations, newest first (live ones on top), then running coding sessions.
    static func conversations(_ store: SessionStore, limit: Int = 30) -> [RemoteSnapshot.Conversation] {
        var result: [RemoteSnapshot.Conversation] = []
        var seen = Set<String>()
        let liveMac = store.conversations.values.filter { $0.kind == .assistant && $0.isLive }.sorted { $0.title < $1.title }
        for c in liveMac {
            seen.insert(c.id)
            if let sid = c.sessionId { seen.insert(sid) }
            result.append(.init(id: phoneID(c), title: c.title, updated: Date(), state: c.liveState?.label, isMac: true, project: nil))
        }
        for s in store.assistantSessions where !seen.contains(s.sessionId) {
            seen.insert(s.sessionId)
            let open = store.conversation(forSessionId: s.sessionId)
            result.append(.init(id: open.map(phoneID) ?? s.sessionId, title: s.title, updated: s.modifiedDate,
                                state: open?.liveState?.label, isMac: true, project: nil))
        }
        result = Array(result.prefix(limit))
        for c in store.liveConversations where c.kind == .coding {
            result.append(.init(id: phoneID(c), title: c.title, updated: Date(), state: c.liveState?.label,
                                isMac: false, project: c.projectName))
        }
        return result
    }

    /// Today's events, open reminders, then reminders ticked off today (shown done, so they can be undone).
    static func today(_ agenda: Agenda?, completed: [Agenda.Reminder] = []) -> [RemoteSnapshot.AgendaItem] {
        guard let agenda else { return [] }
        let events = agenda.events.map {
            RemoteSnapshot.AgendaItem(id: $0.id, title: $0.title,
                                      when: $0.isAllDay ? "All day"
                                          : "\($0.start.formatted(.dateTime.hour().minute()))–\($0.end.formatted(.dateTime.hour().minute()))",
                                      isReminder: false, isOverdue: false, source: $0.calendar, location: $0.location, notes: $0.notes)
        }
        let reminders = agenda.reminders.map { r in
            let when: String = {
                guard let due = r.due else { return "" }
                if r.isOverdue { return "Overdue · " + due.formatted(.dateTime.day().month(.abbreviated)) }
                return r.hasTime ? due.formatted(.dateTime.hour().minute()) : "Today"
            }()
            return RemoteSnapshot.AgendaItem(id: r.id, title: r.title, when: when, isReminder: true, isOverdue: r.isOverdue,
                                             done: false, source: r.list, notes: r.notes)
        }
        let done = completed.map {
            RemoteSnapshot.AgendaItem(id: $0.id, title: $0.title, when: "Done", isReminder: true, isOverdue: false,
                                      done: true, source: $0.list, notes: $0.notes)
        }
        return events + reminders + done
    }

    /// A conversation's messages for the phone: your messages, Claude's
    /// replies, one line per tool, and notices. The newest 200 items.
    /// `id`: the id the phone asked with (echoed back so it always matches).
    static func transcript(_ c: Conversation, id: String? = nil) -> RemoteTranscript {
        let items: [RemoteTranscript.Item] = c.items.suffix(200).compactMap { item in
            switch item.kind {
            case .user(let text):
                return .init(id: item.id, role: .user, text: text)
            case .assistant(let text):
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : .init(id: item.id, role: .assistant, text: t)
            case .tool(let call):
                let a = ToolPresentation.activity(name: call.name, input: call.input, cwd: c.cwd)
                return .init(id: item.id, role: .tool, text: a.detail.isEmpty ? a.title : "\(a.title) · \(a.detail)")
            case .notice(let text, _):
                return .init(id: item.id, role: .notice, text: text)
            case .thinking, .result:
                return nil
            }
        }
        return RemoteTranscript(conversationID: id ?? phoneID(c), title: c.title, items: items, isWorking: c.isWorking,
                                draft: c.draftText.isEmpty ? nil : String(c.draftText.suffix(4000)))
    }
}
