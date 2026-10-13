import Foundation
import Testing
@testable import Suffice

/// The budget's arithmetic. Every number on Overview, Budget and Bills comes from these.
struct BudgetMathTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        return calendar
    }()

    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    var october: MonthSpan { MonthSpan(containing: date(2026, 10, 13), calendar: calendar) }

    // MARK: Months

    @Test func monthSpanCoversTheWholeMonth() {
        #expect(october.contains(date(2026, 10, 1, 0)))
        #expect(october.contains(date(2026, 10, 31, 23)))
        #expect(!october.contains(date(2026, 11, 1, 0)))
        #expect(!october.contains(date(2026, 9, 30, 23)))
        #expect(october.days(calendar: calendar) == 31)
    }

    @Test func dueDayFallsOnTheLastDayOfShortMonths() {
        let february = MonthSpan(containing: date(2026, 2, 10), calendar: calendar)
        #expect(calendar.component(.day, from: february.dueDate(day: 31, calendar: calendar)) == 28)
        let leap = MonthSpan(containing: date(2028, 2, 10), calendar: calendar)
        #expect(calendar.component(.day, from: leap.dueDate(day: 30, calendar: calendar)) == 29)
    }

    // MARK: Budgets and subcategories

    @Test func aBudgetWithSubcategoriesAddsThemUp() {
        // The Home budget from the designs: Mortgage and Home improvements.
        let home = CategoryRecord(name: "Home", limitCents: 0)
        let mortgage = CategoryRecord(name: "Mortgage", limitCents: 2_201_79, parentID: home.id)
        let improvements = CategoryRecord(name: "Home improvements", limitCents: 748_21, parentID: home.id, sortOrder: 1)
        let entries = [
            EntryRecord(date: date(2026, 10, 1), amountCents: 2_201_79, categoryID: mortgage.id),
            EntryRecord(date: date(2026, 10, 4), amountCents: 149_27, categoryID: improvements.id),
        ]
        let statuses = BudgetMath.statuses([home, mortgage, improvements], entries: entries, in: october, calendar: calendar)
        #expect(statuses.count == 1)
        let line = statuses[0]
        #expect(line.limitCents == 2_950_00)
        #expect(line.spentCents == 2_351_06)
        #expect(line.leftCents == 598_94)
        #expect(line.children.map(\.category.name) == ["Mortgage", "Home improvements"])
        #expect(line.children[1].leftCents == 598_94)
    }

    @Test func spendingFiledToTheBudgetItselfCounts() {
        let food = CategoryRecord(name: "Food", limitCents: 0)
        let groceries = CategoryRecord(name: "Groceries", limitCents: 600_00, parentID: food.id)
        let entries = [
            EntryRecord(date: date(2026, 10, 2), amountCents: 20_00, categoryID: food.id),
            EntryRecord(date: date(2026, 10, 3), amountCents: 80_00, categoryID: groceries.id),
        ]
        let line = BudgetMath.statuses([food, groceries], entries: entries, in: october, calendar: calendar)[0]
        #expect(line.spentCents == 100_00)
        #expect(line.limitCents == 600_00)
    }

    @Test func totalsSeparateIncomeSpendingAndUncategorized() {
        let food = CategoryRecord(name: "Food", limitCents: 500_00)
        let home = CategoryRecord(name: "Home", limitCents: 2_000_00)
        let entries = [
            EntryRecord(date: date(2026, 10, 1), amountCents: 4_000_00, kind: .income),
            EntryRecord(date: date(2026, 10, 2), amountCents: 120_50, categoryID: food.id),
            EntryRecord(date: date(2026, 10, 3), amountCents: 2_000_00, categoryID: home.id),
            EntryRecord(date: date(2026, 10, 4), amountCents: 30_00),
            EntryRecord(date: date(2026, 10, 5), amountCents: 10_00, categoryID: UUID()), // deleted category
            EntryRecord(date: date(2026, 9, 30), amountCents: 999_00, categoryID: food.id), // last month
        ]
        let totals = BudgetMath.totals([food, home], entries: entries, in: october, calendar: calendar)
        #expect(totals.incomeCents == 4_000_00)
        #expect(totals.spentCents == 2_160_50)
        #expect(totals.budgetedCents == 2_500_00)
        #expect(totals.uncategorizedCents == 40_00)
        #expect(totals.leftCents == 339_50)
    }

    @Test func budgetsStartAndRepeat() {
        let trip = CategoryRecord(name: "Trip", limitCents: 800_00, startMonth: date(2026, 11, 1, 0), repeatsMonthly: false)
        let gym = CategoryRecord(name: "Gym", limitCents: 40_00, startMonth: date(2026, 11, 1, 0))
        let november = october.offset(by: 1, calendar: calendar)
        let december = october.offset(by: 2, calendar: calendar)
        #expect(!BudgetMath.isActive(trip, in: october, calendar: calendar))
        #expect(BudgetMath.isActive(trip, in: november, calendar: calendar))
        #expect(!BudgetMath.isActive(trip, in: december, calendar: calendar))
        #expect(BudgetMath.isActive(gym, in: december, calendar: calendar))
        #expect(!BudgetMath.isActive(gym, in: october, calendar: calendar))
    }

    @Test func archivedBudgetsLeaveThePlanButKeepTheirSpending() {
        let active = CategoryRecord(name: "Food", limitCents: 500_00)
        let archived = CategoryRecord(name: "Old", limitCents: 300_00, isArchived: true, sortOrder: 1)
        let quiet = CategoryRecord(name: "Quiet", limitCents: 100_00, isArchived: true, sortOrder: 2)
        let entries = [EntryRecord(date: date(2026, 10, 2), amountCents: 50_00, categoryID: archived.id)]
        let statuses = BudgetMath.statuses([active, archived, quiet], entries: entries, in: october, calendar: calendar)
        #expect(statuses.map(\.category.name) == ["Food", "Old"])
        #expect(BudgetMath.totals([active, archived, quiet], entries: entries, in: october, calendar: calendar).budgetedCents == 500_00)
    }

    // MARK: Accounts

    @Test func totalCashCountsIncludedCashAccountsOnly() {
        // The designs' $1,872.42: Chase Checking plus Bank of America. Savings is hidden and the
        // Apple Card is credit.
        let chase = AccountRecord(kind: .checking, balanceCents: 1_109_29, isManual: false)
        let savings = AccountRecord(kind: .savings, balanceCents: 4_250_00, includeInBudget: false, isManual: false)
        let boa = AccountRecord(kind: .checking, balanceCents: 763_13, isManual: false)
        let card = AccountRecord(kind: .credit, balanceCents: 412_18, isManual: false)
        #expect(BudgetMath.totalCash([chase, savings, boa, card], entries: []) == 1_872_42)
    }

    @Test func manualBalancesMoveWithLaterTransactions() {
        let account = AccountRecord(kind: .checking, balanceCents: 1_000_00, balanceDate: date(2026, 10, 5))
        let entries = [
            EntryRecord(date: date(2026, 10, 4), amountCents: 50_00, accountID: account.id), // before the balance
            EntryRecord(date: date(2026, 10, 6), amountCents: 25_00, accountID: account.id),
            EntryRecord(date: date(2026, 10, 7), amountCents: 500_00, kind: .income, accountID: account.id),
            EntryRecord(date: date(2026, 10, 8), amountCents: 99_00), // another account
        ]
        #expect(BudgetMath.balance(of: account, entries: entries) == 1_475_00)
    }

    // MARK: Bills

    @Test func billStates() {
        let bill = BillRecord(name: "Power", amountCents: 142_18, dueDay: 18)
        let month = MonthSpan(containing: date(2026, 10, 1), calendar: calendar)
        func state(on day: Int, payments: [EntryRecord] = []) -> BillState {
            BudgetMath.state(of: bill, in: month, payments: payments, today: date(2026, 10, day), calendar: calendar)
        }
        #expect(state(on: 1) == .upcoming(days: 17))
        #expect(state(on: 18) == .dueToday)
        #expect(state(on: 20) == .overdue(days: 2))
        let payment = EntryRecord(date: date(2026, 10, 16), amountCents: 142_18, billID: bill.id)
        #expect(state(on: 20, payments: [payment]) == .paid(payment.date))
    }

    @Test func theWeekStripCrossesIntoNextMonth() {
        let rent = BillRecord(name: "Rent", amountCents: 1_500_00, dueDay: 1)
        let phone = BillRecord(name: "Phone", amountCents: 80_00, dueDay: 30)
        let week = BudgetMath.week([rent, phone], from: date(2026, 10, 28), calendar: calendar)
        #expect(week.count == 7)
        #expect(week[2].billIDs == [phone.id]) // Oct 30
        #expect(week[4].billIDs == [rent.id]) // Nov 1
        #expect(BudgetMath.dueThisWeek([rent, phone], payments: [], from: date(2026, 10, 28), calendar: calendar) == 1_580_00)
        let paid = EntryRecord(date: date(2026, 10, 29), amountCents: 80_00, billID: phone.id)
        #expect(BudgetMath.dueThisWeek([rent, phone], payments: [paid], from: date(2026, 10, 28), calendar: calendar) == 1_500_00)
    }

    @Test func everyTwoWeeksFromTheFirstDueDate() {
        let paycheck = BillRecord(name: "Daycare", amountCents: 400_00, dueDay: 2, frequency: .weekly, interval: 2, startDate: date(2026, 10, 2, 0))
        let dates = BudgetMath.occurrences(of: paycheck, from: date(2026, 10, 1, 0), to: date(2026, 11, 1, 0), calendar: calendar)
        let days = dates.map { calendar.component(.day, from: $0) }
        #expect(days == [2, 16, 30])
        // Nothing before the first due date.
        #expect(BudgetMath.occurrences(of: paycheck, from: date(2026, 9, 1, 0), to: date(2026, 10, 1, 0), calendar: calendar).isEmpty)
    }

    @Test func quarterlyAndYearlySkipTheMonthsBetween() {
        let water = BillRecord(name: "Water", amountCents: 90_00, dueDay: 15, frequency: .monthly, interval: 3, startDate: date(2026, 1, 15, 0))
        let year = BudgetMath.occurrences(of: water, from: date(2026, 1, 1, 0), to: date(2027, 1, 1, 0), calendar: calendar)
        #expect(year.map { calendar.component(.month, from: $0) } == [1, 4, 7, 10])

        let insurance = BillRecord(name: "Car insurance", amountCents: 900_00, dueDay: 31, frequency: .yearly, startDate: date(2025, 3, 31, 0))
        let next = BudgetMath.nextDue(of: insurance, onOrAfter: date(2026, 10, 12), calendar: calendar)
        #expect(next.map { calendar.dateComponents([.year, .month, .day], from: $0) } == DateComponents(year: 2027, month: 3, day: 31))
    }

    @Test func schedulesStopOnTheirEndDate() {
        let loan = BillRecord(name: "Loan", amountCents: 250_00, dueDay: 5, frequency: .monthly, startDate: date(2026, 9, 5, 0), endDate: date(2026, 11, 5, 0))
        let dates = BudgetMath.occurrences(of: loan, from: date(2026, 1, 1, 0), to: date(2027, 6, 1, 0), calendar: calendar)
        #expect(dates.map { calendar.component(.month, from: $0) } == [9, 10, 11])

        let once = BillRecord(name: "Registration", amountCents: 120_00, dueDay: 20, frequency: .once, startDate: date(2026, 10, 20, 0))
        #expect(BudgetMath.occurrences(of: once, from: date(2026, 1, 1, 0), to: date(2027, 1, 1, 0), calendar: calendar).count == 1)
    }

    @Test func paidMarksOnlyTheDueDateItNames() {
        let bill = BillRecord(name: "Daycare", amountCents: 400_00, dueDay: 2, frequency: .weekly, interval: 2, startDate: date(2026, 10, 2, 0))
        let first = date(2026, 10, 2, 0)
        let second = date(2026, 10, 16, 0)
        let payment = EntryRecord(date: date(2026, 10, 3), amountCents: 400_00, billID: bill.id, billDueDate: first)
        #expect(BudgetMath.state(of: bill, dueOn: first, payments: [payment], today: date(2026, 10, 10), calendar: calendar).isPaid)
        #expect(BudgetMath.state(of: bill, dueOn: second, payments: [payment], today: date(2026, 10, 10), calendar: calendar) == .upcoming(days: 6))
        #expect(BudgetMath.state(of: bill, dueOn: second, payments: [payment], today: date(2026, 10, 18), calendar: calendar) == .overdue(days: 2))
    }
}

/// Typing money and showing it.
struct MoneyTests {
    @Test func parsesWhatPeopleType() {
        #expect(Money.cents(from: "12") == 1200)
        #expect(Money.cents(from: "12.5") == 1250)
        #expect(Money.cents(from: "12.345") == 1235)
        #expect(Money.cents(from: "$1,234.56") == 123_456)
        #expect(Money.cents(from: ".99") == 99)
        #expect(Money.cents(from: "") == nil)
        #expect(Money.cents(from: "abc") == nil)
    }

    @Test func editableRoundTrips() {
        #expect(Money.editable(0) == "")
        #expect(Money.editable(1200) == "12")
        #expect(Money.editable(1250) == "12.50")
        #expect(Money.cents(from: Money.editable(123_456)) == 123_456)
    }
}
