import Foundation

/// A calendar month: its first moment and the first moment of the next.
nonisolated struct MonthSpan: Hashable, Sendable {
    var start: Date
    var end: Date

    init(containing date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.year, .month], from: date)
        let start = calendar.date(from: components) ?? calendar.startOfDay(for: date)
        self.start = start
        self.end = calendar.date(byAdding: .month, value: 1, to: start) ?? start.addingTimeInterval(31 * 86_400)
    }

    func contains(_ date: Date) -> Bool { date >= start && date < end }

    func days(calendar: Calendar = .current) -> Int {
        calendar.range(of: .day, in: .month, for: start)?.count ?? 30
    }

    func offset(by months: Int, calendar: Calendar = .current) -> MonthSpan {
        MonthSpan(containing: calendar.date(byAdding: .month, value: months, to: start) ?? start, calendar: calendar)
    }

    /// The date a bill due on `day` lands on this month. Day 31 in February is the 28th or 29th.
    func dueDate(day: Int, calendar: Calendar = .current) -> Date {
        let clamped = min(max(day, 1), days(calendar: calendar))
        return calendar.date(byAdding: .day, value: clamped - 1, to: start) ?? start
    }
}

/// How one budget or subcategory is doing this month.
nonisolated struct CategoryStatus: Hashable, Sendable, Identifiable {
    var category: CategoryRecord
    /// Spent in it (and, for a budget with subcategories, in them).
    var spentCents: Int
    /// Its own amount, or the sum of its subcategories' amounts.
    var limitCents: Int
    var children: [CategoryStatus] = []

    var id: UUID { category.id }
    var leftCents: Int { limitCents - spentCents }
    var isOver: Bool { limitCents > 0 ? spentCents > limitCents : spentCents > 0 }
    var progress: Double {
        guard limitCents > 0 else { return spentCents > 0 ? 1 : 0 }
        return Double(spentCents) / Double(limitCents)
    }
}

/// A month's whole picture: what came in, what was planned, what went out.
nonisolated struct MonthTotals: Hashable, Sendable {
    var incomeCents: Int
    var spentCents: Int
    var budgetedCents: Int
    /// Spending with no category (or a deleted one).
    var uncategorizedCents: Int
    /// Counted toward stashes this month. It's part of the plan, so it comes out of what's left.
    var stashedCents: Int = 0

    /// Planned, less what went to stashes, less spent. Negative when the month has gone over plan.
    var leftCents: Int { budgetedCents - stashedCents - spentCents }
}

/// Where a bill stands for a month.
nonisolated enum BillState: Hashable, Sendable {
    case paid(Date)
    case overdue(days: Int)
    case dueToday
    case upcoming(days: Int)

    var isPaid: Bool { if case .paid = self { true } else { false } }

    /// Late first, paid last.
    var sortRank: Int {
        switch self {
        case .overdue: 0
        case .dueToday: 1
        case .upcoming: 2
        case .paid: 3
        }
    }
}

/// One day on the Bills strip.
nonisolated struct BillDay: Hashable, Sendable, Identifiable {
    var date: Date
    var billIDs: [UUID]
    var id: Date { date }
}

