import AVFoundation
import Observation
import os
import Speech

/// The audio for talking with Suffice: one engine for the microphone and Suffice's voice, with
/// Apple's voice processing turned on. Because Suffice's voice plays through the same engine,
/// voice processing removes it from what the microphone hears, so you can talk over Suffice and
/// be heard. It also suppresses background noise and works with the system Voice Isolation
/// microphone mode (Control Center › Mic Mode).
final class ConversationAudio {
    static let shared = ConversationAudio()

    let player = AVAudioPlayerNode()
    /// Kokoro's output format; system-voice audio is converted to it.
    let format = AVAudioFormat(standardFormatWithSampleRate: KokoroSynth.sampleRate, channels: 1)!
    private(set) var isRunning = false
    /// Whether echo cancellation is on (it isn't in the Simulator).
    private(set) var hasVoiceProcessing = false

    private let engine = AVAudioEngine()
    private var attached = false
    private var isStarting = false
    /// Microphone audio goes here, on the audio thread.
    private let sink = OSAllocatedUnfairLock<(@Sendable (AVAudioPCMBuffer) -> Void)?>(initialState: nil)
    /// When the microphone last delivered real sound (not digital silence), from the audio thread.
    private let lastSignal = OSAllocatedUnfairLock(initialState: Date.distantPast)
    private var configurationObserver: NSObjectProtocol?
    private var watchdog: Task<Void, Never>?
    private let log = Logger(subsystem: "com.stephenwarren.suffice", category: "conversation")

    private init() {
        // Switching the audio session to two-way voice (and turning on echo cancellation)
        // reconfigures the hardware a moment after the engine starts, which stops the engine.
        // The first conversation after launch always hits this; restart instead of going deaf.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart(reason: "the audio configuration changed", full: false, attempt: 1) }
        }
    }

    /// Opens the microphone and Suffice's voice. `input` receives microphone audio on a
    /// background thread.
    func start(input: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        sink.withLock { $0 = input }
        guard !isRunning, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        try await AudioSessionControl.activateForConversation()
        do {
            try startEngine()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            AudioSessionControl.deactivate()
            throw error
        }
        isRunning = true
        watchMicrophone()
    }

    /// Echo cancellation on, the player attached, the microphone tapped, and the engine started.
    private func startEngine() throws {
        let microphone = engine.inputNode
        #if !targetEnvironment(simulator)
        do {
            try microphone.setVoiceProcessingEnabled(true)
            // Suffice shouldn't hush other audio more than it has to.
            microphone.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: true, duckingLevel: .min)
            hasVoiceProcessing = true
        } catch {
            log.error("Voice processing unavailable: \(error.localizedDescription, privacy: .public)")
        }
        #endif
        if !attached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            attached = true
        }
        tapMicrophone()
        engine.prepare()
        try engine.start()
    }

    /// (Re)installs the tap with the microphone's current format, which can change when the
    /// hardware is reconfigured.
    private func tapMicrophone() {
        let microphone = engine.inputNode
        microphone.removeTap(onBus: 0)
        let sink = self.sink
        let lastSignal = self.lastSignal
        Self.installTap(on: microphone) { buffer in
            if Self.hasSound(buffer) { lastSignal.withLock { $0 = .now } }
            sink.withLock { $0 }?(buffer)
        }
    }

    /// Restarts after the engine stopped on its own, or went silent. `full` also resets echo
    /// cancellation, which on some first starts delivers nothing but zeros.
    private func restart(reason: String, full: Bool, attempt: Int) {
        guard isRunning, !isStarting else { return }
        log.notice("Restarting the microphone: \(reason, privacy: .public)")
        if full || !engine.isRunning {
            engine.stop()
        }
        if full, hasVoiceProcessing {
            engine.inputNode.removeTap(onBus: 0)
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            hasVoiceProcessing = false
        }
        do {
            if full {
                try startEngine()
            } else {
                tapMicrophone()
                engine.prepare()
                try engine.start()
            }
        } catch {
            log.error("Couldn't restart the microphone: \(error.localizedDescription, privacy: .public)")
        }
        watchMicrophone(attempt: attempt)
    }

    /// If no real sound comes in soon after starting, starts over: first just the engine, then
    /// with a full reset. After that it stops trying (the microphone may be in use elsewhere).
    private func watchMicrophone(attempt: Int = 1) {
        watchdog?.cancel()
        guard attempt <= 2 else { return }
        let started = Date.now
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self, self.isRunning else { return }
            if self.lastSignal.withLock({ $0 }) > started { return }
            self.log.notice("No microphone audio after starting (attempt \(attempt))")
            self.restart(reason: "no sound from the microphone", full: attempt == 2, attempt: attempt + 1)
        }
    }

    /// Real microphones always pick up a little noise; exact zeros mean no audio is flowing.
    private nonisolated static func hasSound(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let samples = buffer.floatChannelData?[0] else { return true }
        let count = Int(buffer.frameLength)
        var index = 0
        while index < count {
            if samples[index] != 0 { return true }
            index += 8
        }
        return false
    }

    func stop() {
        sink.withLock { $0 = nil }
        watchdog?.cancel()
        watchdog = nil
        guard isRunning else { return }
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if hasVoiceProcessing {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            hasVoiceProcessing = false
        }
        isRunning = false
        AudioSessionControl.deactivate()
    }

    /// The tap runs on the audio thread, so it's built outside the main actor.
    private nonisolated static func installTap(on input: AVAudioInputNode, handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in handler(buffer) }
    }

    /// Shows the system Mic Mode menu (Standard, Voice Isolation, Wide Spectrum).
    static func showMicrophoneModes() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }

    /// The microphone mode the person picked in Control Center.
    static var microphoneModeName: String {
        switch AVCaptureDevice.activeMicrophoneMode {
        case .voiceIsolation: "Voice Isolation"
        case .wideSpectrum: "Wide Spectrum"
        default: "Standard"
        }
    }
}

