import AVFoundation
import Foundation
import Speech

/// Hold the launcher shortcut and talk. Recognition runs on this Mac only
/// (`requiresOnDeviceRecognition`): your voice never leaves it, and only the
/// words you said go to Claude, as your message.
@MainActor
@Observable
final class VoiceInput {
    static let shared = VoiceInput()

    private(set) var isListening = false
    /// What's been heard so far (updates as you speak).
    private(set) var text = ""
    /// Microphone level, 0…1, for the meter.
    fileprivate(set) var level: Float = 0
    var error: String?

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var tap: AudioTap?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var finished = false

    /// Settings → Assistant → Launcher and pointer.
    static var holdToTalk: Bool { UserDefaults.standard.object(forKey: "voiceHoldToTalk") as? Bool ?? true }

    /// Start listening. False (with `error` set) if the microphone or speech recognition isn't available.
    func start() async -> Bool {
        guard !isListening else { return true }
        error = nil
        text = ""
        level = 0
        finished = false
        guard await Self.authorize() else {
            error = "AgentX needs the microphone and speech recognition to listen. Allow them in System Settings › Privacy & Security."
            return false
        }
        guard let recognizer = Self.recognizer() else {
            error = "On-device speech recognition isn't set up for your language. Turn on Dictation in System Settings › Keyboard, then try again."
            return false
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        let tap = AudioTap(request: request)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            error = "No microphone is available."
            return false
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: tap.handle)
        task = Self.recognize(with: recognizer, request)
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            task?.cancel()
            self.error = "Couldn't start the microphone: \(error.localizedDescription)"
            return false
        }
        self.engine = engine
        self.tap = tap
        isListening = true
        return true
    }

    /// Stop listening and return what was heard (waiting briefly for the last words).
    func stop() async -> String {
        guard isListening else { return text }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        tap?.request.endAudio()
        for _ in 0..<30 where !finished {
            try? await Task.sleep(for: .milliseconds(50))
        }
        task?.cancel()
        engine = nil
        tap = nil
        task = nil
        isListening = false
        level = 0
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stop without sending anything.
    func cancel() {
        guard isListening else { return }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        task?.cancel()
        engine = nil
        tap = nil
        task = nil
        isListening = false
        level = 0
        text = ""
    }

    private static func authorize() async -> Bool {
        guard await speechAuthorization() == .authorized else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    // The two callbacks below come back on background threads. They're made
    // outside the main actor on purpose: a closure written inside main-actor
    // code is checked to run on the main thread, and that check stops the app.

    private nonisolated static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { status in done.resume(returning: status) }
        }
    }

    private nonisolated static func recognize(with recognizer: SFSpeechRecognizer,
                                              _ request: SFSpeechAudioBufferRecognitionRequest) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let heard = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? (error != nil)
            Task { @MainActor in
                let voice = VoiceInput.shared
                if let heard { voice.text = heard }
                if isFinal { voice.finished = true }
            }
        }
    }

    /// A recognizer for your language that works on this Mac (English as a fallback).
    private static func recognizer() -> SFSpeechRecognizer? {
        for locale in [Locale.current, Locale(identifier: "en-US")] {
            if let r = SFSpeechRecognizer(locale: locale), r.supportsOnDeviceRecognition, r.isAvailable { return r }
        }
        return nil
    }
}

/// Feeds microphone audio to the recognizer on the audio thread.
private final class AudioTap: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest
    private var lastLevel = Date.distantPast

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func handle(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        request.append(buffer)
        // About 15 level updates a second is plenty for the meter.
        guard Date().timeIntervalSince(lastLevel) > 0.066, let samples = buffer.floatChannelData?[0] else { return }
        lastLevel = Date()
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = (sum / Float(count)).squareRoot()
        let level = min(1, rms * 12)
        Task { @MainActor in VoiceInput.shared.level = level }
    }
}
