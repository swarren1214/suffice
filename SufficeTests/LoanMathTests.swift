import Foundation
import Testing
@testable import Suffice

/// Loans and net worth. Every figure on Net Worth, Debts, a loan's page and Payoff Plan comes
/// from these. The expected numbers were worked out independently, month by month, with the
/// same rule: interest is the balance times the monthly rate, rounded to the cent.
struct LoanMathTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        return calendar
    }()

    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// $385,000 at 6.25% for 30 years, first payment July 1, 2021.
    var mortgage: LoanRecord {
        LoanRecord(
            originalCents: 385_000_00,
            annualRate: 6.25,
            termMonths: 360,
            firstPaymentDate: date(2021, 7, 1),
            paymentCents: 2_370_52,
            balanceCents: 385_000_00,
            balanceDate: date(2021, 6, 15)
        )
    }

    var today: Date { date(2026, 10, 19) }

    // MARK: Payments

    @Test func paymentPaysTheLoanOffWithinItsTerm() {
        let payment = LoanMath.payment(principalCents: 385_000_00, annualRate: 6.25, months: 360)
        #expect(payment == 2_370_52)
        let schedule = LoanMath.schedule(balanceCents: 385_000_00, annualRate: 6.25, paymentCents: payment, firstDue: date(2021, 7, 1), calendar: calendar)
        #expect(schedule.months == 360)
        #expect(!schedule.neverPaysOff)
        #expect(schedule.rows.reduce(0) { $0 + $1.principalCents } == 385_000_00)
        #expect(schedule.rows.first?.interestCents == 2_005_21)
        #expect(schedule.rows.last?.balanceCents == 0)
    }

    @Test func zeroPercentSplitsTheAmountEvenly() {
        #expect(LoanMath.payment(principalCents: 120_000_00, annualRate: 0, months: 12) == 10_000_00)
        let schedule = LoanMath.schedule(balanceCents: 120_000_00, annualRate: 0, paymentCents: 10_000_00, firstDue: date(2026, 1, 1), calendar: calendar)
        #expect(schedule.months == 12)
        #expect(schedule.totalInterestCents == 0)
    }

    @Test func aPaymentThatDoesntCoverInterestNeverPaysOff() {
        // $1,925 a month of interest on $385,000 at 6%, and only $1,500 paid.
        let schedule = LoanMath.schedule(balanceCents: 385_000_00, annualRate: 6, paymentCents: 1_500_00, firstDue: date(2026, 1, 1), calendar: calendar)
        #expect(schedule.neverPaysOff)
        #expect(schedule.payoffDate == nil)
    }

    // MARK: Dates

    @Test func dueDatesComeBackToTheEndOfTheMonth() {
        let first = date(2026, 1, 31)
        #expect(calendar.component(.day, from: LoanMath.dueDate(1, first: first, calendar: calendar)) == 28)
        #expect(calendar.component(.day, from: LoanMath.dueDate(2, first: first, calendar: calendar)) == 31)
    }

    @Test func countsThePaymentsDueSinceTheBalanceWasSet() {
        // July 2021 through October 2026.
        #expect(LoanMath.paymentsDue(first: date(2021, 7, 1), after: date(2021, 6, 15), through: today, calendar: calendar) == 64)
        let next = LoanMath.nextDueDate(first: date(2021, 7, 1), after: today, calendar: calendar)
        #expect(calendar.dateComponents([.year, .month, .day], from: next) == DateComponents(year: 2026, month: 11, day: 1))
    }

    // MARK: Balances

    @Test func theBalanceComesDownWithEachScheduledPayment() {
        #expect(LoanMath.currentBalance(mortgage, on: today, calendar: calendar) == 357_336_42)
        #expect(LoanMath.interestPaid(mortgage, through: today, calendar: calendar) == 124_049_70)
    }

    @Test func aNewerBalanceStartsTheCountAgain() {
        var loan = mortgage
        loan.balanceCents = 350_000_00
        loan.balanceDate = date(2026, 10, 5)
        // No payment has come due since the 5th.
        #expect(LoanMath.currentBalance(loan, on: today, calendar: calendar) == 350_000_00)
    }

    @Test func aPaidOffLoanOwesNothing() {
        var loan = mortgage
        loan.isPaidOff = true
        #expect(LoanMath.currentBalance(loan, on: today, calendar: calendar) == 0)
    }

    @Test func paidShareStaysBetweenZeroAndOne() {
        #expect(LoanMath.paidShare(originalCents: 0, balanceCents: 100) == 0)
        #expect(LoanMath.paidShare(originalCents: 100_00, balanceCents: 25_00) == 0.75)
        #expect(LoanMath.paidShare(originalCents: 100_00, balanceCents: 120_00) == 0)
    }

    // MARK: Payoff Plan

    @Test func theScheduleAsItStands() {
        let comparison = LoanMath.compare(mortgage, options: PayoffOptions(), from: today, calendar: calendar)
        #expect(comparison.balanceCents == 357_336_42)
        #expect(comparison.scheduled.months == 296)
        #expect(comparison.scheduled.totalInterestCents == 344_328_05)
        #expect(comparison.monthsSaved == 0)
        #expect(comparison.interestSavedCents == 0)
        let payoff = comparison.scheduled.payoffDate.map { calendar.dateComponents([.year, .month], from: $0) }
        #expect(payoff == DateComponents(year: 2051, month: 6))
    }

    @Test func extraEachMonthPaysItOffSooner() {
        let comparison = LoanMath.compare(mortgage, options: PayoffOptions(extraMonthlyCents: 250_00), from: today, calendar: calendar)
        #expect(comparison.monthlyCents == 2_620_52)
        #expect(comparison.plan.months == 239)
        #expect(comparison.monthsSaved == 57)
        #expect(comparison.plan.totalInterestCents == 267_480_10)
        #expect(comparison.interestSavedCents == 344_328_05 - 267_480_10)
    }

    @Test func aLumpSumAndBiweeklyPayments() {
        let options = PayoffOptions(lumpSumCents: 10_000_00, biweekly: true)
        let comparison = LoanMath.compare(mortgage, options: options, from: today, calendar: calendar)
        // A thirteenth payment a year, spread across the twelve.
        #expect(comparison.monthlyCents == 2_370_52 + 197_54)
        #expect(comparison.plan.months == 235)
        #expect(comparison.plan.totalInterestCents == 255_220_56)
    }

    @Test func aRefinanceKeepsTheTimeLeft() {
        let comparison = LoanMath.compare(mortgage, options: PayoffOptions(annualRate: 5), from: today, calendar: calendar)
        #expect(comparison.requiredPaymentCents == 2_103_17)
        #expect(comparison.plan.months == 296)
        #expect(comparison.plan.totalInterestCents == 265_200_83)
    }

    @Test func yearsAddUpToTheSchedule() {
        let projection = LoanMath.projection(mortgage, from: today, calendar: calendar)
        let years = projection.years(calendar: calendar)
        #expect(years.first?.year == 2026)
        #expect(years.last?.year == 2051)
        #expect(years.reduce(0) { $0 + $1.principalCents } == 357_336_42)
        #expect(years.reduce(0) { $0 + $1.interestCents } == projection.totalInterestCents)
        #expect(years.last?.balanceCents == 0)
    }

    @Test func aSavedExtraShowsInTheProjection() {
        var loan = mortgage
        loan.extraMonthlyCents = 250_00
        #expect(LoanMath.projection(loan, from: today, calendar: calendar).months == 239)
        #expect(LoanMath.projection(loan, from: today, includeSavedExtra: false, calendar: calendar).months == 296)
    }

    // MARK: Net worth

    @Test func netWorthCountsEveryAccountAssetCardAndLoan() {
        let set = date(2026, 10, 1)
        let checking = AccountRecord(kind: .checking, balanceCents: 1_000_00, balanceDate: set, includeInBudget: false, isManual: true)
        let manualCard = AccountRecord(kind: .credit, balanceCents: 500_00, balanceDate: set, isManual: true)
        let bankCard = AccountRecord(kind: .credit, balanceCents: 300_00, balanceDate: set, isManual: false)
        let entries = [
            EntryRecord(date: date(2026, 10, 5), amountCents: 200_00, kind: .expense, accountID: checking.id),
            EntryRecord(date: date(2026, 10, 6), amountCents: 100_00, kind: .expense, accountID: manualCard.id),
            // Before the card's balance was set: already in it.
            EntryRecord(date: date(2026, 9, 20), amountCents: 999_00, kind: .expense, accountID: manualCard.id),
        ]
        let totals = NetWorthMath.totals(accounts: [checking, manualCard, bankCard], entries: entries, assetCents: [10_000_00], loanCents: [5_000_00])
        // $800 checking (left out of the budget, still owned) and a $10,000 asset.
        #expect(totals.assetsCents == 10_800_00)
        // $600 and $300 on the cards and a $5,000 loan.
        #expect(totals.debtsCents == 5_900_00)
        #expect(totals.netCents == 4_900_00)
    }

    @Test func anOverdrawnAccountCountsAsOwed() {
        let checking = AccountRecord(kind: .checking, balanceCents: -50_00, balanceDate: .distantPast, isManual: false)
        let totals = NetWorthMath.totals(accounts: [checking], entries: [], assetCents: [], loanCents: [])
        #expect(totals.assetsCents == 0)
        #expect(totals.debtsCents == 50_00)
    }
}
