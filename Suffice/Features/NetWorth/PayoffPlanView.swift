import Charts
import SwiftData
import SwiftUI

/// Payoff Plan: try paying a loan off early. Extra each month, a one-time payment, a refinance
/// rate and biweekly payments, with the new payoff date, interest saved and the balance over
/// time next to the schedule as it stands. Any loan can be picked from the list at the top.
struct PayoffPlanView: View {
    let startingLoan: Loan
    @Environment(\.modelContext) private var context
    @Query(sort: \Loan.sortOrder) private var loans: [Loan]
    @Query private var bills: [Bill]

    @State private var selectedID: UUID?
    /// Dollars, for the sliders.
    @State private var extra: Double = 0
    @State private var lump: Double = 0
    @State private var rate: Double = 0
    @State private var biweekly = false
    @State private var savedPlan = false
    @State private var addedBill = false

    private var loan: Loan {
        loans.first { $0.id == selectedID } ?? startingLoan
    }

    private var options: PayoffOptions {
        PayoffOptions(
            extraMonthlyCents: Int((extra * 100).rounded()),
            lumpSumCents: Int((lump * 100).rounded()),
            biweekly: biweekly,
            annualRate: rate == loan.annualRate ? nil : rate
        )
    }

    var body: some View {
        let loan = self.loan
        let comparison = LoanMath.compare(loan.record, options: options)
        let limits = Limits(loan: loan, balanceCents: comparison.balanceCents)

        GreenScreen("Payoff Plan") {
            LoanPicker(loans: loans.filter { !$0.isPaidOff }, selected: loan) { select($0) }

            GlassCard {
                GlassCardHeader(title: "Paid off", note: savedNote(comparison))
                GlassFigure(text: comparison.plan.neverPaysOff ? "Never" : comparison.plan.payoffDate?.shortMonthYear ?? "Now", color: comparison.plan.neverPaysOff ? Brand.expenseInk : .primary)
                HStack(spacing: 10) {
                    GlassTile(title: "Interest saved", value: Money.whole(comparison.interestSavedCents), color: Brand.greenInk)
                    GlassTile(title: "Each month", value: Money.whole(comparison.monthlyCents))
                }
            }
            .accessibilityElement(children: .combine)

            BalanceChart(comparison: comparison)

            SectionTitle("Try a change")
            Card {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        valueLine("Extra each month", "+" + Money.whole(options.extraMonthlyCents))
                        Slider(value: $extra, in: 0...max(limits.extraMax, extra), step: limits.extraStep) {
                            Text("Extra each month")
                        }
                        HStack(spacing: 8) {
                            ForEach(limits.quick, id: \.self) { amount in
                                Button("+\(Money.whole(Int(amount * 100)))") {
                                    withAnimation(.snappy) { extra = amount }
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(extra == amount ? .white : Brand.green)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 34)
                                .background(extra == amount ? Brand.green : Brand.green.opacity(0.12), in: .capsule)
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        valueLine("One-time payment", Money.whole(options.lumpSumCents))
                        Slider(value: $lump, in: 0...max(limits.lumpMax, lump), step: limits.lumpStep) {
                            Text("One-time payment")
                        }
                        Text("A bonus or tax refund, straight to principal.")
                            .font(.footnote)
                            .foregroundStyle(Brand.secondaryText)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        valueLine("Interest rate", rate.formatted(.number.precision(.fractionLength(0...3))) + "%")
                        Slider(value: $rate, in: 0...max(limits.rateMax, rate), step: 0.125) {
                            Text("Interest rate")
                        }
                        if rate == loan.annualRate {
                            Text("Your current rate. Slide it to see a refinance.")
                                .font(.footnote)
                                .foregroundStyle(Brand.secondaryText)
                        } else {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Refinanced for the same time left: \(Money.text(comparison.requiredPaymentCents)) a month before extras.")
                                    .font(.footnote)
                                    .foregroundStyle(Brand.secondaryText)
                                Spacer(minLength: 8)
                                Button("Use My Rate") { withAnimation(.snappy) { rate = loan.annualRate } }
                                    .font(.footnote.weight(.semibold))
                            }
                        }
                    }

                    Divider()

                    Toggle(isOn: $biweekly) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pay every two weeks")
                            Text("Half a payment every two weeks, 13 a year")
                                .font(.footnote)
                                .foregroundStyle(Brand.secondaryText)
                        }
                    }
                    .tint(Brand.greenBright)
                }
                .tint(Brand.green)
            }

            SectionTitle("Compared")
            CardList(items: comparisonRows(comparison, loan: loan)) { row in
                HStack {
                    Text(row.label)
                    Spacer(minLength: 8)
                    Text(row.scheduled)
                        .foregroundStyle(Brand.secondaryText)
                        .frame(width: 96, alignment: .trailing)
                    Text(row.plan)
                        .fontWeight(.semibold)
                        .frame(width: 96, alignment: .trailing)
                }
                .font(.subheadline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 16)
                .frame(minHeight: 46)
                .accessibilityElement(children: .combine)
            }

            VStack(spacing: 10) {
                Button { savePlan() } label: {
                    Label(savedPlan ? "Saved as Your Plan" : "Save as My Plan", systemImage: savedPlan ? "checkmark" : "flag.checkered")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 40)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(Brand.green)
                .sensoryFeedback(.success, trigger: savedPlan) { _, new in new }

                Button { addToBills() } label: {
                    Label(addedBill ? "Added to Bills" : "Add Extra Payment to Bills", systemImage: addedBill ? "checkmark" : "calendar.badge.plus")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 40)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(options.extraMonthlyCents == 0)
                .sensoryFeedback(.success, trigger: addedBill) { _, new in new }
            }

            Text("Estimates assume the rate stays fixed and payments are on time. Ask your lender how extra payments are applied.")
                .font(.footnote)
                .foregroundStyle(Brand.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .onAppear {
            if selectedID == nil { select(startingLoan) }
        }
        .onChange(of: options) { savedPlan = false; addedBill = false }
    }

    private func valueLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(Brand.green)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }

    private func select(_ loan: Loan) {
        selectedID = loan.id
        extra = Double(loan.extraMonthlyCents) / 100
        lump = 0
        rate = loan.annualRate
        biweekly = false
    }

    private func savedNote(_ comparison: PayoffComparison) -> String {
        if comparison.plan.neverPaysOff { return "Payment too low" }
        let saved = comparison.monthsSaved
        if saved > 0 { return DurationText.months(saved) + " sooner" }
        if saved < 0 { return DurationText.months(-saved) + " later" }
        return "On schedule"
    }

    private struct ComparisonRow: Identifiable {
        var label: String
        var scheduled: String
        var plan: String
        var id: String { label }
    }

    private func comparisonRows(_ comparison: PayoffComparison, loan: Loan) -> [ComparisonRow] {
        func date(_ projection: LoanProjection) -> String {
            projection.neverPaysOff ? "Never" : projection.payoffDate?.shortMonthYear ?? "—"
        }
        return [
            ComparisonRow(label: "Each month", scheduled: Money.whole(loan.paymentCents), plan: Money.whole(comparison.monthlyCents)),
            ComparisonRow(label: "Paid off", scheduled: date(comparison.scheduled), plan: date(comparison.plan)),
            ComparisonRow(label: "Interest ahead", scheduled: Money.whole(comparison.scheduled.totalInterestCents), plan: Money.whole(comparison.plan.totalInterestCents)),
            ComparisonRow(label: "Total to pay", scheduled: Money.whole(comparison.balanceCents + comparison.scheduled.totalInterestCents), plan: Money.whole(comparison.balanceCents + comparison.plan.totalInterestCents)),
        ]
    }

    /// Keeps the extra each month as the loan's plan, so Debts and the loan's page project with it.
    private func savePlan() {
        loan.extraMonthlyCents = options.extraMonthlyCents
        try? context.save()
        savedPlan = true
    }

    /// A monthly bill for the extra payment, due with the loan, so it shows up in Bills.
    /// Updates the one added before instead of adding another.
    private func addToBills() {
        let loan = self.loan
        let cents = options.extraMonthlyCents
        guard cents > 0 else { return }
        let next = LoanMath.nextDueDate(first: loan.firstPaymentDate, after: .now)
        let name = "Extra to \(loan.name)"
        let bill = bills.first { $0.isActive && $0.name == name } ?? {
            let added = Bill(name: name, amountCents: cents, dueDay: Calendar.current.component(.day, from: next), color: loan.color)
            context.insert(added)
            return added
        }()
        bill.amountCents = cents
        bill.frequency = .monthly
        bill.interval = 1
        bill.startDate = next
        bill.note = "Extra principal for \(loan.name), from Payoff Plan."
        try? context.save()
        addedBill = true
    }
}

