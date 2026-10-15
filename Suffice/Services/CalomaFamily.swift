import Foundation

/// The parents' names from Caloma (the family chores and calendar app), through the Hearth app
/// group (`Services/Hearth/HearthShared.swift`). Suffice only reads them, to offer filling in
/// Who's budgeting? and Profile › Household; it never changes Caloma's family.
enum CalomaFamily {
    /// Caloma's parents in Caloma's order, when Caloma is on this iPhone and has shared its
    /// family. Empty otherwise, and in screenshot mode.
    static func parentNames() -> [String] {
        guard !ScreenshotMode.isOn,
              let family = Hearth.read(HearthFamily.self, from: .caloma)?.value else { return [] }
        var seen = Set<String>()
        return family.members
            .filter { $0.role == "parent" }
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Set when someone taps Not Now on "Use names from Caloma?", so it isn't offered again.
    static let dismissedKey = "hearth.calomaNamesDismissed"
}
