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
/// their subcategories, a few weeks of spending and the usual bills. Previews only.
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
        try? context.save()
    }
}
