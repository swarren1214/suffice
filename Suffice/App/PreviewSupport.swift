import SwiftData
import SwiftUI

extension View {
    /// Supplies the router and an in-memory store with a sample month to SwiftUI previews.
    func previewEnvironment() -> some View {
        modifier(PreviewEnvironment())
    }
}

private struct PreviewEnvironment: ViewModifier {
    @State private var router = AppRouter()
    @State private var container: ModelContainer = {
        let container = Persistence.makeContainer(inMemory: true)
        SampleData.insert(into: container.mainContext)
        return container
    }()

    func body(content: Content) -> some View {
        content
            .environment(router)
            .environment(AppLock.shared)
            .modelContainer(container)
            .tint(Brand.green)
    }
}

/// The household from the MVP v2 designs: two people, three accounts, the six budgets with
/// their subcategories, a few weeks of spending, the usual bills, and loans, assets and a year
/// of net worth for Net Worth. Previews only.
enum SampleData {
    static func insert(into context: ModelContext, calendar: Calendar = .current) {
        let steve = Member(name: "Steve", color: .green, sortOrder: 0)
        let partner = Member(name: "Partner", color: .purple, sortOrder: 1)
        context.insert(steve)
        context.insert(partner)
        UserDefaults.standard.set(steve.id.uuidString, forKey: SettingsKey.currentMember)

        let month = MonthSpan(containing: .now, calendar: calendar)
        let chase = Account(institution: "Chase", name: "Checking", mask: "0293", kind: .checking, balanceCents: 1_109_29, colorHex: 0x0E3E8C, sortOrder: 0)
        let chaseSavings = Account(institution: "Chase", name: "Savings", mask: "9932", kind: .savings, balanceCents: 4_250_00, colorHex: 0x0E3E8C, sortOrder: 1)
        chaseSavings.includeInBudget = false
        let boa = Account(institution: "Bank of America", name: "Checking", mask: "4471", kind: .checking, balanceCents: 763_13, colorHex: 0xC8102E, sortOrder: 2)
        let appleCard = Account(institution: "Apple Card", name: "", mask: "", kind: .credit, balanceCents: 412_18, colorHex: 0x1C1C1E, sortOrder: 3)
        for account in [chase, chaseSavings, boa, appleCard] {
            account.balanceDate = .distantFuture // Sample balances are "now"; nothing adjusts them.
            context.insert(account)
        }

        let budgets = StarterData.insertBudgets(into: context, amounts: [
            "Home/Mortgage": 2_201_79, "Home/Home improvements": 748_21,
            "Auto/Gas": 350_00, "Auto/Insurance": 319_00,
            "Food/Groceries": 600_00, "Food/Fast food": 145_00,
            "Utilities/Power": 250_00, "Utilities/Gas": 255_00,
            "Entertainment/Streaming": 40_00, "Entertainment/Date night": 260_00,
            "Giving": 550_00,
        ])

        let today = calendar.component(.day, from: .now)
        func on(_ day: Int, monthsAgo: Int = 0) -> Date {
            let span = month.offset(by: -monthsAgo, calendar: calendar)
            let date = span.dueDate(day: day, calendar: calendar)
            return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        }
        func add(_ payee: String, _ cents: Int, _ category: String?, _ day: Int, _ who: Member, _ account: Account, kind: EntryKind = .expense, reviewed: Bool = true, bill: Bill? = nil) {
            guard day <= today else { return }
            context.insert(LedgerEntry(date: on(day), payee: payee, amountCents: cents, kind: kind, categoryID: category.flatMap { budgets[$0]?.id }, memberID: who.id, accountID: account.id, billID: bill?.id, isReviewed: reviewed))
        }

        let mortgage = Bill(name: "Mortgage", amountCents: 2_201_79, dueDay: 18, color: .orange, categoryID: budgets["Home/Mortgage"]?.id)
        let phone = Bill(name: "T-Mobile", amountCents: 161_06, dueDay: 14, color: .pink, categoryID: budgets["Utilities"]?.id, isAutopay: true)
        let gas = Bill(name: "Dominion Energy", amountCents: 76_27, dueDay: 16, color: .blue, categoryID: budgets["Utilities/Gas"]?.id)
        let power = Bill(name: "Rocky Mountain Power", amountCents: 77_78, dueDay: 26, color: .blue, categoryID: budgets["Utilities/Power"]?.id)
        let netflix = Bill(name: "Netflix", amountCents: 17_99, dueDay: 21, color: .red, categoryID: budgets["Entertainment/Streaming"]?.id, isAutopay: true, isSubscription: true)
        let icloud = Bill(name: "iCloud+ 2 TB", amountCents: 9_99, dueDay: 28, color: .blue, categoryID: budgets["Entertainment/Streaming"]?.id, isAutopay: true, isSubscription: true)
        for bill in [mortgage, phone, gas, power, netflix, icloud] { context.insert(bill) }

        add("Paycheck", 2_750_00, nil, 1, steve, boa, kind: .income)
        add("Paycheck", 2_750_00, nil, 9, steve, boa, kind: .income)
        add("Costco", 214_37, "Food/Groceries", 2, partner, chase)
        add("Smith's", 86_12, "Food/Groceries", 5, partner, appleCard)
        add("Rocky Mountain Power", 77_78, "Utilities/Power", 6, steve, chase)
        add("Amazon", 16_78, nil, 7, partner, appleCard, reviewed: false)
        add("Subway", 8_30, "Food/Fast food", 8, partner, appleCard)
        add("Chevron", 48_20, "Auto/Gas", 3, steve, chase)
        add("Home Depot", 149_27, "Home/Home improvements", 4, steve, chase)
        add("T-Mobile", 161_06, "Utilities", 10, steve, chase, reviewed: false)
        add("Walmart", 285_87, "Food/Groceries", 11, steve, appleCard, reviewed: false)
        add("Chick-fil-A", 12_35, "Food/Fast food", 12, partner, chase, reviewed: false)

        // Loans, set up the day before their first payments, so the schedule brings them down.
        func loan(_ name: String, _ lender: String, _ kind: LoanKind, _ cents: Int, _ rate: Double, _ months: Int, monthsAgo: Int, order: Int) {
            let first = calendar.date(byAdding: .month, value: -monthsAgo, to: month.dueDate(day: 1, calendar: calendar)) ?? .now
            let payment = LoanMath.payment(principalCents: cents, annualRate: rate, months: months)
            let start = calendar.date(byAdding: .day, value: -1, to: first) ?? first
            context.insert(Loan(name: name, lender: lender, kind: kind, originalCents: cents, annualRate: rate, termMonths: months, firstPaymentDate: first, paymentCents: payment, balanceCents: cents, balanceDate: start, sortOrder: order))
        }
        loan("Mortgage", "PennyMac", .mortgage, 385_000_00, 6.25, 360, monthsAgo: 64, order: 0)
        loan("Auto loan", "Chase Auto", .auto, 28_500_00, 5.9, 60, monthsAgo: 30, order: 1)
        loan("Student loan", "Nelnet", .student, 42_000_00, 4.99, 120, monthsAgo: 85, order: 2)
        context.insert(OwnedAsset(name: "Home", kind: .home, valueCents: 512_000_00, sortOrder: 0))
        context.insert(OwnedAsset(name: "Vehicle", kind: .vehicle, valueCents: 26_000_00, sortOrder: 1))
        context.insert(OwnedAsset(name: "401(k)", kind: .investment, valueCents: 118_300_00, sortOrder: 2))
        // Planning: a yearly bill to stash for, three stashes, and a few tax tags.
        let insurance = Bill(name: "State Farm", amountCents: 1_380_00, dueDay: 15, color: .orange, categoryID: budgets["Home"]?.id)
        insurance.frequency = .yearly
        insurance.startDate = calendar.date(from: DateComponents(year: calendar.component(.year, from: .now), month: 3, day: 15)) ?? .now
        context.insert(insurance)
        func stash(_ name: String, _ symbol: String, _ color: CategoryColor, target: Int, monthsAhead: Int, day: Int, saved: Int, monthly: Int, automatic: Bool = true) {
            let due = month.offset(by: monthsAhead, calendar: calendar).dueDate(day: day, calendar: calendar)
            let item = Stash(name: name, symbol: symbol, color: color, targetCents: target, dueDate: due, openingCents: saved - monthly, accountID: chaseSavings.id)
            item.countsAutomatically = automatic
            item.createdAt = calendar.date(byAdding: .month, value: -3, to: .now) ?? .now
            context.insert(item)
            if automatic { context.insert(StashMove(stashID: item.id, month: month.start, amountCents: monthly)) }
        }
        stash("Christmas", "gift", .red, target: 1_200_00, monthsAhead: 2, day: 15, saved: 900_00, monthly: 150_00)
        stash("Car registration", "car", .blue, target: 504_00, monthsAhead: 8, day: 20, saved: 126_00, monthly: 48_00)
        stash("Back to school", "graduationcap", .purple, target: 600_00, monthsAhead: 10, day: 15, saved: 80_00, monthly: 0, automatic: false)
        budgets["Giving"]?.taxTag = .charitable
        let doctor = LedgerEntry(date: on(min(9, today)), payee: "Intermountain Health", amountCents: 185_00, categoryID: budgets["Home"]?.id, memberID: steve.id, accountID: chase.id)
        doctor.taxTag = .medical
        context.insert(doctor)
        context.insert(PayeeRule(payee: "Walgreens", categoryID: nil, taxTag: .hsa))

        // A year of history for the trend.
        for monthsAgo in 1...11 {
            let span = month.offset(by: -monthsAgo, calendar: calendar)
            let growth = (11 - monthsAgo) * 3_400_00
            context.insert(NetWorthSnapshot(month: span.start, assetsCents: 610_000_00 + growth, debtsCents: 412_000_00 - (11 - monthsAgo) * 1_900_00))
        }
        try? context.save()
    }
}
