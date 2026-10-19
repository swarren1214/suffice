import Foundation

// The emergency fund's arithmetic: how many months of essentials the household could cover
// from savings if both paychecks stopped. Pure functions in cents, pinned by
// SufficeTests/RunwayMathTests.swift.

/// The emergency fund as it stands.
nonisolated struct Runway: Hashable, Sendable {
    /// Balances of the accounts that count.
    var savedCents: Int
    /// Essentials a month: the essential budgets' plans, loan payments, essential stashes.
    var essentialsCents: Int
    var goalMonths: Int

    /// Months it would last, or nil when nothing is essential yet.
    var months: Double? { RunwayMath.months(savedCents: savedCents, essentialsCents: essentialsCents) }
    /// Short of the goal by this much (zero once it's reached).
    var gapCents: Int { RunwayMath.gap(goalMonths: goalMonths, savedCents: savedCents, essentialsCents: essentialsCents) }
    /// Past the goal by this much (zero until it's reached).
    var overCents: Int { max(savedCents - goalMonths * essentialsCents, 0) }
    /// Saved a month, it closes the gap in a year.
    var monthlyToCloseCents: Int { RunwayMath.monthlyToClose(gapCents: gapCents) }
}

/// One line of the essentials: a budget (or a subcategory of one that isn't essential), loan
/// payments, or a stash.
nonisolated struct EssentialLine: Hashable, Sendable, Identifiable {
    var id: UUID
    var cents: Int
}

nonisolated enum RunwayMath {
    /// Months of essentials `savedCents` covers, or nil with no essentials.
    static func months(savedCents: Int, essentialsCents: Int) -> Double? {
        guard essentialsCents > 0 else { return nil }
        return Double(max(savedCents, 0)) / Double(essentialsCents)
    }

    /// What's still needed to reach `goalMonths` of essentials.
    static func gap(goalMonths: Int, savedCents: Int, essentialsCents: Int) -> Int {
        max(max(goalMonths, 0) * max(essentialsCents, 0) - max(savedCents, 0), 0)
    }

    /// The gap spread over `months`, rounded up to the cent.
    static func monthlyToClose(gapCents: Int, months: Int = 12) -> Int {
        guard gapCents > 0 else { return 0 }
        let months = max(months, 1)
        return (gapCents + months - 1) / months
    }

    /// The essential budgets' amounts this month. A budget that's essential counts its whole
    /// amount; a subcategory counts on its own only when its budget isn't essential, so nothing
    /// is counted twice.
    static func essentialBudgets(_ statuses: [CategoryStatus]) -> [EssentialLine] {
        statuses.flatMap { status -> [EssentialLine] in
            if status.category.isEssential {
                return [EssentialLine(id: status.id, cents: status.limitCents)]
            }
            return status.children
                .filter { $0.category.isEssential }
                .map { EssentialLine(id: $0.id, cents: $0.limitCents) }
        }
    }

    /// A yearly stash's share of a month: its target ÷ 12, rounded up to the cent. One-time
    /// stashes aren't a monthly cost.
    static func monthlyShare(of stash: StashRecord) -> Int {
        guard stash.repeatsYearly, !stash.isArchived, stash.targetCents > 0 else { return 0 }
        return (stash.targetCents + 11) / 12
    }

    /// Essentials a month in all.
    static func essentials(budgets: [CategoryStatus], loanPaymentsCents: Int, stashes: [StashRecord]) -> Int {
        essentialBudgets(budgets).reduce(0) { $0 + $1.cents }
            + max(loanPaymentsCents, 0)
            + stashes.filter(\.isEssential).reduce(0) { $0 + monthlyShare(of: $1) }
    }
}
