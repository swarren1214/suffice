import Foundation
import Observation
import WatchConnectivity
import WidgetKit

/// The latest numbers from the iPhone. The iPhone sends a new snapshot whenever the budget
/// changes (WatchSync on the phone); it's saved in the watch's app group, where the
/// complications read it, and the complications are asked to redraw. In screenshot mode it holds
/// the demo snapshot instead and never talks to the iPhone or the app group (see ScreenshotMode).
@Observable
final class WatchStore: NSObject {
    static let shared = WatchStore()

    private(set) var snapshot: WidgetSnapshot?

    override init() {
        super.init()
        if ScreenshotMode.isOn {
            snapshot = ScreenshotMode.demoSnapshot()
            return
        }
        snapshot = WidgetStore.load()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }

    fileprivate func receive(_ data: Data) {
        guard let new = WidgetStore.decode(data) else { return }
        // An older snapshot arriving late (the app context after a complication update) is ignored.
        if let current = snapshot, current.updated > new.updated { return }
        snapshot = new
        if WidgetStore.save(new) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

extension WatchStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        // What the iPhone sent while the watch app wasn't running.
        guard let data = session.receivedApplicationContext["snapshot"] as? Data else { return }
        Task { @MainActor in WatchStore.shared.receive(data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["snapshot"] as? Data else { return }
        Task { @MainActor in WatchStore.shared.receive(data) }
    }

    /// Complication updates (transferCurrentComplicationUserInfo on the phone).
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo["snapshot"] as? Data else { return }
        Task { @MainActor in WatchStore.shared.receive(data) }
    }
}
