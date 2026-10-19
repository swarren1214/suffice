import Foundation

// The arithmetic behind Net Worth, Debts, a loan's schedule and Payoff Plan. Pure functions on
// plain values, so the tests can pin every number (SufficeTests/LoanMathTests.swift).
//
// Money stays in whole cents. Each month's interest is the balance times the monthly rate,
// rounded to the cent, as lenders do; the payment pays that interest first and the rest comes
// off the principal. The last payment is only what's left.

/// One payment in a schedule.
nonisolated struct AmortizationRow: Hashable, Sendable, Identifiable {
    /// 0 for the first payment in the schedule.
    var index: Int
    var date: Date
    var principalCents: Int
    var interestCents: Int
    /// Owed after this payment.
    var balanceCents: Int

    var id: Int { index }
    var paymentCents: Int { principalCents + interestCents }
}

/// A year of a schedule, for the yearly view and chart.
nonisolated struct AmortizationYear: Hashable, Sendable, Identifiable {
    var year: Int
    var principalCents: Int
    var interestCents: Int
    /// Owed after the year's last payment.
    var balanceCents: Int

    var id: Int { year }
}

/// Where a run of payments ends up.
nonisolated struct LoanProjection: Hashable, Sendable {
    var rows: [AmortizationRow]
    /// The payment doesn't cover the interest, so the loan would never be paid off.
    var neverPaysOff: Bool = false

    var months: Int { rows.count }
    var totalInterestCents: Int { rows.reduce(0) { $0 + $1.interestCents } }
    var payoffDate: Date? { neverPaysOff ? nil : rows.last?.date }

    func years(calendar: Calendar = .current) -> [AmortizationYear] {
        var years: [AmortizationYear] = []
        for row in rows {
            let year = calendar.component(.year, from: row.date)
            if years.last?.year == year {
                years[years.count - 1].principalCents += row.principalCents
                years[years.count - 1].interestCents += row.interestCents
                years[years.count - 1].balanceCents = row.balanceCents
            } else {
                years.append(AmortizationYear(year: year, principalCents: row.principalCents, interestCents: row.interestCents, balanceCents: row.balanceCents))
            }
        }
        return years
    }
}

/// What someone tries in Payoff Plan.
nonisolated struct PayoffOptions: Hashable, Sendable {
    /// Paid on top of the scheduled payment every month.
    var extraMonthlyCents = 0
    /// Paid once, now, straight to principal.
    var lumpSumCents = 0
    /// Half the payment every two weeks: 26 halves, so one extra payment a year.
    var biweekly = false
    /// A refinance to this rate over the same time left. Nil keeps the loan's rate.
    var annualRate: Double?
}

/// A plan next to the schedule as it stands.
nonisolated struct PayoffComparison: Hashable, Sendable {
    var balanceCents: Int
    var scheduled: LoanProjection
    var plan: LoanProjection
    /// The scheduled payment, or the new one after a refinance.
    var requiredPaymentCents: Int
    /// Everything paid each month under the plan.
    var monthlyCents: Int

    var monthsSaved: Int { scheduled.months - plan.months }
    var interestSavedCents: Int { max(scheduled.totalInterestCents - plan.totalInterestCents, 0) }
}

