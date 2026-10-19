import Foundation
import Testing
@testable import Suffice

/// Splitting one charge across budgets: the parts' arithmetic, and budgets counting only their
/// part of a split charge.
struct SplitMathTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        return calendar
    }()

    func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    var october: MonthSpan { MonthSpan(containing: date(2026, 10, 13), calendar: calendar) }

    let food = UUID()
    let home = UUID()
    let fun = UUID()

    /// The Costco run from the designs: $214.37 across groceries, a shop vac and a gift card.
    var costco: [EntrySplit] {
        [
            EntrySplit(categoryID: food, amountCents: 142_10),
            EntrySplit(categoryID: home, amountCents: 48_27),
            EntrySplit(categoryID: fun, amountCents: 24_00),
        ]
    }

    // MARK: Parts

    @Test func remainingIsWhatsLeftToAssign() {
        #expect(SplitMath.remaining(total: 214_37, parts: costco) == 0)
        #expect(SplitMath.remaining(total: 214_37, parts: Array(costco.prefix(2))) == 24_00)
        #expect(SplitMath.remaining(total: 200_00, parts: costco) == -14_37)
    }

    @Test func evenSharesGiveTheOddCentsToTheLast() {
        #expect(SplitMath.evenly(total: 214_37, count: 3) == [71_45, 71_45, 71_47])
        #expect(SplitMath.evenly(total: 100, count: 0) == [])
    }

    @Test func theBiggestPartIsTheCategoryItShowsAs() {
        #expect(SplitMath.primaryCategory(costco) == food)
        #expect(SplitMath.primaryCategory([]) == nil)
    }

    @Test func emptyPartsDropAndOnePartIsNoSplit() {
        let withEmpty = costco + [EntrySplit(categoryID: nil, amountCents: 0)]
        #expect(SplitMath.cleaned(withEmpty).count == 3)
        #expect(SplitMath.cleaned([EntrySplit(categoryID: food, amountCents: 10_00), EntrySplit(categoryID: home, amountCents: 0)]).isEmpty)
    }

    @Test func aChangedAmountLandsOnTheLastPart() {
        // A $5 tip added after splitting.
        let up = SplitMath.rebalanced(costco, total: 219_37)
        #expect(up.map(\.amountCents) == [142_10, 48_27, 29_00])
        // $30 off: the last part runs out and the one before takes the rest.
        let down = SplitMath.rebalanced(costco, total: 184_37)
        #expect(down.map(\.amountCents) == [142_10, 42_27])
        // Down to less than the first part: no split left.
        #expect(SplitMath.rebalanced(costco, total: 100_00).isEmpty)
    }

    @Test func receiptItemsAreScaledToTheCharge() {
        // Items read: $130 groceries, $45 shop vac, $22 gift card = $197; the charge with tax is
        // $214.37, so each part grows by the same share and the cents land on the biggest.
        let parts = SplitMath.fromItems([
            (food, 100_00), (home, 45_00), (food, 30_00), (fun, 22_00),
        ], total: 214_37)
        #expect(parts.map(\.categoryID) == [food, home, fun])
        #expect(parts.reduce(0) { $0 + $1.amountCents } == 214_37)
        #expect(parts.map(\.amountCents) == [141_46, 48_97, 23_94])
    }

    // MARK: Budgets

    @Test func eachBudgetCountsOnlyItsPart() {
        let foodBudget = CategoryRecord(id: food, name: "Food", limitCents: 1_010_00)
        let homeBudget = CategoryRecord(id: home, name: "Home", limitCents: 2_235_00, sortOrder: 1)
        let funBudget = CategoryRecord(id: fun, name: "Entertainment", limitCents: 245_00, sortOrder: 2)
        let entry = EntryRecord(date: date(2026, 10, 12), amountCents: 214_37, categoryID: food, splits: costco)
        let statuses = BudgetMath.statuses([foodBudget, homeBudget, funBudget], entries: [entry], in: october, calendar: calendar)
        #expect(statuses.map(\.spentCents) == [142_10, 48_27, 24_00])
        let totals = BudgetMath.totals([foodBudget, homeBudget, funBudget], entries: [entry], in: october, calendar: calendar)
        #expect(totals.spentCents == 214_37)
        #expect(totals.uncategorizedCents == 0)
        #expect(entry.cents(in: [home]) == 48_27)
    }

    @Test func aPartWithoutABudgetIsUncategorized() {
        let foodBudget = CategoryRecord(id: food, name: "Food", limitCents: 500_00)
        let entry = EntryRecord(date: date(2026, 10, 12), amountCents: 60_00, categoryID: food, splits: [
            EntrySplit(categoryID: food, amountCents: 40_00),
            EntrySplit(categoryID: nil, amountCents: 20_00),
        ])
        let totals = BudgetMath.totals([foodBudget], entries: [entry], in: october, calendar: calendar)
        #expect(totals.uncategorizedCents == 20_00)
    }
}
