import Charts
import SwiftUI

// Pieces shared by Net Worth, Debts, a loan's page, Payoff Plan and the Overview card.

/// Everything Net Worth adds up, worked out once per render.
struct WealthSummary {
    var totals: NetWorthTotals
    /// Each loan's balance today, by ID. Paid-off loans aren't listed.
    var loanBalances: [UUID: Int]
    /// Each account's balance (cash) or amount owed (cards), by ID.
    var accountBalances: [UUID: Int]

    init(accounts: [Account], entries: [LedgerEntry], loans: [Loan], assets: [OwnedAsset], now: Date = .now) {
        let records = entries.map(\.record)
        var loanBalances: [UUID: Int] = [:]
        for loan in loans where !loan.isPaidOff {
            loanBalances[loan.id] = LoanMath.currentBalance(loan.record, on: now)
        }
        var accountBalances: [UUID: Int] = [:]
        for account in accounts {
            accountBalances[account.id] = account.kind == .credit
                ? NetWorthMath.owed(onCard: account.record, entries: records)
                : BudgetMath.balance(of: account.record, entries: records)
        }
        self.totals = NetWorthMath.totals(
            accounts: accounts.map(\.record),
            entries: records,
            assetCents: assets.map(\.valueCents),
            loanCents: Array(loanBalances.values)
        )
        self.loanBalances = loanBalances
        self.accountBalances = accountBalances
    }
}

/// A loan's ring: how much of what was borrowed is paid off, with its icon inside. Drawn like
/// a budget's ring.
struct PaidRing: View {
    var progress: Double
    var color: CategoryColor
    var symbol: String
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.systemGray6), lineWidth: size * 0.104)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(color.color, style: StrokeStyle(lineWidth: size * 0.104, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: symbol)
                .font(.system(size: size * 0.36, weight: .medium))
                .foregroundStyle(color.color)
        }
        .padding(size * 0.042)
        .frame(width: size, height: size)
        .animation(.smooth, value: progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int((min(max(progress, 0), 1) * 100).rounded())) percent paid off")
    }
}

/// An asset's icon on a pale circle of its color.
struct WealthIcon: View {
    var symbol: String
    var color: CategoryColor
    var size: CGFloat = 40
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(isDark ? color.color : color.ink)
            .frame(width: size, height: size)
            .background(isDark ? color.color.opacity(0.22) : color.tint, in: .circle)
            .accessibilityHidden(true)
    }
}

/// What's owed, in the red of spending pills.
struct OwedPill: View {
    var cents: Int

    var body: some View {
        Text(Money.whole(cents))
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Brand.expense, in: .capsule)
            .accessibilityLabel("Owes \(Money.whole(cents))")
    }
}

/// A row in a Net Worth list: an icon, a name and a detail line, and an amount on the right.
struct WealthRow<Leading: View, Trailing: View>: View {
    var title: String
    var detail: String
    var showsChevron = false
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            leading()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .frame(minHeight: 62)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// A white card holding rows with hairlines between them, for rows of mixed kinds that
/// CardList can't take as one collection.
struct RowsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content()) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    row
                    if index < rows.count - 1 {
                        Divider().padding(.leading, 66)
                    }
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
    }
}

/// How far back the trend reaches.
enum TrendRange: String, CaseIterable, Identifiable {
    case sixMonths, year, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sixMonths: "6M"
        case .year: "1Y"
        case .all: "All"
        }
    }

    var months: Int? {
        switch self {
        case .sixMonths: 6
        case .year: 12
        case .all: nil
        }
    }
}

/// Net worth month by month, with a range picker.
struct NetWorthTrendCard: View {
    var points: [NetWorthPoint]
    @Binding var range: TrendRange

    var body: some View {
        let shown = visible
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Range", selection: $range) {
                    ForEach(TrendRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                if shown.count < 2 {
                    Text("Your trend fills in month by month. Come back next month to see it move.")
                        .font(.subheadline)
                        .foregroundStyle(Brand.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .multilineTextAlignment(.center)
                } else {
                    let low = Double(shown.map(\.netCents).min() ?? 0) / 100
                    Chart(shown) { point in
                        AreaMark(
                            x: .value("Month", point.month, unit: .month),
                            yStart: .value("Low", low),
                            yEnd: .value("Net worth", Double(point.netCents) / 100)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(
                            LinearGradient(colors: [CategoryColor.green.color.opacity(0.28), CategoryColor.green.color.opacity(0)], startPoint: .top, endPoint: .bottom)
                        )
                        LineMark(
                            x: .value("Month", point.month, unit: .month),
                            y: .value("Net worth", Double(point.netCents) / 100)
                        )
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(CategoryColor.green.color)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let dollars = value.as(Double.self) {
                                    Text(Money.compact(Int(dollars * 100)))
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated))
                        }
                    }
                    .frame(height: 170)
                    .accessibilityLabel("Net worth by month")
                }
            }
        }
    }

    private var visible: [NetWorthPoint] {
        guard let months = range.months, let last = points.last else { return points }
        let cutoff = Calendar.current.date(byAdding: .month, value: -(months - 1), to: last.month) ?? last.month
        return points.filter { $0.month >= cutoff }
    }
}

/// "+$4,210 since last month", for the glass card and the Overview card.
enum NetWorthChange {
    static func note(_ points: [NetWorthPoint]) -> String? {
        guard points.count >= 2 else { return nil }
        let change = points[points.count - 1].netCents - points[points.count - 2].netCents
        guard change != 0 else { return "Same as last month" }
        return (change > 0 ? "+" : "−") + Money.whole(abs(change)) + " since last month"
    }

    static func isUp(_ points: [NetWorthPoint]) -> Bool {
        guard points.count >= 2 else { return true }
        return points[points.count - 1].netCents >= points[points.count - 2].netCents
    }
}

extension Loan {
    /// "PennyMac · 6.25%"
    var subtitle: String {
        let rate = annualRate.formatted(.number.precision(.fractionLength(0...3))) + "%"
        return lender.isEmpty ? rate : "\(lender) · \(rate)"
    }
}

extension Date {
    /// "Jun 2051"
    var shortMonthYear: String { formatted(.dateTime.month(.abbreviated).year()) }
}

/// "24 yrs 7 mo", "8 mo", "1 yr".
enum DurationText {
    static func months(_ count: Int) -> String {
        let years = count / 12
        let months = count % 12
        var parts: [String] = []
        if years > 0 { parts.append(years == 1 ? "1 yr" : "\(years) yrs") }
        if months > 0 || years == 0 { parts.append("\(months) mo") }
        return parts.joined(separator: " ")
    }
}