nonisolated enum LoanMath {
    /// The monthly payment that pays `principalCents` off in `months` at `annualRate` percent.
    static func payment(principalCents: Int, annualRate: Double, months: Int) -> Int {
        guard principalCents > 0 else { return 0 }
        guard months > 0 else { return principalCents }
        let rate = annualRate / 1200
        guard rate > 0 else { return Int((Double(principalCents) / Double(months)).rounded(.up)) }
        let payment = Double(principalCents) * rate / (1 - pow(1 + rate, -Double(months)))
        // Rounded up to the cent, so the last payment lands within the term rather than a
        // month past it (the tiny allowance keeps float noise from adding a cent).
        return Int((payment - 0.000_001).rounded(.up))
    }

    /// Payment `index`'s due date, counting from the first (index 0). Always counted from the
    /// first, so a loan due on the 31st comes back to the 31st after a short month.
    static func dueDate(_ index: Int, first: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .month, value: index, to: first) ?? first
    }

    /// How many payments came due after `after` up to and including `through`.
    static func paymentsDue(first: Date, after: Date, through: Date, calendar: Calendar = .current) -> Int {
        guard through > after else { return 0 }
        var count = 0
        var index = 0
        while index < 1_200 {
            let due = dueDate(index, first: first, calendar: calendar)
            if due > through { break }
            if due > after { count += 1 }
            index += 1
        }
        return count
    }

    /// The first payment due after `date`.
    static func nextDueDate(first: Date, after date: Date, calendar: Calendar = .current) -> Date {
        var index = 0
        while index < 1_200 {
            let due = dueDate(index, first: first, calendar: calendar)
            if due > date { return due }
            index += 1
        }
        return dueDate(index, first: first, calendar: calendar)
    }

    /// One month's interest on a balance, rounded to the cent.
    static func monthlyInterest(onCents balance: Int, annualRate: Double) -> Int {
        Int((Double(balance) * annualRate / 1200).rounded())
    }

    /// `payments` scheduled payments from a balance: what's left and the interest paid.
    static func amortize(fromCents balance: Int, annualRate: Double, paymentCents: Int, payments: Int) -> (balanceCents: Int, interestCents: Int) {
        var owed = balance
        var interestPaid = 0
        for _ in 0..<max(payments, 0) {
            guard owed > 0 else { break }
            let interest = monthlyInterest(onCents: owed, annualRate: annualRate)
            guard paymentCents > interest else {
                // The payment doesn't cover the interest: the balance doesn't come down.
                interestPaid += min(paymentCents, interest)
                continue
            }
            interestPaid += interest
            owed -= min(paymentCents - interest, owed)
        }
        return (owed, interestPaid)
    }

    /// Owed on `date`: the balance last set, less the scheduled payments due since.
    static func currentBalance(_ loan: LoanRecord, on date: Date = .now, calendar: Calendar = .current) -> Int {
        guard !loan.isPaidOff else { return 0 }
        let payments = paymentsDue(first: loan.firstPaymentDate, after: loan.balanceDate, through: date, calendar: calendar)
        return amortize(fromCents: loan.balanceCents, annualRate: loan.annualRate, paymentCents: loan.paymentCents, payments: payments).balanceCents
    }

    /// What the schedule says is owed on `date`, from the original amount. The editor offers it
    /// when someone doesn't know today's balance.
    static func scheduledBalance(originalCents: Int, annualRate: Double, paymentCents: Int, firstPaymentDate: Date, on date: Date = .now, calendar: Calendar = .current) -> Int {
        let payments = paymentsDue(first: firstPaymentDate, after: .distantPast, through: date, calendar: calendar)
        return amortize(fromCents: originalCents, annualRate: annualRate, paymentCents: paymentCents, payments: payments).balanceCents
    }

    /// Interest paid from the first payment through `date`, by the schedule.
    static func interestPaid(_ loan: LoanRecord, through date: Date = .now, calendar: Calendar = .current) -> Int {
        let payments = paymentsDue(first: loan.firstPaymentDate, after: .distantPast, through: date, calendar: calendar)
        return amortize(fromCents: loan.originalCents, annualRate: loan.annualRate, paymentCents: loan.paymentCents, payments: payments).interestCents
    }

    /// Interest on the payments due in calendar `year`, by the schedule from the original
    /// amount. Tax Year shows it as an estimate: the lender's Form 1098 is the official figure.
    static func interestPaid(_ loan: LoanRecord, inYear year: Int, calendar: Calendar = .current) -> Int {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let next = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else { return 0 }
        let endOfYear = next.addingTimeInterval(-1)
        let endOfLastYear = start.addingTimeInterval(-1)
        return max(interestPaid(loan, through: endOfYear, calendar: calendar) - interestPaid(loan, through: endOfLastYear, calendar: calendar), 0)
    }

    /// Every payment from `balanceCents` until it's paid off, the first due on `firstDue`.
    static func schedule(balanceCents: Int, annualRate: Double, paymentCents: Int, firstDue: Date, calendar: Calendar = .current, maxMonths: Int = 1_200) -> LoanProjection {
        var rows: [AmortizationRow] = []
        var owed = balanceCents
        var index = 0
        while owed > 0 && index < maxMonths {
            let interest = monthlyInterest(onCents: owed, annualRate: annualRate)
            guard paymentCents > interest else {
                return LoanProjection(rows: rows, neverPaysOff: true)
            }
            let principal = min(paymentCents - interest, owed)
            owed -= principal
            rows.append(AmortizationRow(index: index, date: dueDate(index, first: firstDue, calendar: calendar), principalCents: principal, interestCents: interest, balanceCents: owed))
            index += 1
        }
        return LoanProjection(rows: rows, neverPaysOff: owed > 0)
    }

    /// The rest of a loan from today, at its scheduled payment plus any saved extra.
    static func projection(_ loan: LoanRecord, from date: Date = .now, includeSavedExtra: Bool = true, calendar: Calendar = .current) -> LoanProjection {
        let balance = currentBalance(loan, on: date, calendar: calendar)
        let first = nextDueDate(first: loan.firstPaymentDate, after: date, calendar: calendar)
        let payment = loan.paymentCents + (includeSavedExtra ? loan.extraMonthlyCents : 0)
        return schedule(balanceCents: balance, annualRate: loan.annualRate, paymentCents: payment, firstDue: first, calendar: calendar)
    }

    /// The schedule as it stands next to a plan.
    static func compare(_ loan: LoanRecord, options: PayoffOptions, from date: Date = .now, calendar: Calendar = .current) -> PayoffComparison {
        let balance = currentBalance(loan, on: date, calendar: calendar)
        let first = nextDueDate(first: loan.firstPaymentDate, after: date, calendar: calendar)
        let scheduled = schedule(balanceCents: balance, annualRate: loan.annualRate, paymentCents: loan.paymentCents, firstDue: first, calendar: calendar)

        let rate = options.annualRate ?? loan.annualRate
        let required: Int
        if rate == loan.annualRate || scheduled.neverPaysOff {
            required = loan.paymentCents
        } else {
            // A refinance over the same time left.
            required = payment(principalCents: balance, annualRate: rate, months: scheduled.months)
        }
        let monthly = required + max(options.extraMonthlyCents, 0) + (options.biweekly ? Int((Double(required) / 12).rounded()) : 0)
        let plan = schedule(balanceCents: max(balance - max(options.lumpSumCents, 0), 0), annualRate: rate, paymentCents: monthly, firstDue: first, calendar: calendar)
        return PayoffComparison(balanceCents: balance, scheduled: scheduled, plan: plan, requiredPaymentCents: required, monthlyCents: monthly)
    }

    /// Of what was borrowed, how much is paid off: 0…1.
    static func paidShare(originalCents: Int, balanceCents: Int) -> Double {
        guard originalCents > 0 else { return 0 }
        return min(max(Double(originalCents - balanceCents) / Double(originalCents), 0), 1)
    }
}

