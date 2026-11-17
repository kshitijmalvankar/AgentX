import Foundation
import Testing
@testable import AgentXKit

@Suite("Transcript performance")
@MainActor
struct TranscriptPerformanceTests {
    @Test func hugeToolResultsAreShortened() {
        let big = String(repeating: "x", count: 100_000)
        let kept = TranscriptBuilder.capped(big)
        #expect(kept.count < 21_000)
        #expect(kept.contains("more characters are in the session file"))
        #expect(TranscriptBuilder.capped("short") == "short")
    }

    @Test func streamingTextIsBatched() async throws {
        let c = Conversation(id: "c", sessionId: nil, cwd: "/tmp", title: "t")
        for word in ["Hel", "lo", " wor", "ld"] {
            c.apply(["type": "stream_event", "parent_tool_use_id": nil,
                     "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": .string(word)]]])
        }
        #expect(c.draftText == "", "published in a batch, not per delta")
        // The batch lands about 40 ms later; wait for it rather than a fixed time (tests run in parallel).
        for _ in 0..<200 where c.draftText.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.draftText == "Hello world")
        c.apply(["type": "assistant", "uuid": "a1", "message": ["role": "assistant", "content": [["type": "text", "text": "Hello world"]]]])
        #expect(c.draftText == "" && c.items.count == 1 && c.hasLiveItems)
    }

    @Test func incrementalHistoryTracksWhereItLeftOff() {
        let c = Conversation(id: "c", sessionId: "s", cwd: "/tmp", title: "t")
        c.replaceHistory([["type": "user", "uuid": "u1", "message": ["role": "user", "content": "hi"]]])
        #expect(c.historyCount == 1 && c.lastHistoryUUID == "u1" && !c.hasLiveItems)
        c.appendHistory([["type": "assistant", "uuid": "a1", "message": ["role": "assistant", "content": [["type": "text", "text": "hey"]]]]])
        #expect(c.historyCount == 2 && c.lastHistoryUUID == "a1" && c.items.count == 2)
        c.unload()
        #expect(!c.historyLoaded && c.items.isEmpty && c.historyCount == 0)
    }

    @Test func oldTranscriptsAreUnloaded() {
        let store = SessionStore(client: AgentClient())
        var made: [Conversation] = []
        for i in 0..<10 {
            let c = Conversation(id: "c\(i)", sessionId: "s\(i)", cwd: "/tmp", title: "t\(i)")
            c.replaceHistory([["type": "user", "uuid": .string("u\(i)"), "message": ["role": "user", "content": "hi"]]])
            c.lastViewed = Date().addingTimeInterval(TimeInterval(-1000 + i))
            store.insert(c)
            made.append(c)
        }
        store.select("c0")   // the oldest, now shown
        let loaded = made.filter(\.historyLoaded)
        #expect(made[0].historyLoaded, "the shown conversation stays loaded")
        #expect(loaded.count == SessionStore.loadedTranscriptLimit + 1)
        #expect(!made[1].historyLoaded && made[9].historyLoaded)
    }
}
