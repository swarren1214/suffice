import SwiftData
import SwiftUI

/// A budget's sheet, opened by tapping its tile (or + for a new one). Up top, how the month is
/// going: the ring, what's left, spent of planned. Then everything about the budget, editable in
/// place: name, monthly amount, how often it repeats, color and icon. Existing budgets also show
/// their subcategories and this month's transactions. A subcategory only has a name, an amount
/// and (optionally) its own icon; its color and schedule come from its budget. Nothing saves
/// until Done.
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
    @FocusState private var amountFocused: Bool
    @State private var recurrence: Recurrence = .monthly
    @State private var startMonth = MonthSpan(containing: .now).start
    @State private var parentID: UUID?
    @State private var loaded = false
    /// The start month shown when the sheet opened, so an untouched starter budget keeps
    /// counting in every month.
    @State private var loadedStart = MonthSpan(containing: .now).start
    /// The subcategories as edited in this sheet; saved with Done.
    @State private var subDrafts: [SubcategoryDraft] = []
    /// Existing subcategories removed in this sheet, deleted on Done.
    @State private var removedSubIDs: [UUID] = []
    @State private var expandedSub: UUID?
    @State private var openedEntry: LedgerEntry?
    @State private var confirmsDelete = false
    @State private var pendingDelete = false
    /// Existing budgets open on their transactions; the pencil switches to editing. New ones
    /// start in editing.
    @State private var isEditing = false
    /// Which transaction groups are open (the budget's own, and each subcategory's).
    @State private var expandedGroups: Set<UUID> = []

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

    /// The budget a subcategory sits inside (nil for a budget).
    private var parent: BudgetCategory? {
        guard let id = category?.parentID ?? newParentID else { return nil }
        return categories.first { $0.id == id }
    }

    private var isSubcategory: Bool { (category?.parentID ?? newParentID) != nil }

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

                    if !isEditing {
                        transactionsView(lookup: lookup)
                    } else {
                        editingView
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(category == nil ? (newParentID == nil ? "New budget" : "New subcategory") : (isEditing ? (isSubcategory ? "Edit Subcategory" : "Edit Budget") : ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isEditing && category != nil {
                        Button("Back", systemImage: "chevron.left") {
                            withAnimation(.snappy) { isEditing = false }
                        }
                    } else {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                }
                if !isEditing && category != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit", systemImage: "pencil") {
                            withAnimation(.snappy) { isEditing = true }
                        }
                    }
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(category == nil ? "Create budget" : "Done", systemImage: "checkmark", role: .confirm) { save() }
                        .disabled(!isValid)
                }
            }
            .confirmationDialog("Delete \(name)?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button(isSubcategory ? "Delete Subcategory" : "Delete Budget", role: .destructive) {
                    pendingDelete = true
                    dismiss()
                }
            } message: {
                Text(isSubcategory
                     ? "Its transactions move to \(parent?.name ?? "its budget")."
                     : children.isEmpty
                     ? "Its transactions stay in Activity as uncategorized."
                     : "Its subcategories become budgets of their own. Its transactions stay in Activity.")
            }
            .sheet(item: $openedEntry) { entry in
                TransactionSheet(entry: entry)
            }
            .onAppear(perform: load)
            .onDisappear {
                guard pendingDelete, let category else { return }
                for child in categories where child.parentID == category.id { child.parentID = nil }
                // A deleted subcategory's transactions go back to its budget.
                if let parentID = category.parentID {
                    let id: UUID? = category.id
                    let filed = (try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.categoryID == id }))) ?? []
                    for entry in filed { entry.categoryID = parentID }
                }
                context.delete(category)
                try? context.save()
            }
        }
    }

    /// Everything about the budget, editable: amount, schedule, color, icon, subcategories.
    @ViewBuilder
    private var editingView: some View {
        if isSubcategory {
            group("Amount") { amountRow }
        } else {
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
                    if subDrafts.isEmpty {
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
                ColorChoiceGrid(selection: $color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
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

        if !isSubcategory {
            subcategoriesSection
        }

        if category != nil {
            Button(role: .destructive) { confirmsDelete = true } label: {
                Label(isSubcategory ? "Delete Subcategory" : "Delete Budget", systemImage: "trash")
                    .fontWeight(.semibold)
                    .foregroundStyle(Brand.expenseInk)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 40)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .tint(Brand.expenseInk)
            .padding(.top, 4)
        }
    }

    // MARK: Transactions

    /// The month's transactions. With subcategories: the ones filed to the budget itself on
    /// top, then each subcategory, each a row that opens to its transactions.
    @ViewBuilder
    private func transactionsView(lookup: Lookup) -> some View {
        let title = month == MonthSpan(containing: .now) ? "This month" : DateLabel.month(month.start)
        let count = budgetEntries.count
        if budgetEntries.isEmpty && children.isEmpty {
            EmptyCard(systemName: "tray", title: "No transactions", message: "Nothing is filed to \(name) in \(DateLabel.month(month.start)) yet.")
        } else if children.isEmpty {
            group(title, note: "\(count) transaction\(count == 1 ? "" : "s")") {
                entryList(budgetEntries, lookup: lookup)
            }
        } else if let category {
            let direct = budgetEntries.filter { $0.categoryID == category.id }
            let subs = children.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
            group(title, note: "\(count) transaction\(count == 1 ? "" : "s")") {
                VStack(spacing: 0) {
                    groupRow(id: category.id, symbol: symbol, title: name, detail: "Not in a subcategory", limitCents: nil, entries: direct, lookup: lookup)
                    ForEach(subs) { child in
                        Divider().padding(.leading, 60)
                        groupRow(
                            id: child.id, symbol: child.symbol, title: child.name, detail: nil,
                            limitCents: child.limitCents,
                            entries: budgetEntries.filter { $0.categoryID == child.id },
                            lookup: lookup
                        )
                    }
                }
            }
        }
    }

    /// One group: its icon, name, how much went to it, and a chevron; open, its transactions.
    @ViewBuilder
    private func groupRow(id: UUID, symbol: String, title: String, detail: String?, limitCents: Int?, entries: [LedgerEntry], lookup: Lookup) -> some View {
        let isOpen = expandedGroups.contains(id) && !entries.isEmpty
        let spent = entries.reduce(0) { $0 + $1.amountCents }
        let spentLine = limitCents.map { $0 > 0 ? "\(Money.text(spent)) of \(Money.text($0))" : "\(Money.text(spent)) spent" } ?? "\(Money.text(spent)) spent"
        let countLine = entries.isEmpty ? "Nothing yet" : "\(entries.count) transaction\(entries.count == 1 ? "" : "s")"
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) {
                    if expandedGroups.contains(id) { expandedGroups.remove(id) } else { expandedGroups.insert(id) }
                }
            } label: {
                HStack(spacing: 12) {
                    CategoryIcon(symbol: symbol, color: color, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                        Text([detail, countLine].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(Brand.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(spentLine)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(limitCents.map { $0 > 0 && spent > $0 } == true ? Brand.expenseInk : Color.primary)
                        .monospacedDigit()
                    if !entries.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(entries.isEmpty)
            .accessibilityHint(isOpen ? "Hides its transactions" : "Shows its transactions")

            if isOpen {
                Divider().padding(.leading, 60)
                entryList(entries, lookup: lookup)
            }
        }
    }

    private func entryList(_ list: [LedgerEntry], lookup: Lookup) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider().padding(.leading, 68) }
                Button { openedEntry = entry } label: {
                    TransactionRow(entry: entry, lookup: lookup)
                }
                .buttonStyle(.plain)
                .tint(.primary)
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

            if isEditing {
                TextField(isSubcategory ? "Subcategory name" : "Budget name", text: $name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.words)
                    .padding(.top, 6)
            } else {
                Text(name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }

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
            Text(isSubcategory ? "Each month" : "Monthly amount")
            Spacer()
            TextField("$0.00", text: $amountText)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
                .focused($amountFocused)
                .currencyEditing($amountText, isFocused: amountFocused)
                .frame(maxWidth: 160)
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

    // MARK: Splitting the amount

    private var budgetCents: Int { Money.cents(from: amountText) ?? 0 }
    private var assignedCents: Int { subDrafts.reduce(0) { $0 + (Money.cents(from: $1.amountText) ?? 0) } }
    private var unassignedCents: Int { budgetCents - assignedCents }
    private var budgetName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "this budget" : trimmed
    }

    /// Each subcategory in a lighter shade of the budget's color, for the bar and the legend.
    private func shade(_ index: Int) -> Color {
        color.color.opacity([1.0, 0.62, 0.4, 0.26][index % 4])
    }

    /// The budget's amount split across its subcategories: a bar and legend, a warning when
    /// they add up to more, each subcategory with its amount, what's left for the budget
    /// itself, and Add. Nothing has to be assigned.
    private var subcategoriesSection: some View {
        let isOver = unassignedCents < 0
        let note: String? = subDrafts.isEmpty || budgetCents == 0 ? nil
            : isOver ? "\(Money.text(-unassignedCents)) over"
            : "\(Money.text(assignedCents)) of \(Money.text(budgetCents)) assigned"
        return VStack(alignment: .leading, spacing: 8) {
            group("Subcategories", note: note, noteColor: isOver ? Brand.expenseInk : Brand.secondaryText) {
                VStack(spacing: 0) {
                    if !subDrafts.isEmpty {
                        if budgetCents > 0 {
                            allocationBar(isOver: isOver)
                                .padding(.horizontal, 16)
                                .padding(.top, 16)
                            allocationLegend(isOver: isOver)
                                .padding(.horizontal, 16)
                                .padding(.top, 10)
                                .padding(.bottom, isOver ? 10 : 14)
                        }
                        if isOver {
                            overBanner
                                .padding(.horizontal, 16)
                                // With no amount set there's no bar above it to space it from the top.
                                .padding(.top, budgetCents > 0 ? 0 : 16)
                                .padding(.bottom, 16)
                        }
                        if budgetCents > 0 { Divider().padding(.leading, 16) }
                        ForEach($subDrafts) { $draft in
                            SubcategoryEditorRow(
                                draft: $draft,
                                status: status?.children.first(where: { $0.id == draft.id }),
                                color: color,
                                share: budgetCents > 0 ? Double(Money.cents(from: draft.amountText) ?? 0) / Double(budgetCents) : nil,
                                budgetName: budgetName,
                                isOver: isOver,
                                isExpanded: expandedSub == draft.id,
                                toggle: {
                                    withAnimation(.snappy) { expandedSub = expandedSub == draft.id ? nil : draft.id }
                                },
                                remove: { removeSubcategory(draft.id) }
                            )
                            Divider().padding(.leading, 16)
                        }
                        restRow(isOver: isOver)
                        Divider().padding(.leading, 16)
                    }
                    Button(action: addSubcategory) {
                        Label("Add Subcategory", systemImage: "plus")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .padding(.horizontal, 16)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.green)
                }
            }
            if !subDrafts.isEmpty {
                Text("Split as much or as little as you like. What isn’t assigned stays with \(budgetName) for anything filed to it directly.")
                    .font(.footnote)
                    .foregroundStyle(Brand.secondaryText)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func allocationBar(isOver: Bool) -> some View {
        let whole = Double(max(budgetCents, assignedCents, 1))
        let amounts = subDrafts.map { Money.cents(from: $0.amountText) ?? 0 }
        return GeometryReader { proxy in
            let width = proxy.size.width
            // Each piece is placed at its own offset inside a bar of exactly this width, so the
            // pieces can never add up to more than the bar and push its rounded end out of view.
            let spans = amounts.indices.reduce(into: [(index: Int, start: CGFloat, length: CGFloat)]()) { spans, index in
                let start = spans.last.map { $0.start + $0.length } ?? 0
                spans.append((index, start, width * Double(amounts[index]) / whole))
            }
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    let assignedEnd = spans.last.map { $0.start + $0.length } ?? 0
                    if width - assignedEnd > 0.5 {
                        // Unassigned: the rest of the bar.
                        Rectangle()
                            .fill(Color(.systemGray5))
                            .frame(width: width - assignedEnd)
                            .offset(x: assignedEnd)
                    }
                    ForEach(spans, id: \.index) { span in
                        if span.length > 0 {
                            // A 2 pt gap after each piece, except one that reaches the end.
                            let reachesEnd = span.start + span.length >= width - 0.5
                            Rectangle()
                                .fill(shade(span.index))
                                .frame(width: max(2, reachesEnd ? width - span.start : span.length - 2))
                                .offset(x: span.start)
                        }
                    }
                }
                .frame(width: width, height: 12, alignment: .leading)
                .clipShape(.capsule)
                if isOver {
                    // Where the budget's amount ends.
                    Capsule()
                        .fill(Color.primary)
                        .frame(width: 2, height: 20)
                        .offset(x: width * Double(budgetCents) / whole - 1)
                }
            }
            .frame(height: 20)
        }
        .frame(height: 20)
        .animation(.snappy, value: amounts)
        .accessibilityHidden(true)
    }

    private func allocationLegend(isOver: Bool) -> some View {
        var items: [LegendItem] = []
        for (index, draft) in subDrafts.enumerated() {
            items.append(LegendItem(id: draft.id.uuidString, name: draft.name.isEmpty ? "New" : draft.name, cents: Money.cents(from: draft.amountText) ?? 0, color: shade(index)))
        }
        if !isOver {
            items.append(LegendItem(id: "rest", name: "Unassigned", cents: unassignedCents, color: nil))
        }
        return FlowLayout(spacing: 14, lineSpacing: 6) {
            ForEach(items) { item in
                HStack(spacing: 6) {
                    if let dot = item.color {
                        Circle().fill(dot).frame(width: 10, height: 10)
                    } else {
                        Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2])).foregroundStyle(.tertiary).frame(width: 10, height: 10)
                    }
                    Text(item.name).foregroundStyle(Brand.secondaryText).lineLimit(1)
                    Text(Money.text(item.cents)).fontWeight(.semibold).monospacedDigit()
                }
                .font(.footnote)
            }
        }
    }

    private var overBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Brand.expenseInk)
            VStack(alignment: .leading, spacing: 8) {
                Text("Subcategories add up to **\(Money.text(-unassignedCents))** more than \(budgetName)’s monthly amount.")
                    .font(.subheadline)
                    .foregroundStyle(Brand.expenseInk)
                Button("Raise \(budgetName) to \(Money.text(assignedCents))") {
                    withAnimation(.snappy) { amountText = Money.field(assignedCents) }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .tint(Brand.expenseInk)
                .fontWeight(.semibold)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Brand.expense.opacity(0.12), in: .rect(cornerRadius: 16))
    }

    /// What's left of the budget after the subcategories: for spending filed to it directly.
    private func restRow(isOver: Bool) -> some View {
        HStack(spacing: 12) {
            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5]))
                .foregroundStyle(.tertiary)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Rest of \(budgetName)")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Brand.secondaryText)
                Text(isOver ? "Nothing left for \(budgetName) itself" : "Spending filed to \(budgetName) itself")
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
            }
            Spacer(minLength: 8)
            Text(Money.text(max(unassignedCents, 0)))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isOver ? Brand.secondaryText : Color.primary)
                .padding(.trailing, 12)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    /// A titled white card.
    private func group<Content: View>(_ title: String, note: String? = nil, noteColor: Color = Brand.secondaryText, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let note {
                    Text(note)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(noteColor)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(.horizontal, 4)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
        }
    }

    // MARK: Load and save

    private func load() {
        guard !loaded else { return }
        loaded = true
        isEditing = category == nil
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
        color = parent?.color ?? category.color
        // The budget's own transactions start open.
        expandedGroups = [category.id]
        amountText = Money.field(category.limitCents)
        // No amount of its own yet: start from what its subcategories add up to.
        if category.limitCents == 0, !children.isEmpty {
            amountText = Money.field(children.reduce(0) { $0 + $1.limitCents })
        }
        subDrafts = children
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
            .map { SubcategoryDraft(id: $0.id, isNew: false, name: $0.name, amountText: Money.field($0.limitCents), symbol: $0.symbol) }
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
        let oldSymbol = category?.symbol
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.symbol = symbol

        if let parent {
            // A subcategory: its own name, amount and icon; the rest is its budget's.
            target.parentID = parent.id
            target.limitCents = Money.cents(from: amountText) ?? 0
            target.color = parent.color
            target.repeatsMonthly = parent.repeatsMonthly
            target.startMonth = parent.startMonth
            try? context.save()
            dismiss()
            return
        }

        target.color = color
        target.limitCents = Money.cents(from: amountText) ?? 0
        if subDrafts.isEmpty {
            target.parentID = parentID
        }
        target.repeatsMonthly = recurrence == .monthly
        let untouchedStarter = category?.startMonth == Date.distantPast && startMonth == loadedStart && recurrence == .monthly
        if !untouchedStarter {
            target.startMonth = startMonth
        }
        saveSubcategories(into: target, oldSymbol: oldSymbol)
        try? context.save()
        dismiss()
    }

    // MARK: Subcategories

    private func addSubcategory() {
        let draft = SubcategoryDraft(id: UUID(), isNew: true, name: "", amountText: "", symbol: symbol)
        withAnimation(.snappy) {
            subDrafts.append(draft)
            expandedSub = draft.id
        }
    }

    private func removeSubcategory(_ id: UUID) {
        withAnimation(.snappy) {
            if let draft = subDrafts.first(where: { $0.id == id }), !draft.isNew {
                removedSubIDs.append(id)
            }
            subDrafts.removeAll { $0.id == id }
            if expandedSub == id { expandedSub = nil }
        }
    }

    /// Writes the edited subcategories. They take the budget's color and schedule; their icon
    /// follows the budget's unless they picked their own. Removed ones hand their transactions
    /// back to the budget. New ones without a name are skipped.
    private func saveSubcategories(into budget: BudgetCategory, oldSymbol: String?) {
        for id in removedSubIDs {
            guard let child = categories.first(where: { $0.id == id }) else { continue }
            let childID: UUID? = id
            let filed = (try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.categoryID == childID }))) ?? []
            for entry in filed { entry.categoryID = budget.id }
            context.delete(child)
        }
        for (index, draft) in subDrafts.enumerated() {
            let trimmed = draft.name.trimmingCharacters(in: .whitespaces)
            let child: BudgetCategory
            if !draft.isNew, let existing = categories.first(where: { $0.id == draft.id }) {
                child = existing
                if !trimmed.isEmpty { child.name = trimmed }
            } else {
                guard !trimmed.isEmpty else { continue }
                child = BudgetCategory(name: trimmed, symbol: draft.symbol, color: color, limitCents: 0, parentID: budget.id)
                context.insert(child)
            }
            child.parentID = budget.id
            child.limitCents = Money.cents(from: draft.amountText) ?? 0
            child.symbol = draft.symbol == oldSymbol ? symbol : draft.symbol
            child.color = color
            child.repeatsMonthly = budget.repeatsMonthly
            child.startMonth = budget.startMonth
            child.sortOrder = index
        }
    }
}

