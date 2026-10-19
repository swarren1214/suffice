import SwiftData
import SwiftUI

/// Net Worth's Emergency fund card: months of essentials and the gap to the goal (or "Past your
/// goal"). Opens the Emergency Fund screen.
struct EmergencyFundCard: View {
    @Query private var categories: [BudgetCategory]
    @Query private var accounts: [Account]
    @Query private var entries: [LedgerEntry]
    @Query private var loans: [Loan]
    @Query(filter: #Predicate<Stash> { $0.isArchived == false }) private var stashes: [Stash]
    @State private var settings = PlanningSettings.shared

    var body: some View {
        let runway = EmergencyFund.runway(categories: categories, accounts: accounts, loans: loans, stashes: stashes, entries: entries.map(\.record), settings: settings)
        NavigationLink {
            EmergencyFundView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "shield")
                    .font(.headline)
                    .foregroundStyle(CategoryColor.orange.ink)
                    .frame(width: 40, height: 40)
                    .background(CategoryColor.orange.tint, in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Emergency fund")
                        .font(.subheadline)
                        .foregroundStyle(Brand.secondaryText)
                    if let months = EmergencyFund.monthsText(runway) {
                        Text("\(months) months of essentials")
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                        if runway.gapCents > 0 {
                            Text("\(Money.whole(runway.gapCents)) short of \(runway.goalMonths) months")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(CategoryColor.orange.ink)
                                .monospacedDigit()
                        } else {
                            Text("Past your goal of \(runway.goalMonths) months")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Brand.greenInk)
                        }
                    } else {
                        Text("Pick what’s essential")
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
            .contentShape(.rect(cornerRadius: 26))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the emergency fund")
    }
}