/// A spoken conversation with Suffice, hands free.
///
/// The microphone stays open the whole time. When you stop talking for a moment (the pause is
/// set in Profile › Ask Suffice), what you said goes to Suffice, which answers out loud; then it
/// listens again. Start talking while Suffice is thinking or speaking and it stops to listen.
/// Speech is recognized on the iPhone.
@Observable
final class AskConversation {
    enum Phase: Equatable {
        case starting
        case listening
        case thinking
        case speaking
        /// Nothing said for a while: the microphone is off until Resume.
        case paused
        case failed(String)
    }

    private(set) var phase: Phase = .starting
    /// What you're saying now.
    private(set) var transcript = ""
    /// Your last finished question.
    private(set) var question = ""
    /// Suffice's latest reply (or the notice it gave instead).
    private(set) var replyID: UUID?
    /// Microphone loudness, 0...1, for the waveform and glow.
    private(set) var level: Double = 0

    @ObservationIgnored private var engine: AskEngine?
    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    /// The request the microphone feeds, read on the audio thread.
    @ObservationIgnored private let request = OSAllocatedUnfairLock<SFSpeechAudioBufferRecognitionRequest?>(uncheckedState: nil)
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    /// Bumped for every new recognition request, so results from an old one are ignored.
    @ObservationIgnored private var turn = 0
    /// Bumped for every question (and on barge-in), so a stale answer isn't spoken.
    @ObservationIgnored private var exchange = 0
    @ObservationIgnored private var sending: Task<Void, Never>?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var lastHeard = Date.now
    @ObservationIgnored private var turnStarted = Date.now
    @ObservationIgnored private var spokenReply = ""
    @ObservationIgnored private let audio = ConversationAudio.shared
    @ObservationIgnored private let speaker = AskSpeaker.shared
    @ObservationIgnored private let log = Logger(subsystem: "com.stephenwarren.suffice", category: "conversation")