/// A subcategory as edited in the budget sheet.
struct SubcategoryDraft: Identifiable, Equatable {
    var id: UUID
    var isNew: Bool
    var name: String
    var amountText: String
    var symbol: String
}

/// A subcategory inside the budget sheet: its icon, name and share of the budget, with its
/// amount right in the row. Tapped open: its name and icon, and Delete.
private struct SubcategoryEditorRow: View {
    @Binding var draft: SubcategoryDraft
    var status: CategoryStatus?
    var color: CategoryColor
    /// Its amount as a fraction of the budget's, when the budget has one.
    var share: Double?
    var budgetName: String
    var isOver: Bool
    var isExpanded: Bool
    var toggle: () -> Void
    var remove: () -> Void
    @FocusState private var amountFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: toggle) {
                    HStack(spacing: 12) {
                        CategoryIcon(symbol: draft.symbol, color: color, size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(draft.name.isEmpty ? "New subcategory" : draft.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(draft.name.isEmpty ? .secondary : .primary)
                                    .lineLimit(1)
                                Image(systemName: "chevron.down")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.tertiary)
                                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            }
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(Brand.secondaryText)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint(isExpanded ? "Closes the subcategory" : "Edits its name and icon")

                TextField("$0.00", text: $draft.amountText)
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.decimalPad)
                    .focused($amountFocused)
                    .currencyEditing($draft.amountText, isFocused: amountFocused)
                    .foregroundStyle(isOver && amountFocused ? Brand.expenseInk : Color.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(width: 124)
                    .background(Color(.systemGray6), in: .rect(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(amountFocused ? Brand.green : .clear, lineWidth: 2)
                    }
                    .accessibilityLabel("\(draft.name.isEmpty ? "New subcategory" : draft.name) amount")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if isExpanded {
                editor
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }

    /// "75% of Home", with what's been spent this month when there's any.
    private var caption: String {
        var parts: [String] = []
        if let share { parts.append("\(Int((share * 100).rounded()))% of \(budgetName)") }
        if let status, status.spentCents > 0 { parts.append("\(Money.text(status.spentCents)) spent") }
        return parts.isEmpty ? "No amount yet" : parts.joined(separator: " · ")
    }

    private var quickIcons: [String] {
        SymbolChoices.quick.contains(draft.symbol) ? SymbolChoices.quick : [draft.symbol] + SymbolChoices.quick.prefix(11)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            Divider().padding(.leading, 16)
            HStack {
                Text("Name")
                Spacer()
                TextField("Subcategory name", text: $draft.name)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            Divider().padding(.leading, 16)
            VStack(alignment: .leading, spacing: 8) {
                Text("Icon")
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(quickIcons, id: \.self) { option in
                            IconChoiceButton(name: option, isSelected: option == draft.symbol, color: color) {
                                withAnimation(.snappy) { draft.symbol = option }
                            }
                            .frame(width: 52)
                            .accessibilityLabel(option.replacingOccurrences(of: ".", with: " "))
                        }
                        NavigationLink {
                            IconLibraryView(selection: $draft.symbol, color: color)
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Brand.green)
                                .frame(width: 52, height: 44)
                                .background(Color(.systemGray6), in: .capsule)
                        }
                        .accessibilityLabel("More icons")
                    }
                }
                .scrollIndicators(.hidden)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider().padding(.leading, 16)
            Button(role: .destructive, action: remove) {
                Label("Delete Subcategory", systemImage: "trash")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Brand.expenseInk)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .padding(.horizontal, 16)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }
}

/// One entry in the bar's legend.
private struct LegendItem: Identifiable {
    var id: String
    var name: String
    var cents: Int
    var color: Color?
}

/// Lays its children out left to right, wrapping onto new lines (the bar's legend).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

#Preview {
    BudgetSheet(category: nil, month: MonthSpan(containing: .now))
        .previewEnvironment()
}
