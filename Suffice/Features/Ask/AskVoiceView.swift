import AVFoundation
import SwiftData
import SwiftUI

/// Talking with Suffice, hands free, from the Ask · Voice design. The microphone stays on: pause
/// for a moment and Suffice answers out loud (all on the device), then listens again. Start
/// talking while it thinks or speaks and it stops to listen. Every exchange is also added to
/// the Ask conversation.
struct AskVoiceView: View {
    /// Called when the person taps Type: the conversation's text field takes over.
    var onType: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.spokenReplies) private var spokenReplies = true
    @State private var engine = AskEngine.shared
    @State private var conversation = AskConversation()
    @State private var speaker = AskSpeaker.shared
    @State private var model = KokoroModel.shared
    @State private var micMode = ConversationAudio.microphoneModeName
    @State private var openedBudget: BudgetCategory?

    private var reply: AskMessage? {
        guard let id = conversation.replyID else { return nil }
        return engine.messages.first { $0.id == id }
    }

    /// Before anything's been asked here: the last answer from the typed conversation, as in the
    /// design ("Last time you asked about Dining Out…").
    private var earlierReply: AskMessage? {
        engine.messages.last { $0.role == .assistant }
    }

    var body: some View {
        ZStack {
            ListeningGlow(active: conversation.isListening, level: conversation.level)

            VStack(alignment: .leading, spacing: 0) {
                topBar
                Spacer(minLength: 24)
                LiveTranscript(
                    heading: heading,
                    text: conversation.isListening ? conversation.transcript : conversation.question,
                    placeholder: conversation.question.isEmpty
                        ? "Ask about your money, like “how much is left for groceries?”"
                        : "Go ahead, I’m listening.",
                    isListening: conversation.isListening,
                    quoted: true
                )
                Spacer(minLength: 24)
                VoicePanel { panel }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .readableWidth(640)
        }
        .voiceScreenBackground()
        .task {
            speaker.prewarm()
            await conversation.start(with: engine)
            micMode = ConversationAudio.microphoneModeName
        }
        .onDisappear { conversation.stop() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Back from Control Center, where the mic mode is picked.
            micMode = ConversationAudio.microphoneModeName
        }
        .sheet(item: $openedBudget) { category in
            BudgetSheet(category: category, month: MonthSpan(containing: .now))
        }
    }

    private var heading: String {
        switch conversation.phase {
        case .listening, .starting: "Listening"
        case .thinking, .speaking: "You asked"
        case .paused: "Paused"
        case .failed: "Suffice"
        }
    }

    /// Close, the privacy pill, and the microphone mode (Voice Isolation keeps background
    /// voices and noise out).
    private var topBar: some View {
        ZStack(alignment: .trailing) {
            VoiceTopBar { close() }
            Button {
                ConversationAudio.showMicrophoneModes()
            } label: {
                Image(systemName: micMode == "Voice Isolation" ? "person.wave.2.fill" : "waveform.and.mic")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Microphone mode: \(micMode)")
            .accessibilityHint("Choose Voice Isolation to keep background voices out.")
        }
    }

    @ViewBuilder
    private var panel: some View {
        status
        if let reply, conversation.phase != .thinking {
            answer(reply, earlier: false)
        } else if reply == nil, conversation.phase == .listening || conversation.phase == .starting, let earlierReply {
            answer(earlierReply, earlier: true)
        }
        if spokenReplies {
            naturalVoiceOffer
        }
        buttons
    }

    /// What's happening now, with the one control that fits it.
    @ViewBuilder
    private var status: some View {
        switch conversation.phase {
        case .starting:
            HStack(spacing: 12) {
                ProgressView()
                Text("Starting…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
        case .listening:
            VStack(spacing: 12) {
                Waveform(level: conversation.level)
                    .frame(height: 48)
                HStack {
                    Text(conversation.transcript.isEmpty
                         ? "Listening… Suffice answers when you pause."
                         : "Pause when you’re done, or tap Send.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !conversation.transcript.isEmpty {
                        Button("Send", systemImage: "arrow.up") { conversation.finishSpeaking() }
                            .labelStyle(.iconOnly)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Brand.green, in: .circle)
                            .buttonStyle(.plain)
                    }
                }
            }
        case .thinking:
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Checking your budgets…")
                    Text("Keep talking to change your question.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        case .speaking:
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.2.fill")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .foregroundStyle(Brand.green)
                    .font(.title3)
                Text("Start talking to interrupt.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop", systemImage: "stop.fill") { conversation.interrupt() }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 36, height: 36)
                    .background(.fill.secondary, in: .circle)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop Suffice and listen")
            }
        case .paused:
            HStack(spacing: 12) {
                Image(systemName: "mic.slash")
                    .foregroundStyle(.secondary)
                Text("The microphone is off.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await conversation.resume() }
                } label: {
                    Label("Resume", systemImage: "mic.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .background(Brand.green.opacity(0.15), in: .capsule)
            }
        case .failed(let message):
            Text(message).font(.subheadline)
        }
    }

    @ViewBuilder
    private func answer(_ reply: AskMessage, earlier: Bool) -> some View {
        Label("Suffice", systemImage: "sparkles")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
        Text(AskFormatting.attributed(earlier ? "Last time: " + reply.text : reply.text))
            .font(.body)
            .foregroundStyle(earlier ? .secondary : .primary)
            .fixedSize(horizontal: false, vertical: true)
        if reply.role == .assistant, !earlier {
            AskCards(message: reply, data: engine.data) { category in
                openedBudget = category
            } onTransfer: { move in
                engine.resolveTransfer(reply, move: move)
            }
        }
    }

    /// Until the natural voice is on the device, a one-line offer to get it.
    @ViewBuilder
    private var naturalVoiceOffer: some View {
        switch model.state {
        case .notDownloaded, .failed:
            Button {
                model.download()
            } label: {
                Label("Get Suffice’s natural voice (\(KokoroModel.approximateSize), runs on this \(DeviceName.current))", systemImage: "arrow.down.circle")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction).tint(Brand.green)
                Text("\(Int(fraction * 100))%").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
        case .ready, .unavailable:
            EmptyView()
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button {
                conversation.stop()
                dismiss()
                onType()
            } label: {
                Text("Type").frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.plain)
            .font(.headline)
            .background(.fill.secondary, in: .capsule)

            if case .failed = conversation.phase {
                Button {
                    Task { await conversation.resume() }
                } label: {
                    Label("Try Again", systemImage: "mic.fill").frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.plain)
                .font(.headline)
                .foregroundStyle(.white)
                .background(Brand.green, in: .capsule)
            } else {
                Button { close() } label: {
                    Text("Done").frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.plain)
                .font(.headline)
                .foregroundStyle(.white)
                .background(Brand.green, in: .capsule)
            }
        }
    }

    private func close() {
        conversation.stop()
        dismiss()
    }
}
