import FoundationModels
import SwiftUI
import UIKit

nonisolated extension SettingsKey {
    /// Whether Ask answers out loud when you talk to it.
    static let spokenReplies = "ask.spokenReplies"
}

/// "iPhone" or "iPad", for "On this iPhone".
enum DeviceName {
    static var current: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }
}

extension View {
    /// Keeps content to a comfortable reading width on iPad, centered; no change on iPhone.
    func readableWidth(_ maxWidth: CGFloat = 720) -> some View {
        frame(maxWidth: maxWidth).frame(maxWidth: .infinity)
    }
}

/// What the voice screen says when it can't listen.
enum VoiceMessages {
    static let denied = "Suffice needs microphone and speech recognition access to listen. Turn them on in Settings › Suffice."
    static let unavailable = "Speech recognition isn't available right now. Check that Siri & Dictation languages are downloaded, then try again."
}

nonisolated enum AskText {
    /// Lowercased words without punctuation or accents, for comparing what was heard.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}

/// Whether Apple's on-device model can run here, and what to tell the person when it can't.
enum OnDeviceModel {
    enum Availability: Equatable {
        case available
        /// Supported device, but its built-in AI is turned off.
        case notEnabled
        /// Turned on, but the model is still downloading.
        case notReady
        /// This device can't run the on-device model.
        case unsupported

        var message: String {
            switch self {
            case .available: ""
            case .notEnabled: "Ask runs on your \(DeviceName.current)’s built-in AI, which is turned off. You can turn it on in the Settings app."
            case .notReady: "Your \(DeviceName.current)’s built-in AI is still getting ready. Try again in a little while."
            case .unsupported: "Ask needs a newer \(DeviceName.current) with built-in AI. Everything else in Suffice works without it."
            }
        }

        var statusText: String {
            switch self {
            case .available: "Ready"
            case .notEnabled: "Turned off"
            case .notReady: "Getting ready"
            case .unsupported: "Not supported"
            }
        }
    }

    static var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available: .available
        case .unavailable(.appleIntelligenceNotEnabled): .notEnabled
        case .unavailable(.modelNotReady): .notReady
        case .unavailable: .unsupported
        }
    }
}