/// The budget's arithmetic. Pure functions over snapshots, so every number on screen comes from
/// here and is covered by tests. Which budgets count, what's spent in each, and when bills come
/// due and are paid live in HearthMoney (Services/Hearth, from ~/Developer/hearthkit), shared
/// with Ember so both apps always agree; these call it.
nonisolated enum BudgetMath {
    /// Whether a budget counts in `month`: started by then, and either repeating or a one-month
    /// budget for exactly that month. Archived budgets drop out.
    static func isActive(_ category: CategoryRecord, in month: MonthSpan, calendar: Calendar = .current) -> Bool {
        HearthMoney.isActive(category.money, in: month.money, calendar: calendar)
    }

    /// Spending per category ID for entries in `month`. Income is ignored. Nil key = uncategorized.
    /// What a stash paid for doesn't count: it was planned, month by month, before it came.
    static func spentByCategory(_ entries: [EntryRecord], in month: MonthSpan) -> [UUID?: Int] {
        HearthMoney.spentByCategory(entries.map(\.money), in: month.money)
    }

    /// The top-level budgets for `month`, each with its subcategories, in sort order. A budget
    /// that isn't active still shows if money was spent in it. A budget's amount is its own;
    /// subcategories needn't add up to it.
    static func statuses(_ categories: [CategoryRecord], entries: [EntryRecord], in month: MonthSpan, calendar: Calendar = .current) -> [CategoryStatus] {
        let byID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func convert(_ status: HearthMoney.Status) -> CategoryStatus? {
            guard let category = byID[status.category.id] else { return nil }
            return CategoryStatus(category: category, spentCents: status.spentCents, limitCents: status.limitCents,
                                  children: status.children.compactMap(convert))
        }
        return HearthMoney.statuses(categories.map(\.money), entries: entries.map(\.money), in: month.money, calendar: calendar)
            .compactMap(convert)
    }

    /// The month's totals. `stashMoves` are the stash amounts counted (any month; only this
    /// month's count).
    static func totals(_ categories: [CategoryRecord], entries: [EntryRecord], in month: MonthSpan, stashMoves: [StashMoveRecord] = [], calendar: Calendar = .current) -> MonthTotals {
        let inMonth = entries.filter { month.contains($0.date) }
        let known = Set(categories.map(\.id))
        let income = inMonth.filter { $0.kind == .income }.reduce(0) { $0 + $1.amountCents }
        let expenses = inMonth.filter { $0.kind == .expense }
        let spent = expenses.reduce(0) { $0 + $1.spendingCents }
        let uncategorized = expenses
            .flatMap(\.spendingParts)
            .filter { part in part.categoryID.map { !known.contains($0) } ?? true }
            .reduce(0) { $0 + $1.amountCents }
        let budgeted = statuses(categories, entries: entries, in: month, calendar: calendar).reduce(0) { $0 + $1.limitCents }
        return MonthTotals(incomeCents: income, spentCents: spent, budgetedCents: budgeted, uncategorizedCents: uncategorized, stashedCents: StashMath.stashed(stashMoves, in: month))
    }

    /// An account's balance now. Manual accounts move with every transaction filed to them
    /// after the balance was set; synced accounts report their own balance.
    static func balance(of account: AccountRecord, entries: [EntryRecord]) -> Int {
        guard account.isManual else { return account.balanceCents }
        return entries
            .filter { $0.accountID == account.id && $0.date >= account.balanceDate }
            .reduce(account.balanceCents) { $0 + $1.signedCents }
    }

    /// Overview's Total cash: checking, savings and cash that count toward the budget.
    static func totalCash(_ accounts: [AccountRecord], entries: [EntryRecord]) -> Int {
        accounts
            .filter { $0.includeInBudget && $0.kind.isCash }
            .reduce(0) { $0 + balance(of: $1, entries: entries) }
    }

    // MARK: Bills

    /// Every date `bill` comes due from `start` up to (not including) `end`, oldest first.
    static func occurrences(of bill: BillRecord, from start: Date, to end: Date, calendar: Calendar = .current) -> [Date] {
        HearthMoney.occurrences(of: bill.money, from: start, to: end, calendar: calendar)
    }

    /// The payment recorded for one due date of a bill, if there is one. A payment marks the due
    /// date it names; an older payment without one counts for its month.
    static func payment(for bill: BillRecord, dueOn due: Date, payments: [EntryRecord], calendar: Calendar = .current) -> EntryRecord? {
        guard let found = HearthMoney.payment(for: bill.money, dueOn: due, payments: payments.map(\.money), calendar: calendar) else { return nil }
        return payments.first { $0.id == found.id }
    }

    /// Where one due date of a bill stands today.
    static func state(of bill: BillRecord, dueOn due: Date, payments: [EntryRecord], today: Date = .now, calendar: Calendar = .current) -> BillState {
        if let payment = payment(for: bill, dueOn: due, payments: payments, calendar: calendar) {
            return .paid(payment.date)
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: today), to: calendar.startOfDay(for: due)).day ?? 0
        if days < 0 { return .overdue(days: -days) }
        if days == 0 { return .dueToday }
        return .upcoming(days: days)
    }

    /// A bill's state for the first time it comes due in `month` (monthly bills: their one
    /// due date). Upcoming with no days when it isn't due that month.
    static func state(
        of bill: BillRecord,
        in month: MonthSpan,
        payments: [EntryRecord],
        today: Date = .now,
        calendar: Calendar = .current
    ) -> BillState {
        guard let due = occurrences(of: bill, from: month.start, to: month.end, calendar: calendar).first else {
            return .upcoming(days: 0)
        }
        return state(of: bill, dueOn: due, payments: payments, today: today, calendar: calendar)
    }

    /// The next due date on or after `date`, looking up to two years ahead.
    static func nextDue(of bill: BillRecord, onOrAfter date: Date = .now, calendar: Calendar = .current) -> Date? {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .year, value: 2, to: start) ?? start
        return occurrences(of: bill, from: start, to: end, calendar: calendar).first
    }

    /// The seven days starting today, each with the bills due that day.
    static func week(_ bills: [BillRecord], from today: Date = .now, calendar: Calendar = .current) -> [BillDay] {
        let first = calendar.startOfDay(for: today)
        let end = calendar.date(byAdding: .day, value: 7, to: first) ?? first
        let due = bills.map { ($0.id, occurrences(of: $0, from: first, to: end, calendar: calendar)) }
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: first) else { return nil }
            let ids = due
                .filter { entry in entry.1.contains { date in calendar.isDate(date, inSameDayAs: day) } }
                .map { entry in entry.0 }
            return BillDay(date: day, billIDs: ids)
        }
    }

    /// What's still owed on the bills due in the next seven days.
    static func dueThisWeek(_ bills: [BillRecord], payments: [EntryRecord], from today: Date = .now, calendar: Calendar = .current) -> Int {
        let first = calendar.startOfDay(for: today)
        let end = calendar.date(byAdding: .day, value: 7, to: first) ?? first
        return bills.reduce(0) { total, bill in
            total + occurrences(of: bill, from: first, to: end, calendar: calendar)
                .filter { payment(for: bill, dueOn: $0, payments: payments, calendar: calendar) == nil }
                .count * bill.amountCents
        }
    }

    /// "Every month on the 18th", "Every 2 weeks on Friday", "Once on Oct 18".
    static func scheduleText(_ bill: BillRecord, calendar: Calendar = .current) -> String {
        let interval = max(bill.interval, 1)
        let every = interval == 1 ? "Every \(bill.frequency.unit)" : "Every \(interval) \(bill.frequency.unit)s"
        let ordinal = NumberFormatter()
        ordinal.numberStyle = .ordinal
        let day = ordinal.string(from: NSNumber(value: bill.dueDay)) ?? "\(bill.dueDay)"
        switch bill.frequency {
        case .once:
            return bill.startDate > .distantPast ? "Once, on \(bill.startDate.formatted(.dateTime.month(.abbreviated).day().year()))" : "Once"
        case .weekly:
            return "\(every) on \(bill.startDate.formatted(.dateTime.weekday(.wide)))"
        case .monthly:
            return "\(every) on the \(day)"
        case .yearly:
            let month = bill.startDate > .distantPast ? bill.startDate.formatted(.dateTime.month(.wide)) : ""
            return "\(every) on \(month) \(bill.dueDay)".replacingOccurrences(of: "  ", with: " ")
        }
    }
}
