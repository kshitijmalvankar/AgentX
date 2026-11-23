import AppKit
import Vision

/// Reading the text in a window on this Mac (Apple's Vision framework), so
/// questions about what's on screen and pointing at things in web pages don't
/// need a picture sent to Claude. Needs Screen Recording, like Look at Window.
enum ScreenText {
    /// What a window says, top to bottom.
    struct Reading: Sendable {
        var text: String
        var appName: String
        var windowTitle: String?
    }

    /// The text in `app`'s front window.
    static func read(_ app: NSRunningApplication) async throws -> Reading {
        let shot = try await ScreenGrabber.captureImage(of: app, maxDimension: 3000)
        let lines = try await Task.detached(priority: .userInitiated) { try recognize(shot.image).map(\.text) }.value
        return Reading(text: lines.joined(separator: "\n"), appName: app.localizedName ?? "the app", windowTitle: shot.title)
    }

    /// Where `target` is written in `app`'s front window, in screen coordinates
    /// (origin at the top-left of the main screen), or nil.
    static func locate(_ target: String, in app: NSRunningApplication) async throws -> CGRect? {
        let shot = try await ScreenGrabber.captureImage(of: app, maxDimension: 3000)
        let image = shot.image, frame = shot.frame
        return try await Task.detached(priority: .userInitiated) {
            guard let box = try bestMatch(for: target, in: image) else { return nil }
            // Vision's boxes are 0…1 with the origin at the bottom-left of the image.
            return CGRect(x: frame.minX + box.minX * frame.width, y: frame.minY + (1 - box.maxY) * frame.height,
                          width: box.width * frame.width, height: box.height * frame.height)
        }.value
    }

    /// The text in an image (a circled part of the screen), top to bottom.
    nonisolated static func text(in image: CGImage) -> String {
        ((try? recognize(image)) ?? []).map(\.text).joined(separator: "\n")
    }

    private struct Line { let text: String; let candidate: VNRecognizedText; let box: CGRect }

    private static func recognize(_ image: CGImage) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { o -> Line? in
            guard let c = o.topCandidates(1).first else { return nil }
            return Line(text: c.string, candidate: c, box: o.boundingBox)
        }
        // Top to bottom, then left to right.
        return lines.sorted { abs($0.box.midY - $1.box.midY) > 0.01 ? $0.box.midY > $1.box.midY : $0.box.minX < $1.box.minX }
    }

    /// The box of the best match for `target`: the exact words inside a line, preferring short lines (buttons).
    private static func bestMatch(for target: String, in image: CGImage) throws -> CGRect? {
        let want = NameMatch.fold(target)
        guard !want.isEmpty else { return nil }
        var best: (box: CGRect, score: Double)?
        for line in try recognize(image) {
            let have = NameMatch.fold(line.text)
            guard let range = have.range(of: want) else { continue }
            let score = (have == want ? 100 : 50) - Double(have.count) * 0.1
            guard score > (best?.score ?? -1) else { continue }
            // The words' own box when Vision can give it; the line's otherwise.
            let original = line.candidate.string
            let start = original.index(original.startIndex, offsetBy: have.distance(from: have.startIndex, to: range.lowerBound), limitedBy: original.endIndex)
            let end = start.flatMap { original.index($0, offsetBy: want.count, limitedBy: original.endIndex) }
            var box = line.box
            if let start, let end, let words = try? line.candidate.boundingBox(for: start..<end) { box = words.boundingBox }
            best = (box, score)
        }
        return best?.box
    }
}
