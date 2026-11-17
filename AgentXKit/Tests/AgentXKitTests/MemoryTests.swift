import Foundation
import Testing
@testable import AgentXKit

@Suite("Memory")
@MainActor
struct MemoryTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("memory-\(UUID().uuidString)")
    let scratch = ScratchDefaults()

    func store() -> MemoryStore { MemoryStore(folder: folder, defaults: scratch.defaults) }
    func cleanUp() { try? FileManager.default.removeItem(at: folder); scratch.remove() }

    @Test func savesUpdatesAndForgets() throws {
        defer { cleanUp() }
        let m = store()
        #expect(try m.save(title: "Prefers short replies", body: "Keep answers brief.", kind: .preference, source: "Conversation “x”", reviewed: false))
        #expect(m.items.count == 1)
        #expect(m.unreviewedCount == 1)
        // Same title (any case) updates instead of adding a duplicate.
        #expect(try m.save(title: "prefers short replies", body: "Two or three lines.", kind: .preference, source: nil, reviewed: false) == false)
        #expect(m.items.count == 1)
        #expect(m.items[0].body == "Two or three lines.")
        #expect(m.items[0].source == "Conversation “x”", "the original source is kept")

        let file = folder.appendingPathComponent("prefers-short-replies.md")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasPrefix("---\ntitle: prefers short replies\nkind: preference\n"))
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
        #expect(try String(contentsOf: folder.appendingPathComponent("MEMORY.md"), encoding: .utf8).contains("prefers-short-replies.md"))

        try m.forget(m.items[0].id)
        #expect(m.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".trash/prefers-short-replies.md").path), "recoverable")
    }

    @Test func refusesSecretsAndRespectsPause() throws {
        defer { cleanUp() }
        let m = store()
        #expect(throws: MemoryStore.SaveError.secret("a GitHub token")) {
            try m.save(title: "GitHub", body: "token ghp_abcdefghijklmnopqrstuvwxyz0123456789", kind: .other, source: nil, reviewed: false)
        }
        #expect(throws: MemoryStore.SaveError.secret("a card number")) {
            try m.save(title: "Card", body: "My card is 4111 1111 1111 1111", kind: .me, source: nil, reviewed: false)
        }
        m.isPaused = true
        #expect(throws: MemoryStore.SaveError.paused) {
            try m.save(title: "Lives in Dublin", body: "Dublin, Ireland.", kind: .me, source: nil, reviewed: false)
        }
        #expect(m.promptSection() == nil, "paused: Claude gets nothing")
        #expect(store().isPaused, "the choice is remembered")
    }

    @Test func readsHandEditedFiles() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\ntitle: Enda Fallon\nkind: person\nupdated: 2026-11-17T10:00:00Z\n---\n\nPhD supervisor at TUS.\n"
            .write(to: folder.appendingPathComponent("enda-fallon.md"), atomically: true, encoding: .utf8)
        try "Just a note with no front matter.".write(to: folder.appendingPathComponent("loose-note.md"), atomically: true, encoding: .utf8)
        let m = store()
        let enda = try #require(m.item(titled: "enda fallon"))
        #expect(enda.kind == .person && enda.body == "PhD supervisor at TUS." && enda.reviewed)
        #expect(m.item(titled: "loose note")?.body == "Just a note with no front matter.")
        #expect(m.search("supervisor tus").map(\.title) == ["Enda Fallon"])
    }

    @Test func claudeGetsACappedIndex() throws {
        defer { cleanUp() }
        let m = store()
        #expect(m.promptSection()?.contains("(No memories yet.)") == true)
        for i in 0..<120 {
            try m.save(title: "Project \(i)", body: String(repeating: "detail ", count: 40), kind: .project, source: nil, reviewed: true)
        }
        let prompt = try #require(m.promptSection())
        #expect(prompt.contains("memory_save"))
        #expect(prompt.contains("- … more: use memory_search"))
        #expect(prompt.count < MemoryStore.indexLimit + 2_000)
    }

    @Test func slugsAreSafeFileNames() {
        #expect(MemoryStore.slug("Prefers short replies!") == "prefers-short-replies")
        #expect(MemoryStore.slug("../../etc/passwd") == "etc-passwd")
        #expect(MemoryStore.slug("Café crème") == "cafe-creme")
        #expect(MemoryStore.slug("???") == "memory")
    }
}

@Suite("Secret detector")
struct SecretDetectorTests {
    @Test(arguments: [
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        "sk-ant-api03-abcdefghijklmnopqrstuvwxyz",
        "my token is ghp_abcdefghijklmnopqrstuvwxyz0123",
        "AKIAIOSFODNN7EXAMPLE",
        "password: hunter22",
        "the wifi password is CorrectHorse",
        "4111-1111-1111-1111",
        "SSN 123-45-6789",
    ])
    func spotsSecrets(_ text: String) {
        #expect(SecretDetector.find(in: text) != nil, "\(text)")
    }

    @Test(arguments: [
        "Prefers short replies",
        "Uses 1Password as their password manager",
        "Meeting on 2026-11-17 at 10:00",
        "Phone ends in 4821",
        "Order number 1234 5678 9012 3456",   // not a valid card (fails Luhn)
    ])
    func leavesOrdinaryTextAlone(_ text: String) {
        #expect(SecretDetector.find(in: text) == nil, "\(text)")
    }
}
