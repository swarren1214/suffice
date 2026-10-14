import Foundation

/// App-wide settings: iCloud and links shown in Settings.
enum AppConfig {
    /// Household sync: the budget goes to the person's iCloud with CKSyncEngine and can be
    /// shared with another Apple Account (Profile › Household). Needs the iCloud (CloudKit),
    /// Push Notifications and Background Modes › Remote notifications capabilities, and
    /// CKSharingSupported in Info.plist. When false, everything stays on this device.
    static let cloudSyncEnabled = true
    static let cloudKitContainerID = "iCloud.com.stephenwarren.suffice"

    nonisolated static let apiBaseURL = URL(string: "https://lifestyle-api-liart.vercel.app")!
    nonisolated static let supabaseURL = URL(string: "https://clvyeeboffmgofxrvtsv.supabase.co")!
    nonisolated static let supabasePublishableKey = "sb_publishable_3Q2nwZBnvkJQR0st35k0ng_mObjJgJD"
    /// Logo.dev publishable key (pk_…, meant to ship in apps) for merchant logos Plaid doesn't
    /// have. Empty shows initials instead.
    nonisolated static let logoDevPublishableKey = "pk_WdicpzisRSC2-QwpXtq6FA"

    static let appName = "Suffice"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }
}
