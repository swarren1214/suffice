import SwiftData
import SwiftUI

/// Step 4, Plan the month: an amount for each budget, suggested from the last three months of
/// bank transactions when there are some, against the household's income. Use This Plan saves
/// the amounts; I'll Plan Later leaves them.
struct OnboardingPlan: View {
    @Environment(OnboardingFlow.self) private var flow
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @AppStorage(SettingsKey.monthlyIncome) private var savedIncome = 0
    @State private var showsNewBudget = false
    @State private var hasHistory = false
    /// When Add a Budget opened, so only the budget added there joins the list.
    @State private var addingSince = Date.distantFuture
    @FocusState private var focused: UUID?
    @FocusState private var incomeFocused: Bool

    private var monthName: String { router.month.start.formatted(.dateTime.month(.wide)) }

    private var rows: [PlanRow] { flow.planRows ?? [] }
    private var planned: Int { rows.reduce(0) { $0 + (Money.cents(from: $1.amountText) ?? 0) } }
    private var income: Int { Money.cents(from: flow.incomeText) ?? 0 }

    var body: some View {
        @Bindable var flow = flow
        OnboardingStep(
            title: "Plan \(monthName)",
            subtitle: hasHistory
                ? "Suggested from your last three months. Tap any amount to change it."
                : "How much would you like to spend on each this month? You can change any of it later."
        ) {
            incomeCard
            OnboardingCard {
                ForEach($flow.planRows.unwrapped) { $row in
                    if row.id != rows.first?.id { OnboardingDivider(inset: 62) }
                    budgetRow($row)
                }
            }
            OnboardingAddLink(title: "Add a Budget") {
                addingSince = .now
                showsNewBudget = true
            }
        } controls: {
            Button("Use This Plan", action: apply)
                .buttonStyle(.onboarding())
                .disabled(planned == 0)
            Button("I’ll Plan Later") {
                focused = nil
                flow.next()
            }
            .buttonStyle(.onboarding(.plain))
        }
        .onAppear(perform: prepare)
        .sheet(isPresented: $showsNewBudget, onDismiss: addNewBudgets) {
            BudgetSheet(category: nil, month: router.month)
        }
    }

    // MARK: Income