/// Slider ranges that fit the loan: up to about one more payment a month, and up to about 15%
/// of the balance at once.
private struct Limits {
    var extraMax: Double
    var extraStep: Double
    var lumpMax: Double
    var lumpStep: Double
    var rateMax: Double
    var quick: [Double]

    init(loan: Loan, balanceCents: Int) {
        let payment = Double(loan.paymentCents) / 100
        let step: Double = payment >= 1_000 ? 25 : (payment >= 200 ? 10 : 5)
        extraStep = step
        extraMax = max((payment / step).rounded(.up) * step, step * 20)
        let balance = Double(balanceCents) / 100
        let lumpStep: Double = balance >= 100_000 ? 500 : (balance >= 10_000 ? 100 : 25)
        self.lumpStep = lumpStep
        lumpMax = max(min((balance * 0.15 / lumpStep).rounded(.up) * lumpStep, (balance / lumpStep).rounded(.up) * lumpStep), lumpStep * 10)
        rateMax = max(12, (loan.annualRate + 4).rounded(.up))
        quick = payment >= 1_000 ? [100, 250, 500] : (payment >= 200 ? [25, 50, 100] : [10, 25, 50])
    }
}

/// The loan to plan for: its ring, name and balance in a glass capsule over the green; tapping
/// it lists every loan.
private struct LoanPicker: View {
    var loans: [Loan]
    var selected: Loan
    var select: (Loan) -> Void

