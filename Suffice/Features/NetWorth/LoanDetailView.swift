import Charts
import SwiftData
import SwiftUI

/// One loan: its balance and how much is paid off, the facts, how the next payment splits,
/// each year's payments as a chart, and the amortization schedule. Plan a Payoff opens
/// Payoff Plan on it.
struct LoanDetailView: View {
    @Bindable var loan: Loan
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var scheduleView: ScheduleView = .yearly
    @State private var showsAllMonths = false
    @State private var purchases = HearthPurchases.shared

    enum ScheduleView: String, CaseIterable, Identifiable {
        case yearly, monthly
        var id: String { rawValue }
        var title: String { self == .yearly ? "Yearly" : "Monthly" }
    }

    var body: some View {
        let record = loan.record
        let balance = LoanMath.currentBalance(record)
        let projection = LoanMath.projection(record)
        let paidShare = LoanMath.paidShare(originalCents: loan.originalCents, balanceCents: balance)
        let rate = loan.annualRate.formatted(.number.precision(.fractionLength(0...3))) + "%"

        GreenScreen(loan.name, trailing: loan.isPaidOff ? "Paid off" : rate) {
            GlassCard {
                GlassCardHeader(title: "Balance", note: "\(Int((paidShare * 100).rounded()))% paid off")
                GlassFigure(text: Money.text(balance))
                ProgressBar(progress: paidShare, color: Brand.green, track: .primary.opacity(0.1))
                HStack(spacing: 10) {
                    GlassTile(title: "Monthly payment", value: Money.text(loan.paymentCents + loan.escrowCents))
                    GlassTile(title: "Paid off", value: payoffText(projection))
                }
            }
            .accessibilityElement(children: .combine)

            facts(balance: balance, projection: projection)

            if !loan.isPaidOff, let next = projection.rows.first {
                SectionTitle("Next payment · \(next.date.formatted(.dateTime.month(.abbreviated).day()))")
                NextPaymentCard(row: next, crossover: projection.rows.first { $0.principalCents > $0.interestCents }?.date)

                SectionTitle("Each year’s payments")
                YearlyChart(years: projection.years())

                SectionTitle(title: "Schedule") {
                    Picker("Schedule", selection: $scheduleView) {
                        ForEach(ScheduleView.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
                ScheduleTable(projection: projection, view: scheduleView, showsAllMonths: $showsAllMonths)

                // The payoff planner comes with Suffice Plus or Hearth+; the loan and its
                // schedule are free.
                if purchases.isUnlocked {
                    NavigationLink {
                        PayoffPlanView(startingLoan: loan)
                    } label: {
                        Label("Plan a Payoff", systemImage: "slider.horizontal.3")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 40)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .tint(Brand.green)
                } else {
                    HearthLockedCard(
                        "Plan a payoff",
                        detail: "Try extra payments, a lump sum, a new rate or biweekly payments, and see the payoff date and interest saved."
                    )
                }
            }
        }
        .refreshable { await HouseholdSync.shared.syncNow() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = true } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
        }
        .sheet(isPresented: $editing) {
            LoanEditor(loan: loan, onDelete: { dismiss() })
        }
    }

    private func payoffText(_ projection: LoanProjection) -> String {
        if loan.isPaidOff { return "Done" }
        if projection.neverPaysOff { return "Never" }
        return projection.payoffDate?.shortMonthYear ?? "Done"
    }

    private func facts(balance: Int, projection: LoanProjection) -> some View {
        let record = loan.record
        var rows: [Fact] = []
        if !loan.lender.isEmpty { rows.append(Fact(label: "Lender", value: loan.lender)) }
        rows.append(Fact(label: "Borrowed", value: "\(Money.whole(loan.originalCents)) · \(loan.firstPaymentDate.shortMonthYear)"))
        rows.append(Fact(label: "Term", value: DurationText.months(loan.termMonths)))
        if !loan.isPaidOff {
            rows.append(Fact(label: "Time left", value: projection.neverPaysOff ? "—" : DurationText.months(projection.months)))
            rows.append(Fact(label: "Interest paid so far", value: Money.whole(LoanMath.interestPaid(record))))
            rows.append(Fact(label: "Interest still ahead", value: projection.neverPaysOff ? "—" : Money.whole(projection.totalInterestCents)))
        }
        if loan.escrowCents > 0 {
            rows.append(Fact(label: "Escrow each month", value: Money.text(loan.escrowCents)))
        }
        if loan.extraMonthlyCents > 0 {
            rows.append(Fact(label: "Your plan", value: "+\(Money.whole(loan.extraMonthlyCents)) a month"))
        }
        rows.append(Fact(label: "Balance as of", value: DateLabel.short(loan.balanceDate)))
        return CardList(items: rows) { fact in
            LabeledContent(fact.label) {
                Text(fact.value).monospacedDigit()
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
        }
    }

    private struct Fact: Identifiable {
        var label: String
        var value: String
        var id: String { label }
    }
}

/// The next payment: a bar split into principal and interest, the two amounts, and when
/// principal overtakes interest.
private struct NextPaymentCard: View {
    var row: AmortizationRow
    var crossover: Date?

    var body: some View {
        let share = row.paymentCents > 0 ? Double(row.interestCents) / Double(row.paymentCents) : 0
        Card {
            VStack(alignment: .leading, spacing: 12) {
                GeometryReader { proxy in
                    HStack(spacing: 3) {
                        Capsule().fill(CategoryColor.green.color)
                            .frame(width: max((proxy.size.width - 3) * (1 - share), 4))
                        Capsule().fill(CategoryColor.orange.color)
                    }
                }
                .frame(height: 10)
                .accessibilityHidden(true)
                HStack(spacing: 10) {
                    SplitTile(title: "To principal", value: Money.text(row.principalCents), color: .green)
                    SplitTile(title: "To interest", value: Money.text(row.interestCents), color: .orange)
                }
                Text(sentence(share: share))
                    .font(.subheadline)
                    .foregroundStyle(Brand.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sentence(share: Double) -> String {
        let percent = Int((share * 100).rounded())
        guard let crossover else { return "\(percent)% of this payment is interest." }
        if crossover <= row.date { return "\(percent)% of this payment is interest; most of it now goes to principal." }
        return "\(percent)% of this payment is interest. More goes to principal than interest starting \(crossover.shortMonthYear)."
    }
}

private struct SplitTile: View {
    var title: String
    var value: String
    var color: CategoryColor

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(color.color).frame(width: 8, height: 8)
                Text(title)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 19, weight: .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.systemGroupedBackground), in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
}

/// Principal and interest paid each year, stacked.
private struct YearlyChart: View {
    var years: [AmortizationYear]

    var body: some View {
        Card {
            Chart {
                ForEach(years) { year in
                    BarMark(x: .value("Year", String(year.year)), y: .value("Amount", Double(year.principalCents) / 100))
                        .foregroundStyle(by: .value("Part", "Principal"))
                    BarMark(x: .value("Year", String(year.year)), y: .value("Amount", Double(year.interestCents) / 100))
                        .foregroundStyle(by: .value("Part", "Interest"))
                }
            }
            .chartForegroundStyleScale(["Principal": CategoryColor.green.color, "Interest": CategoryColor.orange.color])
            .chartLegend(position: .bottom, alignment: .leading)
            .chartXAxis {
                // The first year, then every fifth.
                AxisMarks(values: years.filter { $0.year % 5 == 0 || $0.year == years.first?.year }.map { String($0.year) }) { _ in
                    AxisValueLabel()
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let dollars = value.as(Double.self) { Text(Money.compact(Int(dollars * 100))) }
                    }
                }
            }
            .frame(height: 190)
            .accessibilityLabel("Principal and interest paid each year")
        }
    }
}

/// The amortization schedule: a row a year, or a row a month (the next two years, then all of
/// them on request).
private struct ScheduleTable: View {
    var projection: LoanProjection
    var view: LoanDetailView.ScheduleView
    @Binding var showsAllMonths: Bool

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                row(view == .yearly ? "Year" : "Month", "Principal", "Interest", "Balance", isHeader: true)
                Divider()
                LazyVStack(spacing: 0) {
                    if view == .yearly {
                        ForEach(projection.years()) { year in
                            row(String(year.year), Money.whole(year.principalCents), Money.whole(year.interestCents), Money.whole(year.balanceCents))
                        }
                    } else {
                        ForEach(showsAllMonths ? projection.rows : Array(projection.rows.prefix(24))) { payment in
                            row(payment.date.formatted(.dateTime.month(.abbreviated).year(.twoDigits)), Money.whole(payment.principalCents), Money.whole(payment.interestCents), Money.whole(payment.balanceCents))
                        }
                    }
                }
                if view == .monthly && projection.rows.count > 24 {
                    Divider()
                    Button(showsAllMonths ? "Show Fewer" : "Show All \(projection.rows.count) Payments") {
                        withAnimation(.smooth) { showsAllMonths.toggle() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
            }
        }
    }

    private func row(_ period: String, _ principal: String, _ interest: String, _ balance: String, isHeader: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(period).frame(maxWidth: .infinity, alignment: .leading)
            Text(principal).frame(maxWidth: .infinity, alignment: .trailing)
                .foregroundStyle(isHeader ? Brand.secondaryText : CategoryColor.green.ink)
            Text(interest).frame(maxWidth: .infinity, alignment: .trailing)
                .foregroundStyle(isHeader ? Brand.secondaryText : CategoryColor.orange.ink)
            Text(balance).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(isHeader ? .caption.weight(.semibold) : .subheadline)
        .foregroundStyle(isHeader ? Brand.secondaryText : .primary)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 16)
        .padding(.vertical, isHeader ? 10 : 9)
        .accessibilityElement(children: .combine)
    }
}
