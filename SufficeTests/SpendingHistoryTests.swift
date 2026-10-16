import Foundation
import Testing
@testable import Suffice

/// Onboarding's suggested plan and found bills, from bank history.
struct SpendingHistoryTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        return calendar
    }()

    func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    var now: Date { date(2026, 10, 16) }

    func item(_ payee: String, _ cents: Int, _ date: Date, _ category: String?, income: Bool = false) -> SpendingHistory.Item {
        SpendingHistory.Item(id: UUID(), date: date, payee: payee, amountCents: cents, isIncome: income, category: category)
    }

    @Test func categoriesLandInTheStarterBudgets() {
        #expect(SpendingHistory.budgetName(for: "RENT_AND_UTILITIES_RENT") == "Home")
        #expect(SpendingHistory.budgetName(for: "RENT_AND_UTILITIES_GAS_AND_ELECTRICITY") == "Utilities")
        #expect(SpendingHistory.budgetName(for: "RENT_AND_UTILITIES") == "Utilities")
        #expect(SpendingHistory.budgetName(for: "FOOD_AND_DRINK_GROCERIES") == "Food")
        #expect(SpendingHistory.budgetName(for: "TRANSPORTATION_GAS") == "Auto")
        #expect(SpendingHistory.budgetName(for: "TRANSFER_OUT_ACCOUNT_TRANSFER") == nil)
        #expect(SpendingHistory.budgetName(for: "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT") == nil)
        #expect(SpendingHistory.budgetName(for: nil) == nil)
    }

    @Test func averagesCoverTheMonthsOfHistory() {
        let items = [
            item("Smith's", 30_000, date(2026, 7, 20), "FOOD_AND_DRINK_GROCERIES"),
            item("Smith's", 30_000, date(2026, 8, 20), "FOOD_AND_DRINK_GROCERIES"),
            item("Smith's", 30_000, date(2026, 9, 20), "FOOD_AND_DRINK_GROCERIES"),
            item("Transfer", 100_000, date(2026, 9, 1), "TRANSFER_OUT_ACCOUNT_TRANSFER"),
            item("Paycheck", 640_000, date(2026, 9, 15), "INCOME_WAGES", income: true),
        ]
        let spending = SpendingHistory.monthlySpending(items, now: now)
        // July 20 to October 16 is just under three months.
        #expect(spending["Food"].map { (30_000...32_000).contains($0) } == true)
        #expect(spending["Home"] == nil)
        #expect(SpendingHistory.monthlyIncome(items, now: now) > 0)
    }

    @Test func suggestionsAreTidy() {
        #expect(SpendingHistory.suggestion(for: 94_000) == 94_000)
        #expect(SpendingHistory.suggestion(for: 45_480) == 45_000)
        #expect(SpendingHistory.suggestion(for: 218_000) == 220_000)
        #expect(SpendingHistory.suggestion(for: 0) == 0)
    }

    @Test func findsMonthlyBillsButNotGroceries() {
        let items = [
            item("Verizon Wireless", 14_000, date(2026, 7, 22), "RENT_AND_UTILITIES_TELEPHONE"),
            item("Verizon Wireless", 14_000, date(2026, 8, 22), "RENT_AND_UTILITIES_TELEPHONE"),
            item("Verizon Wireless", 14_000, date(2026, 9, 22), "RENT_AND_UTILITIES_TELEPHONE"),
            item("Rocky Mountain Power", 8_200, date(2026, 8, 12), "RENT_AND_UTILITIES_GAS_AND_ELECTRICITY"),
            item("Rocky Mountain Power", 11_000, date(2026, 9, 12), "RENT_AND_UTILITIES_GAS_AND_ELECTRICITY"),
            item("Netflix.com", 1_549, date(2026, 8, 18), "ENTERTAINMENT_TV_AND_MOVIES"),
            item("Netflix.com", 1_549, date(2026, 9, 18), "ENTERTAINMENT_TV_AND_MOVIES"),
            item("Smith's", 9_000, date(2026, 8, 3), "FOOD_AND_DRINK_GROCERIES"),
            item("Smith's", 9_000, date(2026, 9, 3), "FOOD_AND_DRINK_GROCERIES"),
            item("Old Gym", 4_000, date(2026, 6, 1), "PERSONAL_CARE_GYMS_AND_FITNESS_CENTERS"),
            item("Old Gym", 4_000, date(2026, 7, 1), "PERSONAL_CARE_GYMS_AND_FITNESS_CENTERS"),
        ]
        let found = SpendingHistory.findBills(items, now: now, calendar: calendar)
        #expect(found.map(\.name) == ["Verizon Wireless", "Rocky Mountain Power", "Netflix.com"])
        #expect(found[0].dueDay == 22 && !found[0].isVariable && found[0].budgetName == "Utilities")
        #expect(found[1].isVariable)
        #expect(found[2].isSubscription)
    }

    @Test func skipsBillsAlreadyAdded() {
        let items = [
            item("VERIZON WIRELESS #123", 14_000, date(2026, 8, 22), "RENT_AND_UTILITIES_TELEPHONE"),
            item("VERIZON WIRELESS #123", 14_000, date(2026, 9, 22), "RENT_AND_UTILITIES_TELEPHONE"),
        ]
        #expect(SpendingHistory.findBills(items, existingNames: ["Verizon"], now: now, calendar: calendar).isEmpty)
    }

    @Test func payeeKeysMatchLoosely() {
        #expect(PayeeKey.normalized("NETFLIX.COM 866-579") == "netflix")
        #expect(PayeeKey.matches("verizon wireless", "verizon"))
        #expect(!PayeeKey.matches("verizon", "veritas"))
    }
}
