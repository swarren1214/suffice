import Foundation
import SwiftData

/// The emergency fund from the household's records: the accounts that count, the essential
/// budgets' plans for this month, open loans' payments and essential stashes. Net Worth's card,
/// the Emergency Fund screen and Ask all read it from here (the arithmetic is RunwayMath's).
@MainActor
enum EmergencyFund {
    /// An account and what it holds now.
    struct AccountLine: Identifiable {
        var account: Account
        var balanceCents: Int
        var id: UUID { account.id }
    }

    /// The accounts that could hold savings (not credit cards), with their balances.
    static func accounts(_ accounts: [Account], entries: [EntryRecord]) -> [AccountLine] {
        accounts
            .filter { $0.kind != .credit }
            .map { AccountLine(account: $0, balanceCents: BudgetMath.balance(of: $0.record, entries: entries)) }
    }

    /// What the counting accounts hold (an overdrawn one counts as nothing).
    static func saved(_ lines: [AccountLine]) -> Int {
        lines.filter(\.account.countsTowardEmergencyFund).reduce(0) { $0 + max($1.balanceCents, 0) }
    }

    /// Open loans' scheduled payments a month.
    static func loanPayments(_ loans: [Loan]) -> Int {
        loans.filter { !$0.isPaidOff }.reduce(0) { $0 + max($1.paymentCents, 0) }
    }

    /// This month's budgets with their plans (spending doesn't matter here).
    static func budgets(_ categories: [BudgetCategory], month: MonthSpan = MonthSpan(containing: .now)) -> [CategoryStatus] {
        BudgetMath.statuses(categories.map(\.record), entries: [], in: month)
    }

    static func runway(
        categories: [BudgetCategory],
        accounts: [Account],
        loans: [Loan],
        stashes: [Stash],
        entries: [EntryRecord],
        settings: PlanningSettings = .shared
    ) -> Runway {
        let essentials = RunwayMath.essentials(
            budgets: budgets(categories),
            loanPaymentsCents: settings.loansAreEssential ? loanPayments(loans) : 0,
            stashes: stashes.filter { !$0.isArchived }.map(\.record)
        )
        return Runway(
            savedCents: saved(self.accounts(accounts, entries: entries)),
            essentialsCents: essentials,
            goalMonths: settings.runwayGoalMonths
        )
    }

    /// The same, fetched from the store (Ask).
    static func runway(in context: ModelContext) -> Runway {
        runway(
            categories: (try? context.fetch(FetchDescriptor<BudgetCategory>())) ?? [],
            accounts: (try? context.fetch(FetchDescriptor<Account>())) ?? [],
            loans: (try? context.fetch(FetchDescriptor<Loan>())) ?? [],
            stashes: (try? context.fetch(FetchDescriptor<Stash>())) ?? [],
            entries: ((try? context.fetch(FetchDescriptor<LedgerEntry>())) ?? []).map(\.record)
        )
    }

    /// "5.1" (or "99+"). Nil when nothing is essential yet.
    static func monthsText(_ runway: Runway) -> String? {
        guard let months = runway.months else { return nil }
        return months >= 100 ? "99+" : months.formatted(.number.precision(.fractionLength(1)))
    }
}
