import Foundation
import OSLog
import SwiftData

enum Persistence {
    static let schema = Schema([
        Member.self,
        BudgetCategory.self,
        LedgerEntry.self,
        Bill.self,
        Account.self,
        PayeeRule.self,
        LinkedBank.self,
    ])

    private static let log = Logger(subsystem: "com.stephenwarren.suffice", category: "persistence")

    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        // Previews and tests use an in-memory store and never touch iCloud.
        let syncs = AppConfig.cloudSyncEnabled && !inMemory
        let configuration = ModelConfiguration(
            "Suffice",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: syncs ? .private(AppConfig.cloudKitContainerID) : .none
        )
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // Never crash on launch over the store. Set the unreadable one aside (kept for
            // recovery) and start fresh; with sync on, iCloud fills it back in.
            log.fault("Couldn't open the data store, starting a fresh one: \(error.localizedDescription, privacy: .public)")
            setAside(configuration.url)
            if let container = try? ModelContainer(for: schema, configurations: [configuration]) {
                return container
            }
            log.fault("The fresh store failed too; running in memory this launch")
            let memory = ModelConfiguration("Suffice", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            do {
                return try ModelContainer(for: schema, configurations: [memory])
            } catch {
                fatalError("Could not create even an in-memory Suffice store: \(error)")
            }
        }
    }

    /// Renames the store and its journal files with a timestamp, so a fresh store can be made.
    private static func setAside(_ url: URL) {
        let stamp = Int(Date.now.timeIntervalSince1970)
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            guard manager.fileExists(atPath: file.path) else { continue }
            let aside = URL(fileURLWithPath: url.path + ".unreadable-\(stamp)" + suffix)
            try? manager.moveItem(at: file, to: aside)
        }
    }

    /// Entries in a month, oldest first.
    static func entries(in month: MonthSpan, context: ModelContext) -> [LedgerEntry] {
        let start = month.start
        let end = month.end
        let descriptor = FetchDescriptor<LedgerEntry>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\.date)]
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            log.error("Couldn't fetch entries: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

/// Housekeeping that keeps the household tidy.
enum Household {
    /// Folds people with the same name into one: their transactions move to the person kept,
    /// and so does a photo if the kept one has none. Fixes duplicates left by finishing
    /// onboarding more than once. Runs at launch; does nothing when there are none.
    static func mergeDuplicateMembers(in context: ModelContext, defaults: UserDefaults = .standard) {
        let members = (try? context.fetch(FetchDescriptor<Member>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let groups = Dictionary(grouping: members) { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
        let duplicates = groups.values.filter { $0.count > 1 }
        guard !duplicates.isEmpty else { return }
        let current = defaults.string(forKey: SettingsKey.currentMember) ?? ""
        let entries = (try? context.fetch(FetchDescriptor<LedgerEntry>())) ?? []
        for group in duplicates {
            // Keep the one this iPhone belongs to, else the oldest.
            let keeper = group.first { $0.id.uuidString == current } ?? group[0]
            for extra in group where extra.id != keeper.id {
                for entry in entries where entry.memberID == extra.id {
                    entry.memberID = keeper.id
                }
                if keeper.photoData == nil, let photo = extra.photoData {
                    keeper.photoData = photo
                }
                if extra.id.uuidString == current {
                    defaults.set(keeper.id.uuidString, forKey: SettingsKey.currentMember)
                }
                context.delete(extra)
            }
        }
        try? context.save()
    }
}

/// The budgets a new household starts with, from the MVP v2 designs. Amounts start at zero
/// so the first thing the two of you do is decide your own plan.
enum StarterData {
    struct Budget {
        var name: String
        var symbol: String
        var color: CategoryColor
        var subcategories: [String]
    }

    static let budgets: [Budget] = [
        Budget(name: "Home", symbol: "house", color: .orange, subcategories: ["Mortgage", "Home improvements"]),
        Budget(name: "Auto", symbol: "car", color: .blue, subcategories: ["Gas", "Insurance"]),
        Budget(name: "Food", symbol: "fork.knife", color: .red, subcategories: ["Groceries", "Fast food"]),
        Budget(name: "Utilities", symbol: "bolt", color: .green, subcategories: ["Power", "Gas"]),
        Budget(name: "Entertainment", symbol: "ticket", color: .purple, subcategories: ["Streaming", "Date night"]),
        Budget(name: "Giving", symbol: "heart", color: .yellow, subcategories: []),
    ]

    /// Adds the starter budgets once, the first time the app opens with an empty store.
    static func seedIfNeeded(in context: ModelContext, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: SettingsKey.seeded) else { return }
        defaults.set(true, forKey: SettingsKey.seeded)
        let existing = (try? context.fetchCount(FetchDescriptor<BudgetCategory>())) ?? 0
        guard existing == 0 else { return }
        insertBudgets(into: context)
        try? context.save()
    }

    /// Inserts the starter budgets with the given amounts (zero when missing). Returns them by
    /// name, subcategories as "Parent/Child".
    @discardableResult
    static func insertBudgets(into context: ModelContext, amounts: [String: Int] = [:]) -> [String: BudgetCategory] {
        var byName: [String: BudgetCategory] = [:]
        for (index, budget) in budgets.enumerated() {
            let parent = BudgetCategory(name: budget.name, symbol: budget.symbol, color: budget.color, limitCents: amounts[budget.name] ?? 0, sortOrder: index)
            context.insert(parent)
            byName[budget.name] = parent
            for (childIndex, name) in budget.subcategories.enumerated() {
                let key = "\(budget.name)/\(name)"
                let child = BudgetCategory(name: name, symbol: budget.symbol, color: budget.color, limitCents: amounts[key] ?? 0, parentID: parent.id, sortOrder: childIndex)
                context.insert(child)
                byName[key] = child
            }
        }
        return byName
    }
}
