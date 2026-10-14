import SwiftUI

/// Profile › Ask Suffice: the on-device model's status, how long a pause ends your turn, and
/// the spoken replies (Kokoro's natural voice, shared with Sated and Hearken).
struct AskSettingsView: View {
    @AppStorage(SettingsKey.spokenReplies) private var spokenReplies = true
    @AppStorage(SettingsKey.askVoice) private var voice = KokoroVoices.defaultID
    @AppStorage(SettingsKey.askPause) private var pause = AskPause.medium.seconds
    @State private var model = KokoroModel.shared
    @State private var speaker = AskSpeaker.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("On-Device Model", value: OnDeviceModel.availability.statusText)
                if OnDeviceModel.availability != .available {
                    Text(OnDeviceModel.availability.message).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Ask answers from your Suffice data with your \(DeviceName.current)’s built-in AI. Your questions and your data never leave it.")
            }

            Section {
                Picker("Answer After a Pause Of", selection: $pause) {
                    ForEach(AskPause.allCases) { option in
                        Text("\(option.name) (\(option.seconds.formatted()) s)").tag(option.seconds)
                    }
                }
                Toggle("Spoken Replies", isOn: $spokenReplies)
                if spokenReplies {
                    NaturalVoiceRow(model: model)
                    if model.isReady {
                        Picker("Voice", selection: $voice) {
                            ForEach(KokoroVoices.choices) { option in
                                Text("\(option.name) · \(option.detail)").tag(option.id)
                            }
                        }
                    }
                    Button(speaker.isActive ? "Stop" : "Play Sample", systemImage: speaker.isActive ? "stop.fill" : "play.fill") {
                        if speaker.isActive {
                            speaker.stop()
                        } else {
                            speaker.speak("Hi, I'm Suffice. You have $18.60 left for Dining Out, with 18 days to go.")
                        }
                    }
                }
            } header: {
                Text("Talking to Suffice")
            } footer: {
                Text("When you talk to Suffice, it answers once you pause for that long, and you can talk over it to interrupt. The natural voice is a one-time \(KokoroModel.approximateSize) download that Sated and Hearken share, so it's only downloaded once per \(DeviceName.current). Until then, Suffice speaks with the best Apple voice on your \(DeviceName.current).")
            }

            Section {
                Text("The natural voice is Kokoro (Apache 2.0), run with KokoroSwift (MIT) and MisakiSwift (Apache 2.0).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Ask Suffice")
        .onAppear { model.refresh() }
        .onDisappear { speaker.stop() }
    }
}

/// The natural voice: download it, watch it download, or remove it.
private struct NaturalVoiceRow: View {
    var model: KokoroModel

    var body: some View {
        switch model.state {
        case .unavailable:
            LabeledContent("Natural Voice", value: "Needs a real device")
        case .notDownloaded:
            Button {
                model.download()
            } label: {
                LabeledContent("Natural Voice") {
                    Text("Download \(KokoroModel.approximateSize)").foregroundStyle(Brand.green)
                }
            }
            .foregroundStyle(.primary)
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Natural Voice") {
                    Button("Cancel") { model.cancelDownload() }
                }
                ProgressView(value: fraction).tint(Brand.green)
            }
        case .ready:
            LabeledContent("Natural Voice", value: "On this \(DeviceName.current)")
                .swipeActions {
                    Button(role: .destructive) { model.remove() } label: {
                        Image(systemName: "trash").accessibilityLabel("Remove")
                    }
                    .tint(.red)
                }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Natural Voice") {
                    Button("Try Again") { model.download() }
                }
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    NavigationStack { AskSettingsView() }
}
