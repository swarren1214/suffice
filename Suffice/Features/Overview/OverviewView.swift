import SwiftData
import SwiftUI
import UIKit

/// Overview: the account cards. All accounts comes first (Total cash, this month's income and
/// expenses); swipe for each account, its card colored from its bank's logo. Under the cards,
/// whatever fits the card in front: net worth, every account's In budget switch and the loans
/// (Features/NetWorth), or one account's
/// switch, card color, this month's money in and out, and its latest transactions. That part
/// scrolls on its own, fading out as it passes under the cards.
struct OverviewView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \Account.sortOrder) private var accountList: [Account]
    @Query private var allEntries: [LedgerEntry]
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @AppStorage(SettingsKey.currentMember) private var currentMember = ""
    /// Card colors picked in an account's Card color row, by account ID. On this device only.
    @AppStorage(SettingsKey.cardStyles) private var savedStyles = ""
    @SceneStorage("overview.card") private var selection = AccountCardItem.allID
    @State private var showsConnect = false
    @State private var editing: Account?
    @State private var openEntry: LedgerEntry?
    @State private var width: CGFloat = 390
    /// Colors and images from the banks' logos, as they load.
    @State private var logoColors: [URL: RGB] = [:]
    @State private var logoImages: [URL: UIImage] = [:]

    var body: some View {
        let records = allEntries.map(\.record)
        let items = cardItems(records: records)
        let index = items.firstIndex { $0.id == selection } ?? 0
        let current = accounts.first { $0.id.uuidString == selection }

        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Overview")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text(index == 0 ? "All accounts" : "\(index) of \(items.count - 1)")
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.numericText())
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.white.opacity(colorScheme == .light ? 0.88 : 1))
            .padding(.horizontal, 20)
            .padding(.top, 4)

            AccountCarousel(items: items, selection: $selection, cardWidth: cardWidth)
                .padding(.top, 2)

            CardPager(count: items.count, index: index) { position in
                guard items.indices.contains(position) else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { selection = items[position].id }
            }

            ScrollView {
                VStack(spacing: 16) {
                    // The plan couldn't renew: update the payment method.
                    HearthBillingBanner()
                    Group {
                        if let current {
                            AccountDetail(
                                account: current,
                                palette: palette(for: current),
                                style: style(for: current),
                                setStyle: { setStyle($0, for: current) },
                                records: records,
                                entries: allEntries.filter { $0.accountID == current.id }.sorted { $0.date > $1.date },
                                month: router.month,
                                lookup: Lookup(categories: categories, members: members, accounts: accountList),
                                edit: { editing = current },
                                open: { openEntry = $0 }
                            )
                        } else {
                            allAccounts
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: GreenScreen<EmptyView>.readableWidth)
                .frame(maxWidth: .infinity)
                .animation(.smooth(duration: 0.3), value: selection)
            }
            // Pull down to fetch the latest from iCloud and bring connected banks up to date.
            .refreshable {
                await HouseholdSync.shared.syncNow()
                await BankSync.syncAll(memberID: UUID(uuidString: currentMember), in: context)
            }
            // Each card's details start at the top.
            .id(selection)
            // What scrolls up fades out before it reaches the page dots.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 28)
                    Color.black
                }
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(alignment: .top) { HeaderGradient() }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Overview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            // The title is drawn large in the content, as in the designs.
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
            }
        }
        .tabToolbar { EmptyView() }
        .task(id: logoURLs) { await loadLogos() }
        // An account deleted while its card was in front: back to All accounts.
        .onChange(of: accountList.map(\.id)) { _, ids in
            if selection != AccountCardItem.allID, !ids.contains(where: { $0.uuidString == selection }) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { selection = AccountCardItem.allID }
            }
        }
        .sheet(isPresented: $showsConnect) {
            ConnectView(step: nil) { showsConnect = false }
        }
        .sheet(item: $editing) { account in
            AccountEditor(account: account)
        }
        .sheet(item: $openEntry) { entry in
            TransactionSheet(entry: entry)
        }
    }

    private var cardWidth: CGFloat { min(max(width - 78, 270), 360) }

    // MARK: All accounts

    private var allAccounts: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Net worth first: everything owned minus owed, opening Net Worth.
            NetWorthCard()
                .padding(.bottom, 8)
            SectionTitle(title: "Accounts") {
                TintedCapsuleButton(title: "Add", systemImage: "plus") { showsConnect = true }
            }
            if accounts.isEmpty {
                EmptyCard(systemName: "building.columns", title: "No accounts yet", message: "Add the accounts you budget from to see your total cash here.")
            } else {
                CardList(items: accounts, inset: 68) { account in
                    AccountSwitchRow(account: account, palette: palette(for: account), logo: logoImage(for: account)) {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { selection = account.id.uuidString }
                    }
                }
                Text("Accounts in the budget count toward Total cash and what’s left to spend. Credit cards count their spending, never what’s owed.")
                    .font(.footnote)
                    .foregroundStyle(Brand.secondaryText)
                    .padding(.horizontal, 6)
            }
            LoansSection()
                .padding(.top, 12)
        }
    }

    // MARK: Cards

    /// Accounts in the order of their banks, each bank's accounts together.
    private var accounts: [Account] {
        var order: [String] = []
        var byBank: [String: [Account]] = [:]
        for account in accountList {
            let key = account.institution.isEmpty ? account.name : account.institution
            if byBank[key] == nil { order.append(key) }
            byBank[key, default: []].append(account)
        }
        return order.flatMap { byBank[$0] ?? [] }
    }

    private func cardItems(records: [EntryRecord]) -> [AccountCardItem] {
        let month = router.month
        let inMonth = records.filter { month.contains($0.date) }
        let income = inMonth.filter { $0.kind == .income }.reduce(0) { $0 + $1.amountCents }
        let expenses = inMonth.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amountCents }
        let cash = BudgetMath.totalCash(accountList.map(\.record), entries: records)
        let total = AccountCardItem(
            id: AccountCardItem.allID,
            content: .total(cash: cash, income: income, expenses: expenses, included: accountList.filter(\.includeInBudget).count, count: accountList.count),
            palette: .total,
            logo: nil,
            accessibilityLabel: "All accounts, \(Money.text(cash)) total cash"
        )
        return [total] + accounts.map { account in
            let balance = BudgetMath.balance(of: account.record, entries: records)
            let name = account.kind == .cash ? "Cash" : account.displayName
            return AccountCardItem(
                id: account.id.uuidString,
                content: .account(account, balance: balance),
                palette: palette(for: account),
                logo: logoImage(for: account),
                accessibilityLabel: "\(name)\(account.mask.isEmpty ? "" : ", ending \(account.mask)"), \(Money.text(balance))\(account.includeInBudget ? "" : ", not in budget")"
            )
        }
    }

    // MARK: Colors

    private func logoURL(for account: Account) -> URL? {
        guard account.kind != .cash else { return nil }
        return BankLogo.url(name: account.institution.isEmpty ? account.name : account.institution, domain: account.institutionDomain)
    }

    private func logoImage(for account: Account) -> UIImage? {
        logoURL(for: account).flatMap { logoImages[$0] }
    }

    private var logoURLs: [URL] {
        Array(Set(accountList.compactMap(logoURL(for:)))).sorted { $0.absoluteString < $1.absoluteString }
    }

    private func loadLogos() async {
        for url in logoURLs where logoImages[url] == nil {
            // Banks Logo.dev doesn't know keep their fallback color.
            guard let image = await LogoStore.shared.image(for: url) else { continue }
            let color = await LogoColors.color(for: url, image: image)
            withAnimation(.smooth) {
                logoImages[url] = image
                if let color { logoColors[url] = color }
            }
        }
    }

    private var styles: [String: String] {
        guard let data = savedStyles.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return decoded
    }

    private func style(for account: Account) -> CardStyle {
        styles[account.id.uuidString].flatMap(CardStyle.init(rawValue:)) ?? .automatic
    }

    private func setStyle(_ style: CardStyle, for account: Account) {
        var all = styles
        all[account.id.uuidString] = style == .automatic ? nil : style.rawValue
        if let data = try? JSONEncoder().encode(all) { savedStyles = String(decoding: data, as: UTF8.self) }
    }

    /// A picked style; else the bank's logo color (a deeper shade for a credit card from a bank
    /// you also bank with, so the two look different); else a fallback for the account.
    private func palette(for account: Account) -> CardPalette {
        if let base = style(for: account).base { return CardPalette(base: base) }
        if let url = logoURL(for: account), let color = logoColors[url] {
            let twin = account.kind == .credit && accountList.contains {
                $0.kind != .credit && $0.institution == account.institution && !account.institution.isEmpty
            }
            return CardPalette(base: twin ? color.shifted(lightness: -12) : color)
        }
        return CardPalette(base: CardStyle.fallback(for: account.id).base ?? RGB(hex: 0x3A3D45))
    }
}

