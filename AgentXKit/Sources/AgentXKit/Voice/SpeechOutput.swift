import AVFoundation
import Foundation

/// Reading answers aloud after you ask by voice (Settings → Assistant →
/// Launcher and pointer). Uses macOS's own voices, on this Mac.
@MainActor
@Observable
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechOutput()

    private(set) var isSpeaking = false
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    /// Off unless you turn it on in Settings.
    static var readAloud: Bool { UserDefaults.standard.object(forKey: "voiceReadAloud") as? Bool ?? false }

    /// How much of a long answer to read (the rest is on screen).
    static let maxCharacters = 1_500

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ markdown: String) {
        stop()
        var text = Self.plainText(markdown)
        guard !text.isEmpty else { return }
        if text.count > Self.maxCharacters {
            let cut = text.prefix(Self.maxCharacters)
            text = String(cut[..<(cut.lastIndex(where: { ".!?".contains($0) }) ?? cut.endIndex)]) + ". The rest is on screen."
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    /// Markdown as it should sound: no symbols, code left out, links as their words.
    nonisolated static func plainText(_ markdown: String) -> String {
        var t = markdown
        t = t.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " (code on screen) ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^\s{0,3}(#{1,6}|>|[-*+]|\d+[.)])\s+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(\*\*|__|\*|_|`|~~)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^\s*\|?[-:| ]+\|[-:| ]*$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "|", with: ", ")
        t = t.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
