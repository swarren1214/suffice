import SwiftData
import SwiftUI

/// A budget's sheet, opened by tapping its tile (or + for a new one). Up top, how the month is
/// going: the ring, what's left, spent of planned. Then everything about the budget, editable in
/// place: name, monthly amount, how often it repeats, color and icon. Existing budgets also show
/// their subcategories and this month's transactions. Nothing saves until Done.
struct BudgetSheet: View {
    /// Nil to create a new budget.
    let category: BudgetCategory?
    let month: MonthSpan
    /// For a new subcategory: the budget it goes inside.
    var newParentID: UUID?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var entries: [LedgerEntry]

    @State private var name = ""
    @State private var symbol = "house"
    @State private var color: CategoryColor = .orange
    @State private var amountText = ""
    @State private var recurrence: Recurrence = .monthly
    @State private var startMonth = MonthSpan(containing: .now).start
    @State private var parentID: UUID?
    @State private var loaded = false
    /// The start month shown when the sheet opened, so an untouched starter budget keeps
    /// counting in every month.
    @State private var loadedStart = MonthSpan(containing: .now).start
    @State private var openedChild: BudgetCategory?
    @State private var addsSubcategory = false
    @State private var openedEntry: LedgerEntry?
    @State private var confirmsDelete = false
    @State private var pendingDelete = false

    enum Recurrence: String, CaseIterable, Identifiable {
        case monthly, once
        var id: String { rawValue }
        var title: String { self == .monthly ? "Every month" : "One month only" }
    }

