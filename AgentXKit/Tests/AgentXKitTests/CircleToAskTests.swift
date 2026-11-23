import CoreGraphics
import Testing
@testable import AgentXKit

@Suite("Circle to Ask")
struct CircleToAskTests {
    private let main = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func theCircledAreaOnTheMainScreen() throws {
        // A loop around a paragraph, in the overlay's coordinates (top-left origin).
        let points = [CGPoint(x: 100, y: 200), CGPoint(x: 400, y: 190), CGPoint(x: 420, y: 320), CGPoint(x: 110, y: 330)]
        let region = try #require(CircleToAsk.region(of: points, screenFrame: main, mainHeight: main.height))
        #expect(region == CGRect(x: 92, y: 182, width: 336, height: 156), "the loop's box, with a little room around it")
    }

    @Test func aSecondScreenAboveTheMainOne() throws {
        // AppKit puts a screen above the main one at y = 982; from the top-left it's at y = -1080.
        let above = CGRect(x: 0, y: 982, width: 1920, height: 1080)
        let points = [CGPoint(x: 50, y: 50), CGPoint(x: 250, y: 150)]
        let region = try #require(CircleToAsk.region(of: points, screenFrame: above, mainHeight: main.height))
        #expect(region == CGRect(x: 42, y: -1080 + 42, width: 216, height: 116))
    }

    @Test func clicksAndScribblesDontCount() {
        #expect(CircleToAsk.region(of: [], screenFrame: main, mainHeight: main.height) == nil)
        #expect(CircleToAsk.region(of: [CGPoint(x: 10, y: 10), CGPoint(x: 14, y: 12)], screenFrame: main, mainHeight: main.height) == nil)
    }

    @Test func itStaysOnTheScreen() throws {
        let points = [CGPoint(x: 2, y: 2), CGPoint(x: 300, y: 300)]
        let region = try #require(CircleToAsk.region(of: points, screenFrame: main, mainHeight: main.height))
        #expect(region.minX == 0 && region.minY == 0)
    }

    @Test func aPictureGoesAlongOnlyWhenThereIsLittleText() {
        #expect(CircleToAsk.wantsPicture(text: ""))
        #expect(CircleToAsk.wantsPicture(text: "Q1  Q2  Q3\n12%  18%"), "a chart's labels")
        #expect(!CircleToAsk.wantsPicture(text: "Quantum entanglement is a phenomenon in which the quantum states of two particles are linked."))
    }
}
