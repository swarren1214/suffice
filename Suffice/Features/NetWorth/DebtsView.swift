import SwiftData
import SwiftUI

/// Debts: what's left on every loan, when it's all paid off, each loan as a tile with its ring,
/// and a timeline of payoff dates. Tapping a tile opens the loan.
struct DebtsView: View {
    @Query(sort: \Loan.sortOrder) private var loans: [Loan]
    @State private var addsLoan = false
    @State private var showsPaidOff = false

    var body: some View {
        let open = loans.filter { !$0.isPaidOff }
        let paidOff = loans.filter(\.isPaidOff)
        let rows = open.map { DebtLine(loan: $0) }
        let monthly = open.reduce(0) { $0 + $1.paymentCents + $1.extraMonthlyCents }

        GreenScreen("Debts", trailing: open.isEmpty ? nil : "\(Money.whole(monthly)) a month") {
            if open.isEmpty {
                EmptyCard(systemName: "checkmark.seal", title: "No loans", message: "Add a mortgage, car or student loan to see its schedule and plan an early payoff.", isGlass: true)
            } else {
                DebtsSummaryCard(lines: rows)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(rows) { line in
                        NavigationLink {
                            LoanDetailView(loan: line.loan)
                        } label: {
                            LoanTile(line: line)
                        }
                        .buttonStyle(.plain)
                    }
                }

                SectionTitle("Payoff timeline")
                PayoffTimeline(lines: rows)

                if let tip = RollOverTip(lines: rows) {
                    Card {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "sparkles")
                                .font(.headline)
                                .foregroundStyle(Brand.green)
                                .frame(width: 36, height: 36)
                                .background(Brand.greenPale, in: .circle)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tip.title).font(.headline)
                                Text(tip.message)
                                    .font(.subheadline)
                                    .foregroundStyle(Brand.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            if !paidOff.isEmpty {
                DisclosureGroup("Paid off (\(paidOff.count))", isExpanded: $showsPaidOff) {
                    VStack(spacing: 8) {
                        ForEach(paidOff) { loan in
                            NavigationLink {
                                LoanDetailView(loan: loan)
                            } label: {
                                WealthRow(title: loan.name, detail: loan.subtitle, showsChevron: true) {
                                    PaidRing(progress: 1, color: loan.color, symbol: loan.symbol, size: 40)
                                } trailing: {
                                    EmptyView()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.headline)
                .tint(.primary)
                .padding(.horizontal, 4)
            }
        }
        .refreshable { await HouseholdSync.shared.syncNow() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { addsLoan = true } label: {
                    Label("Add Loan", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $addsLoan) { LoanEditor(loan: nil) }
    }
}

/// A loan with today's balance and where its schedule ends, worked out once.
struct DebtLine: Identifiable {
    var loan: Loan
    var balanceCents: Int
    var projection: LoanProjection

    init(loan: Loan, now: Date = .now) {
        self.loan = loan
        self.balanceCents = LoanMath.currentBalance(loan.record, on: now)
        self.projection = LoanMath.projection(loan.record, from: now)
    }

    var id: UUID { loan.id }
    var paidShare: Double { LoanMath.paidShare(originalCents: loan.originalCents, balanceCents: balanceCents) }
}

/// The glass card: everything left to pay, when the last loan is gone, a bar of how much is
/// paid off, then paid off and interest still ahead.
private struct DebtsSummaryCard: View {
    var lines: [DebtLine]

    var body: some View {
        let owed = lines.reduce(0) { $0 + $1.balanceCents }
        let borrowed = lines.reduce(0) { $0 + $1.loan.originalCents }
        let interest = lines.reduce(0) { $0 + $1.projection.totalInterestCents }
        let neverPaysOff = lines.contains { $0.projection.neverPaysOff }
        let lastDate = lines.compactMap(\.projection.payoffDate).max()
        GlassCard {
            GlassCardHeader(title: "Left to pay off", note: neverPaysOff ? nil : lastDate.map { "Debt-free \($0.shortMonthYear)" })
            GlassFigure(text: Money.whole(owed))
            if borrowed > 0 {
                ProgressBar(progress: LoanMath.paidShare(originalCents: borrowed, balanceCents: owed), color: Brand.green, track: .primary.opacity(0.1))
            }
            HStack(spacing: 10) {
                GlassTile(title: "Paid off", value: Money.whole(max(borrowed - owed, 0)))
                GlassTile(title: "Interest ahead", value: Money.whole(interest))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One loan as a tile, like a budget: its ring, how much is paid, its name, what's left, and its
/// rate and payment.
private struct LoanTile: View {
    var line: DebtLine

    var body: some View {
        let loan = line.loan
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                PaidRing(progress: line.paidShare, color: loan.color, symbol: loan.symbol, size: 44)
                Spacer(minLength: 4)
                Text(line.paidShare, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.secondaryText)
                    .monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(loan.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(Money.whole(line.balanceCents)) left")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("\(loan.annualRate.formatted(.number.precision(.fractionLength(0...3))))% · \(Money.whole(loan.paymentCents))/mo")
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        .contentShape(.rect(cornerRadius: 22))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loan.name)
        .accessibilityValue("\(Money.whole(line.balanceCents)) left, \(Int((line.paidShare * 100).rounded())) percent paid off")
        .accessibilityHint("Opens the loan")
    }
}

/// Each loan's payoff date as a bar from today: the longer the bar, the later it's gone.
private struct PayoffTimeline: View {
    var lines: [DebtLine]

    var body: some View {
        let sorted = lines.sorted { $0.projection.months < $1.projection.months }
        let longest = max(sorted.last?.projection.months ?? 1, 1)
        Card {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(sorted) { line in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(line.loan.name).font(.subheadline.weight(.medium))
                            Spacer()
                            Text(line.projection.neverPaysOff ? "Payment too low" : line.projection.payoffDate?.shortMonthYear ?? "Paid off")
                                .font(.subheadline)
                                .foregroundStyle(line.projection.neverPaysOff ? Brand.expenseInk : Brand.secondaryText)
                                .monospacedDigit()
                        }
                        ProgressBar(progress: max(Double(line.projection.months) / Double(longest), 0.02), color: line.loan.color.color)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// When a smaller loan ends years before the biggest, its payment rolled into the biggest one
/// pays that off sooner. Shown when the difference is worth a line.
private struct RollOverTip {
    var title: String
    var message: String

    init?(lines: [DebtLine], now: Date = .now) {
        let open = lines.filter { !$0.projection.neverPaysOff && $0.projection.months > 0 }
        guard open.count >= 2, let target = open.max(by: { $0.projection.months < $1.projection.months }) else { return nil }
        let others = open.filter { $0.id != target.id && $0.projection.months < target.projection.months }
        guard !others.isEmpty else { return nil }
        let freed = others.reduce(0) { $0 + $1.loan.paymentCents + $1.loan.extraMonthlyCents }
        let freeMonth = others.map(\.projection.months).max() ?? 0

        // The target's schedule with the freed payments added once the others are gone.
        let loan = target.loan.record
        var owed = target.balanceCents
        let payment = loan.paymentCents + loan.extraMonthlyCents
        var months = 0
        while owed > 0 && months < 1_200 {
            let interest = LoanMath.monthlyInterest(onCents: owed, annualRate: loan.annualRate)
            let paid = payment + (months >= freeMonth ? freed : 0)
            guard paid > interest else { return nil }
            owed -= min(paid - interest, owed)
            months += 1
        }
        let saved = target.projection.months - months
        guard saved >= 12, let freeDate = others.compactMap(\.projection.payoffDate).max() else { return nil }
        let newDate = LoanMath.dueDate(max(months - 1, 0), first: target.projection.rows.first?.date ?? now)
        title = "\(Money.whole(freed)) a month frees up in \(freeDate.formatted(.dateTime.year()))"
        message = "Once your other loans are paid off in \(freeDate.shortMonthYear), putting their payments toward the \(target.loan.name.lowercased()) pays it off in \(newDate.shortMonthYear), \(DurationText.months(saved)) early."
    }
}

#Preview {
    NavigationStack { DebtsView() }
        .previewEnvironment()
}