    init(category: BudgetCategory?, month: MonthSpan, newParentID: UUID? = nil) {
        self.category = category
        self.month = month
        self.newParentID = newParentID
        let start = month.start
        let end = month.end
        _entries = Query(filter: #Predicate<LedgerEntry> { $0.date >= start && $0.date < end }, sort: \.date, order: .reverse)
    }

    private var children: [BudgetCategory] {
        guard let category else { return [] }
        return categories.filter { $0.parentID == category.id && !$0.isArchived }
    }

    /// Budgets this one could sit inside (never itself).
    private var parents: [BudgetCategory] {
        categories.filter { $0.parentID == nil && $0.id != category?.id && !$0.isArchived }
    }

    /// The quick icons, with the chosen one up front when it came from the library.
    private var quickIcons: [String] {
        SymbolChoices.quick.contains(symbol) ? SymbolChoices.quick : [symbol] + SymbolChoices.quick.prefix(11)
    }

    private var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    /// This month's numbers for the budget (or subcategory), from BudgetMath.
    private var status: CategoryStatus? {
        guard let category else { return nil }
        let all = BudgetMath.statuses(categories.map(\.record), entries: entries.map(\.record), in: month)
        if category.parentID == nil {
            return all.first { $0.id == category.id }
        }
        return all.flatMap(\.children).first { $0.id == category.id }
    }

    /// Transactions filed to the budget or any of its subcategories.
    private var budgetEntries: [LedgerEntry] {
        guard let category else { return [] }
        let ids = Set([category.id] + children.map(\.id))
        return entries.filter { $0.kind == .expense && $0.categoryID.map(ids.contains) == true }
    }

    var body: some View {
        let lookup = Lookup(categories: categories, members: members, accounts: accounts)

        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header

                    group("Budget") {
                        VStack(spacing: 0) {
                            amountRow
                            Divider().padding(.leading, 16)
                            Picker("Repeats", selection: $recurrence) {
                                ForEach(Recurrence.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            Divider().padding(.leading, 16)
                            monthRow
                            if children.isEmpty {
                                Divider().padding(.leading, 16)
                                CategoryPicker(
                                    title: "Part of",
                                    selection: $parentID,
                                    choices: parents.map { CategoryChoice($0) },
                                    noneTitle: "Its own budget",
                                    isInList: false
                                )
                                .padding(.horizontal, 16)
                                .frame(minHeight: 52)
                            }
                        }
                    }

                    group("Color") {
                        HStack(spacing: 0) {
                            ForEach(CategoryColor.allCases) { option in
                                Button { withAnimation(.snappy) { color = option } } label: {
                                    Circle()
                                        .fill(option.color)
                                        .frame(width: 28, height: 28)
                                        .frame(width: 38, height: 44)
                                        .overlay(Circle().strokeBorder(option == color ? option.color : .clear, lineWidth: 2.5).frame(width: 36, height: 36))
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel(option.name)
                                .accessibilityAddTraits(option == color ? .isSelected : [])
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }

                    group("Icon") {
                        VStack(spacing: 8) {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                                ForEach(quickIcons, id: \.self) { option in
                                    IconChoiceButton(name: option, isSelected: option == symbol, color: color) {
                                        withAnimation(.snappy) { symbol = option }
                                    }
                                    .accessibilityLabel(option.replacingOccurrences(of: ".", with: " "))
                                }
                            }
                            NavigationLink {
                                IconLibraryView(selection: $symbol, color: color)
                            } label: {
                                Label("More Icons", systemImage: "magnifyingglass")
                            }
                            .tint(Brand.green)
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 36)
                        }
                        .padding(12)
                    }

                    if let category, category.parentID == nil, let status {
                        group("Subcategories") {
                            VStack(spacing: 0) {
                                ForEach(status.children) { child in
                                    Button {
                                        openedChild = lookup.categories[child.id]
                                    } label: {
                                        SubcategoryRow(status: child, color: color)
                                    }
                                    .buttonStyle(.plain)
                                    Divider().padding(.leading, 16)
                                }
                                Button {
                                    addsSubcategory = true
                                } label: {
                                    Label("Add Subcategory", systemImage: "plus")
                                        .font(.body.weight(.semibold))
                                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                        .padding(.horizontal, 16)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Brand.green)
                            }
                        }
                    }

                    if category != nil, !budgetEntries.isEmpty {
                        group(month == MonthSpan(containing: .now) ? "This month" : DateLabel.month(month.start)) {
                            VStack(spacing: 0) {
                                ForEach(Array(budgetEntries.prefix(25).enumerated()), id: \.element.id) { index, entry in
                                    if index > 0 { Divider().padding(.leading, 68) }
                                    Button { openedEntry = entry } label: {
                                        TransactionRow(entry: entry, lookup: lookup)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    if category != nil {
                        Button(role: .destructive) { confirmsDelete = true } label: {
                            Text("Delete Budget")
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 52)
                                .background(Brand.expense.opacity(0.12), in: .rect(cornerRadius: 26))
                        }
                        .foregroundStyle(Brand.expenseInk)
                        .fontWeight(.semibold)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(category == nil ? (newParentID == nil ? "New budget" : "New subcategory") : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(category == nil ? "Create budget" : "Done", systemImage: "checkmark", role: .confirm) { save() }
                        .disabled(!isValid)
                }
            }
            .confirmationDialog("Delete \(name)?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete Budget", role: .destructive) {
                    pendingDelete = true
                    dismiss()
                }
            } message: {
                Text(children.isEmpty
                     ? "Its transactions stay in Activity as uncategorized."
                     : "Its subcategories become budgets of their own. Its transactions stay in Activity.")
            }
            .sheet(item: $openedChild) { child in
                BudgetSheet(category: child, month: month)
            }
            .sheet(isPresented: $addsSubcategory) {
                BudgetSheet(category: nil, month: month, newParentID: category?.id)
            }
            .sheet(item: $openedEntry) { entry in
                TransactionSheet(entry: entry)
            }
            .onAppear(perform: load)
            .onDisappear {
                guard pendingDelete, let category else { return }
                for child in categories where child.parentID == category.id { child.parentID = nil }
                context.delete(category)
                try? context.save()
            }
        }
    }

    // MARK: Pieces

    /// The ring with the icon, the name (editable), what's left and spent of planned.
    private var header: some View {
        VStack(spacing: 6) {
            if let status {
                ZStack {
                    Circle().stroke(Color(.systemGray5), lineWidth: 11)
                    Circle()
                        .trim(from: 0, to: min(status.progress, 1))
                        .stroke(status.isOver ? Brand.expense : color.color, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: symbol)
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(color.color)
                }
                .frame(width: 112, height: 112)
                .animation(.smooth, value: status.progress)
                .accessibilityHidden(true)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(color.ink)
                    .frame(width: 76, height: 76)
                    .background(color.tint, in: .circle)
                    .accessibilityHidden(true)
            }

            TextField("Budget name", text: $name)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.words)
                .padding(.top, 6)

            if let status {
                Text(status.leftCents >= 0 ? "\(Money.text(status.leftCents)) left" : "\(Money.text(-status.leftCents)) over")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(status.leftCents >= 0 ? Brand.green : Brand.expenseInk)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(summaryLine(status))
                    .font(.subheadline)
                    .foregroundStyle(Brand.secondaryText)
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func summaryLine(_ status: CategoryStatus) -> String {
        var line = status.limitCents > 0
            ? "\(Money.text(status.spentCents)) spent of \(Money.text(status.limitCents))"
            : "\(Money.text(status.spentCents)) spent, no amount planned"
        if month == MonthSpan(containing: .now) {
            let calendar = Calendar.current
            let left = month.days(calendar: calendar) - calendar.component(.day, from: .now)
            line += left == 0 ? " · last day" : " · \(left) day\(left == 1 ? "" : "s") to go"
        }
        return line
    }

    private var amountRow: some View {
        HStack {
            Text("Monthly amount")
            Spacer()
            if children.isEmpty {
                TextField("$0.00", text: $amountText)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.decimalPad)
                    .frame(maxWidth: 160)
            } else {
                Text(Money.text(children.reduce(0) { $0 + $1.limitCents }))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHint("Set by its subcategories")
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 54)
    }

    /// Starts (repeating) or Month (one month only), from a year back to a year ahead.
    private var monthRow: some View {
        HStack {
            Text(recurrence == .monthly ? "Starts" : "Month")
            Spacer()
            Menu {
                ForEach(-12..<13, id: \.self) { offset in
                    let option = MonthSpan(containing: .now).offset(by: offset)
                    Button(option.start.formatted(.dateTime.month(.wide).year())) { startMonth = option.start }
                }
            } label: {
                Text(startMonth.formatted(.dateTime.month(.wide).year()))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color(.systemGray5), in: .capsule)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }

    /// A titled white card.
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.bold())
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
        }
    }

    // MARK: Load and save

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let category else {
            parentID = newParentID
            startMonth = month.start
            if let parent = categories.first(where: { $0.id == newParentID }) {
                symbol = parent.symbol
                color = parent.color
            }
            return
        }
        name = category.name
        symbol = category.symbol
        color = category.color
        amountText = Money.editable(category.limitCents)
        recurrence = category.repeatsMonthly ? .monthly : .once
        startMonth = category.startMonth > .distantPast ? category.startMonth : MonthSpan(containing: category.createdAt).start
        loadedStart = startMonth
        parentID = category.parentID
    }

    private func save() {
        let target: BudgetCategory
        if let category {
            target = category
        } else {
            let siblings = categories.filter { $0.parentID == parentID }
            target = BudgetCategory(name: "", symbol: symbol, color: color, limitCents: 0, sortOrder: (siblings.map(\.sortOrder).max() ?? -1) + 1)
            context.insert(target)
        }
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.symbol = symbol
        target.color = color
        if children.isEmpty {
            target.limitCents = Money.cents(from: amountText) ?? 0
            target.parentID = parentID
        }
        target.repeatsMonthly = recurrence == .monthly
        let untouchedStarter = category?.startMonth == Date.distantPast && startMonth == loadedStart && recurrence == .monthly
        if !untouchedStarter {
            target.startMonth = startMonth
        }
        // Subcategories share their budget's look.
        for child in children {
            child.symbol = symbol
            child.color = color
        }
        try? context.save()
        dismiss()
    }
}

/// A subcategory in the budget sheet: name, what's left, bar, spent of planned.
private struct SubcategoryRow: View {
    var status: CategoryStatus
    var color: CategoryColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(status.category.name).font(.body.weight(.medium))
                Spacer()
                Text(status.leftCents >= 0 ? "\(Money.text(status.leftCents)) left" : "\(Money.text(-status.leftCents)) over")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(status.leftCents >= 0 ? Brand.green : Brand.expenseInk)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            ProgressBar(progress: status.progress, color: status.isOver ? Brand.expense : color.color)
            Text("\(Money.text(status.spentCents)) of \(Money.text(status.limitCents))")
                .font(.caption)
                .foregroundStyle(Brand.secondaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    BudgetSheet(category: nil, month: MonthSpan(containing: .now))
        .previewEnvironment()
}