    private var incomeCard: some View {
        @Bindable var flow = flow
        let progress = income > 0 ? min(Double(planned) / Double(income), 1) : 0
        let left = income - planned
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Income each month")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xBFF0CB))
                Spacer()
                TextField("Add", text: $flow.incomeText, prompt: Text("Add").foregroundStyle(.white.opacity(0.6)))
                    .font(.system(size: 17, weight: .bold))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.decimalPad)
                    .focused($incomeFocused)
                    .currencyEditing($flow.incomeText, isFocused: incomeFocused)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .frame(minWidth: 70, minHeight: 34)
                    .background(.white.opacity(0.14), in: .capsule)
                    .accessibilityLabel("Income each month")
            }
            if income > 0 {
                GeometryReader { proxy in
                    Capsule().fill(.white.opacity(0.18))
                        .overlay(alignment: .leading) {
                            Capsule().fill(left < 0 ? Color(hex: 0xFF8A8A) : .white)
                                .frame(width: proxy.size.width * progress)
                        }
                }
                .frame(height: 10)
                .animation(.smooth, value: progress)
                HStack {
                    Text("\(Money.whole(planned)) planned")
                        .foregroundStyle(Color(hex: 0xE5F7E9))
                    Spacer()
                    Text(left >= 0 ? "\(Money.whole(left)) left to plan" : "\(Money.whole(-left)) over income")
                        .fontWeight(.bold)
                }
                .font(.system(size: 13))
                .contentTransition(.numericText())
            } else {
                Text("Add what comes in each month to see how much is left to plan.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: 0xE5F7E9))
            }
        }
        .padding(16)
        .background(
            LinearGradient(colors: [Color(hex: 0x0B6B2A), Color(hex: 0x064A1D)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: .rect(cornerRadius: 24, style: .continuous)
        )
    }

    // MARK: Budgets

    private func budgetRow(_ row: Binding<PlanRow>) -> some View {
        let value = row.wrappedValue
        let isFocused = focused == value.id
        return HStack(spacing: 12) {
            Image(systemName: value.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(value.color.color)
                .frame(width: 36, height: 36)
                .background(value.color.color.opacity(0.2), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(value.name).font(.system(size: 15, weight: .semibold))
                    if value.isNew {
                        Text("New")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(OnboardingStyle.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(OnboardingStyle.accent.opacity(0.16), in: .capsule)
                    }
                }
                if !value.hint.isEmpty {
                    Text(value.hint)
                        .font(.system(size: 12))
                        .foregroundStyle(OnboardingStyle.tertiaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            TextField("$0", text: row.amountText, prompt: Text("$0").foregroundStyle(OnboardingStyle.tertiaryText))
                .font(.system(size: 15, weight: .bold))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
                .focused($focused, equals: value.id)
                .currencyEditing(row.amountText, isFocused: isFocused)
                .padding(.horizontal, 10)
                .frame(width: 96, height: 34)
                .background(.white.opacity(isFocused ? 0.16 : 0.08), in: .rect(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("\(value.name) amount")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: Working it out

    /// The household's budgets, each with the average from the bank history (when there is one)
    /// and a tidy suggestion; plus Shopping when that's where a lot goes and there's no budget
    /// for it. Worked out once; edits survive going back and forth.
    private func prepare() {
        let items = SpendingHistory.items(in: context)
        let averages = SpendingHistory.monthlySpending(items)
        hasHistory = !averages.isEmpty
        guard flow.planRows == nil else { return }

        let categories = ((try? context.fetch(FetchDescriptor<BudgetCategory>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? [])
            .filter { !$0.isArchived }
        let parents = categories.filter { $0.parentID == nil && BudgetMath.isActive($0.record, in: router.month) }
        var rows = parents.map { parent in
            let subs = categories.filter { $0.parentID == parent.id }.map(\.name)
            let average = averages.first { $0.key.localizedCaseInsensitiveCompare(parent.name) == .orderedSame }?.value ?? 0
            let cents = parent.limitCents > 0 ? parent.limitCents : SpendingHistory.suggestion(for: average)
            return PlanRow(
                id: parent.id,
                name: parent.name,
                symbol: parent.symbol,
                color: parent.color,
                hint: hint(subcategories: subs, average: average),
                amountText: Money.field(cents)
            )
        }
        let shopping = SpendingHistory.shopping
        if let average = averages[shopping.name], average >= 5_000,
           !parents.contains(where: { $0.name.localizedCaseInsensitiveCompare(shopping.name) == .orderedSame }) {
            rows.append(PlanRow(
                id: UUID(), name: shopping.name, symbol: shopping.symbol, color: shopping.color,
                hint: hint(subcategories: ["Stores", "online orders"], average: average),
                amountText: Money.field(SpendingHistory.suggestion(for: average)), isNew: true
            ))
        }
        flow.planRows = rows

        if flow.incomeText.isEmpty {
            let income = savedIncome > 0 ? savedIncome : SpendingHistory.suggestion(for: SpendingHistory.monthlyIncome(items))
            flow.incomeText = Money.field(income)
        }
    }

    private func hint(subcategories: [String], average: Int) -> String {
        let names = subcategories.prefix(2).joined(separator: ", ")
        let avg = average > 0 ? "avg \(Money.whole(average))" : ""
        return [names, avg].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// After Add a Budget: any new top-level budget joins the list.
    private func addNewBudgets() {
        guard var rows = flow.planRows else { return }
        let known = Set(rows.map(\.id))
        let categories = (try? context.fetch(FetchDescriptor<BudgetCategory>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        for category in categories where category.parentID == nil && !category.isArchived && !known.contains(category.id) && category.createdAt >= addingSince {
            rows.append(PlanRow(id: category.id, name: category.name, symbol: category.symbol, color: category.color, hint: "", amountText: Money.field(category.limitCents)))
        }
        flow.planRows = rows
    }

    /// Saves every amount, adds the new budgets, and keeps the income.
    private func apply() {
        focused = nil
        incomeFocused = false
        let categories = (try? context.fetch(FetchDescriptor<BudgetCategory>())) ?? []
        var nextOrder = (categories.filter { $0.parentID == nil }.map(\.sortOrder).max() ?? -1) + 1
        flow.planRows = rows.map { row in
            var row = row
            let cents = Money.cents(from: row.amountText) ?? 0
            if row.isNew {
                guard cents > 0 else { return row }
                let category = BudgetCategory(name: row.name, symbol: row.symbol, color: row.color, limitCents: cents, sortOrder: nextOrder)
                context.insert(category)
                nextOrder += 1
                // Added once: coming back to this step updates it like any other budget.
                row.id = category.id
                row.isNew = false
            } else if let category = categories.first(where: { $0.id == row.id }) {
                category.limitCents = cents
            }
            return row
        }
        try? context.save()
        savedIncome = income
        flow.next()
    }
}

extension Binding where Value == [PlanRow]? {
    /// A binding to an optional array, as a binding to its elements (empty when nil).
    var unwrapped: Binding<[PlanRow]> {
        Binding<[PlanRow]>(get: { wrappedValue ?? [] }, set: { wrappedValue = $0 })
    }
}