/// An account in the All accounts list: a little card in its colors, its name and whether it's
/// in the budget, and its In budget switch. Tapping the name brings its card forward.
private struct AccountSwitchRow: View {
    @Bindable var account: Account
    var palette: CardPalette
    var logo: UIImage?
    var show: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: show) {
                HStack(spacing: 12) {
                    MiniCard(account: account, palette: palette, logo: logo)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.kind == .cash ? "Cash" : account.displayName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Brand.secondaryText)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows this account’s card")
            Toggle("\(account.displayName) in budget", isOn: $account.includeInBudget)
                .labelsHidden()
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .frame(minHeight: 62)
    }

    private var detail: String {
        let state = account.includeInBudget ? "In budget" : "Not in budget"
        return account.mask.isEmpty ? state : "•••• \(account.mask) · \(state)"
    }
}

/// An account's card, shrunk to a swatch.
private struct MiniCard: View {
    var account: Account
    var palette: CardPalette
    var logo: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.face)
            if let logo {
                Image(uiImage: logo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 16, height: 16)
                    .background(.white)
                    .clipShape(.rect(cornerRadius: 4, style: .continuous))
            } else {
                Text(account.kind == .cash ? "$" : String((account.institution.isEmpty ? account.name : account.institution).prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(palette.ink.color)
            }
        }
        .frame(width: 42, height: 27)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.14)))
        .accessibilityHidden(true)
    }
}

