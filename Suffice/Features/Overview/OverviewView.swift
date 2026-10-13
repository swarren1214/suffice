import SwiftData
import SwiftUI

/// Overview: Total cash across the accounts in the budget, this month's income and expenses,
/// and every account grouped by bank. Banks with more than one account expand to switch each
/// one in or out of the budget.
struct OverviewView: View {
    @Environment(AppRouter.self) private var router
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var allEntries: [LedgerEntry]
    @State private var showsConnect = false
    @State private var editing: Account?
    @State private var expanded: Set<String> = []
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.currentMember) private var currentMember = ""

    var body: some View {
        let records = allEntries.map(\.record)
        let month = router.month
        let inMonth = records.filter { month.contains($0.date) }
        let income = inMonth.filter { $0.kind == .income }.reduce(0) { $0 + $1.amountCents }
        let expenses = inMonth.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amountCents }
        let cash = BudgetMath.totalCash(accounts.map(\.record), entries: records)
        let groups = institutions

        GreenScreen("Overview") {
            TotalCashCard(cash: cash, income: income, expenses: expenses, isThisMonth: router.isThisMonth)

            SectionTitle(title: "Accounts") {
                TintedCapsuleButton(title: "Add", systemImage: "plus") { showsConnect = true }
            }

            if groups.isEmpty {
                EmptyCard(systemName: "building.columns", title: "No accounts yet", message: "Add the accounts you budget from to see your total cash here.")
            } else {
                CardList(items: groups, inset: 68) { group in
                    InstitutionRow(
                        group: group,
                        records: records,
                        isExpanded: expanded.contains(group.id),
                        toggle: {
                            withAnimation(.snappy) {
                                if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
                            }
                        },
                        edit: { editing = $0 }
                    )
                }
            }
        }
        .tabToolbar { EmptyView() }
        // Pull down to bring connected banks up to date.
        .refreshable {
            await BankSync.syncAll(memberID: UUID(uuidString: currentMember), in: context)
        }
        .sheet(isPresented: $showsConnect) {
            ConnectView(step: nil) { showsConnect = false }
        }
        .sheet(item: $editing) { account in
            AccountEditor(account: account)
        }
        .onAppear {
            // Open the first bank with several accounts, as in the design.
            if expanded.isEmpty, let first = groups.first(where: { $0.accounts.count > 1 }) {
                expanded.insert(first.id)
            }
        }
    }

    /// Accounts grouped by institution, in the order of their first account.
    private var institutions: [InstitutionGroup] {
        var order: [String] = []
        var byName: [String: [Account]] = [:]
        for account in accounts {
            let key = account.institution.isEmpty ? account.name : account.institution
            if byName[key] == nil { order.append(key) }
            byName[key, default: []].append(account)
        }
        return order.map { InstitutionGroup(name: $0, accounts: byName[$0] ?? []) }
    }
}

struct InstitutionGroup: Identifiable {
    var name: String
    var accounts: [Account]
    var id: String { name }
}

/// The Liquid Glass card: total cash, then income and expenses for the month.
private struct TotalCashCard: View {
    var cash: Int
    var income: Int
    var expenses: Int
    var isThisMonth: Bool

    var body: some View {
        GlassCard {
            GlassCardHeader(title: "Total cash", note: isThisMonth ? "This month" : "That month")
            GlassFigure(text: Money.text(cash))
            HStack(spacing: 10) {
                GlassTile(title: "Income", value: Money.text(income))
                GlassTile(title: "Expenses", value: Money.text(expenses))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A bank: its logo initial, what's available, and (when it has several accounts) a chevron
/// that opens its accounts with In budget switches.
private struct InstitutionRow: View {
    var group: InstitutionGroup
    var records: [EntryRecord]
    var isExpanded: Bool
    var toggle: () -> Void
    var edit: (Account) -> Void

    private var isCredit: Bool { group.accounts.allSatisfy { $0.kind == .credit } }
    private var first: Account? { group.accounts.first }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                if group.accounts.count > 1 {
                    toggle()
                } else if let first {
                    edit(first)
                }
            } label: {
                HStack(spacing: 12) {
                    InstitutionLogo(name: group.name, colorHex: first?.colorHex ?? 0x0E3E8C, isCard: isCredit)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(Brand.secondaryText)
                            .monospacedDigit()
                    }
                    Spacer()
                    if group.accounts.count > 1 {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(group.accounts.count > 1 ? (isExpanded ? "Hides accounts" : "Shows accounts") : "Edits the account")

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(group.accounts) { account in
                        SubAccountRow(account: account, edit: { edit(account) })
                    }
                }
                .padding(.leading, 68)
                .padding(.trailing, 16)
                .padding(.bottom, 6)
            }
        }
    }

    private var subtitle: String {
        let included = group.accounts.filter(\.includeInBudget)
        let total = included.reduce(0) { $0 + BudgetMath.balance(of: $1.record, entries: records) }
        let sources = Set(group.accounts.map(\.source.label)).sorted().joined(separator: ", ")
        return "\(isCredit ? "Balance" : "Available") \(Money.text(total)) · \(sources)"
    }
}

private struct SubAccountRow: View {
    @Bindable var account: Account
    var edit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button(action: edit) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.name.isEmpty ? account.kind.name : account.name)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Brand.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                Toggle("Include \(account.name) in budget", isOn: $account.includeInBudget)
                    .labelsHidden()
            }
            .frame(minHeight: 50)
        }
    }

    private var detail: String {
        let state = account.includeInBudget ? "In budget" : "Hidden"
        return account.mask.isEmpty ? state : "•••• \(account.mask) · \(state)"
    }
}

/// A bank's round logo: its initial on its color, or a card for credit cards.
struct InstitutionLogo: View {
    var name: String
    var colorHex: Int
    var isCard = false
    var size: CGFloat = 40

    var body: some View {
        Group {
            if isCard {
                Image(systemName: "creditcard")
                    .font(.system(size: size * 0.45, weight: .medium))
            } else {
                Text(name.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: size * 0.42, weight: .bold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(Color(hex: UInt32(truncatingIfNeeded: colorHex)), in: .circle)
        .accessibilityHidden(true)
    }
}

#Preview {
    NavigationStack { OverviewView() }
        .previewEnvironment()
}
