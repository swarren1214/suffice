import SwiftData
import SwiftUI

/// Budget: what's left this month, then every budget as a tile with its ring and what's left.
/// Tapping a tile opens its budget sheet.
struct BudgetView: View {
    @Environment(AppRouter.self) private var router
    @State private var showsNewBudget = false

    var body: some View {
        MonthBudget(month: router.month)
            .id(router.month)
            .tabToolbar {
                Button {
                    showsNewBudget = true
                } label: {
                    Label("New Budget", systemImage: "plus")
                        .foregroundStyle(.white)
                }
            }
            .sheet(isPresented: $showsNewBudget) {
                BudgetSheet(category: nil, month: router.month)
            }
    }
}

private struct MonthBudget: View {
    let month: MonthSpan
    @Query private var entries: [LedgerEntry]
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @State private var opened: BudgetCategory?

    init(month: MonthSpan) {
        self.month = month
        let start = month.start
        let end = month.end
        _entries = Query(filter: #Predicate<LedgerEntry> { $0.date >= start && $0.date < end })
    }

    var body: some View {
        let records = entries.map(\.record)
        let categoryRecords = categories.map(\.record)
        let statuses = BudgetMath.statuses(categoryRecords, entries: records, in: month)
        let totals = BudgetMath.totals(categoryRecords, entries: records, in: month)
        let lookup = Lookup(categories: categories)
        let leftText = totals.leftCents >= 0 ? "\(Money.text(totals.leftCents)) left" : "\(Money.text(-totals.leftCents)) over"

        GreenScreen("Budget", trailing: totals.budgetedCents > 0 ? leftText : nil) {
            if statuses.isEmpty {
                EmptyCard(systemName: "dollarsign.circle", title: "No budgets yet", message: "Tap + to plan what each part of the month gets.")
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(statuses) { status in
                        if let category = lookup.categories[status.id] {
                            Button { opened = category } label: {
                                BudgetTile(category: category, status: status)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if totals.uncategorizedCents > 0 {
                Card {
                    HStack {
                        Label("Uncategorized", systemImage: "questionmark.circle")
                        Spacer()
                        Text(Money.text(totals.uncategorizedCents))
                            .fontWeight(.semibold)
                            .foregroundStyle(Brand.expenseInk)
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                }
            }
        }
        .sheet(item: $opened) { category in
            BudgetSheet(category: category, month: month)
        }
    }
}

/// One budget as a tile: its ring, its name, what's left, and spent of planned.
private struct BudgetTile: View {
    var category: BudgetCategory
    var status: CategoryStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                CategoryRing(progress: status.progress, color: category.color, symbol: category.symbol, size: 44)
                Spacer(minLength: 4)
                if status.limitCents > 0 {
                    Text(status.progress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(status.leftCents >= 0 ? Brand.secondaryText : Brand.expenseInk)
                        .monospacedDigit()
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(category.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(status.leftCents >= 0 ? "\(Money.whole(status.leftCents)) left" : "\(Money.whole(-status.leftCents)) over")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(status.leftCents >= 0 ? Brand.green : Brand.expenseInk)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(status.limitCents > 0 ? "\(Money.whole(status.spentCents)) of \(Money.whole(status.limitCents))" : "\(Money.whole(status.spentCents)) spent, no plan")
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
        .accessibilityLabel(category.name)
        .accessibilityValue(status.leftCents >= 0
            ? "\(Money.whole(status.leftCents)) left of \(Money.whole(status.limitCents))"
            : "\(Money.whole(-status.leftCents)) over \(Money.whole(status.limitCents))")
        .accessibilityHint("Opens the budget")
    }
}

#Preview {
    NavigationStack { BudgetView() }
        .previewEnvironment()
}
