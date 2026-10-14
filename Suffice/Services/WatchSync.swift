import Foundation
import WatchConnectivity

/// Sends the widget snapshot to the Apple Watch, where the Suffice watch app and its
/// complications show it. The watch never opens the budget itself; it shows what the iPhone
/// last sent. Every new snapshot goes as the application context (the watch gets the latest
/// the next time it can), and, when a Suffice complication is on the watch face, as a
/// complication update, which wakes the watch app to redraw it (iOS allows about 50 a day,
/// so those are spaced out).
final class WatchSync: NSObject {
    static let shared = WatchSync()

    /// The last complication update sent, to space them out.
    private var lastComplicationSend = Date.distantPast
    private static let complicationSpacing: TimeInterval = 10 * 60

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Sends a new snapshot. `urgent` skips the spacing (an explicit refresh, a new month).
    func send(_ snapshot: WidgetSnapshot, urgent: Bool = false) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let data = WidgetStore.encode(snapshot) else { return }
        try? session.updateApplicationContext(["snapshot": data])
        let spaced = Date.now.timeIntervalSince(lastComplicationSend) >= Self.complicationSpacing
        if session.isComplicationEnabled, session.remainingComplicationUserInfoTransfers > 0, urgent || spaced {
            session.transferCurrentComplicationUserInfo(["snapshot": data])
            lastComplicationSend = .now
        }
    }

    /// The snapshot the widgets already have, for when the watch connects.
    fileprivate func resendStored() {
        if let snapshot = WidgetStore.load() { send(snapshot, urgent: true) }
    }
}

extension WatchSync: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        guard activationState == .activated else { return }
        Task { @MainActor in WatchSync.shared.resendStored() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Switched to another watch: start again with the new one.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    /// The watch app was installed, or a complication was added to the face.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in WatchSync.shared.resendStored() }
    }
}
