import SwiftData
import SwiftUI

/// Net Worth › Emergency fund: how many months of essentials the household could cover from
/// savings if both paychecks stopped, against a goal. Below, the goal, which accounts count
/// toward it, and which budgets are essential.
struct EmergencyFundView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var entries: [LedgerEntry]
    @Query(sort: \Loan.sortOrder) private var loans: [Loan]
    @Query(filter: #Predicate<Stash> { $0.isArchived == false }, sort: \Stash.sortOrder) private var stashes: [Stash]
    @State private var settings = PlanningSettings.shared
    @State private var stashing: StashSheetItem?

    var body: some View {
        let records = entries.map(\.record)
        let lines = EmergencyFund.accounts(accounts, entries: records)
        let runway = EmergencyFund.runway(categories: categories, accounts: accounts, loans: loans, stashes: stashes, entries: records, settings: settings)
        let budgets = EmergencyFund.budgets(categories)

        GreenScreen("Emergency Fund") {
            RunwayCard(runway: runway)

            goalCard(runway, lines: lines)

            SectionTitle("What counts toward it")
            if lines.isEmpty {
                EmptyCard(systemName: "banknote", title: "No accounts yet", message: "Add your savings account on Overview, and it counts here.")
            } else {
                CardList(items: lines, inset: 68) { line in
                    accountRow(line)
                }
            }

            SectionTitle("Essentials each month")
            essentialsCard(budgets)

            Text("Essentials are what you’d still pay with no income: each budget’s planned amount. Turn on loan payments only when no essential budget already plans them. Ask can answer “how long could we last?”.")
                .font(.footnote)
                .foregroundStyle(Brand.secondaryText)
                .padding(.horizontal, 6)
        }
        .refreshable { await HouseholdSync.shared.syncNow() }
        .sheet(item: $stashing) { item in
            StashEditor(stash: item.stash, initial: item.draft)
        }
    }

    // MARK: Goal

    private func goalCard(_ runway: Runway, lines: [EmergencyFund.AccountLine]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $settings.runwayGoalMonths, in: 1...12) {
                    HStack {
                        Text("Goal")
                        Spacer()
                        Text(runway.goalMonths == 1 ? "1 month" : "\(runway.goalMonths) months")
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                }
                Text(advice(runway))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if runway.gapCents > 0, runway.essentialsCents > 0 {
                    Button {
                        let account = lines.first { $0.account.countsTowardEmergencyFund }?.account.id
                        stashing = StashSheetItem(stash: nil, draft: .emergencyFund(gapCents: runway.gapCents, accountID: account))
                    } label: {
                        Text("Stash \(Money.whole(runway.gapCents))")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                            .background(Brand.green, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Starts a stash for the rest of the goal, over a year")
                }
            }
        }
    }

    private func advice(_ runway: Runway) -> String {
        guard runway.essentialsCents > 0 else {
            return "Pick what’s essential below: the budgets you’d still pay with no income."
        }
        if runway.gapCents > 0 {
            return "You’re \(Money.whole(runway.gapCents)) short of \(runway.goalMonths) months. Saving \(Money.whole(runway.monthlyToCloseCents)) a month gets you there in a year."
        }
        return "You’re past your goal by \(Money.whole(runway.overCents)). Anything over it could go toward a loan or investing."
    }

    // MARK: Accounts

    private func accountRow(_ line: EmergencyFund.AccountLine) -> some View {
        let account = line.account
        return Toggle(isOn: Binding(
            get: { account.countsTowardEmergencyFund },
            set: { on in
                account.isEmergencyFund = on
                try? context.save()
            }
        )) {
            HStack(spacing: 12) {
                InstitutionLogo(name: account.institution.isEmpty ? account.name : account.institution, colorHex: account.colorHex, isCard: false, size: 40, domain: account.institutionDomain)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.kind == .cash ? "Cash" : account.displayName)
                        .lineLimit(1)
                    Text("\(account.kind.name) · \(Money.whole(line.balanceCents))")
                        .font(.caption)
                        .foregroundStyle(Brand.secondaryText)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 64)
    }

    // MARK: Essentials

    /// One row of the essentials list.
    private struct EssentialItem: Identifiable {
        var id: String
        var name: String
        var color: CategoryColor
        var cents: Int
        var isOn: Bool
        var indent: Bool
        var toggle: () -> Void
    }

    /// Every budget with its plan (a budget that isn't essential lists its subcategories under
    /// it, so one of those can count alone), loan payments, and the yearly stashes.
    private func essentialItems(_ budgets: [CategoryStatus]) -> [EssentialItem] {
        let lookup = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var items: [EssentialItem] = []
        for status in budgets {
            guard let category = lookup[status.id] else { continue }
            items.append(EssentialItem(id: category.id.uuidString, name: category.name, color: category.color, cents: status.limitCents, isOn: category.countsAsEssential, indent: false) {
                category.isEssential = !category.countsAsEssential
                try? context.save()
            })
            guard !category.countsAsEssential else { continue }
            for child in status.children {
                guard let sub = lookup[child.id] else { continue }
                items.append(EssentialItem(id: sub.id.uuidString, name: "\(category.name) › \(sub.name)", color: category.color, cents: child.limitCents, isOn: sub.countsAsEssential, indent: true) {
                    sub.isEssential = !sub.countsAsEssential
                    try? context.save()
                })
            }
        }
        let payments = EmergencyFund.loanPayments(loans)
        if payments > 0 {
            items.append(EssentialItem(id: "loans", name: "Loan payments", color: .gray, cents: payments, isOn: settings.loansAreEssential, indent: false) {
                settings.loansAreEssential.toggle()
            })
        }
        for stash in stashes where stash.repeatsYearly {
            items.append(EssentialItem(id: stash.id.uuidString, name: "Stash: \(stash.name)", color: stash.color, cents: RunwayMath.monthlyShare(of: stash.record), isOn: stash.isEssential, indent: false) {
                stash.isEssential.toggle()
                try? context.save()
            })
        }
        return items
    }

    @ViewBuilder
    private func essentialsCard(_ budgets: [CategoryStatus]) -> some View {
        let items = essentialItems(budgets)
        if items.isEmpty {
            EmptyCard(systemName: "list.bullet", title: "No plans yet", message: "Give your budgets monthly amounts, and pick the ones you’d still pay with no income.")
        } else {
            CardList(items: items, inset: 38) { item in
                essentialRow(name: item.name, color: item.color, cents: item.cents, isOn: item.isOn, indent: item.indent, toggle: item.toggle)
            }
        }
    }

    private func essentialRow(name: String, color: CategoryColor, cents: Int, isOn: Bool, indent: Bool, toggle: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { toggle() }
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(color.color)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(name)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text("\(Money.whole(cents))/mo")
                    .font(.subheadline)
                    .foregroundStyle(Brand.secondaryText)
                    .monospacedDigit()
                Image(systemName: "checkmark")
                    .fontWeight(.bold)
                    .foregroundStyle(Brand.green)
                    .opacity(isOn ? 1 : 0)
                    .frame(width: 22, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .padding(.leading, indent ? 32 : 16)
            .padding(.trailing, 16)
            .frame(minHeight: 52)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityHint(isOn ? "Counts as essential. Tap to leave it out." : "Tap to count it as essential")
    }
}

/// The glass card: months of essentials, a gauge with the goal marked, saved and essentials.
private struct RunwayCard: View {
    var runway: Runway

    var body: some View {
        GlassCard {
            GlassCardHeader(title: "If both paychecks stopped", note: "Goal \(runway.goalMonths) month\(runway.goalMonths == 1 ? "" : "s")")
            if let text = EmergencyFund.monthsText(runway) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    GlassFigure(text: text)
                        .fixedSize()
                    Text("months of essentials")
                        .font(.headline)
                        .foregroundStyle(Brand.greenInk)
                }
                RunwayGauge(months: runway.months ?? 0, goal: runway.goalMonths)
            } else {
                Text("Pick what’s essential")
                    .font(.title2.bold())
            }
            HStack(spacing: 10) {
                GlassTile(title: "Saved for it", value: Money.whole(runway.savedCents))
                GlassTile(title: "Essentials a month", value: Money.whole(runway.essentialsCents))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// How far the months reach toward the goal, the goal marked with a line.
struct RunwayGauge: View {
    var months: Double
    var goal: Int

    var body: some View {
        let scale = max(Double(goal) * 1.25, months, 1)
        let color: Color = months >= Double(goal) ? Brand.green : (months >= 3 ? CategoryColor.green.color : CategoryColor.orange.color)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.green.opacity(0.14))
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * min(months / scale, 1))
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.primary)
                    .frame(width: 3, height: 18)
                    .offset(x: proxy.size.width * Double(goal) / scale - 1.5)
            }
        }
        .frame(height: 10)
        .animation(.smooth, value: months)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(months.formatted(.number.precision(.fractionLength(1)))) of \(goal) months")
    }
}

#Preview {
    NavigationStack { EmergencyFundView() }
        .previewEnvironment()
}
