import SwiftUI
#if !os(watchOS)
import UIKit
#endif

/// Keys for settings stored with @AppStorage. Keep every key here so views stay in sync.
nonisolated enum SettingsKey {
    /// Welcome and Connect have been finished or skipped.
    static let onboarded = "onboarding.done"
    /// The starter categories have been added (first launch).
    static let seeded = "data.seeded"
    /// The household member this iPhone belongs to: the avatar in the toolbar, and who new
    /// transactions start out as.
    static let currentMember = "household.currentMember"
    /// Ask for Face ID when the app opens (Profile › Lock with Face ID).
    static let faceIDLock = "privacy.faceIDLock"
    /// The Sign in with Apple user, when they chose to sign in.
    static let appleUserID = "account.appleUserID"
    /// Reminders (Profile › Reminders): the morning before a bill is due, a budget passing 80%
    /// or going over, and a Sunday check-in.
    static let remindBills = "reminders.bills"
    static let remindBudgets = "reminders.budgets"
    static let remindWeekly = "reminders.weekly"
    /// Take-home pay per month, from onboarding's plan (dollars and cents, as cents).
    static let monthlyIncome = "plan.monthlyIncome"
    /// Onboarding ended with Show Me Around: the tour runs when the tabs first appear.
    static let wantsTour = "tour.pending"
    /// Card colors picked on Overview, by account ID (JSON). On this device only.
    static let cardStyles = "overview.cardStyles"
    /// Someone who joined a household was asked which person they are.
    static let askedWhoAmI = "household.askedWhoAmI"
    /// Net Worth's trend range (6M, 1Y, All).
    static let netWorthRange = "netWorth.range"
    /// Planning, kept in iCloud key-value storage (PlanningSettings) so it follows the Apple
    /// Account: the emergency fund's goal in months, whether loan payments count as essentials,
    /// and the bills whose stash suggestion someone dismissed (JSON array of IDs).
    static let runwayGoalMonths = "planning.runwayGoalMonths"
    static let loansAreEssential = "planning.loansAreEssential"
    static let dismissedStashSuggestions = "planning.dismissedStashSuggestions"
    /// Tax Year's last chosen year.
    static let taxYear = "tax.year"
}

/// Suffice's brand colors, from the MVP v2 designs. The darker greens carry white text; the
/// bright #06A830 is kept for switches and large areas, where it meets contrast.
nonisolated enum Brand {
    /// Buttons, selected tab, income pills, the confirm button on sheets.
    static let green = Color(hex: 0x047A24)
    /// Top of the header gradient.
    static let greenDeep = Color(hex: 0x037A23)
    /// Middle of the header gradient.
    static let greenMid = Color(hex: 0x0B9F3B)
    /// Switch tracks.
    static let greenBright = Color(hex: 0x06A830)
    /// The pale green behind the signed-in person's initial.
    static let greenPale = Color(hex: 0xDCEFE3)
    static let greenInk = Color(hex: 0x035F1C)
    /// Spending pills and "Spent" figures.
    static let expense = Color(hex: 0xD9343A)
    /// Red text and icons: deep red on light backgrounds, a lighter coral in dark mode, where
    /// the deep red is too dim to read.
    #if os(watchOS)
    // The watch is always dark.
    static let expenseInk = Color(hex: 0xFF6B6B)
    #else
    static let expenseInk = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 0x6B / 255, blue: 0x6B / 255, alpha: 1)
            : UIColor(red: 0xC2 / 255, green: 0x1F / 255, blue: 0x1F / 255, alpha: 1)
    })
    #endif
    /// The Total cash card.
    static let cashStart = Color(hex: 0x5A3FD9)
    static let cashEnd = Color(hex: 0x2563C9)
    /// Secondary text on white cards.
    static let secondaryText = Color(hex: 0x6B6B70)
}

