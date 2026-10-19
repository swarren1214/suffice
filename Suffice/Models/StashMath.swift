import Foundation

// The arithmetic behind stashes. Pure functions on plain values, pinned by
// SufficeTests/StashMathTests.swift.
//
// A stash counts an amount on the 1st of each month until it's due. Each month's amount is
// what's still needed divided by the 1sts left, the due month included, rounded up to the
// dollar: $1,380 due March 15, counted from October 19, is five 1sts (November through March)
// at $276. When the bill comes, it's paid from what's stashed; a yearly stash then starts over
// for the same date next year, with anything left over carried forward.

/// Where a stash stands this month.
nonisolated enum StashStatus: Hashable, Sendable {
    /// This month's amount is counted (or it only started this month).
    case onTrack
    /// This month's amount isn't counted yet.
    case behind(cents: Int)
    /// What's stashed covers the target.
    case funded
    /// Its date has come and it hasn't been used yet.
    case due

    var label: String {
        switch self {
        case .onTrack: "On track"
        case .behind(let cents): "Behind \(Money.whole(cents))"
        case .funded: "Fully stashed"
        case .due: "Due"
        }
    }

    var isBehind: Bool { if case .behind = self { true } else { false } }
}

/// A stash as it stands today, for its row and its sheet.
nonisolated struct StashSummary: Hashable, Sendable {
    /// What's stashed: what it started with, plus every month counted, less what it paid for.
    var balanceCents: Int
    /// The amount for the next month to count (this month's, if it isn't counted yet).
    var monthlyCents: Int
    /// The 1sts left to count, the due month included.
    var monthsLeft: Int
    /// Counted this month.
    var thisMonthCents: Int
    var status: StashStatus

    /// 0…1 of the target.
    func progress(targetCents: Int) -> Double {
        guard targetCents > 0 else { return 0 }
        return min(max(Double(balanceCents) / Double(targetCents), 0), 1)
    }
}

/// A bill that comes rarely enough to stash for, with what stashing for it would take.
nonisolated struct StashSuggestion: Hashable, Sendable, Identifiable {
    var billID: UUID
    var name: String
    var amountCents: Int
    var dueDate: Date
    /// From the next 1st until it's due.
    var monthlyCents: Int
    var monthsLeft: Int
    /// Once it starts over: the bill spread across the time between bills.
    var afterCents: Int
    var repeatsYearly: Bool

    var id: UUID { billID }
}

