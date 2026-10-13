import Foundation

/// App-wide settings: iCloud and links shown in Settings.
enum AppConfig {
    /// The budget syncs through the person's private CloudKit database. Needs the iCloud
    /// (CloudKit), Push Notifications and Background Modes › Remote notifications capabilities.
    /// When false, everything stays on this device.
    ///
    /// Note for the household: the private database belongs to one Apple Account. Sharing one
    /// budget between two people's iPhones needs CloudKit sharing (see README › Sharing with
    /// your spouse), which is the next milestone.
    static let cloudSyncEnabled = false
    static let cloudKitContainerID = "iCloud.com.stephenwarren.suffice"

    static let appName = "Suffice"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }
}