/// One account, under its card: the In budget switch, its card color, this month's money in and
/// out, and its latest transactions.
private struct AccountDetail: View {
    @Bindable var account: Account
    var palette: CardPalette
    var style: CardStyle
    var setStyle: (CardStyle) -> Void
    var records: [EntryRecord]
    /// This account's transactions, newest first.
    var entries: [LedgerEntry]
    var month: MonthSpan
    var lookup: Lookup
    var edit: () -> Void
    var open: (LedgerEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "chart.pie.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(account.includeInBudget ? Brand.greenBright : Color(.systemGray), in: .rect(cornerRadius: 10, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("In budget").font(.body.weight(.medium))
                        Text(budgetNote)
                            .font(.caption)
                            .foregroundStyle(Brand.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Toggle("\(account.displayName) in budget", isOn: $account.includeInBudget.animation(.smooth))
                        .labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                Divider().padding(.leading, 60)
                Menu {
                    Picker("Card Color", selection: Binding(get: { style }, set: { setStyle($0) })) {
                        ForEach(CardStyle.allCases) { option in
                            Text(option.name).tag(option)
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(palette.face)
                            .frame(width: 34, height: 34)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Card color").font(.body.weight(.medium)).foregroundStyle(.primary)
                            Text(style.name)
                                .font(.caption)
                                .foregroundStyle(Brand.secondaryText)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 60)
                Button(action: edit) {
                    HStack(spacing: 12) {
                        Image(systemName: "pencil")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Color(hex: 0x3D3D3D), in: .rect(cornerRadius: 10, style: .continuous))
                            .accessibilityHidden(true)
                        Text("Edit Account").font(.body.weight(.medium)).foregroundStyle(.primary)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))

            HStack(spacing: 10) {
                tile(inLabel, "+" + Money.text(moneyIn), color: moneyIn > 0 ? Brand.green : .primary)
                tile(outLabel, (moneyOut > 0 ? "−" : "") + Money.text(moneyOut), color: .primary)
            }

            SectionTitle("Recent")
            if entries.isEmpty {
                EmptyCard(systemName: "creditcard", title: "No transactions yet", message: "What’s spent from or paid into this account shows up here.")
            } else {
                CardList(items: Array(entries.prefix(4)), inset: 68) { entry in
                    Button { open(entry) } label: {
                        TransactionRow(entry: entry, lookup: lookup)
                    }
                    .buttonStyle(.plain)
                    .tint(.primary)
                }
            }
        }
    }

    private var inMonth: [EntryRecord] {
        records.filter { $0.accountID == account.id && month.contains($0.date) }
    }

    private var moneyIn: Int { inMonth.filter { $0.kind == .income }.reduce(0) { $0 + $1.amountCents } }
    private var moneyOut: Int { inMonth.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amountCents } }

    private var monthName: String { month.start.formatted(.dateTime.month(.wide)) }
    private var inLabel: String { account.kind == .credit ? "Paid in \(monthName)" : "In, \(monthName)" }
    private var outLabel: String { account.kind == .credit ? "Spent in \(monthName)" : "Out, \(monthName)" }

    private var budgetNote: String {
        guard account.includeInBudget else { return "Left out of Total cash and the budget" }
        switch account.kind {
        case .credit: return "Its spending counts toward your budget. What’s owed stays out of Total cash."
        case .savings: return "Counts toward Total cash"
        default: return "Counts toward Total cash, and its spending toward your budget"
        }
    }

    private func tile(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Brand.secondaryText)
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(color)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
}

/// A bank's round logo: its initial on its color, or a card for credit cards.
struct InstitutionLogo: View {
    var name: String
    var colorHex: Int
    var isCard = false
    var size: CGFloat = 40
    /// The bank's website domain when known (Plaid); otherwise it's matched by name.
    var domain: String? = nil

    var body: some View {
        mark
            // The bank's logo from Logo.dev over the initial, once it loads. Banks Logo.dev
            // doesn't know keep the initial.
            .overlay {
                if let url = BankLogo.url(name: name, domain: domain) {
                    MerchantLogoImage(url: url, size: size)
                }
            }
            .accessibilityHidden(true)
    }

    private var mark: some View {
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
