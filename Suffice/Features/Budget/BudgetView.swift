import SwiftData
import SwiftUI

/// Budget: what's left this month, then every budget as a tile with its ring and what's left.
/// Tapping a tile opens its budget sheet.
struct BudgetView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.hearthDuoPose) private var pose
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @State private var showsNewBudget = false
    /// Add Expense (iPhone Duo: the outer display's one toolbar item, and the open-wide rail).
    @State private var newExpense: DraftItem?
    /// Today's Number, the glance board for a desk or counter (iPhone Duo's Tent pose).
    @State private var showsTodayBoard = false
    /// Open wide's ledger filter: one person's spending, or everyone's. Kept here, above the
    /// pose layouts, so it survives folding and unfolding.
    @State private var memberFilter: UUID?

    var body: some View {
        MonthBudget(month: router.month, memberFilter: memberFilter, showTodayBoard: { showsTodayBoard = true })
            .id(router.month)
            // Closed (outer display): Add Expense is the only toolbar item, so it never overflows.
            .toolbar {
                if pose == .outer {
                    ToolbarItem(placement: .primaryAction) {
                        addExpenseButton
                    }
                }
            }
            .tabToolbar(isShown: pose != .outer) {
                if pose == .openWide {
                    // Open wide: Add Expense and Filter on the trailing rail; Edit Budget and New
                    // Budget stay above the budgets they change, on the leading pane.
                    addExpenseButton
                    ChoicePopoverButton(sections: filterSections) {
                        Label("Filter", systemImage: memberFilter == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                            .foregroundStyle(.white)
                    }
                } else {
                    Button {
                        showsNewBudget = true
                    } label: {
                        Label("New Budget", systemImage: "plus")
                            .foregroundStyle(.white)
                    }
                }
                if router.isThisMonth {
                    HearthGlanceBoardButton(title: "Today's Number", systemImage: "dollarsign.circle") {
                        showsTodayBoard = true
                    }
                }
            }
            .sheet(isPresented: $showsNewBudget) {
                BudgetSheet(category: nil, month: router.month)
            }
            .sheet(item: $newExpense) { item in
                TransactionSheet(entry: nil, initial: item.draft)
            }
            .fullScreenCover(isPresented: $showsTodayBoard) {
                TodayBoard()
            }
    }

    private var addExpenseButton: some View {
        Button {
            var draft = EntryDraft()
            draft.date = router.entryDate
            newExpense = DraftItem(draft: draft)
        } label: {
            Label("Add Expense", systemImage: "plus")
                .foregroundStyle(.white)
        }
    }

    /// Open wide's filter: everyone, or one person.
    private var filterSections: [[ChoiceItem]] {
        let everyone = ChoiceItem(id: "all", title: "Everyone", systemImage: "person.2", isSelected: memberFilter == nil) {
            withAnimation(.snappy) { memberFilter = nil }
        }
        let people = members.map { member in
            ChoiceItem(id: member.id.uuidString, title: member.name, systemImage: "person", isSelected: memberFilter == member.id) {
                withAnimation(.snappy) { memberFilter = member.id }
            }
        }
        return people.isEmpty ? [[everyone]] : [[everyone], people]
    }
}

