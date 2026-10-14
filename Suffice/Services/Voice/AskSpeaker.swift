import AVFoundation
import Observation
import OSLog
import UIKit

nonisolated extension SettingsKey {
    /// The Kokoro voice Suffice speaks with.
    static let askVoice = "ask.voice"
}

/// Speaks Suffice's replies out loud, entirely on the iPhone.
///
/// With the natural voice downloaded, Kokoro generates the speech on the device, a sentence or
/// two at a time, so the first words play while the rest is still being made. Without it (or
/// in the Simulator, where MLX can't run), the best Apple voice installed on the phone reads
/// the reply instead.
///
/// During a spoken conversation the audio plays through the conversation's engine
/// (`ConversationAudio`), so echo cancellation knows what Suffice is saying and you can talk
/// over it. Otherwise it uses its own engine and audio session.
@Observable
final class AskSpeaker: NSObject {
    static let shared = AskSpeaker()

    enum State: Equatable {
        case idle
        /// Generating the first sentence.
        case preparing
        case speaking
    }

    private(set) var state: State = .idle
    var isActive: Bool { state != .idle }

    private let log = Logger(subsystem: "com.stephenwarren.suffice", category: "speaker")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: KokoroSynth.sampleRate, channels: 1)!
    private let synthesizer = AVSpeechSynthesizer()
    /// Bumped by every speak and stop, so callbacks from an earlier reply are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var producer: Task<Void, Never>?
    @ObservationIgnored private var pendingBuffers = 0
    @ObservationIgnored private var producing = false
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?
    /// Called once when the current reply has finished playing (not when it's stopped).
    @ObservationIgnored private var onFinished: (() -> Void)?
    /// Turns system-voice audio into Kokoro's format for the conversation engine.
    @ObservationIgnored private var converter: AVAudioConverter?

    /// The conversation's engine when one is running.
    private var conversation: ConversationAudio? {
        ConversationAudio.shared.isRunning ? ConversationAudio.shared : nil
    }

    /// The player node the reply goes to.
    private var output: AVAudioPlayerNode { conversation?.player ?? player }

    override init() {
        super.init()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        synthesizer.delegate = self
        // Another part of the app (or another app) took the audio hardware: stop cleanly.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    /// Whether replies use the natural voice right now.
    var usesNaturalVoice: Bool { KokoroModel.shared.isReady }

    private var voiceID: String {
        let saved = UserDefaults.standard.string(forKey: SettingsKey.askVoice) ?? KokoroVoices.defaultID
        return KokoroVoices.voice(saved) == nil ? KokoroVoices.defaultID : saved
    }

    /// Loads the model ahead of a reply, so speech starts sooner.
    func prewarm() {
        if usesNaturalVoice { KokoroSynth.shared.prewarm() }
    }

    /// Speaks `text`. `onFinished` runs when it has all played, and not if it's stopped.
    func speak(_ text: String, onFinished: (() -> Void)? = nil) {
        stop()
        let prepared = KokoroText.prepare(text)
        guard !prepared.isEmpty else {
            onFinished?()
            return
        }
        let current = generation
        self.onFinished = onFinished
        state = .preparing
        Task {
            if conversation == nil {
                do {
                    try await AudioSessionControl.activateForPlayback()
                } catch {
                    log.error("Couldn't start audio: \(error.localizedDescription, privacy: .public)")
                }
            }
            guard current == generation else { return }
            if usesNaturalVoice {
                producer = Task { await speakNaturally(Self.groups(prepared), generation: current) }
            } else if conversation != nil {
                speakSystemVoiceInConversation(prepared, generation: current)
            } else {
                speakWithSystemVoice(prepared)
            }
        }
    }

    func stop() {
        generation += 1
        onFinished = nil
        producer?.cancel()
        producer = nil
        producing = false
        pendingBuffers = 0
        player.stop()
        conversation?.player.stop()
        if engine.isRunning { engine.stop() }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        if state != .idle {
            state = .idle
            if conversation == nil { AudioSessionControl.deactivate() }
        }
    }

    /// The reply is done: give the audio back so other apps' music comes back up (the
    /// conversation keeps its own audio until it ends).
    private func finished() {
        if engine.isRunning { engine.stop() }
        state = .idle
        if conversation == nil { AudioSessionControl.deactivate() }
        let done = onFinished
        onFinished = nil
        done?()
    }

    // MARK: Natural voice

    /// Generates sentence groups one after another and queues each as it's ready.
    private func speakNaturally(_ groups: [String], generation current: Int) async {
        guard conversation != nil || startEngine() else {
            speakWithSystemVoice(groups.joined(separator: " "))
            return
        }
        let output = self.output
        producing = true
        output.play()
        for (index, piece) in groups.enumerated() {
            guard !Task.isCancelled, current == generation else { return }
            let samples: [Float]
            do {
                samples = try await KokoroSynth.shared.synthesize(piece, voice: voiceID, gpu: UIApplication.shared.applicationState == .active)
            } catch {
                guard current == generation else { return }
                log.error("Natural voice failed, using the system voice: \(error.localizedDescription, privacy: .public)")
                // Say the rest with the system voice rather than going quiet. Moving the
                // generation on first keeps the stopped buffers' callbacks from ending it.
                generation += 1
                producing = false
                pendingBuffers = 0
                output.stop()
                let rest = groups[index...].joined(separator: " ")
                if conversation != nil {
                    speakSystemVoiceInConversation(rest, generation: generation)
                } else {
                    speakWithSystemVoice(rest)
                }
                return
            }
            guard !Task.isCancelled, current == generation, let buffer = makeBuffer(samples) else { continue }
            pendingBuffers += 1
            state = .speaking
            output.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                let speaker = self
                Task { @MainActor in speaker?.bufferFinished(generation: current) }
            }
        }
        guard current == generation else { return }
        producing = false
        if pendingBuffers == 0 { finished() }
    }

    private func bufferFinished(generation current: Int) {
        guard current == generation else { return }
        pendingBuffers = max(pendingBuffers - 1, 0)
        if pendingBuffers == 0, !producing { finished() }
    }

    /// The first sentence alone so speech starts fast, then up to ~240 characters at a time.
    static func groups(_ text: String) -> [String] {
        let sentences = KokoroText.sentences(text).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = sentences.first else { return [] }
        var groups = [first]
        var current = ""
        for sentence in sentences.dropFirst() {
            if current.count + sentence.count > 240, !current.isEmpty {
                groups.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : " ") + sentence
        }
        if !current.isEmpty { groups.append(current) }
        return groups.flatMap { KokoroText.chunks($0) }
    }

    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        // A short breath after each group.
        let silence = Int(0.12 * KokoroSynth.sampleRate)
        let frames = samples.count + silence
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        (channel + samples.count).update(repeating: 0, count: silence)
        return buffer
    }

    /// Starts the engine; false when it can't (playing a node then would crash the app).
    private func startEngine() -> Bool {
        guard !engine.isRunning else { return true }
        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            log.error("Couldn't start the audio engine: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: System voice

    private func speakWithSystemVoice(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestSystemVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        state = .speaking
        synthesizer.speak(utterance)
    }

    /// The system voice, played through the conversation engine: the synthesizer writes audio
    /// buffers instead of playing them, and each is converted and queued like Kokoro's.
    private func speakSystemVoiceInConversation(_ text: String, generation current: Int) {
        guard let conversation else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestSystemVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        producing = true
        state = .speaking
        conversation.player.play()
        let target = format
        synthesizer.write(utterance) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            let isLast = pcm.frameLength == 0
            let speaker = self
            Task { @MainActor in
                guard let self = speaker, current == self.generation else { return }
                if isLast {
                    self.producing = false
                    if self.pendingBuffers == 0 { self.finished() }
                    return
                }
                guard let converted = self.convert(pcm, to: target) else { return }
                self.pendingBuffers += 1
                conversation.player.scheduleBuffer(converted, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    let speaker = self
                    Task { @MainActor in speaker?.bufferFinished(generation: current) }
                }
            }
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }

    fileprivate func systemVoiceFinished() {
        guard !producing, state == .speaking, !synthesizer.isSpeaking else { return }
        finished()
    }

    /// The highest-quality English voice on the phone: Premium, then Enhanced, then the default.
    static var bestSystemVoice: AVSpeechSynthesisVoice? {
        let language = Locale.current.language.languageCode?.identifier == "en" ? Locale.current.identifier.replacingOccurrences(of: "_", with: "-") : "en-US"
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        let ranked = english.sorted { lhs, rhs in
            if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
            return (lhs.language == language ? 1 : 0) > (rhs.language == language ? 1 : 0)
        }
        return ranked.first ?? AVSpeechSynthesisVoice(language: language)
    }
}

extension AskSpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.systemVoiceFinished() }
    }
}
