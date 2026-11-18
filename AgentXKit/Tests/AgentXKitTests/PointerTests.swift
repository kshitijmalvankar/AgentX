import Foundation
import Testing
@testable import AgentXKit

@Suite("Pointing at things")
struct PointerTests {
    @Test func labelsMatchBestWhenExact() {
        #expect(ScreenTargets.score("Export…", "export") == 3, "trailing ellipsis ignored")
        #expect(ScreenTargets.score("Export to PDF", "Export") == 2)
        #expect(ScreenTargets.score("Quick Export", "export") == 1)
        #expect(ScreenTargets.score("Café", "cafe") == 3, "accents ignored")
        #expect(ScreenTargets.score("Share", "export") == 0)
        #expect(ScreenTargets.score("", "export") == 0)
    }

    @Test func aSpotInAPictureLandsOnTheWindow() throws {
        // A 1000×500 pt window at (100, 50), pictured at 2000×1000 pixels.
        let look = ScreenGrabber.LastLook(windowFrame: CGRect(x: 100, y: 50, width: 1000, height: 500),
                                          imageSize: CGSize(width: 2000, height: 1000), appName: "Safari")
        let spot = try #require(ScreenTargets.spot(x: 1000, y: 500, in: look))
        #expect(spot.midX == 600 && spot.midY == 300)
        #expect(ScreenTargets.spot(x: 2500, y: 10, in: look) == nil, "outside the picture")
    }
}
