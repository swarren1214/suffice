import SwiftData
import SwiftUI

// Budget on iPhone Duo (the "Hearth on iPhone Duo" canvas). MonthBudget picks one of these from
// `\.hearthDuoPose`; every piece of state (the chosen budget, what the Money Date has settled)
// lives in MonthBudget, above them, so opening, closing or folding the phone never loses it.
//
// - Closed (outer display): "Can I spend this?" — safe to spend this week, and the three budgets
//   closest to their limit.
// - Open wide (inner landscape): "Category and ledger" — budgets on the leading pane, the chosen
//   one's transactions on the trailing pane.
// - Book (partly folded, held): "Money Date" — how the month went on the left page, a short
//   agenda to talk through on the right.
// - Tent: "Today's Number", a glance board opened from the toolbar (TodayBoard).

// MARK: - Shared pieces

extension View {
    /// The Budget screen's look for the Duo layouts that don't use GreenScreen: the green header
    /// behind everything (it runs under the trailing rail), the gray page, an inline title.
    func duoGreenChrome(_ title: String) -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(alignment: .top) { HeaderGradient() }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

extension LimitLevel {
    /// Green with room to spare, amber near the limit, orange once over.
    var color: Color {
        switch self {
        case .fine: Brand.green
        case .near: Color(hex: 0xF2A900)
        case .over: Color(hex: 0xF3754D)
        }
    }
}

/// An account as a short line: a card shows only its last four digits ("Chase •••• 0293").
enum AccountLabel {
    static func short(_ account: Account) -> String {
        guard !account.mask.isEmpty else { return account.displayName }
        let name = account.institution.isEmpty ? account.name : account.institution
        return "\(name) •••• \(String(account.mask.suffix(4)))"
    }
}

/// A budget with its bar: icon, name, what's left (or over), and a bar that turns amber near
/// the limit and orange when over.
struct LimitBarRow: View {
    let status: CategoryStatus
    let category: BudgetCategory?
    var isSelected = false

