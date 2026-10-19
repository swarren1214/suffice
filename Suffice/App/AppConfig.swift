import Foundation

/// App-wide settings: iCloud and links shown in Settings.
enum AppConfig {
    /// Household sync: the budget goes to the person's iCloud with CKSyncEngine and can be
    /// shared with another Apple Account (Profile › Household). Needs the iCloud (CloudKit),
    /// Push Notifications and Background Modes › Remote notifications capabilities, and
    /// CKSharingSupported in Info.plist. When false, everything stays on this device.
    static let cloudSyncEnabled = true
    static let cloudKitContainerID = "iCloud.com.stephenwarren.suffice"

    nonisolated static let apiBaseURL = URL(string: "https://api.hearthapps.com")!
    nonisolated static let supabaseURL = URL(string: "https://kvhvsztvfpydhfpzicyy.supabase.co")!
    nonisolated static let supabasePublishableKey = "sb_publishable_j0eyoaQiN3fogFINKooaDA_V0yjXkgY"
    /// Logo.dev publishable key (pk_…, meant to ship in apps) for merchant logos Plaid doesn't
    /// have. Empty shows initials instead.
    nonisolated static let logoDevPublishableKey = "pk_WdicpzisRSC2-QwpXtq6FA"

    /// Receipts from Email: the OAuth client IDs Suffice signs in to mailboxes with (read-only).
    /// Empty leaves that mailbox's Connect off. See README › Receipts from email for setting
    /// them up.
    /// - Google: an iOS OAuth client in Google Cloud ("….apps.googleusercontent.com") with the
    ///   Gmail API on and the gmail.readonly scope on the consent screen.
    /// - Microsoft: an app registration in Microsoft Entra with the iOS redirect URI
    ///   msauth.com.stephenwarren.suffice://auth and Mail.Read + User.Read (delegated).
    nonisolated static let googleClientID = ""
    nonisolated static let microsoftClientID = ""

    static let appName = "Suffice"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }
}
