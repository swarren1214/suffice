import AVFoundation

/// Every change to the shared audio session goes through one serial queue, off the main thread
/// (activating blocks), so a late "deactivate" can never land after the next "activate".
nonisolated enum AudioSessionControl {
    private static let queue = DispatchQueue(label: "com.stephenwarren.suffice.audiosession")

    /// For listening: the microphone.
    static func activateForRecording() async throws {
        try await run {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        }
    }

    /// For Ask's spoken replies.
    static func activateForPlayback() async throws {
        try await run {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
            try session.setActive(true)
        }
    }

    /// For talking with Ask: the microphone and the spoken replies at once, through Apple's voice
    /// processing (echo cancellation and noise suppression). Speaker by default, so the
    /// conversation isn't stuck in the earpiece; AirPods and other headsets work too.
    static func activateForConversation() async throws {
        try await run {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        }
    }

    /// Hands audio back to other apps (and un-ducks their music).
    static func deactivate() {
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private static func run(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