    /// How long a silence ends your turn.
    var pause: Double {
        (UserDefaults.standard.object(forKey: SettingsKey.askPause) as? Double) ?? AskPause.medium.seconds
    }
    private var speaksReplies: Bool {
        (UserDefaults.standard.object(forKey: SettingsKey.spokenReplies) as? Bool) ?? true
    }
    /// After this long with nothing said, the microphone turns off.
    private let idleLimit: TimeInterval = 45

    var isListening: Bool { phase == .listening }

    func start(with engine: AskEngine) async {
        self.engine = engine
        // Screenshot mode: the last exchange, being spoken, without the microphone or speech
        // recognition (so no permission prompts).
        if ScreenshotMode.isOn {
            question = engine.messages.last { $0.role == .user }?.text ?? ""
            replyID = engine.messages.last { $0.role == .assistant }?.id
            phase = .speaking
            return
        }
        phase = .starting
        speaker.stop()
        guard await Self.permissionsGranted() else {
            phase = .failed(VoiceMessages.denied)
            return
        }
        guard let recognizer, recognizer.isAvailable, Self.canRecognize(with: recognizer) else {
            phase = .failed(VoiceMessages.unavailable)
            return
        }
        let request = self.request
        do {
            try await audio.start { buffer in
                request.withLockUnchecked { $0 }?.append(buffer)
                ConversationLevel.report(buffer)
            }
        } catch {
            log.error("Couldn't start the conversation: \(error.localizedDescription, privacy: .public)")
            phase = .failed(VoiceMessages.unavailable)
            return
        }
        ConversationLevel.onLevel = { [weak self] level in self?.level = level }
        transcript = ""
        lastHeard = .now
        phase = .listening
        beginTurn()
        watch()
    }

    /// Ends the conversation: microphone off, Suffice quiet.
    func stop() {
        exchange += 1
        turn += 1
        watcher?.cancel()
        watcher = nil
        endRecognition()
        speaker.stop()
        audio.stop()
        ConversationLevel.onLevel = nil
        level = 0
        if phase != .paused, !isFailed { phase = .paused }
    }

    func resume() async {
        guard let engine else { return }
        await start(with: engine)
    }

    /// Ends your turn now instead of waiting for the pause.
    func finishSpeaking() {
        guard phase == .listening, !transcript.isEmpty else { return }
        endTurn()
    }

    /// Stops Suffice mid-sentence and listens.
    func interrupt() {
        guard phase == .speaking || phase == .thinking else { return }
        bargeIn()
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    // MARK: Recognition

    /// A fresh recognition request. One is always running while the conversation is on, so
    /// you can be heard while Suffice thinks or talks.
    private func beginTurn() {
        endRecognition()
        guard let recognizer else { return }
        turn += 1
        let current = turn
        turnStarted = .now
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        request.taskHint = .dictation
        self.request.withLockUnchecked { $0 = request }
        task = Self.recognize(with: recognizer, request: request) { [weak self] text, isFinal, failed in
            let conversation = self
            Task { @MainActor in conversation?.heard(text, isFinal: isFinal || failed, turn: current) }
        }
    }

    private func endRecognition() {
        request.withLockUnchecked { request in
            request?.endAudio()
            request = nil
        }
        task?.cancel()
        task = nil
    }

    private func heard(_ text: String?, isFinal: Bool, turn current: Int) {
        guard current == turn else { return }
        let text = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, text != transcript {
            switch phase {
            case .speaking, .thinking:
                // Suffice's own voice can leak through; only real words from you interrupt.
                if Self.wordCount(text) >= 2, !isEcho(text) {
                    bargeIn()
                    transcript = text
                    lastHeard = .now
                }
            case .listening:
                transcript = text
                lastHeard = .now
            default:
                break
            }
        }
        if isFinal {
            // The recognizer ended the request on its own (a long silence, or its time limit).
            if phase == .listening, !transcript.isEmpty {
                endTurn()
            } else if phase == .listening || phase == .thinking || phase == .speaking {
                beginTurn()
            }
        }
    }

    /// Checks for the end of your turn, and keeps recognition requests short.
    private func watch() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard phase == .listening else { return }
        let quiet = Date.now.timeIntervalSince(lastHeard)
        // Still making sound mid-word: not a pause yet.
        if level > 0.35 { lastHeard = .now; return }
        if !transcript.isEmpty, quiet >= pause {
            endTurn()
        } else if transcript.isEmpty {
            if quiet >= idleLimit {
                stop()
            } else if Date.now.timeIntervalSince(turnStarted) > 50 {
                // Recognition requests are limited to about a minute.
                beginTurn()
            }
        }
    }

