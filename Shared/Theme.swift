import SwiftUI

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
    static let expenseInk = Color(hex: 0xC21F1F)
    /// The Total cash card.
    static let cashStart = Color(hex: 0x5A3FD9)
    static let cashEnd = Color(hex: 0x2563C9)
    /// Secondary text on white cards.
    static let secondaryText = Color(hex: 0x6B6B70)
}

/// A category's color: the bright stroke for its ring, a darker ink for its name, and a pale
/// tint behind its icon. The first six are the MVP v2 palette.
nonisolated enum CategoryColor: String, CaseIterable, Identifiable, Codable, Sendable {
    case orange, red, green, blue, purple, yellow, pink, teal, gray

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .orange: Color(hex: 0xF3754D)
        case .red: Color(hex: 0xF13636)
        case .green: Color(hex: 0x2FB45E)
        case .blue: Color(hex: 0x3EAEFF)
        case .purple: Color(hex: 0x7B61FF)
        case .yellow: Color(hex: 0xF2C200)
        case .pink: Color(hex: 0xE84C8B)
        case .teal: Color(hex: 0x1BA8A0)
        case .gray: Color(hex: 0x8E8E93)
        }
    }

    var ink: Color {
        switch self {
        case .orange: Color(hex: 0xB9461F)
        case .red: Color(hex: 0xC21F1F)
        case .green: Color(hex: 0x1E7A40)
        case .blue: Color(hex: 0x1F6FB0)
        case .purple: Color(hex: 0x5B3FD9)
        case .yellow: Color(hex: 0x8A6D00)
        case .pink: Color(hex: 0xA8245C)
        case .teal: Color(hex: 0x0F6E69)
        case .gray: Color(hex: 0x5B5B60)
        }
    }

    var tint: Color {
        switch self {
        case .orange: Color(hex: 0xFDE9E2)
        case .red: Color(hex: 0xFDE3E3)
        case .green: Color(hex: 0xDFF3E5)
        case .blue: Color(hex: 0xE0F1FF)
        case .purple: Color(hex: 0xECE8FF)
        case .yellow: Color(hex: 0xFFF7CF)
        case .pink: Color(hex: 0xFCE4EE)
        case .teal: Color(hex: 0xDDF4F2)
        case .gray: Color(hex: 0xEDEDF0)
        }
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
