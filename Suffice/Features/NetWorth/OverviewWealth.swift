import Charts
import SwiftData
import SwiftUI

/// Overview's way into Net Worth: the figure, how it moved since last month and a small trend.
/// It also keeps this month's snapshot current, so the trend has history.
struct NetWorthCard: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var entries: [LedgerEntry]
    @Query(sort: \Loan.sortOrder) private var loans: [Loan]
    @Query(sort: \OwnedAsset.sortOrder) private var assets: [OwnedAsset]
    @Query private var snapshots: [NetWorthSnapshot]

    var body: some View {
        let summary = WealthSummary(accounts: accounts, entries: entries, loans: loans, assets: assets)
        let points = NetWorthHistory.points(snapshots, current: summary.totals)
        let net = summary.totals.netCents

        NavigationLink {
            NetWorthView()
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Net worth")
                        .font(.subheadline)
                        .foregroundStyle(Brand.secondaryText)
                    Text(net < 0 ? "−" + Money.whole(-net) : Money.whole(net))
                        .font(.title2.bold())
                        .foregroundStyle(net < 0 ? Brand.expenseInk : .primary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(NetWorthChange.note(points) ?? "\(Money.whole(summary.totals.assetsCents)) owned · \(Money.whole(summary.totals.debtsCents)) owed")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(points.count >= 2 ? (NetWorthChange.isUp(points) ? Brand.green : Brand.expenseInk) : Brand.secondaryText)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                if points.count >= 2 {
                    Chart(points.suffix(12)) { point in
                        LineMark(x: .value("Month", point.month), y: .value("Net worth", Double(point.netCents)))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .foregroundStyle(CategoryColor.green.color)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(width: 92, height: 40)
                    .accessibilityHidden(true)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
            .contentShape(.rect(cornerRadius: 26))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Net Worth")
        .task(id: summary.totals) { NetWorthHistory.record(summary.totals, in: context) }
    }
}

/// Overview's loans: each with its ring and balance, opening its page; All Debts opens Debts.
/// With no loans yet, a single row to add one.
struct LoansSection: View {
    @Query(sort: \Loan.sortOrder) private var loans: [Loan]
    @State private var addsLoan = false

    var body: some View {
        let open = loans.filter { !$0.isPaidOff }
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Loans") {
                if open.isEmpty {
                    TintedCapsuleButton(title: "Add", systemImage: "plus") { addsLoan = true }
                } else {
                    NavigationLink {
                        DebtsView()
                    } label: {
                        HStack(spacing: 4) {
                            Text("All Debts")
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
            }
            if open.isEmpty {
                Button { addsLoan = true } label: {
                    WealthRow(title: "Track a loan", detail: "A mortgage, car or student loan: its schedule and payoff") {
                        WealthIcon(symbol: "building.columns.fill", color: .green)
                    } trailing: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Brand.green)
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
                }
                .buttonStyle(.plain)
            } else {
                CardList(items: open, inset: 66) { loan in
                    let balance = LoanMath.currentBalance(loan.record)
                    let next = LoanMath.nextDueDate(first: loan.firstPaymentDate, after: .now)
                    NavigationLink {
                        LoanDetailView(loan: loan)
                    } label: {
                        WealthRow(title: loan.name, detail: "\(loan.subtitle) · next \(next.formatted(.dateTime.month(.abbreviated).day()))") {
                            PaidRing(progress: LoanMath.paidShare(originalCents: loan.originalCents, balanceCents: balance), color: loan.color, symbol: loan.symbol, size: 40)
                        } trailing: {
                            Text(Money.whole(balance))
                                .font(.body.weight(.semibold))
                                .monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
                }
                Text("Loans count toward net worth, never toward what’s left to spend.")
                    .font(.footnote)
                    .foregroundStyle(Brand.secondaryText)
                    .padding(.horizontal, 6)
            }
        }
        .sheet(isPresented: $addsLoan) { LoanEditor(loan: nil) }
    }
}
