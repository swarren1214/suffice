import Foundation

/// A person's own choices, which follow them to their other devices (same iCloud account): the
/// colors picked for account cards, Net Worth's range and the tax year last looked at. Planning's
/// choices follow them the same way (`PlanningSettings`), and so do having finished onboarding
/// and seen the tour (HearthKit's `HearthOnboarding` and `HearthTour`).
///
/// Views keep reading and writing them in UserDefaults (`@AppStorage`). This mirrors those keys
/// to iCloud key-value storage (NSUbiquitousKeyValueStore), as Hearken and Sated do: a change
/// here goes up, and a change from another device comes down into UserDefaults. What belongs to
/// one device stays out: reminders (notifications are allowed per device), the Face ID lock,
/// sign-in and caches.
@MainActor
final class PersonalSettings {
    static let shared = PersonalSettings()

    static let keys: [String] = [
        SettingsKey.cardStyles, SettingsKey.netWorthRange, SettingsKey.taxYear,
    ]

    private let defaults = UserDefaults.standard
    private let cloud = NSUbiquitousKeyValueStore.default
    private var observers: [any NSObjectProtocol] = []
    /// Each key's value as last copied up or down, so only real local changes go up.
    private var known: [String: Any] = [:]

    private init() {}

    /// Starts mirroring. Call once at launch.
    func start() {
        // Screenshot mode's demo settings never reach the person's iCloud.
        guard observers.isEmpty, !ScreenshotMode.isOn else { return }
        // iCloud's value was set on another device and wins; a setting only made here goes up.
        for key in Self.keys {
            if let value = cloud.object(forKey: key) {
                apply(value, to: key)
            } else if let value = defaults.object(forKey: key) {
                cloud.set(value, forKey: key)
                known[key] = value
            }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main) { notification in
            let changed = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            MainActor.assumeIsolated { PersonalSettings.shared.pullFromCloud(changed) }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PersonalSettings.shared.pushToCloud() }
        })
        cloud.synchronize()
    }

    /// Another device changed something (or iCloud finished its first download).
    private func pullFromCloud(_ changedKeys: [String]?) {
        for key in Self.keys where changedKeys?.contains(key) ?? true {
            guard let value = cloud.object(forKey: key) else { continue }
            apply(value, to: key)
        }
    }

    /// Something in UserDefaults changed: send up the listed settings that changed here.
    private func pushToCloud() {
        for key in Self.keys {
            let local = defaults.object(forKey: key)
            guard !Self.same(local, known[key]) else { continue }
            known[key] = local
            if let local {
                cloud.set(local, forKey: key)
            } else {
                cloud.removeObject(forKey: key)
            }
        }
    }

    private func apply(_ value: Any, to key: String) {
        known[key] = value
        guard !Self.same(defaults.object(forKey: key), value) else { return }
        defaults.set(value, forKey: key)
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): (a as? NSObject)?.isEqual(b) ?? false
        default: false
        }
    }
}