    var body: some View {
        ChoicePopoverButton(sections: [loans.map { loan in
            ChoiceItem(id: loan.id.uuidString, title: loan.name, systemImage: loan.symbol, isSelected: loan.id == selected.id) { select(loan) }
        }]) {
            HStack(spacing: 12) {
                Image(systemName: selected.symbol)
                    .font(.headline)
                    .foregroundStyle(selected.color.color)
                    .frame(width: 40, height: 40)
                    .background(.white, in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(selected.name).font(.headline)
                    Text(selected.subtitle)
                        .font(.footnote)
                        .opacity(0.85)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.leading, 6)
            .padding(.trailing, 16)
            .frame(minHeight: 54)
            .contentShape(.capsule)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Loan: \(selected.name)")
        .accessibilityHint("Picks another loan")
    }
}

/// What's owed over time: the schedule as it stands (dashed) and the plan (filled).
private struct BalanceChart: View {
    var comparison: PayoffComparison

    private struct Point: Identifiable {
        var series: String
        var date: Date
        var dollars: Double
        var id: String { "\(series)-\(date.timeIntervalSince1970)" }
    }

    var body: some View {
        let scheduled = points(comparison.scheduled, series: "As scheduled", start: comparison.balanceCents)
        let plan = points(comparison.plan, series: "This plan", start: comparison.balanceCents)
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Chart {
                    ForEach(scheduled) { point in
                        LineMark(x: .value("Date", point.date), y: .value("Balance", point.dollars), series: .value("Plan", point.series))
                            .foregroundStyle(Color(.systemGray2))
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    }
                    ForEach(plan) { point in
                        AreaMark(x: .value("Date", point.date), y: .value("Balance", point.dollars), series: .value("Plan", point.series))
                            .foregroundStyle(LinearGradient(colors: [CategoryColor.green.color.opacity(0.26), CategoryColor.green.color.opacity(0)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Date", point.date), y: .value("Balance", point.dollars), series: .value("Plan", point.series))
                            .foregroundStyle(CategoryColor.green.color)
                            .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
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
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: .dateTime.year())
                    }
                }
                .frame(height: 180)
                .accessibilityLabel("Balance over time, as scheduled and with this plan")

                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Capsule().stroke(Color(.systemGray2), style: StrokeStyle(lineWidth: 2, dash: [3, 2])).frame(width: 16, height: 2)
                        Text("As scheduled")
                    }
                    HStack(spacing: 6) {
                        Capsule().fill(CategoryColor.green.color).frame(width: 16, height: 3)
                        Text("This plan")
                    }
                }
                .font(.caption)
                .foregroundStyle(Brand.secondaryText)
                .accessibilityHidden(true)
            }
        }
    }

    /// Today's balance, then about 120 points along the way, then zero.
    private func points(_ projection: LoanProjection, series: String, start: Int) -> [Point] {
        var result = [Point(series: series, date: .now, dollars: Double(start) / 100)]
        let rows = projection.rows
        let every = max(rows.count / 120, 1)
        for (offset, row) in rows.enumerated() where offset % every == 0 || offset == rows.count - 1 {
            result.append(Point(series: series, date: row.date, dollars: Double(row.balanceCents) / 100))
        }
        return result
    }
}
