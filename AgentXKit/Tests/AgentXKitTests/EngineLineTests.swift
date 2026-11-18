import Foundation
import Testing
@testable import AgentXKit

@Suite("Engine messages")
struct EngineLineTests {
    @Test func lineSeparatorsInEmailsDontSplitAMessage() throws {
        let message: JSONValue = ["id": "core-1", "result": ["text": .string("Dear Kshitij,\u{2028}see below\u{2029}Enda")]]
        let data = try #require(AgentClient.encodeLine(message))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("\u{2028}") && !text.contains("\u{2029}"))
        #expect(text.filter { $0 == "\n" }.count == 1 && text.hasSuffix("\n"))
        let back = try JSONValue.parse(data.dropLast())
        #expect(back["result"]?["text"]?.string == "Dear Kshitij,\u{2028}see below\u{2029}Enda", "escaped, not changed")
    }
}
