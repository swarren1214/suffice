import Foundation
import Testing
@testable import Suffice

/// Stashes: the monthly amount, what's stashed, where a stash stands, the next yearly cycle,
/// and how a bill paid from a stash and the month's stash amounts show in the budget. The
/// figures are the Planning prototype's, from October 19, 2026.
struct StashMathTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        return calendar
    }()

    func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func monthStart(_ year: Int, _ month: Int) -> Date {
        MonthSpan(containing: date(year, month, 1), calendar: calendar).start
    }

    var today: Date { date(2026, 10, 19) }
    var october: MonthSpan { MonthSpan(containing: today, calendar: calendar) }

    // MARK: The monthly amount

    @Test func homeInsuranceIsFiveMonthsAt276() {
        let left = StashMath.monthsLeft(from: today, due: date(2027, 3, 15), calendar: calendar)
        #expect(left == 5)
        #expect(StashMath.monthly(targetCents: 1_380_00, savedCents: 0, monthsLeft: left) == 276_00)
    }

    @Test func whatsAlreadyStashedComesOff() {
        let left = StashMath.monthsLeft(from: today, due: date(2026, 12, 15), calendar: calendar)
        #expect(left == 2)
        #expect(StashMath.monthly(targetCents: 1_200_00, savedCents: 900_00, monthsLeft: left) == 150_00)
    }

    @Test func roundsUpToTheDollar() {
        let left = StashMath.monthsLeft(from: today, due: date(2027, 6, 20), calendar: calendar)
        #expect(left == 8)
        #expect(StashMath.monthly(targetCents: 504_00, savedCents: 126_00, monthsLeft: left) == 48_00)
    }

    @Test func dueThisMonthStillAsksForTheRest() {
        #expect(StashMath.monthsLeft(from: today, due: date(2026, 10, 30), calendar: calendar) == 1)
        #expect(StashMath.monthly(targetCents: 300_00, savedCents: 300_00, monthsLeft: 1) == 0)
        #expect(StashMath.monthly(targetCents: 300_00, savedCents: 400_00, monthsLeft: 3) == 0)
    }

    @Test func theNextYearlyCycleIsTheTargetOverTwelve() {
        let next = StashMath.nextCycle(after: date(2027, 3, 15), targetCents: 1_380_00, calendar: calendar)
        #expect(next.monthlyCents == 115_00)
        #expect(calendar.dateComponents([.year, .month, .day], from: next.dueDate) == DateComponents(year: 2028, month: 3, day: 15))
        // Anything left over carries forward.
        #expect(StashMath.nextCycle(after: date(2027, 3, 15), targetCents: 1_380_00, leftoverCents: 120_00, calendar: calendar).monthlyCents == 105_00)
    }

    // MARK: Balance and status

    var christmas: StashRecord {
        StashRecord(name: "Christmas", targetCents: 1_200_00, dueDate: date(2026, 12, 15), openingCents: 750_00, createdAt: date(2026, 6, 2))
    }

    @Test func balanceIsOpeningPlusMovesLessPayments() {
        let stash = christmas
        let moves = [StashMoveRecord(stashID: stash.id, month: monthStart(2026, 10), amountCents: 150_00)]
        let paid = EntryRecord(date: date(2026, 12, 10), amountCents: 80_00, stashID: stash.id, stashCents: 80_00)
        #expect(StashMath.balance(of: stash, moves: moves, entries: []) == 900_00)
        #expect(StashMath.balance(of: stash, moves: moves, entries: [paid]) == 820_00)
    }

    @Test func countedThisMonthIsOnTrack() {
        let stash = christmas
        let moves = [StashMoveRecord(stashID: stash.id, month: monthStart(2026, 10), amountCents: 150_00)]
        let summary = StashMath.summary(stash, moves: moves, entries: [], today: today, calendar: calendar)
        #expect(summary.balanceCents == 900_00)
        #expect(summary.status == .onTrack)
        #expect(summary.monthlyCents == 150_00)
        #expect(summary.monthsLeft == 2)
        #expect(summary.thisMonthCents == 150_00)
    }

    @Test func notCountedThisMonthIsBehindByThisMonthsAmount() {
        let stash = christmas
        let summary = StashMath.summary(stash, moves: [], entries: [], today: today, calendar: calendar)
        // $450 still needed over October, November and December.
        #expect(summary.status == .behind(cents: 150_00))
        #expect(summary.status.label == "Behind $150")
    }

    @Test func aNewStashStartsOnTheNextFirst() {
        let stash = StashRecord(name: "Home insurance", targetCents: 1_380_00, dueDate: date(2027, 3, 15), createdAt: today)
        let summary = StashMath.summary(stash, moves: [], entries: [], today: today, calendar: calendar)
        #expect(summary.status == .onTrack)
        #expect(summary.monthlyCents == 276_00)
        #expect(summary.monthsLeft == 5)
    }

    @Test func coveringTheTargetIsFullyStashed() {
        let stash = StashRecord(name: "Tires", targetCents: 600_00, dueDate: date(2027, 4, 1), openingCents: 600_00, createdAt: date(2026, 1, 5))
        let summary = StashMath.summary(stash, moves: [], entries: [], today: today, calendar: calendar)
        #expect(summary.status == .funded)
        #expect(summary.monthlyCents == 0)
    }

    // MARK: Counting the 1st

    @Test func countsEveryFirstSinceTheLastOneThroughTheDueMonth() {
        let stash = StashRecord(name: "Registration", targetCents: 504_00, dueDate: date(2027, 1, 20), createdAt: date(2026, 7, 9))
        let months = StashMath.monthsToCount(stash, lastCounted: monthStart(2026, 8), today: today, calendar: calendar)
        #expect(months == [monthStart(2026, 9), monthStart(2026, 10)])
        // Nothing past the due month, and nothing for the month it was made.
        let late = StashMath.monthsToCount(stash, lastCounted: nil, today: date(2027, 4, 2), calendar: calendar)
        #expect(late.first == monthStart(2026, 8))
        #expect(late.last == monthStart(2027, 1))
    }

    @Test func eachMonthsAmountComesFromWhatWasStashedBefore() {
        let stash = StashRecord(name: "Home insurance", targetCents: 1_380_00, dueDate: date(2027, 3, 15), createdAt: today)
        #expect(StashMath.amount(for: stash, month: monthStart(2026, 11), balanceBefore: 0, calendar: calendar) == 276_00)
        #expect(StashMath.amount(for: stash, month: monthStart(2027, 3), balanceBefore: 1_104_00, calendar: calendar) == 276_00)
        #expect(StashMath.amount(for: stash, month: monthStart(2027, 4), balanceBefore: 1_380_00, calendar: calendar) == 0)
    }

    @Test func twoDevicesCountingTheSameFirstFoldIntoOne() {
        let stash = UUID()
        let moves = [
            StashMoveRecord(stashID: stash, month: monthStart(2026, 11), amountCents: 276_00),
            StashMoveRecord(stashID: stash, month: monthStart(2026, 11), amountCents: 276_00),
            StashMoveRecord(stashID: stash, month: monthStart(2026, 12), amountCents: 276_00),
        ]
        let groups = StashMath.duplicateGroups(moves, calendar: calendar)
        #expect(groups.count == 1)
        #expect(groups.first?.count == 2)
    }

    // MARK: The budget

    @Test func aBillPaidFromAStashCountsOnlyTheShortfall() {
        let home = UUID()
        let homeBudget = CategoryRecord(id: home, name: "Home", limitCents: 2_235_00)
        let stash = UUID()
        let covered = StashMath.covered(paymentCents: 1_380_00, balanceCents: 1_000_00)
        #expect(covered == 1_000_00)
        let payment = EntryRecord(date: date(2027, 3, 14), amountCents: 1_380_00, categoryID: home, stashID: stash, stashCents: covered)
        let march = MonthSpan(containing: date(2027, 3, 14), calendar: calendar)
        let statuses = BudgetMath.statuses([homeBudget], entries: [payment], in: march, calendar: calendar)
        #expect(statuses.first?.spentCents == 380_00)
        #expect(BudgetMath.totals([homeBudget], entries: [payment], in: march, calendar: calendar).spentCents == 380_00)
    }

    @Test func leftToSpendTakesOffWhatsStashed() {
        let budget = CategoryRecord(name: "Everything", limitCents: 4_869_00)
        let spent = EntryRecord(date: date(2026, 10, 12), amountCents: 3_071_06, categoryID: budget.id)
        let before = BudgetMath.totals([budget], entries: [spent], in: october, calendar: calendar)
        #expect(before.leftCents == 1_797_94)
        let moves = [
            StashMoveRecord(stashID: UUID(), month: october.start, amountCents: 150_00),
            StashMoveRecord(stashID: UUID(), month: october.start, amountCents: 48_00),
            StashMoveRecord(stashID: UUID(), month: october.start, amountCents: 52_00),
            // Another month's doesn't count.
            StashMoveRecord(stashID: UUID(), month: october.offset(by: -1, calendar: calendar).start, amountCents: 52_00),
        ]
        let after = BudgetMath.totals([budget], entries: [spent], in: october, stashMoves: moves, calendar: calendar)
        #expect(after.stashedCents == 250_00)
        #expect(after.leftCents == 1_547_94)
    }

    // MARK: Suggestions

    @Test func suggestsRareBillsWithTimeToStash() {
        var insurance = BillRecord(name: "State Farm", amountCents: 1_380_00, dueDay: 15)
        insurance.frequency = .yearly
        insurance.startDate = date(2026, 3, 15)
        var soon = BillRecord(name: "Registration", amountCents: 186_00, dueDay: 20)
        soon.frequency = .yearly
        soon.startDate = date(2025, 11, 20)
        let monthly = BillRecord(name: "Phone", amountCents: 161_06, dueDay: 14)
        let suggestions = StashMath.suggestions(bills: [insurance, soon, monthly], stashes: [], today: today, calendar: calendar)
        // November 20 is one 1st away: too soon to stash for.
        #expect(suggestions.map(\.name) == ["State Farm"])
        #expect(suggestions.first?.monthlyCents == 276_00)
        #expect(suggestions.first?.afterCents == 115_00)
        #expect(suggestions.first?.monthsLeft == 5)

        let stashed = StashRecord(targetCents: 1_380_00, dueDate: date(2027, 3, 15), billID: insurance.id)
        #expect(StashMath.suggestions(bills: [insurance], stashes: [stashed], today: today, calendar: calendar).isEmpty)
        #expect(StashMath.suggestions(bills: [insurance], stashes: [], dismissed: [insurance.id], today: today, calendar: calendar).isEmpty)
    }
}