/// A category's color: the bright stroke for its ring, a darker ink for its name, and a pale
/// tint behind its icon. Either one of the presets (the first six are the MVP v2 palette) or a
/// custom color someone picked, stored as "#RRGGBB" with its ink and tint worked out from it.
/// The raw value is what's saved, so existing budgets ("orange", "blue"…) read the same.
nonisolated struct CategoryColor: RawRepresentable, Hashable, Identifiable, Codable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        if Self.presets[rawValue] != nil || Self.hex(from: rawValue) != nil {
            self.rawValue = rawValue
        } else {
            return nil
        }
    }

    private init(preset: String) { rawValue = preset }

    /// A custom color from its hex value.
    init(hex: UInt32) {
        rawValue = String(format: "#%06X", hex & 0xFFFFFF)
    }

    // Saved as the bare string ("orange", "#3A7BD5"), as when this was an enum.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CategoryColor(rawValue: raw) ?? .gray
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let orange = CategoryColor(preset: "orange")
    static let red = CategoryColor(preset: "red")
    static let green = CategoryColor(preset: "green")
    static let blue = CategoryColor(preset: "blue")
    static let purple = CategoryColor(preset: "purple")
    static let yellow = CategoryColor(preset: "yellow")
    static let pink = CategoryColor(preset: "pink")
    static let teal = CategoryColor(preset: "teal")
    static let gray = CategoryColor(preset: "gray")

    /// The preset swatches, in order. Custom colors aren't listed here.
    static let allCases: [CategoryColor] = [.orange, .red, .green, .blue, .purple, .yellow, .pink, .teal, .gray]

    var id: String { rawValue }
    var isCustom: Bool { Self.presets[rawValue] == nil }
    var name: String { isCustom ? "Custom color" : rawValue.capitalized }

    var color: Color { Color(hex: palette.color) }
    var ink: Color { Color(hex: palette.ink) }
    var tint: Color { Color(hex: palette.tint) }

    /// The color as hex, for a custom color picker to start from.
    var hexValue: UInt32 { palette.color }

    // MARK: Palette

    private struct Palette {
        var color: UInt32
        var ink: UInt32
        var tint: UInt32
    }

    private static let presets: [String: Palette] = [
        "orange": Palette(color: 0xF3754D, ink: 0xB9461F, tint: 0xFDE9E2),
        "red": Palette(color: 0xF13636, ink: 0xC21F1F, tint: 0xFDE3E3),
        "green": Palette(color: 0x2FB45E, ink: 0x1E7A40, tint: 0xDFF3E5),
        "blue": Palette(color: 0x3EAEFF, ink: 0x1F6FB0, tint: 0xE0F1FF),
        "purple": Palette(color: 0x7B61FF, ink: 0x5B3FD9, tint: 0xECE8FF),
        "yellow": Palette(color: 0xF2C200, ink: 0x8A6D00, tint: 0xFFF7CF),
        "pink": Palette(color: 0xE84C8B, ink: 0xA8245C, tint: 0xFCE4EE),
        "teal": Palette(color: 0x1BA8A0, ink: 0x0F6E69, tint: 0xDDF4F2),
        "gray": Palette(color: 0x8E8E93, ink: 0x5B5B60, tint: 0xEDEDF0),
    ]

    private var palette: Palette {
        if let preset = Self.presets[rawValue] { return preset }
        let base = Self.hex(from: rawValue) ?? 0x8E8E93
        // Ink: the color darkened enough to read on white. Tint: mostly white with a wash of it.
        return Palette(color: base, ink: Self.mix(base, with: 0x000000, amount: 0.38), tint: Self.mix(base, with: 0xFFFFFF, amount: 0.86))
    }

    private static func hex(from raw: String) -> UInt32? {
        guard raw.hasPrefix("#"), raw.count == 7 else { return nil }
        return UInt32(raw.dropFirst(), radix: 16)
    }

    private static func mix(_ a: UInt32, with b: UInt32, amount: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let x = Double((a >> shift) & 0xFF)
            let y = Double((b >> shift) & 0xFF)
            return UInt32((x + (y - x) * amount).rounded()) & 0xFF
        }
        return (channel(16) << 16) | (channel(8) << 8) | channel(0)
    }
}

/// A household member's badge: a pale circle with their initial in a darker ink.
nonisolated enum MemberColor: String, CaseIterable, Identifiable, Codable, Sendable {
    case green, purple, blue, orange, pink, teal

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var background: Color {
        switch self {
        case .green: Color(hex: 0xDCEFE3)
        case .purple: Color(hex: 0xE7E1F7)
        case .blue: Color(hex: 0xDDEBFA)
        case .orange: Color(hex: 0xFBE6D9)
        case .pink: Color(hex: 0xF9E0EA)
        case .teal: Color(hex: 0xD9F1EF)
        }
    }

    var ink: Color {
        switch self {
        case .green: Color(hex: 0x035F1C)
        case .purple: Color(hex: 0x5B3FB0)
        case .blue: Color(hex: 0x1F5FA8)
        case .orange: Color(hex: 0xA34A12)
        case .pink: Color(hex: 0xA3245A)
        case .teal: Color(hex: 0x0F6E69)
        }
    }
}

extension Color {
    nonisolated init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
