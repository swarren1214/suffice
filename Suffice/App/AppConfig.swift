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

    nonisolated static let apiBaseURL = URL(string: "https://lifestyle-api-liart.vercel.app")!
    nonisolated static let supabaseURL = URL(string: "https://clvyeeboffmgofxrvtsv.supabase.co")!
    nonisolated static let supabasePublishableKey = "sb_publishable_3Q2nwZBnvkJQR0st35k0ng_mObjJgJD"
    /// Logo.dev publishable key (pk_…, meant to ship in apps) for merchant logos Plaid doesn't
    /// have. Empty shows initials instead.
    nonisolated static let logoDevPublishableKey = ""

    static let appName = "Suffice"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }
}
