import Foundation
import Testing
@testable import Suffice

/// The emergency fund: months of essentials, the gap to the goal, and which amounts count as
/// essentials. The figures are the Planning prototype's sample household.
struct RunwayMathTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        return calendar
    }()

    var october: MonthSpan {
        MonthSpan(containing: calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 12))!, calendar: calendar)
    }

    @Test func monthsGapAndMonthlyToClose() throws {
        let runway = Runway(savedCents: 24_150_00, essentialsCents: 4_774_00, goalMonths: 6)
        let months = try #require(runway.months)
        #expect((months * 100).rounded() == 506)
        #expect(runway.gapCents == 4_494_00)
        #expect(runway.monthlyToCloseCents == 374_50)
        #expect(runway.overCents == 0)
    }

    @Test func pastTheGoal() {
        let runway = Runway(savedCents: 32_000_00, essentialsCents: 4_774_00, goalMonths: 6)
        #expect(runway.gapCents == 0)
        #expect(runway.overCents == 3_356_00)
        #expect(runway.monthlyToCloseCents == 0)
    }

    @Test func nothingEssentialHasNoNumber() {
        #expect(Runway(savedCents: 24_150_00, essentialsCents: 0, goalMonths: 6).months == nil)
        #expect(RunwayMath.months(savedCents: 24_150_00, essentialsCents: 0) == nil)
    }

    @Test func aBudgetAndItsSubcategoryArentCountedTwice() {
        let food = CategoryRecord(name: "Food", limitCents: 1_010_00, isEssential: true)
        let groceries = CategoryRecord(name: "Groceries", limitCents: 600_00, parentID: food.id, isEssential: true)
        let fastFood = CategoryRecord(name: "Fast food", limitCents: 410_00, parentID: food.id, sortOrder: 1)
        let statuses = BudgetMath.statuses([food, groceries, fastFood], entries: [], in: october, calendar: calendar)
        #expect(RunwayMath.essentials(budgets: statuses, loanPaymentsCents: 0, stashes: []) == 1_010_00)
    }

    @Test func theSampleHouseholdsEssentials() {
        let home = CategoryRecord(name: "Home", limitCents: 2_235_00, sortOrder: 0, isEssential: true)
        let utilities = CategoryRecord(name: "Utilities", limitCents: 445_00, sortOrder: 1, isEssential: true)
        let food = CategoryRecord(name: "Food", limitCents: 1_010_00, sortOrder: 2)
        let groceries = CategoryRecord(name: "Groceries", limitCents: 600_00, parentID: food.id, isEssential: true)
        let fastFood = CategoryRecord(name: "Fast food", limitCents: 410_00, parentID: food.id, sortOrder: 1)
        let auto = CategoryRecord(name: "Auto", limitCents: 384_00, sortOrder: 3, isEssential: true)
        let fun = CategoryRecord(name: "Entertainment", limitCents: 245_00, sortOrder: 4)
        let statuses = BudgetMath.statuses([home, utilities, food, groceries, fastFood, auto, fun], entries: [], in: october, calendar: calendar)
        var insurance = StashRecord(name: "Home insurance", targetCents: 1_380_00, dueDate: .now)
        insurance.isEssential = true
        let christmas = StashRecord(name: "Christmas", targetCents: 1_200_00, dueDate: .now)
        #expect(RunwayMath.monthlyShare(of: insurance) == 115_00)
        #expect(RunwayMath.essentials(budgets: statuses, loanPaymentsCents: 995_00, stashes: [insurance, christmas]) == 4_774_00)
    }

    @Test func startingEssentials() {
        #expect(BudgetCategory.essentialByDefault("Home"))
        #expect(BudgetCategory.essentialByDefault("groceries"))
        #expect(!BudgetCategory.essentialByDefault("Fast food"))
        #expect(!BudgetCategory.essentialByDefault("Giving"))
    }
}