    var body: some View {
        let level = LimitLevel(status)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: category?.symbol ?? "circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(category?.color.ink ?? Color.gray, in: .rect(cornerRadius: 8))
                    .accessibilityHidden(true)
                Text(status.category.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(status.leftCents >= 0 ? "\(Money.whole(status.leftCents)) left" : "\(Money.whole(-status.leftCents)) over")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(status.leftCents >= 0 ? Color.primary : Brand.expenseInk)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            ProgressBar(progress: status.progress, color: level.color)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isSelected ? Color.primary.opacity(0.07) : Color.clear)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One transaction with who paid and from which account (cards by their last four digits).
struct LedgerLine: View {
    let entry: LedgerEntry
    let lookup: Lookup
    /// The part of a split charge that counts in the budget showing.
    var partCents: Int? = nil

    var body: some View {
        HStack(spacing: 12) {
            MerchantAvatar(name: entry.payee, isIncome: entry.kind == .income, member: lookup.member(entry.memberID), logoURL: entry.logoURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.payee.isEmpty ? "Untitled" : entry.payee)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            AmountPill(cents: partCents ?? entry.amountCents, kind: entry.kind)
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 64)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var meta: String {
        var parts = [entry.date.formatted(.dateTime.month(.abbreviated).day())]
        if let member = lookup.member(entry.memberID) { parts.append("\(member.name) paid") }
        if let account = lookup.account(entry.accountID) { parts.append(AccountLabel.short(account)) }
        if entry.isSplit, let partCents { parts.append("\(Money.text(partCents)) of a \(Money.text(entry.amountCents)) split") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Closed: "Can I spend this?"

/// The outer display answers one question: what's safe to spend this week. Below it, the three
/// budgets closest to their limit. Tapping one opens its budget sheet.
struct SpendCheckView: View {
    let month: MonthSpan
    let totals: MonthTotals
    let statuses: [CategoryStatus]
    let entries: [EntryRecord]
    let lookup: Lookup
    /// Opens Today's Number. A button in the content rather than on the rail, so Add Expense
    /// stays the outer display's only toolbar item. Nil when an earlier month is showing.
    let showTodayBoard: (() -> Void)?
    let open: (BudgetCategory) -> Void

    var body: some View {
        let isThisMonth = month == MonthSpan(containing: .now)
        let safe = isThisMonth ? SpendPace.safeThisWeek(leftCents: totals.leftCents, month: month, entries: entries) : max(totals.leftCents, 0)
        let closest = SpendPace.closest(statuses)

        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GlassCard {
                    GlassCardHeader(title: isThisMonth ? "Safe to spend this week" : "Left to spend", note: DateLabel.month(month.start))
                    GlassFigure(text: Money.whole(safe), color: totals.leftCents < 0 ? Brand.expenseInk : .primary)
                    Text(totals.leftCents < 0 ? "\(Money.whole(-totals.leftCents)) over plan this month" : "\(Money.whole(totals.leftCents)) left this month")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)

                if let showTodayBoard {
                    Button(action: showTodayBoard) {
                        Label("Today's Number", systemImage: "dollarsign.circle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    // A text button: the text color, not the app's (AGENT.md).
                    .tint(.primary)
                }

                if closest.isEmpty {
                    EmptyCard(systemName: "dollarsign.circle", title: "No plans yet", message: "Open the phone to plan what each part of the month gets.")
                } else {
                    SectionTitle("Closest to the limit")
                    CardList(items: closest, inset: 16) { status in
                        Button {
                            if let category = lookup.categories[status.id] { open(category) }
                        } label: {
                            LimitBarRow(status: status, category: lookup.categories[status.id])
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the budget")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .duoGreenChrome("Budget")
    }
}

// MARK: - Open wide: "Category and ledger"

/// Budgets on the leading pane (with Edit Budget above the list it changes), the chosen
/// budget's transactions on the trailing pane, with who paid and from which account.
struct CategoryLedgerSplit: View {
    let month: MonthSpan
    let totals: MonthTotals
    let statuses: [CategoryStatus]
    let entries: [LedgerEntry]
    let lookup: Lookup
    let memberFilter: UUID?
    @Binding var selectedID: UUID?
    let edit: (BudgetCategory) -> Void
    let create: () -> Void
    let openEntry: (LedgerEntry) -> Void

    var body: some View {
        let selected = statuses.first { $0.id == selectedID } ?? statuses.first
        HearthFoldSplit(axes: .horizontal) {
            categoryPane(selected: selected)
        } secondary: {
            ledgerPane(selected)
        }
        .duoGreenChrome("Budget")
    }

    private func categoryPane(selected: CategoryStatus?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(totals.leftCents < 0 ? "Over plan" : "Left to spend")
                            .font(.footnote.weight(.semibold))
                        Text(Money.whole(abs(totals.leftCents)))
                            .font(.title.bold())
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .foregroundStyle(.white)
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 8)
                    // Edit Budget stays above the list it changes, not on the rail.
                    Button {
                        if let id = selected?.id, let category = lookup.categories[id] { edit(category) }
                    } label: {
                        Label("Edit Budget", systemImage: "pencil")
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.glass)
                    .disabled(selected == nil)
                    Button(action: create) {
                        Label("New Budget", systemImage: "plus")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.glass)
                }

                if statuses.isEmpty {
                    EmptyCard(systemName: "dollarsign.circle", title: "No budgets yet", message: "Tap + to plan what each part of the month gets.")
                } else {
                    CardList(items: statuses, inset: 16) { status in
                        Button {
                            withAnimation(.snappy) { selectedID = status.id }
                        } label: {
                            LimitBarRow(status: status, category: lookup.categories[status.id], isSelected: status.id == selected?.id)
                        }
                        .buttonStyle(.plain)
                    }
                    .clipShape(.rect(cornerRadius: 26))
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func ledgerPane(_ selected: CategoryStatus?) -> some View {
        if let selected {
            let ids = Set([selected.id] + lookup.categories.values.filter { $0.parentID == selected.id }.map(\.id))
            let rows = entries
                .filter { $0.kind == .expense && $0.touches(ids) && (memberFilter == nil || $0.memberID == memberFilter) }
                .sorted { $0.date > $1.date }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selected.category.name)
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text(selected.limitCents > 0 ? "\(Money.whole(selected.spentCents)) of \(Money.whole(selected.limitCents)) · \(DateLabel.month(month.start))" : "\(Money.whole(selected.spentCents)) spent · \(DateLabel.month(month.start))")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(.white)

                    if rows.isEmpty {
                        EmptyCard(systemName: "tray", title: "No transactions", message: memberFilter == nil ? "Nothing filed to \(selected.category.name) in \(DateLabel.month(month.start))." : "Nothing from this person in \(selected.category.name) yet.")
                    } else {
                        CardList(items: rows, inset: 68) { entry in
                            Button { openEntry(entry) } label: {
                                LedgerLine(entry: entry, lookup: lookup, partCents: entry.isSplit ? entry.cents(in: ids) : nil)
                            }
                            .buttonStyle(.plain)
                            .tint(.primary)
                        }
                    }
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView("No budgets yet", systemImage: "dollarsign.circle", description: Text("Add a budget to see its transactions here."))
        }
    }
}

// MARK: - Book: "Money Date"

/// One thing to talk through on a Money Date, built from what Suffice already knows:
/// overspending, renewals coming up, and stash goals. Each resolves with one action.
struct AgendaItem: Identifiable {
    enum Kind { case overspent, renewal, stash }

    enum Action {
        case openBudget(BudgetCategory)
        case openBill(Bill)
        case markStashed(Stash)
        case startStash(Bill, due: Date)
    }

    var id: String
    var kind: Kind
    var title: String
    var detail: String
    var actionTitle: String
    var actionSymbol: String
    var action: Action

    var symbol: String {
        switch kind {
        case .overspent: "exclamationmark.triangle.fill"
        case .renewal: "arrow.triangle.2.circlepath"
        case .stash: "archivebox.fill"
        }
    }

    var tileColor: Color {
        switch kind {
        case .overspent: CategoryColor.orange.ink
        case .renewal: CategoryColor.blue.ink
        case .stash: Brand.green
        }
    }
}

/// A monthly check-in for two, held open like a book: the left page is how the month went,
/// the right page is a short agenda. Two equal pages, so neither person reads across the fold.
struct MoneyDateView: View {
    let month: MonthSpan
    let totals: MonthTotals
    let statuses: [CategoryStatus]
    let lookup: Lookup
    let agenda: [AgendaItem]
    let resolved: Set<String>
    let resolve: (AgendaItem) -> Void

    var body: some View {
        HearthFoldSplit {
            ScrollView { monthPage.padding(16) }
        } secondary: {
            ScrollView { agendaPage.padding(16) }
        }
        .duoGreenChrome("Money Date")
    }

    private var monthPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            pageTitle("How \(DateLabel.month(month.start)) went")
            BudgetSummaryCard(totals: totals, isThisMonth: month == MonthSpan(containing: .now), showsStashed: totals.stashedCents > 0)
            Card {
                HStack {
                    Label("Came in", systemImage: "arrow.down.left")
                    Spacer()
                    Text(Money.whole(totals.incomeCents))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .font(.subheadline)
            }
            if !statuses.isEmpty {
                SectionTitle("Every budget")
                CardList(items: statuses, inset: 16) { status in
                    LimitBarRow(status: status, category: lookup.categories[status.id])
                }
            }
        }
    }

    private var agendaPage: some View {
        let open = agenda.filter { !resolved.contains($0.id) }
        let done = agenda.filter { resolved.contains($0.id) }
        return VStack(alignment: .leading, spacing: 12) {
            pageTitle("To talk through")
            if agenda.isEmpty {
                EmptyCard(systemName: "checkmark.seal", title: "Nothing to talk through", message: "No overspending, renewals or stashes need a word this month.", isGlass: true)
            } else {
                Text(done.isEmpty ? "\(agenda.count) to go" : "\(done.count) of \(agenda.count) settled")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                CardList(items: open + done, inset: 66) { item in
                    AgendaRow(item: item, isResolved: resolved.contains(item.id)) { resolve(item) }
                }
            }
        }
    }

    private func pageTitle(_ text: String) -> some View {
        Text(text)
            .font(.title.bold())
            .foregroundStyle(.white)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 4)
    }
}

private struct AgendaRow: View {
    let item: AgendaItem
    let isResolved: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(item.tileColor, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .strikethrough(isResolved)
                Text(item.detail)
                    .font(.subheadline)
                    .foregroundStyle(Brand.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if isResolved {
                    Label("Settled", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Button(action: action) {
                        Label(item.actionTitle, systemImage: item.actionSymbol)
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    // A text button in a row: the text color, not the app's (AGENT.md).
                    .tint(.primary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(isResolved ? 0.6 : 1)
    }
}

// MARK: - Tent: "Today's Number"

/// The glance board for a desk or counter: what's safe to spend today, readable from across the
/// room, with the week's spending underneath (today solid white, the rest faint). Add Expense
/// stays one tap away on the rail. Always this month, whatever month the app is showing.
struct TodayBoard: View {
    @Query private var entries: [LedgerEntry]
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query private var stashMoves: [StashMove]
    @State private var adding: DraftItem?
    private let month: MonthSpan
    private let days: [Date]

    init() {
        let month = MonthSpan(containing: .now)
        let days = SpendPace.week(containing: .now)
        self.month = month
        self.days = days
        let weekEnd = days.last.flatMap { Calendar.current.date(byAdding: .day, value: 1, to: $0) } ?? month.end
        let start = min(month.start, days.first ?? month.start)
        let end = max(month.end, weekEnd)
        _entries = Query(filter: #Predicate<LedgerEntry> { $0.date >= start && $0.date < end })
    }

    var body: some View {
        let records = entries.map(\.record)
        let inMonth = records.filter { month.contains($0.date) }
        let totals = BudgetMath.totals(categories.map(\.record), entries: inMonth, in: month, stashMoves: stashMoves.map(\.record))
        let safe = SpendPace.safeToday(leftCents: totals.leftCents, month: month, entries: inMonth)
        let week = SpendPace.spending(on: days, entries: records)
        let weekTotal = week.reduce(0) { $0 + $1.cents }

        HearthGlanceBoard("Today's Number", color: Brand.green) {
            VStack(spacing: 24) {
                Spacer(minLength: 0)
                HearthGlanceFigure(value: Money.whole(safe), label: totals.leftCents < 0 ? "Over plan this month" : "Safe to spend today")
                WeekBars(days: week)
                Text("\(Money.whole(weekTotal)) spent this week")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .opacity(0.85)
                Spacer(minLength: 0)
            }
        } actions: {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    adding = DraftItem(draft: EntryDraft())
                } label: {
                    Label("Add Expense", systemImage: "plus")
                }
            }
        }
        .sheet(item: $adding) { item in
            TransactionSheet(entry: nil, initial: item.draft)
        }
    }
}

/// The week's spending as seven bars: today solid white, the other days faint.
private struct WeekBars: View {
    let days: [DaySpend]

    var body: some View {
        let most = max(days.map(\.cents).max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(days) { day in
                let isToday = Calendar.current.isDateInToday(day.date)
                VStack(spacing: 6) {
                    Capsule()
                        .fill(Color.white.opacity(isToday ? 1 : 0.3))
                        .frame(height: 8 + 92 * CGFloat(day.cents) / CGFloat(most))
                    Text(day.date.formatted(.dateTime.weekday(.narrow)))
                        .font(.headline)
                        .opacity(isToday ? 1 : 0.6)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide)))
                .accessibilityValue(Money.whole(day.cents))
            }
        }
        .frame(maxWidth: 520)
    }
}
