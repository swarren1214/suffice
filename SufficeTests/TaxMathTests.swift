import Foundation
import Testing
@testable import Suffice

/// Tax tags: which tag a transaction gets, split parts with their own tags, the year's totals,
/// and a loan's interest for a year from its schedule.
struct TaxMathTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        return calendar
    }()

    func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    // MARK: Which tag

    @Test func theTransactionsOwnTagWinsThenThePayeeRuleThenTheBudget() {
        #expect(TaxMath.resolvedTag(own: .medical, rule: .hsa, budget: .charitable) == .medical)
        #expect(TaxMath.resolvedTag(own: .untagged, rule: .hsa, budget: .charitable) == .hsa)
        #expect(TaxMath.resolvedTag(own: .untagged, rule: .untagged, budget: .charitable) == .charitable)
        #expect(TaxMath.resolvedTag(own: .untagged, rule: nil, budget: nil) == .untagged)
    }

    @Test func aSubcategoryGoesByItsBudgetsTag() {
        let giving = CategoryRecord(name: "Giving", limitCents: 0, taxTag: .charitable)
        let church = CategoryRecord(name: "Church", limitCents: 0, parentID: giving.id)
        let food = CategoryRecord(name: "Food", limitCents: 0)
        #expect(TaxMath.budgetTag(for: church.id, categories: [giving, church, food]) == .charitable)
        #expect(TaxMath.budgetTag(for: food.id, categories: [giving, church, food]) == .untagged)
        #expect(TaxMath.budgetTag(for: nil, categories: [giving]) == .untagged)
    }

    // MARK: The year

    @Test func splitPartsCountByTheirOwnTags() {
        let costco = EntryRecord(date: date(2026, 10, 2), payee: "Costco", amountCents: 214_37, splits: [
            EntrySplit(categoryID: UUID(), amountCents: 166_10),
            EntrySplit(categoryID: UUID(), amountCents: 48_27, taxTag: .business),
        ])
        let items = TaxMath.items([TaxSource(entry: costco, hasReceipt: true)], year: 2026, calendar: calendar)
        #expect(items.count == 1)
        #expect(items.first?.tag == .business)
        #expect(items.first?.cents == 48_27)
        #expect(items.first?.isPart == true)
    }

    @Test func aPartWithoutATagGoesByTheCharge() {
        let pharmacy = EntryRecord(date: date(2026, 3, 9), payee: "Walgreens", amountCents: 60_00, splits: [
            EntrySplit(categoryID: UUID(), amountCents: 45_00),
            EntrySplit(categoryID: UUID(), amountCents: 15_00, taxTag: .untagged),
        ], taxTag: .hsa)
        let items = TaxMath.items([TaxSource(entry: pharmacy, hasReceipt: false)], year: 2026, calendar: calendar)
        #expect(items.map(\.cents) == [45_00])
        #expect(items.map(\.tag) == [.hsa])
    }

    @Test func theYearsTotalsByTag() {
        let sources = [
            TaxSource(entry: EntryRecord(date: date(2026, 1, 4), payee: "Church", amountCents: 250_00, taxTag: .charitable), hasReceipt: true),
            TaxSource(entry: EntryRecord(date: date(2026, 2, 4), payee: "Church", amountCents: 250_00, taxTag: .charitable), hasReceipt: true),
            TaxSource(entry: EntryRecord(date: date(2026, 10, 9), payee: "Intermountain Health", amountCents: 185_00, taxTag: .medical), hasReceipt: false),
            // Last year, untagged, and income don't count.
            TaxSource(entry: EntryRecord(date: date(2025, 12, 20), payee: "Church", amountCents: 250_00, taxTag: .charitable), hasReceipt: true),
            TaxSource(entry: EntryRecord(date: date(2026, 5, 1), payee: "Costco", amountCents: 90_00), hasReceipt: false),
            TaxSource(entry: EntryRecord(date: date(2026, 5, 1), payee: "Refund", amountCents: 20_00, kind: .income, taxTag: .medical), hasReceipt: false),
        ]
        let items = TaxMath.items(sources, year: 2026, calendar: calendar)
        let summary = TaxMath.summary(items)
        #expect(summary.totalCents == 685_00)
        #expect(summary.transactions == 3)
        #expect(summary.withReceipt == 2)
        #expect(summary.missingReceipts == 1)
        #expect(summary.tags.map(\.tag) == [.charitable, .medical])
        #expect(summary.tags.first?.count == 2)
        #expect(summary.tags.last?.missingReceipts == 1)
        #expect(TaxMath.missingReceipts(items).map(\.payee) == ["Intermountain Health"])
        #expect(TaxMath.missingByTag(items).first?.tag == .medical)
    }

    // MARK: Loan interest

    @Test func mortgageInterestForAYearFromTheSchedule() {
        // $385,000 at 6.25% for 30 years, first payment July 1, 2021.
        let mortgage = LoanRecord(
            originalCents: 385_000_00,
            annualRate: 6.25,
            termMonths: 360,
            firstPaymentDate: date(2021, 7, 1),
            paymentCents: 2_370_52,
            balanceCents: 385_000_00,
            balanceDate: date(2021, 6, 15)
        )
        #expect(LoanMath.interestPaid(mortgage, inYear: 2026, calendar: calendar) == 22_473_79)
        #expect(LoanMath.interestPaid(mortgage, inYear: 2025, calendar: calendar) == 22_834_72)
        #expect(LoanMath.interestPaid(mortgage, inYear: 2020, calendar: calendar) == 0)
    }
}
