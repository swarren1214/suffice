import Foundation

/// How close a budget is to its plan, for the bars on the iPhone Duo's outer display: amber
/// near the limit, orange once it's over.
nonisolated enum LimitLevel: Hashable, Sendable {
    case fine, near, over

    /// Near from 85% of the plan.
    static let nearShare = 0.85

    init(_ status: CategoryStatus) {
        if status.isOver {
            self = .over
        } else if status.limitCents > 0, status.progress >= Self.nearShare {
            self = .near
        } else {
            self = .fine
        }
    }
}

/// One day's budget spending, for the week's bars.
nonisolated struct DaySpend: Hashable, Sendable, Identifiable {
    var date: Date
    var cents: Int
    var id: Date { date }
}

/// What's safe to spend now: what's left of the month's plan, spread evenly over the days left.
/// Pure functions over snapshots, like BudgetMath. Used by Budget on the iPhone Duo's outer
/// display ("Can I spend this?") and the Today's Number board.
nonisolated enum SpendPace {
    /// Budget spending on one day: expenses, less what a stash paid for (the same spending that
    /// comes out of Left to spend).
    static func spent(on day: Date, entries: [EntryRecord], calendar: Calendar = .current) -> Int {
        entries
            .filter { $0.kind == .expense && calendar.isDate($0.date, inSameDayAs: day) }
            .reduce(0) { $0 + $1.spendingCents }
    }

    /// Days left in `month`, today included (at least 1). The whole month when today isn't in it.
    static func daysLeft(in month: MonthSpan, today: Date = .now, calendar: Calendar = .current) -> Int {
        guard month.contains(today) else { return month.days(calendar: calendar) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: today), to: month.end).day ?? 1
        return max(days, 1)
    }

    /// The seven days of the week that holds `today`, from the calendar's first weekday.
    static func week(containing today: Date = .now, calendar: Calendar = .current) -> [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? calendar.startOfDay(for: today)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// Each day of `days` with its spending.
    static func spending(on days: [Date], entries: [EntryRecord], calendar: Calendar = .current) -> [DaySpend] {
        days.map { DaySpend(date: $0, cents: spent(on: $0, entries: entries, calendar: calendar)) }
    }

    /// What each day from today to the month's end can take and still land on plan: what was
    /// left this morning over the days left. Zero once the month is over plan.
    static func dailyCents(leftCents: Int, month: MonthSpan, entries: [EntryRecord], today: Date = .now, calendar: Calendar = .current) -> Int {
        let spentToday = month.contains(today) ? spent(on: today, entries: entries, calendar: calendar) : 0
        let morning = leftCents + spentToday
        guard morning > 0 else { return 0 }
        return morning / daysLeft(in: month, today: today, calendar: calendar)
    }

    /// Safe to spend for the rest of today.
    static func safeToday(leftCents: Int, month: MonthSpan, entries: [EntryRecord], today: Date = .now, calendar: Calendar = .current) -> Int {
        guard month.contains(today) else { return max(leftCents, 0) }
        let daily = dailyCents(leftCents: leftCents, month: month, entries: entries, today: today, calendar: calendar)
        return max(min(daily - spent(on: today, entries: entries, calendar: calendar), max(leftCents, 0)), 0)
    }

    /// Safe to spend for the rest of this week: today through the week's last day, never past
    /// the month's end or more than is left.
    static func safeThisWeek(leftCents: Int, month: MonthSpan, entries: [EntryRecord], today: Date = .now, calendar: Calendar = .current) -> Int {
        guard month.contains(today) else { return max(leftCents, 0) }
        let first = calendar.startOfDay(for: today)
        let weekEnd = calendar.dateInterval(of: .weekOfYear, for: today)?.end ?? month.end
        let days = max(calendar.dateComponents([.day], from: first, to: min(weekEnd, month.end)).day ?? 1, 1)
        let daily = dailyCents(leftCents: leftCents, month: month, entries: entries, today: today, calendar: calendar)
        let week = daily * days - spent(on: today, entries: entries, calendar: calendar)
        return max(min(week, max(leftCents, 0)), 0)
    }

    /// The budgets with a plan that are closest to it (or furthest over), nearest first.
    static func closest(_ statuses: [CategoryStatus], count: Int = 3) -> [CategoryStatus] {
        Array(statuses.filter { $0.limitCents > 0 }.sorted { $0.progress > $1.progress }.prefix(count))
    }
}
