import Foundation

/// What the widgets show, written by the app into the shared app group whenever the budget
/// changes, and read by the widget extension. The widgets never open the SwiftData store
/// themselves, so they stay fast and never touch CloudKit.
nonisolated struct WidgetSnapshot: Codable, Sendable {
    nonisolated struct Budget: Codable, Sendable, Identifiable, Hashable {
        var id: UUID
        var name: String
        var symbol: String
        var color: CategoryColor
        var spentCents: Int
        var limitCents: Int

        var leftCents: Int { limitCents - spentCents }
        var progress: Double {
            guard limitCents > 0 else { return spentCents > 0 ? 1 : 0 }
            return Double(spentCents) / Double(limitCents)
        }
    }

    /// One time a bill comes due.
    nonisolated struct Due: Codable, Sendable, Identifiable, Hashable {
        var billID: UUID
        var name: String
        var amountCents: Int
        var date: Date
        var color: CategoryColor
        var isPaid: Bool
        var isAutopay: Bool
        var isSubscription: Bool
        var id: String { "\(billID.uuidString)-\(date.timeIntervalSinceReferenceDate)" }
    }

    /// When the app wrote this.
    var updated: Date
    /// The first day of the month the budget numbers are for.
    var month: Date
    var budgetedCents: Int
    var spentCents: Int
    var incomeCents: Int
    var cashCents: Int
    /// Top-level budgets in the app's order.
    var budgets: [Budget]
    /// Unpaid bills from the last two months, and every due date in the next 45 days.
    var dues: [Due]

    var leftCents: Int { budgetedCents - spentCents }
    var progress: Double {
        guard budgetedCents > 0 else { return 0 }
        return Double(spentCents) / Double(budgetedCents)
    }

    /// The bills still to pay, oldest first: overdue ones, then upcoming.
    var unpaid: [Due] {
        dues.filter { !$0.isPaid }.sorted { $0.date < $1.date }
    }

    /// What's still owed on bills due today through the next six days (and any overdue).
    func owedThisWeek(from today: Date = .now, calendar: Calendar = .current) -> Int {
        let end = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: today)) ?? today
        return dues.filter { !$0.isPaid && $0.date < end }.reduce(0) { $0 + $1.amountCents }
    }
}

/// Reading and writing the snapshot in the app group.
nonisolated enum WidgetStore {
    static let appGroup = "group.com.stephenwarren.suffice"
    private static let fileName = "widget-snapshot.json"

    /// The widget kinds, so the app can reload them by name.
    enum Kind {
        static let leftToSpend = "LeftToSpendWidget"
        static let bills = "BillsWidget"
        static let cash = "TotalCashWidget"
        // On Apple Watch:
        static let watchLeftToSpend = "WatchLeftToSpend"
        static let watchBudget = "WatchBudget"
        static let watchUpNext = "WatchUpNext"
    }

    private static var url: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: fileName)
    }

    static func load() -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    /// The snapshot as JSON, as the iPhone sends it to the watch.
    static func encode(_ snapshot: WidgetSnapshot) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(snapshot)
    }

    static func decode(_ data: Data) -> WidgetSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    /// True when the file changed, so callers only reload widgets when something is new.
    @discardableResult
    static func save(_ snapshot: WidgetSnapshot) -> Bool {
        guard let url else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return false }
        // Ignore `updated` when comparing, or every save would look like a change.
        var comparable = snapshot
        comparable.updated = .distantPast
        if let old = load() {
            var oldComparable = old
            oldComparable.updated = .distantPast
            if let a = try? encoder.encode(comparable), let b = try? encoder.encode(oldComparable), a == b {
                return false
            }
        }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

/// Links the widgets open: suffice://budget, suffice://bills, suffice://overview.
nonisolated enum WidgetLink {
    static let scheme = "suffice"
    static let overview = URL(string: "suffice://overview")!
    static let budget = URL(string: "suffice://budget")!
    static let bills = URL(string: "suffice://bills")!
}