nonisolated enum StashMath {
    /// The 1sts after `date` up to and including the due month's: November through March from
    /// October 19 to March 15 is five. Never less than one, so a stash due this month still
    /// asks for the rest.
    static func monthsLeft(from date: Date, due: Date, calendar: Calendar = .current) -> Int {
        max(monthsBetween(date, due, calendar: calendar), 1)
    }

    /// Calendar months from `from`'s month to `to`'s (negative when `to` is earlier).
    static func monthsBetween(_ from: Date, _ to: Date, calendar: Calendar = .current) -> Int {
        let a = calendar.dateComponents([.year, .month], from: from)
        let b = calendar.dateComponents([.year, .month], from: to)
        return ((b.year ?? 0) * 12 + (b.month ?? 0)) - ((a.year ?? 0) * 12 + (a.month ?? 0))
    }

    /// What's still needed spread over `monthsLeft` 1sts, rounded up to the dollar. Zero once
    /// it's all saved.
    static func monthly(targetCents: Int, savedCents: Int, monthsLeft: Int) -> Int {
        let need = targetCents - savedCents
        guard need > 0 else { return 0 }
        let months = max(monthsLeft, 1)
        let perMonth = (need + months - 1) / months
        return (perMonth + 99) / 100 * 100
    }

    /// What it started with, plus every month counted, less what it paid for.
    static func balance(openingCents: Int, moves: [Int], payments: [Int]) -> Int {
        openingCents + moves.reduce(0, +) - payments.reduce(0, +)
    }

    /// A stash's balance from its moves and the transactions it paid for.
    static func balance(of stash: StashRecord, moves: [StashMoveRecord], entries: [EntryRecord]) -> Int {
        balance(
            openingCents: stash.openingCents,
            moves: moves.filter { $0.stashID == stash.id }.map(\.amountCents),
            payments: entries.filter { $0.stashID == stash.id }.map(\.stashCents)
        )
    }

    /// The amount to count on the 1st of `month` (its first moment), given what was stashed
    /// before it. Zero for months after the due month.
    static func amount(for stash: StashRecord, month: Date, balanceBefore: Int, calendar: Calendar = .current) -> Int {
        let left = monthsBetween(month, stash.dueDate, calendar: calendar)
        guard left >= 0 else { return 0 }
        return monthly(targetCents: stash.targetCents, savedCents: balanceBefore, monthsLeft: left + 1)
    }

    /// The 1sts still to count, oldest first: every month after the last one counted (or the
    /// month it was made) through this month, but none past the due month.
    static func monthsToCount(_ stash: StashRecord, lastCounted: Date?, today: Date = .now, calendar: Calendar = .current) -> [Date] {
        guard !stash.isArchived, stash.targetCents > 0 else { return [] }
        let from = MonthSpan(containing: max(lastCounted ?? .distantPast, stash.createdAt), calendar: calendar)
        let through = MonthSpan(containing: min(today, stash.dueDate), calendar: calendar)
        var months: [Date] = []
        var month = from.offset(by: 1, calendar: calendar)
        while month.start <= through.start && months.count < 240 {
            months.append(month.start)
            month = month.offset(by: 1, calendar: calendar)
        }
        return months
    }

    /// Where a stash stands today.
    static func summary(_ stash: StashRecord, moves: [StashMoveRecord], entries: [EntryRecord], today: Date = .now, calendar: Calendar = .current) -> StashSummary {
        let own = moves.filter { $0.stashID == stash.id }
        let balance = balance(of: stash, moves: own, entries: entries)
        let thisMonth = MonthSpan(containing: today, calendar: calendar)
        let counted = own.filter { thisMonth.contains($0.month) }.reduce(0) { $0 + $1.amountCents }
        let hasMove = own.contains { thisMonth.contains($0.month) }
        let startedThisMonth = thisMonth.contains(stash.createdAt)
        let left = monthsBetween(today, stash.dueDate, calendar: calendar)

        // The next month to count: this one, unless it's counted or the stash only just started.
        let next = hasMove || startedThisMonth ? thisMonth.offset(by: 1, calendar: calendar) : thisMonth
        let monthly = amount(for: stash, month: next.start, balanceBefore: balance, calendar: calendar)
        let monthsLeft = max(monthsBetween(next.start, stash.dueDate, calendar: calendar) + 1, 0)

        let status: StashStatus
        if stash.targetCents > 0, balance >= stash.targetCents {
            status = .funded
        } else if calendar.startOfDay(for: today) > calendar.startOfDay(for: stash.dueDate) {
            status = .due
        } else if hasMove || startedThisMonth || left < 0 {
            status = .onTrack
        } else {
            status = .behind(cents: amount(for: stash, month: thisMonth.start, balanceBefore: balance, calendar: calendar))
        }
        return StashSummary(balanceCents: balance, monthlyCents: monthly, monthsLeft: monthsLeft, thisMonthCents: counted, status: status)
    }

    /// A yearly stash's next cycle once it's used: the same date next year, and the monthly
    /// amount from then (the target ÷ 12, less anything left over).
    static func nextCycle(after due: Date, targetCents: Int, leftoverCents: Int = 0, calendar: Calendar = .current) -> (dueDate: Date, monthlyCents: Int) {
        let next = calendar.date(byAdding: .year, value: 1, to: due) ?? due
        let monthly = monthly(targetCents: targetCents, savedCents: max(leftoverCents, 0), monthsLeft: monthsLeft(from: due, due: next, calendar: calendar))
        return (next, monthly)
    }

    /// How much of a payment a stash covers: all of it, or what's there.
    static func covered(paymentCents: Int, balanceCents: Int) -> Int {
        min(max(paymentCents, 0), max(balanceCents, 0))
    }

    /// Counted toward stashes in `month`.
    static func stashed(_ moves: [StashMoveRecord], in month: MonthSpan) -> Int {
        moves.filter { month.contains($0.month) }.reduce(0) { $0 + $1.amountCents }
    }

    /// Groups of moves that count the same month of the same stash (two devices both counted
    /// the 1st before they synced). The caller keeps the oldest of each.
    static func duplicateGroups(_ moves: [StashMoveRecord], calendar: Calendar = .current) -> [[StashMoveRecord]] {
        let groups = Dictionary(grouping: moves.filter { $0.stashID != nil }) { move in
            "\(move.stashID?.uuidString ?? "")|\(MonthSpan(containing: move.month, calendar: calendar).start.timeIntervalSinceReferenceDate)"
        }
        return groups.values.filter { $0.count > 1 }
    }

    // MARK: Suggestions

    /// Bills that come every three months or less often, with no stash yet and at least two
    /// 1sts before they're due: worth stashing for, so they don't land on one month's budget.
    static func suggestions(bills: [BillRecord], stashes: [StashRecord], dismissed: Set<UUID> = [], today: Date = .now, calendar: Calendar = .current) -> [StashSuggestion] {
        let covered = Set(stashes.filter { !$0.isArchived }.compactMap(\.billID))
        return bills.compactMap { bill -> StashSuggestion? in
            guard !covered.contains(bill.id), !dismissed.contains(bill.id), bill.amountCents > 0 else { return nil }
            let monthsApart: Int
            switch bill.frequency {
            case .yearly: monthsApart = 12 * max(bill.interval, 1)
            case .monthly: monthsApart = max(bill.interval, 1)
            case .once, .weekly: return nil
            }
            guard monthsApart >= 3, let due = BudgetMath.nextDue(of: bill, onOrAfter: today, calendar: calendar) else { return nil }
            let left = monthsBetween(today, due, calendar: calendar)
            guard left >= 2 else { return nil }
            return StashSuggestion(
                billID: bill.id,
                name: bill.name,
                amountCents: bill.amountCents,
                dueDate: due,
                monthlyCents: monthly(targetCents: bill.amountCents, savedCents: 0, monthsLeft: left),
                monthsLeft: left,
                afterCents: monthly(targetCents: bill.amountCents, savedCents: 0, monthsLeft: monthsApart),
                repeatsYearly: bill.frequency == .yearly && max(bill.interval, 1) == 1
            )
        }
        .sorted { $0.dueDate < $1.dueDate }
    }
}
