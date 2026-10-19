import SwiftData
import SwiftUI

/// Net Worth, from Overview's card: everything owned minus everything owed, its trend, then
/// assets (accounts, then homes, cars and investments typed in by hand) and debts (loans, then
/// credit cards).
struct NetWorthView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var entries: [LedgerEntry]
    @Query(sort: \Loan.sortOrder) private var loans: [Loan]
    @Query(sort: \OwnedAsset.sortOrder) private var assets: [OwnedAsset]
    @Query private var snapshots: [NetWorthSnapshot]
    @AppStorage(SettingsKey.netWorthRange) private var range: TrendRange = .year
    @State private var addsAsset = false
    @State private var addsLoan = false
    @State private var editingAsset: OwnedAsset?

    var body: some View {
        let summary = WealthSummary(accounts: accounts, entries: entries, loans: loans, assets: assets)
        let points = NetWorthHistory.points(snapshots, current: summary.totals)
        let cash = accounts.filter { $0.kind != .credit }
        let cards = accounts.filter { $0.kind == .credit && (summary.accountBalances[$0.id] ?? 0) > 0 }
        let openLoans = loans.filter { !$0.isPaidOff }

        GreenScreen("Net Worth") {
            GlassCard {
                GlassCardHeader(title: "What you own, minus what you owe", note: nil)
                GlassFigure(text: signedWhole(summary.totals.netCents), color: summary.totals.netCents < 0 ? Brand.expenseInk : .primary)
                if let change = NetWorthChange.note(points) {
                    Text(change)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(NetWorthChange.isUp(points) ? Brand.greenInk : Brand.expenseInk)
                        .monospacedDigit()
                }
                HStack(spacing: 10) {
                    GlassTile(title: "Assets", value: Money.whole(summary.totals.assetsCents))
                    GlassTile(title: "Debts", value: Money.whole(summary.totals.debtsCents))
                }
            }
            .accessibilityElement(children: .combine)

            NetWorthTrendCard(points: points, range: $range)

            EmergencyFundCard()

            SectionTitle(title: "Assets") {
                TintedCapsuleButton(title: "Add", systemImage: "plus") { addsAsset = true }
            }
            if cash.isEmpty && assets.isEmpty {
                EmptyCard(systemName: "house", title: "Nothing here yet", message: "Add your home, car or retirement accounts to see what you own.")
            } else {
                RowsCard {
                    ForEach(cash) { account in
                        WealthRow(title: account.kind == .cash ? "Cash" : account.displayName, detail: accountDetail(account)) {
                            InstitutionLogo(name: account.institution.isEmpty ? account.name : account.institution, colorHex: account.colorHex, isCard: false, size: 40, domain: account.institutionDomain)
                        } trailing: {
                            Text(Money.whole(summary.accountBalances[account.id] ?? 0))
                                .font(.body.weight(.semibold))
                                .monospacedDigit()
                        }
                    }
                    ForEach(assets) { asset in
                        Button { editingAsset = asset } label: {
                            WealthRow(title: asset.name, detail: "Your estimate · \(DateLabel.short(asset.valueDate))") {
                                WealthIcon(symbol: asset.kind.symbol, color: asset.kind.color)
                            } trailing: {
                                Text(Money.whole(asset.valueCents))
                                    .font(.body.weight(.semibold))
                                    .monospacedDigit()
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Edits the value")
                    }
                }
            }

            SectionTitle(title: "Debts") {
                NavigationLink {
                    DebtsView()
                } label: {
                    HStack(spacing: 4) {
                        Text("See all")
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.green)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .background(Brand.green.opacity(0.12), in: .capsule)
                }
                .buttonStyle(.plain)
            }
            if openLoans.isEmpty && cards.isEmpty {
                EmptyCard(systemName: "checkmark.seal", title: "No debts", message: "Add a loan to see its schedule and when it’s paid off.")
            } else {
                RowsCard {
                    ForEach(openLoans) { loan in
                        let balance = summary.loanBalances[loan.id] ?? 0
                        NavigationLink {
                            LoanDetailView(loan: loan)
                        } label: {
                            WealthRow(title: loan.name, detail: loan.subtitle) {
                                PaidRing(progress: LoanMath.paidShare(originalCents: loan.originalCents, balanceCents: balance), color: loan.color, symbol: loan.symbol, size: 40)
                            } trailing: {
                                OwedPill(cents: balance)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(cards) { card in
                        WealthRow(title: card.displayName, detail: card.mask.isEmpty ? "Credit card" : "•••• \(card.mask)") {
                            InstitutionLogo(name: card.institution.isEmpty ? card.name : card.institution, colorHex: card.colorHex, isCard: true, size: 40, domain: card.institutionDomain)
                        } trailing: {
                            OwedPill(cents: summary.accountBalances[card.id] ?? 0)
                        }
                    }
                }
            }

            Text("Every account counts here, in the budget or not. Home and car values are your own estimates; tap one to update it.")
                .font(.footnote)
                .foregroundStyle(Brand.secondaryText)
                .padding(.horizontal, 6)
        }
        .refreshable { await HouseholdSync.shared.syncNow() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Add Asset", menuIcon: "house") { addsAsset = true }
                    Button("Add Loan", menuIcon: "building.columns") { addsLoan = true }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .task(id: summary.totals) { NetWorthHistory.record(summary.totals, in: context) }
        .sheet(isPresented: $addsAsset) { AssetEditor(asset: nil) }
        .sheet(isPresented: $addsLoan) { LoanEditor(loan: nil) }
        .sheet(item: $editingAsset) { asset in AssetEditor(asset: asset) }
    }

    private func signedWhole(_ cents: Int) -> String {
        cents < 0 ? "−" + Money.whole(-cents) : Money.whole(cents)
    }

    private func accountDetail(_ account: Account) -> String {
        let kind = account.kind == .cash ? "Cash" : account.kind.name
        return account.mask.isEmpty ? kind : "\(kind) · •••• \(account.mask)"
    }
}

#Preview {
    NavigationStack { NetWorthView() }
        .previewEnvironment()
}
