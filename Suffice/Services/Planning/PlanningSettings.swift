import Foundation
import Observation

/// Planning choices that aren't records: the emergency fund's goal, whether loan payments count
/// as essentials, and which stash suggestions were dismissed. Kept in iCloud key-value storage,
/// so they follow the Apple Account to every device it's signed in on (and fall back to this
/// device when iCloud isn't available).
@Observable
final class PlanningSettings {
    static let shared = PlanningSettings()

    /// Months of essentials to aim for, 1–12.
    var runwayGoalMonths: Int {
        didSet {
            let clamped = min(max(runwayGoalMonths, 1), 12)
            if clamped != runwayGoalMonths { runwayGoalMonths = clamped; return }
            write(clamped, forKey: SettingsKey.runwayGoalMonths)
        }
    }

    /// Loan payments count toward essentials.
    var loansAreEssential: Bool {
        didSet { write(loansAreEssential, forKey: SettingsKey.loansAreEssential) }
    }

    /// Bills whose "stash for this" suggestion someone answered Not Now.
    private(set) var dismissedSuggestions: Set<UUID> = []

    @ObservationIgnored private let cloud = NSUbiquitousKeyValueStore.default
    @ObservationIgnored private let local = UserDefaults.standard
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        runwayGoalMonths = 6
        // Off to begin with: Home's plan usually already includes the mortgage payment.
        loansAreEssential = false
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        cloud.synchronize()
    }

    func dismissSuggestion(for billID: UUID) {
        dismissedSuggestions.insert(billID)
        let ids = dismissedSuggestions.map(\.uuidString).sorted()
        if let data = try? JSONEncoder().encode(ids) {
            write(data, forKey: SettingsKey.dismissedStashSuggestions)
        }
    }

    /// Reads everything again (another device changed it).
    private func reload() {
        if let goal = value(forKey: SettingsKey.runwayGoalMonths) as? Int ?? (value(forKey: SettingsKey.runwayGoalMonths) as? NSNumber)?.intValue,
           (1...12).contains(goal), goal != runwayGoalMonths {
            runwayGoalMonths = goal
        }
        if let loans = value(forKey: SettingsKey.loansAreEssential) as? Bool, loans != loansAreEssential {
            loansAreEssential = loans
        }
        if let data = value(forKey: SettingsKey.dismissedStashSuggestions) as? Data,
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            dismissedSuggestions = Set(ids.compactMap(UUID.init(uuidString:)))
        }
    }

    private func value(forKey key: String) -> Any? {
        cloud.object(forKey: key) ?? local.object(forKey: key)
    }

    private func write(_ value: Any, forKey key: String) {
        cloud.set(value, forKey: key)
        local.set(value, forKey: key)
    }
}
