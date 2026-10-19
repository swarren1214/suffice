import SwiftData
import SwiftUI

/// Bills: what's due in the next seven days on a strip, then every time a bill comes due this
/// month (weekly bills several times), late ones first, each with Mark paid. Subscriptions are
/// listed on their own, and bills that skip this month (quarterly, yearly) at the end with their
/// next date. Marking one paid records the payment in Activity under the bill's category.
struct BillsView: View {
    @Environment(AppRouter.self) private var router
    @State private var showsNewBill = false

    var body: some View {
        MonthBills(month: router.month)
            .id(router.month)
            .tabToolbar {
                Button {
                    showsNewBill = true
                } label: {
                    Label("Add Bill", systemImage: "plus")
                        .foregroundStyle(.white)
                }
            }
            .sheet(isPresented: $showsNewBill) {
                BillEditor(bill: nil)
            }
            // A bill shared or opened in Suffice (Share › Suffice, Open in Suffice).
            .sheet(item: Bindable(router).incomingDocument) { document in
                BillImportSheet(document: document)
            }
    }
}

/// One time a bill comes due.
private struct BillDue: Identifiable {
    var bill: Bill
    var date: Date
    var state: BillState
    var id: String { "\(bill.id.uuidString)-\(date.timeIntervalSinceReferenceDate)" }
}

