import Foundation
import Testing
@testable import AgentXKit
@testable import AgentXShared

/// The links Control Center buttons open must be ones AgentX accepts.
@Suite("Control Center links")
struct ControlLinkTests {
    private let token = String(repeating: "ab", count: 32)

    @Test func runAnAutomation() throws {
        let id = UUID()
        let url = SharedChannel.url("run/\(id.uuidString)", scheme: "agentx-dev", token: token)
        #expect(url.absoluteString == "agentx-dev://run/\(id.uuidString)?t=\(token)")
        #expect(try URLRoute.parse(url, scheme: "agentx-dev", token: token).get() == .runAutomation(id))
    }

    @Test func stopNeedsTheToken() throws {
        let signed = SharedChannel.url("stop", scheme: "agentx", token: token)
        #expect(try URLRoute.parse(signed, scheme: "agentx", token: token).get() == .stopEverything)
        let unsigned = SharedChannel.url("stop", scheme: "agentx", token: nil)
        #expect(URLRoute.parse(unsigned, scheme: "agentx", token: token) == .failure(.missingToken))
    }

    @Test func plainLinksNeedNoToken() throws {
        #expect(try URLRoute.parse(SharedChannel.url("launcher", scheme: "agentx", token: nil), scheme: "agentx", token: token).get()
                == .launcher(prefill: nil))
        #expect(try URLRoute.parse(SharedChannel.url("approvals", scheme: "agentx", token: nil), scheme: "agentx", token: token).get()
                == .approvals)
    }

    @Test func outsideTheAppItsTheInstalledAgentX() {
        // Tests run without AgentX's Info.plist keys.
        #expect(SharedChannel.appName == "AgentX" && SharedChannel.urlScheme == "agentx")
        #expect(SharedChannel.dataDirectory.path.hasSuffix("Library/Application Support/AgentX"))
    }
}