    // MARK: Turns

    private func endTurn() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let engine else { return }
        question = text
        transcript = ""
        exchange += 1
        let current = exchange
        phase = .thinking
        // Keep listening while Suffice thinks, so you can add to or change your question.
        beginTurn()
        let previous = sending
        sending = Task { [weak self] in
            // Suffice answers one question at a time.
            await previous?.value
            guard let self, current == self.exchange else { return }
            let before = engine.messages.count
            await engine.send(text)
            guard current == self.exchange else { return }
            self.answered(engine.messages.dropFirst(before).last(where: { $0.role != .user }), exchange: current)
        }
    }

    private func answered(_ reply: AskMessage?, exchange current: Int) {
        guard let reply else {
            phase = .listening
            lastHeard = .now
            return
        }
        replyID = reply.id
        guard speaksReplies, reply.role == .assistant else {
            phase = .listening
            lastHeard = .now
            return
        }
        spokenReply = reply.text
        phase = .speaking
        speaker.speak(reply.text) { [weak self] in
            guard let self, current == self.exchange, self.phase == .speaking else { return }
            self.phase = .listening
            self.lastHeard = .now
        }
    }

    /// You started talking while Suffice was thinking or speaking.
    private func bargeIn() {
        exchange += 1
        speaker.stop()
        phase = .listening
        lastHeard = .now
    }

    /// Words heard while Suffice talks that are all in what Suffice is saying: its own voice
    /// leaking past echo cancellation, not you.
    private func isEcho(_ text: String) -> Bool {
        guard phase == .speaking, !spokenReply.isEmpty else { return false }
        let said = Set(AskText.words(spokenReply))
        return AskText.words(text).allSatisfy { said.contains($0) }
    }

    private static func wordCount(_ text: String) -> Int {
        AskText.words(text).count
    }

    // MARK: Permissions and recognition helpers

    private nonisolated static func recognize(with recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest, update: @escaping @Sendable (String?, Bool, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            update(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }

    /// On a real iPhone, only on-device recognition is allowed. The Simulator has none.
    private static func canRecognize(with recognizer: SFSpeechRecognizer) -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return recognizer.supportsOnDeviceRecognition
        #endif
    }

    private nonisolated static func permissionsGranted() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// Turns microphone buffers into a 0...1 level on the main actor, about 20 times a second.
nonisolated enum ConversationLevel {
    @MainActor static var onLevel: ((Double) -> Void)?
    private static let last = OSAllocatedUnfairLock(initialState: Date.distantPast)

    nonisolated static func report(_ buffer: AVAudioPCMBuffer) {
        let now = Date.now
        let due = last.withLock { last -> Bool in
            guard now.timeIntervalSince(last) > 0.05 else { return false }
            last = now
            return true
        }
        guard due, let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let level = min(Double(sqrt(sum / Float(count))) * 12, 1)
        Task { @MainActor in onLevel?(level) }
    }
}

/// How long Suffice waits after you stop talking before it answers.
nonisolated enum AskPause: Double, CaseIterable, Identifiable {
    case short = 0.8
    case medium = 1.3
    case long = 2.0

    var id: Double { rawValue }
    var seconds: Double { rawValue }
    var name: String {
        switch self {
        case .short: "Short"
        case .medium: "Medium"
        case .long: "Long"
        }
    }
}

nonisolated extension SettingsKey {
    /// Seconds of silence that end your turn when talking with Suffice.
    static let askPause = "ask.pause"
}