private struct MonthBills: View {
    let month: MonthSpan
    @Query(filter: #Predicate<Bill> { $0.isActive == true }, sort: \Bill.dueDay) private var bills: [Bill]
    @Query private var entries: [LedgerEntry]
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @AppStorage(SettingsKey.currentMember) private var currentMember = ""
    @Query(filter: #Predicate<Stash> { $0.isArchived == false }) private var stashes: [Stash]
    @Query private var stashMoves: [StashMove]
    @Query(filter: #Predicate<LedgerEntry> { $0.stashID != nil }) private var stashPaid: [LedgerEntry]
    @Query(sort: \BillStatement.dueDate, order: .reverse) private var statements: [BillStatement]
    @State private var editing: Bill?
    @State private var differentAmount: DraftItem?
    @State private var stashing: StashSheetItem?
    @State private var reviewing: BillStatement?

    /// How far back to look for unpaid bills while showing this month.
    private static let overdueWindowDays = 62

    init(month: MonthSpan) {
        self.month = month
        // Payments from a few months back through next month: early payments, catch-ups and
        // the seven-day strip crossing into next month.
        let start = month.offset(by: -3).start
        let end = month.offset(by: 1).end
        _entries = Query(filter: #Predicate<LedgerEntry> { $0.date >= start && $0.date < end })
    }

    var body: some View {
        let payments = entries.filter { $0.billID != nil }.map(\.record)
        let isThisMonth = month == MonthSpan(containing: .now)
        let regular = bills.filter { !$0.isSubscription }
        let subscriptions = bills.filter(\.isSubscription)
        let upcoming = dues(for: regular, payments: payments, includeOverdue: isThisMonth)
        let subscriptionDues = dues(for: subscriptions, payments: payments, includeOverdue: isThisMonth)
        let later = regular.filter { bill in !upcoming.contains { $0.bill.id == bill.id } }
        let saving = savingByBill()
        let statementRecords = statements.map(\.record)
        let newBills = statements.filter { !$0.isReviewed }

        GreenScreen("Bills") {
            if bills.isEmpty {
                EmptyCard(systemName: "calendar", title: "No bills yet", message: "Tap + to add the bills you pay on a schedule, like the mortgage, phone and power.")
            } else {
                WeekCard(
                    days: BudgetMath.week(bills.map(\.record)),
                    total: StatementMath.dueThisWeek(bills.map(\.record), payments: payments, statements: statementRecords)
                )
            }

            // Bills Suffice read (from email, or shared to it), waiting for a look.
            ForEach(newBills) { statement in
                Button { reviewing = statement } label: {
                    NewStatementCard(statement: statement, billName: bills.first { $0.id == statement.billID }?.name)
                }
                .buttonStyle(.plain)
            }

            if !bills.isEmpty {

                if !upcoming.isEmpty {
                    SectionTitle("Upcoming")
                    dueList(upcoming, saving: saving, statements: statementRecords)
                }

                if !subscriptionDues.isEmpty {
                    SectionTitle("Subscriptions")
                    dueList(subscriptionDues, saving: saving, statements: statementRecords)
                }

                if !later.isEmpty {
                    SectionTitle("Not due in \(DateLabel.month(month.start))")
                    CardList(items: later) { bill in
                        Button { editing = bill } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bill.name).foregroundStyle(.primary)
                                    if let monthly = saving[bill.id] {
                                        SavingLine(cents: monthly)
                                    }
                                }
                                Spacer()
                                Text(laterText(bill))
                                    .foregroundStyle(Brand.secondaryText)
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .frame(minHeight: 50)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            stashMenuItem(bill)
                            Button("Edit Bill", menuIcon: "pencil") { editing = bill }
                        }
                    }
                }
            }
        }
        // Pull down to fetch the latest from iCloud.
        .refreshable { await HouseholdSync.shared.syncNow() }
        .sheet(item: $editing) { bill in
            BillSheet(bill: bill)
        }
        .sheet(item: $reviewing) { statement in
            BillReadSheet(statement: statement)
        }
        .sheet(item: $differentAmount) { item in
            TransactionSheet(entry: nil, initial: item.draft)
        }
        .sheet(item: $stashing) { item in
            StashEditor(stash: item.stash, initial: item.draft)
        }
    }

    /// Each bill with a stash, and what's stashed for it a month.
    private func savingByBill() -> [UUID: Int] {
        let moves = stashMoves.map(\.record)
        let paid = stashPaid.map(\.record)
        var result: [UUID: Int] = [:]
        for stash in stashes {
            guard let billID = stash.billID else { continue }
            let summary = StashMath.summary(stash.record, moves: moves, entries: paid)
            let cents = max(summary.monthlyCents, summary.thisMonthCents)
            if cents > 0 { result[billID] = cents }
        }
        return result
    }

    /// "Stash for This…" on a bill without one opens a new stash for its next due date; a bill
    /// with one opens it.
    @ViewBuilder
    private func stashMenuItem(_ bill: Bill) -> some View {
        if let stash = stashes.first(where: { $0.billID == bill.id }) {
            Button("Open Stash", menuIcon: "archivebox") {
                stashing = StashSheetItem(stash: stash, draft: StashDraft(stash))
            }
        } else if bill.frequency != .weekly, let due = BudgetMath.nextDue(of: bill.record) {
            Button("Stash for This…", menuIcon: "archivebox") {
                stashing = StashSheetItem(stash: nil, draft: .forBill(bill, due: due))
            }
        }
    }

    private func dueList(_ dues: [BillDue], saving: [UUID: Int], statements: [StatementRecord]) -> some View {
        CardList(items: dues, inset: 66) { due in
            let record = due.bill.record
            let statement = StatementMath.statement(for: record, dueOn: due.date, statements: statements)
            BillRow(
                bill: due.bill,
                state: due.state,
                dueDate: due.date,
                savingCents: saving[due.bill.id],
                statementCents: statement?.amountCents,
                usualCents: statement == nil ? nil : StatementMath.average(StatementMath.history(due.bill.id, statements: statements))
            ) {
                togglePaid(due)
            }
            .contentShape(.rect)
            .onTapGesture { editing = due.bill }
            .tint(.primary)
            .contextMenu {
                if !due.state.isPaid {
                    Button("Pay a Different Amount…", menuIcon: "dollarsign.circle") {
                        differentAmount = DraftItem(draft: Ledger.paymentDraft(for: due.bill, dueOn: due.date, memberID: currentMemberID, amountCents: BillStatements.amount(for: due.bill, dueOn: due.date, in: context)))
                    }
                }
                if let link = due.bill.payLink, !due.state.isPaid {
                    Button("Pay at \(due.bill.payHost ?? "Website")", menuIcon: "arrow.up.right") { openURL(link) }
                }
                stashMenuItem(due.bill)
                Button("Edit Bill", menuIcon: "pencil") { editing = due.bill }
            }
        }
    }

    /// Every time the bills come due this month, plus (while showing this month) anything
    /// still unpaid from the last two months. Late ones first, then by date.
    private func dues(for bills: [Bill], payments: [EntryRecord], includeOverdue: Bool) -> [BillDue] {
        let calendar = Calendar.current
        let from = includeOverdue
            ? calendar.date(byAdding: .day, value: -Self.overdueWindowDays, to: month.start) ?? month.start
            : month.start
        return bills.flatMap { bill in
            BudgetMath.occurrences(of: bill.record, from: from, to: month.end).compactMap { date -> BillDue? in
                let state = BudgetMath.state(of: bill.record, dueOn: date, payments: payments)
                // Before this month, only what's still unpaid.
                if date < month.start, state.isPaid { return nil }
                return BillDue(bill: bill, date: date, state: state)
            }
        }
        .sorted { ($0.state.sortRank, $0.date) < ($1.state.sortRank, $1.date) }
    }

    private func laterText(_ bill: Bill) -> String {
        guard let next = BudgetMath.nextDue(of: bill.record, onOrAfter: month.end) else { return "No more due dates" }
        return "\(bill.amountLabel) · next \(DateLabel.short(next))"
    }

    private var currentMemberID: UUID? {
        UUID(uuidString: currentMember).flatMap { id in members.contains { $0.id == id } ? id : nil }
    }

    private func togglePaid(_ due: BillDue) {
        withAnimation(.snappy) {
            if due.state.isPaid {
                Ledger.unpay(due.bill, dueOn: due.date, context: context)
            } else if due.bill.isVariable, StatementMath.statement(for: due.bill.record, dueOn: due.date, statements: statements.map(\.record)) == nil {
                // A variable bill's amount isn't known ahead (no statement for it yet): open the
                // payment to fill it in, starting from the average.
                differentAmount = DraftItem(draft: Ledger.paymentDraft(for: due.bill, dueOn: due.date, memberID: currentMemberID))
            } else {
                _ = Ledger.pay(due.bill, dueOn: due.date, memberID: currentMemberID, in: context)
            }
        }
    }
}

/// The glass card at the top: what's due in the next 7 days, and the week strip with today in
/// green and a red dot under bill days.
private struct WeekCard: View {
    var days: [BillDay]
    var total: Int

