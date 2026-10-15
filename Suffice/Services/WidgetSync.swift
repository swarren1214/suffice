import Foundation
import SwiftData
import WidgetKit

/// Writes the widget snapshot from the budget and asks the widgets to redraw. Runs after every
/// save, when the app goes to the background, and when it opens.
enum WidgetSync {
    private static var pending: Task<Void, Never>?

    /// Coalesces bursts of saves (typing, Mark paid, imports) into one write.
    static func schedule(_ container: ModelContainer) {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            refresh(container.mainContext)
        }
    }

    static func refresh(_ context: ModelContext, now: Date = .now) {
        // Screenshot mode's demo household stays out of the widgets and the watch.
        guard !ScreenshotMode.isOn else { return }
        let snapshot = makeSnapshot(context, now: now)
        if WidgetStore.save(snapshot) {
            WidgetCenter.shared.reloadAllTimelines()
            // The watch app and its complications get the same numbers.
            WatchSync.shared.send(snapshot)
        }
    }

    static func makeSnapshot(_ context: ModelContext, now: Date = .now) -> WidgetSnapshot {
        let calendar = Calendar.current
        let month = MonthSpan(containing: now, calendar: calendar)

        let categories = (try? context.fetch(FetchDescriptor<BudgetCategory>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let bills = (try? context.fetch(FetchDescriptor<Bill>(predicate: #Predicate { $0.isActive == true }))) ?? []
        let entries = ((try? context.fetch(FetchDescriptor<LedgerEntry>())) ?? []).map(\.record)

        let categoryRecords = categories.map(\.record)
        let statuses = BudgetMath.statuses(categoryRecords, entries: entries, in: month, calendar: calendar)
        let totals = BudgetMath.totals(categoryRecords, entries: entries, in: month, calendar: calendar)
        let byID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let budgets = statuses.compactMap { status -> WidgetSnapshot.Budget? in
            guard let category = byID[status.id] else { return nil }
            return WidgetSnapshot.Budget(
                id: category.id,
                name: category.name,
                symbol: category.symbol,
                color: category.color,
                spentCents: status.spentCents,
                limitCents: status.limitCents
            )
        }

        // Unpaid bills from the last two months, and everything due in the next 45 days.
        let today = calendar.startOfDay(for: now)
        let from = calendar.date(byAdding: .day, value: -62, to: today) ?? today
        let to = calendar.date(byAdding: .day, value: 45, to: today) ?? today
        let payments = entries.filter { $0.billID != nil }
        let dues = bills.flatMap { bill in
            let record = bill.record
            return BudgetMath.occurrences(of: record, from: from, to: to, calendar: calendar).compactMap { date -> WidgetSnapshot.Due? in
                let isPaid = BudgetMath.payment(for: record, dueOn: date, payments: payments, calendar: calendar) != nil
                if date < today, isPaid { return nil }
                return WidgetSnapshot.Due(
                    billID: bill.id,
                    name: bill.name,
                    amountCents: bill.amountCents,
                    date: date,
                    color: bill.color,
                    isPaid: isPaid,
                    isAutopay: bill.isAutopay,
                    isSubscription: bill.isSubscription
                )
            }
        }
        .sorted { $0.date < $1.date }

        return WidgetSnapshot(
            updated: now,
            month: month.start,
            budgetedCents: totals.budgetedCents,
            spentCents: totals.spentCents,
            incomeCents: totals.incomeCents,
            cashCents: BudgetMath.totalCash(accounts.map(\.record), entries: entries),
            budgets: budgets,
            dues: dues
        )
    }
}
