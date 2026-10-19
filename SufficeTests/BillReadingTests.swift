import Foundation
import Testing
@testable import Suffice

/// Bills read from statements, receipts matched to transactions, and email text. The figures
/// are the Bills & Receipts prototype's.
struct BillReadingTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        return calendar
    }()

    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    var utilities: BillRecord {
        var bill = BillRecord(name: "Santaquin City Utilities", amountCents: 150_07, dueDay: 20)
        bill.startDate = date(2026, 1, 20)
        return bill
    }

    // MARK: Statements

    @Test func aStatementSetsItsDueDatesAmount() {
        let bill = utilities
        let october = StatementRecord(billID: bill.id, amountCents: 142_86, dueDate: date(2026, 10, 20))
        #expect(StatementMath.amount(for: bill, dueOn: date(2026, 10, 20), statements: [october]) == 142_86)
        // Another month keeps the bill's amount.
        #expect(StatementMath.amount(for: bill, dueOn: date(2026, 11, 20), statements: [october]) == 150_07)
        // A statement someone said not to use doesn't count.
        var off = october
        off.usesAmount = false
        #expect(StatementMath.amount(for: bill, dueOn: date(2026, 10, 20), statements: [off]) == 150_07)
    }

    @Test func aStatementAFewDaysOffStillCounts() {
        let bill = utilities
        let shifted = StatementRecord(billID: bill.id, amountCents: 142_86, dueDate: date(2026, 10, 22))
        #expect(StatementMath.amount(for: bill, dueOn: date(2026, 10, 20), statements: [shifted]) == 142_86)
    }

    @Test func theWeekUsesStatementAmounts() {
        let bill = utilities
        let october = StatementRecord(billID: bill.id, amountCents: 142_86, dueDate: date(2026, 10, 20))
        #expect(StatementMath.dueThisWeek([bill], payments: [], statements: [october], from: date(2026, 10, 19), calendar: calendar) == 142_86)
        let paid = EntryRecord(date: date(2026, 10, 19), amountCents: 142_86, billID: bill.id, billDueDate: calendar.startOfDay(for: date(2026, 10, 20)))
        #expect(StatementMath.dueThisWeek([bill], payments: [paid], statements: [october], from: date(2026, 10, 19), calendar: calendar) == 0)
    }

    @Test func historyAndAverage() {
        let id = UUID()
        let amounts = [151_12, 166_40, 172_05, 138_92, 129_04, 142_86]
        let statements = amounts.enumerated().map { index, cents in
            StatementRecord(billID: id, amountCents: cents, dueDate: date(2026, 5 + index, 20))
        }
        let history = StatementMath.history(id, statements: statements)
        #expect(history.first?.amountCents == 142_86)
        #expect(history.count == 6)
        #expect(StatementMath.average(history) == 150_07)
    }

    @Test func chargesAddUp() {
        let charges = [58_10, 41_25, 18_50, 16_00, 9_01].map { StatementCharge(name: "Charge", amountCents: $0) }
        #expect(StatementMath.chargesMatch(charges, amountCents: 142_86))
        #expect(!StatementMath.chargesMatch(charges, amountCents: 150_00))
    }

    @Test func findsTheBillByWhoItsFrom() {
        let bill = utilities
        let power = BillRecord(name: "Rocky Mountain Power", amountCents: 77_78, dueDay: 26)
        #expect(StatementMath.bill(named: "Santaquin City", in: [power, bill])?.id == bill.id)
        #expect(StatementMath.bill(named: "Dominion Energy", in: [power, bill]) == nil)
        // Generic words don't match: another city's power isn't Santaquin City Utilities.
        #expect(StatementMath.bill(named: "Provo City Power", in: [bill]) == nil)
        // A distinctive word does.
        #expect(StatementMath.bill(named: "Utilities of Santaquin", in: [power, bill])?.id == bill.id)
    }

    // MARK: Matching receipts

    @Test func sameAmountStoreAndDayAttachesOnItsOwn() {
        let charge = EntryRecord(date: date(2026, 10, 9), payee: "INTERMOUNTAIN HC", amountCents: 185_00)
        let receipt = ReceiptCandidate(merchant: "Intermountain Health", totalCents: 185_00, date: date(2026, 10, 9))
        #expect(ReceiptMatcher.match(receipt, entries: [charge], calendar: calendar) == .sure(charge.id))
        // One that already has a receipt is left alone.
        #expect(ReceiptMatcher.match(receipt, entries: [charge], taken: [charge.id], calendar: calendar) == .none)
    }

    @Test func aTipAddedAfterTheReceiptAsks() {
        let charge = EntryRecord(date: date(2026, 10, 12), payee: "Olive Garden 1234", amountCents: 100_94)
        let receipt = ReceiptCandidate(merchant: "Olive Garden", totalCents: 84_12, date: date(2026, 10, 11, 19))
        #expect(ReceiptMatcher.match(receipt, entries: [charge], calendar: calendar) == .check(charge.id, .tip(differenceCents: 16_82)))
    }

    @Test func twoChargesAskAndPickTheCloser() {
        let near = EntryRecord(date: date(2026, 10, 7), payee: "Amazon", amountCents: 16_78)
        let far = EntryRecord(date: date(2026, 10, 10), payee: "AMAZON MKTPL", amountCents: 16_78)
        let receipt = ReceiptCandidate(merchant: "Amazon", totalCents: 16_78, date: date(2026, 10, 6))
        #expect(ReceiptMatcher.match(receipt, entries: [far, near], calendar: calendar) == .check(near.id, .twoCharges))
    }

    @Test func aChargeDaysLaterAsks() {
        let charge = EntryRecord(date: date(2026, 10, 3), payee: "Walgreens", amountCents: 23_40)
        let receipt = ReceiptCandidate(merchant: "Walgreens", totalCents: 23_40, date: date(2026, 9, 29))
        #expect(ReceiptMatcher.match(receipt, entries: [charge], calendar: calendar) == .check(charge.id, .daysApart(4)))
    }

    @Test func noChargeYetWaits() {
        let other = EntryRecord(date: date(2026, 10, 17), payee: "Costco", amountCents: 42_18)
        let receipt = ReceiptCandidate(merchant: "Target", totalCents: 42_18, date: date(2026, 10, 14))
        #expect(ReceiptMatcher.match(receipt, entries: [other], calendar: calendar) == .none)
        // Income never matches.
        let refund = EntryRecord(date: date(2026, 10, 14), payee: "Target", amountCents: 42_18, kind: .income)
        #expect(ReceiptMatcher.match(receipt, entries: [refund], calendar: calendar) == .none)
    }

    // MARK: Email text

    @Test func htmlBecomesReadableText() {
        let html = """
            <html><head><style>td{color:red}</style></head><body>
            <h1>Thanks for your order</h1><table><tr><td>Office visit</td><td>$150.00</td></tr>
            <tr><td>Lab work</td><td>$35.00</td></tr></table><p>Total&nbsp;paid: <b>$185.00</b></p>
            <script>track()</script></body></html>
            """
        let text = EmailText.plainText(fromHTML: html)
        #expect(text.contains("Thanks for your order"))
        #expect(text.contains("Office visit $150.00"))
        #expect(text.contains("Total paid: $185.00"))
        #expect(!text.contains("color:red"))
        #expect(!text.contains("track()"))
    }

    @Test func readsDates() {
        #expect(EmailText.date("2026-10-20", calendar: calendar) == date(2026, 10, 20))
        #expect(EmailText.date("10/20/2026", calendar: calendar) == date(2026, 10, 20))
        #expect(EmailText.date("", calendar: calendar) == nil)
        #expect(EmailText.date("2026-13-01", calendar: calendar) == nil)
    }
}