    var body: some View {
        let count = days.reduce(0) { $0 + $1.billIDs.count }
        GlassCard {
            GlassCardHeader(title: "Due in the next 7 days", note: count == 0 ? "Nothing due" : "\(count) bill\(count == 1 ? "" : "s")")
            GlassFigure(text: Money.text(total))
            HStack(spacing: 4) {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    let isToday = index == 0
                    VStack(spacing: 3) {
                        Text(day.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(isToday ? Color.white : Color.secondary)
                        Text(day.date.formatted(.dateTime.day()))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(isToday ? Color.white : Color.primary)
                        Circle()
                            .fill(day.billIDs.isEmpty ? .clear : Brand.expense)
                            .frame(width: 6, height: 6)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        if isToday {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Brand.green)
                                .shadow(color: Brand.green.opacity(0.3), radius: 5, y: 4)
                        } else {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.primary.opacity(0.06))
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide).month().day()))
                    .accessibilityValue(day.billIDs.isEmpty ? "No bills" : "\(day.billIDs.count) bill\(day.billIDs.count == 1 ? "" : "s") due")
                }
            }
        }
    }
}

/// "Saving $48/mo": a bill that has a stash.
private struct SavingLine: View {
    var cents: Int

    var body: some View {
        Label("Saving \(Money.whole(cents))/mo", systemImage: "archivebox.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(CategoryColor.green.ink)
            .labelStyle(.titleAndIcon)
            .monospacedDigit()
    }
}

private struct BillRow: View {
    var bill: Bill
    var state: BillState
    var dueDate: Date
    /// What its stash saves a month, when it has one.
    var savingCents: Int? = nil
    /// The amount on this due date's statement, and the average of its statements.
    var statementCents: Int? = nil
    var usualCents: Int? = nil
    var togglePaid: () -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 12) {
            Text(bill.initial)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(bill.color.ink, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(bill.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isLate ? Brand.expenseInk : Brand.secondaryText)
                    .monospacedDigit()
                    .lineLimit(1)
                if let savingCents {
                    SavingLine(cents: savingCents)
                }
                if statementCents != nil {
                    Text(statementLine)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CategoryColor.green.ink)
                        .monospacedDigit()
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let link = bill.payLink, !state.isPaid, !dynamicTypeSize.isAccessibilitySize {
                Button {
                    openURL(link)
                } label: {
                    HStack(spacing: 3) {
                        Text("Pay")
                        Image(systemName: "arrow.up.right").font(.caption.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.green)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34)
                    .background(Brand.green.opacity(0.12), in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pay \(bill.name) at \(bill.payHost ?? "its website")")
            }
            Button(action: togglePaid) {
                Text(state.isPaid ? "✓ Paid" : "Mark paid")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(state.isPaid ? Color.white : Color.primary)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .background(state.isPaid ? Brand.green : Color(.systemGray5), in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.isPaid ? "\(bill.name) paid. Mark unpaid" : "Mark \(bill.name) paid")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 62)
    }

    private var isLate: Bool {
        if case .overdue = state { true } else { false }
    }

    /// "From your Oct bill · usually ~$150".
    private var statementLine: String {
        var line = "From your \(dueDate.formatted(.dateTime.month(.abbreviated))) bill"
        if let usualCents, let statementCents, usualCents != statementCents { line += " · usually ~\(Money.whole(usualCents))" }
        return line
    }

    private var detail: String {
        var parts = [statementCents.map { Money.text($0) } ?? bill.amountLabel, dueDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())]
        if case .overdue(let days) = state { parts.append(days == 1 ? "1 day late" : "\(days) days late") }
        if bill.frequency != .monthly || bill.interval > 1 {
            parts.append(BudgetMath.scheduleText(bill.record))
        }
        if bill.isAutopay { parts.append("Autopay") }
        return parts.joined(separator: " · ")
    }
}

/// "New bill from your email · Santaquin City · $142.86 due Oct 20 · Review".
private struct NewStatementCard: View {
    let statement: BillStatement
    var billName: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statement.source == .email ? "envelope" : "doc.text")
                .font(.headline)
                .foregroundStyle(Brand.green)
                .frame(width: 40, height: 40)
                .background(Brand.greenPale, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(statement.source == .email ? "New bill from your email" : "New bill to check")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("\(billName ?? (statement.sender.isEmpty ? "Pick its bill" : statement.sender)) · \(Money.text(statement.amountCents)) due \(statement.dueDate.formatted(.dateTime.month(.abbreviated).day())) · Review")
                    .font(.footnote)
                    .foregroundStyle(Brand.secondaryText)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
        .contentShape(.rect(cornerRadius: 26))
        .accessibilityHint("Opens what Suffice read from the bill")
    }
}

#Preview {
    NavigationStack { BillsView() }
        .previewEnvironment()
}
