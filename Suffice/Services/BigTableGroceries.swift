import Foundation

/// BigTable's grocery list (through the Hearth app group, `HearthGroceries`), shown on the
/// groceries budget as planned spending. Suffice only reads it and never records it as a
/// transaction, so the real charge at the store isn't counted twice.
enum BigTableGroceries {
    /// BigTable's active list, when it shared one in the last two weeks and there's still
    /// something to buy. Nil in screenshot mode.
    static func currentList(now: Date = .now) -> HearthGroceries.List? {
        guard !ScreenshotMode.isOn,
              let list = Hearth.read(HearthGroceries.self, from: .bigtable, maxAge: 14 * 24 * 60 * 60, now: now)?.value.list,
              list.remainingCount > 0 else { return nil }
        return list
    }

    /// What's left to buy should cost, in cents: the list's estimate scaled to the items not
    /// checked off yet. Nil when BigTable has no estimate.
    static func remainingCents(_ list: HearthGroceries.List) -> Int? {
        guard let estimate = list.estimatedCost, estimate > 0, list.itemCount > 0 else { return nil }
        let share = Double(list.remainingCount) / Double(list.itemCount)
        return Int((estimate * share * 100).rounded())
    }

    /// Whether a budget is for groceries, going by its name ("Groceries", "Food at home").
    static func isGroceries(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["grocer", "food at home", "supermarket"].contains { lower.contains($0) }
    }

    static let link = URL(string: "bigtable://grocery")

    /// Shares this month's groceries budget (planned, spent, left) so BigTable can show it on
    /// the grocery list. With no groceries budget, BigTable's copy is removed.
    static func publishBudget(_ budgets: [WidgetSnapshot.Budget], now: Date = .now) {
        guard !ScreenshotMode.isOn else { return }
        guard let budget = budgets.first(where: { isGroceries($0.name) }) else {
            Hearth.remove(HearthGroceryBudget.self, from: .suffice)
            return
        }
        let month = MonthSpan(containing: now).start
        let shared = HearthGroceryBudget(
            name: budget.name,
            month: HearthDay.string(from: month),
            limitCents: budget.limitCents,
            spentCents: budget.spentCents,
            currencyCode: Locale.current.currency?.identifier ?? "USD",
            link: "suffice://budget"
        )
        Hearth.publish(shared, from: .suffice)
    }
}