private struct MonthBudget: View {
    let month: MonthSpan
    var memberFilter: UUID? = nil
    var showTodayBoard: () -> Void = {}
    @Environment(\.hearthDuoPose) private var pose
    @Environment(\.modelContext) private var context
    @Query private var entries: [LedgerEntry]
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query private var stashMoves: [StashMove]
    @Query(filter: #Predicate<Stash> { $0.isArchived == false }) private var stashes: [Stash]
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(filter: #Predicate<Bill> { $0.isActive == true }) private var bills: [Bill]
    @Query(filter: #Predicate<LedgerEntry> { $0.stashID != nil }) private var stashPaid: [LedgerEntry]
    @Query(filter: #Predicate<LedgerEntry> { $0.billID != nil }) private var billPayments: [LedgerEntry]
    @State private var opened: BudgetCategory?
    @State private var settings = PlanningSettings.shared
    // iPhone Duo state, kept here above the pose layouts so it follows the hand: the budget
    // chosen in Open wide (or tapped on the outer display), the Money Date items settled, and
    // what's open from them.
    @State private var selectedID: UUID?
    @State private var settledAgenda: Set<String> = []
    @State private var openedEntry: LedgerEntry?
    @State private var openedBill: Bill?
    @State private var stashing: StashSheetItem?
    @State private var creating = false
    @State private var gridWidth: CGFloat = 0

    init(month: MonthSpan, memberFilter: UUID? = nil, showTodayBoard: @escaping () -> Void = {}) {
        self.month = month
        self.memberFilter = memberFilter
        self.showTodayBoard = showTodayBoard
        let start = month.start
        let end = month.end
        _entries = Query(filter: #Predicate<LedgerEntry> { $0.date >= start && $0.date < end })
    }

    var body: some View {
        let records = entries.map(\.record)
        let categoryRecords = categories.map(\.record)
        let statuses = BudgetMath.statuses(categoryRecords, entries: records, in: month)
        let totals = BudgetMath.totals(categoryRecords, entries: records, in: month, stashMoves: stashMoves.map(\.record))
        let lookup = Lookup(categories: categories)
        let isThisMonth = month == MonthSpan(containing: .now)

        Group {
            switch pose {
            case .outer:
                SpendCheckView(month: month, totals: totals, statuses: statuses, entries: records, lookup: lookup, showTodayBoard: isThisMonth ? Optional(showTodayBoard) : nil) { category in
                    selectedID = category.id
                    opened = category
                }
            case .openWide:
                CategoryLedgerSplit(
                    month: month,
                    totals: totals,
                    statuses: statuses,
                    entries: entries,
                    lookup: Lookup(categories: categories, members: members, accounts: accounts),
                    memberFilter: memberFilter,
                    selectedID: $selectedID,
                    edit: { opened = $0 },
                    create: { creating = true },
                    openEntry: { openedEntry = $0 }
                )
            case .book:
                MoneyDateView(
                    month: month,
                    totals: totals,
                    statuses: statuses,
                    lookup: lookup,
                    agenda: agenda(statuses: statuses, isThisMonth: isThisMonth),
                    resolved: settledAgenda,
                    resolve: resolve
                )
            case .standard, .laptop:
                monthAtAGlance(statuses: statuses, totals: totals, lookup: lookup, isThisMonth: isThisMonth)
            }
        }
        // Pull down to fetch the latest from iCloud.
        .refreshable { await HouseholdSync.shared.syncNow() }
        .sheet(item: $opened) { category in
            BudgetSheet(category: category, month: month)
        }
        .sheet(isPresented: $creating) {
            BudgetSheet(category: nil, month: month)
        }
        .sheet(item: $openedEntry) { entry in
            TransactionSheet(entry: entry)
        }
        .sheet(item: $openedBill) { bill in
            BillSheet(bill: bill)
        }
        .sheet(item: $stashing) { item in
            StashEditor(stash: item.stash, initial: item.draft)
        }
    }

    /// The Budget screen as on every iPhone (and the Duo's inner display in portrait: "the month
    /// at a glance"): Left to spend leads, then every budget as a tile.
    private func monthAtAGlance(statuses: [CategoryStatus], totals: MonthTotals, lookup: Lookup, isThisMonth: Bool) -> some View {
        GreenScreen("Budget") {
            BudgetSummaryCard(totals: totals, isThisMonth: isThisMonth, showsStashed: totals.stashedCents > 0 || !stashes.isEmpty)

            if statuses.isEmpty {
                EmptyCard(systemName: "dollarsign.circle", title: "No budgets yet", message: "Tap + to plan what each part of the month gets.")
            } else {
                // Two across on iPhone, four or six on iPad: always an even number, so a fold
                // falls between tiles.
                LazyVGrid(columns: HearthEvenColumns.flexible(HearthEvenColumns.count(for: gridWidth, minimumCellWidth: 150), spacing: 10), spacing: 10) {
                    ForEach(statuses) { status in
                        if let category = lookup.categories[status.id] {
                            Button { opened = category } label: {
                                BudgetTile(category: category, status: status)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
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

            // Stashes are about now: what's set aside today for what's coming.
            if isThisMonth {
                StashesSection()
                    .padding(.top, 10)
            }
        }
    }

    // MARK: Money Date (Book)

    /// The Money Date's agenda, from what Suffice already knows: budgets over plan, renewals and
    /// yearly bills due in the next 30 days, stashes behind this month, and a rare bill worth
    /// stashing for. Renewals and stashes are about now, so they show only for this month.
    private func agenda(statuses: [CategoryStatus], isThisMonth: Bool) -> [AgendaItem] {
        var items: [AgendaItem] = []
        let lookup = Lookup(categories: categories)

        for status in statuses where status.isOver {
            guard let category = lookup.categories[status.id] else { continue }
            let over = status.spentCents - status.limitCents
            items.append(AgendaItem(
                id: "over-\(status.id.uuidString)",
                kind: .overspent,
                title: "\(category.name) is \(Money.whole(over)) over",
                detail: status.limitCents > 0
                    ? "\(Money.whole(status.spentCents)) spent of \(Money.whole(status.limitCents)). Look at what went in, or change the plan."
                    : "\(Money.whole(status.spentCents)) spent with no plan.",
                actionTitle: "Open Budget",
                actionSymbol: "chart.pie",
                action: .openBudget(category)
            ))
        }

        guard isThisMonth else { return items }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let horizon = calendar.date(byAdding: .day, value: 30, to: today) ?? today
        let payments = billPayments.map(\.record)

        for bill in bills where bill.isSubscription || bill.frequency == .yearly {
            guard let due = BudgetMath.nextDue(of: bill.record, onOrAfter: today), due < horizon,
                  BudgetMath.payment(for: bill.record, dueOn: due, payments: payments) == nil else { continue }
            items.append(AgendaItem(
                id: "renew-\(bill.id.uuidString)-\(due.timeIntervalSinceReferenceDate)",
                kind: .renewal,
                title: "\(bill.name) renews \(DateLabel.short(due))",
                detail: "\(bill.amountLabel), \(BudgetMath.scheduleText(bill.record).lowercased()). Keep it, or cancel before it renews.",
                actionTitle: "Open Bill",
                actionSymbol: "doc.text",
                action: .openBill(bill)
            ))
        }

        let moves = stashMoves.map(\.record)
        let paid = stashPaid.map(\.record)
        // Only stashes marked by hand, as in the stash sheet: an automatic one is counted by
        // StashScheduler, and marking it here could skip months it still owes.
        for stash in stashes where !stash.countsAutomatically {
            let summary = StashMath.summary(stash.record, moves: moves, entries: paid)
            guard case .behind(let cents) = summary.status else { continue }
            items.append(AgendaItem(
                id: "stash-\(stash.id.uuidString)",
                kind: .stash,
                title: "\(stash.name): \(Money.whole(cents)) for this month",
                detail: "\(Money.whole(summary.balanceCents)) stashed of \(Money.whole(stash.targetCents)), due \(DateLabel.short(stash.dueDate)).",
                actionTitle: "Mark Stashed",
                actionSymbol: "archivebox",
                action: .markStashed(stash)
            ))
        }

        if let suggestion = StashMath.suggestions(bills: bills.map(\.record), stashes: stashes.map(\.record), dismissed: settings.dismissedSuggestions).first,
           let bill = bills.first(where: { $0.id == suggestion.billID }) {
            items.append(AgendaItem(
                id: "suggest-\(bill.id.uuidString)",
                kind: .stash,
                title: "Stash for \(bill.name)?",
                detail: "\(Money.whole(suggestion.amountCents)) due \(DateLabel.short(suggestion.dueDate)): \(Money.whole(suggestion.monthlyCents)) a month covers it.",
                actionTitle: "Start a Stash",
                actionSymbol: "plus",
                action: .startStash(bill, due: suggestion.dueDate)
            ))
        }
        return items
    }

    /// Settles an agenda item with its one action.
    private func resolve(_ item: AgendaItem) {
        withAnimation(.snappy) { _ = settledAgenda.insert(item.id) }
        switch item.action {
        case .openBudget(let category):
            opened = category
        case .openBill(let bill):
            openedBill = bill
        case .markStashed(let stash):
            StashScheduler.markStashed(stash, in: context)
        case .startStash(let bill, due: let due):
            stashing = StashSheetItem(stash: nil, draft: .forBill(bill, due: due))
        }
    }
}

/// The glass card at the top: what's left of the plan, a bar, then planned, stashed and spent.
/// Also the Money Date's left page (BudgetDuoViews.swift).
struct BudgetSummaryCard: View {
    var totals: MonthTotals
    var isThisMonth: Bool
    /// The household has stashes (or counted some this month).
    var showsStashed = false

    var body: some View {
        let isOver = totals.leftCents < 0
        let used = totals.spentCents + totals.stashedCents
        let progress = totals.budgetedCents > 0 ? Double(used) / Double(totals.budgetedCents) : 0
        GlassCard {
            GlassCardHeader(title: isOver ? "Over plan" : "Left to spend", note: isThisMonth ? "This month" : "That month")
            GlassFigure(text: Money.text(abs(totals.leftCents)), color: isOver ? Brand.expenseInk : .primary)
            if totals.budgetedCents > 0 {
                ProgressBar(progress: progress, color: isOver ? Brand.expense : Brand.green, track: .primary.opacity(0.1))
            }
            // Three tiles across where they fit; stacked on the narrowest screens and the
            // largest text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: showsStashed ? 8 : 10) { tiles }
                VStack(spacing: 8) { tiles }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var tiles: some View {
        GlassTile(title: "Planned", value: Money.whole(totals.budgetedCents))
            .frame(minWidth: 96)
        if showsStashed {
            GlassTile(title: "Stashed", value: Money.whole(totals.stashedCents))
                .frame(minWidth: 96)
        }
        GlassTile(title: "Spent", value: Money.whole(totals.spentCents))
            .frame(minWidth: 96)
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