// MARK: - Net worth

nonisolated struct NetWorthTotals: Hashable, Sendable {
    var assetsCents: Int
    var debtsCents: Int

    var netCents: Int { assetsCents - debtsCents }
}

nonisolated enum NetWorthMath {
    /// A credit card's balance owed. A bank-synced card reports it; a manual one moves with
    /// what's filed to it after its balance was set (spending adds, payments and refunds take off).
    static func owed(onCard account: AccountRecord, entries: [EntryRecord]) -> Int {
        guard account.isManual else { return max(account.balanceCents, 0) }
        let moved = entries
            .filter { $0.accountID == account.id && $0.date >= account.balanceDate }
            .reduce(0) { $0 - $1.signedCents }
        return max(account.balanceCents + moved, 0)
    }

    /// Every account (in the budget or not), every asset, every card and loan that isn't paid off.
    static func totals(accounts: [AccountRecord], entries: [EntryRecord], assetCents: [Int], loanCents: [Int]) -> NetWorthTotals {
        var assets = assetCents.reduce(0, +)
        var debts = loanCents.reduce(0, +)
        for account in accounts {
            if account.kind == .credit {
                debts += owed(onCard: account, entries: entries)
            } else {
                // An overdrawn account is a debt, not a negative asset.
                let balance = BudgetMath.balance(of: account, entries: entries)
                if balance >= 0 { assets += balance } else { debts += -balance }
            }
        }
        return NetWorthTotals(assetsCents: assets, debtsCents: debts)
    }
}
