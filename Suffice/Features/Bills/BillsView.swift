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
    @AppStorage(SettingsKey.currentMember) private var currentMember = ""
    @State private var editing: Bill?
    @State private var differentAmount: DraftItem?

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

        GreenScreen("Bills") {
            if bills.isEmpty {
                EmptyCard(systemName: "calendar", title: "No bills yet", message: "Tap + to add the bills you pay on a schedule, like the mortgage, phone and power.")
            } else {
                WeekCard(
                    days: BudgetMath.week(bills.map(\.record)),
                    total: BudgetMath.dueThisWeek(bills.map(\.record), payments: payments)
                )

                if !upcoming.isEmpty {
                    SectionTitle("Upcoming")
                    dueList(upcoming)
                }

                if !subscriptionDues.isEmpty {
                    SectionTitle("Subscriptions")
                    dueList(subscriptionDues)
                }

                if !later.isEmpty {
                    SectionTitle("Not due in \(DateLabel.month(month.start))")
                    CardList(items: later) { bill in
                        Button { editing = bill } label: {
                            HStack {
                                Text(bill.name).foregroundStyle(.primary)
                                Spacer()
                                Text(laterText(bill))
                                    .foregroundStyle(Brand.secondaryText)
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 50)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .sheet(item: $editing) { bill in
            BillEditor(bill: bill)
        }
        .sheet(item: $differentAmount) { item in
            TransactionSheet(entry: nil, initial: item.draft)
        }
    }

    private func dueList(_ dues: [BillDue]) -> some View {
        CardList(items: dues, inset: 66) { due in
            BillRow(bill: due.bill, state: due.state, dueDate: due.date) {
                togglePaid(due)
            }
            .contentShape(.rect)
            .onTapGesture { editing = due.bill }
            .tint(.primary)
            .contextMenu {
                if !due.state.isPaid {
                    Button("Pay a Different Amount…", systemImage: "dollarsign.circle") {
                        differentAmount = DraftItem(draft: Ledger.paymentDraft(for: due.bill, dueOn: due.date, memberID: currentMemberID))
                    }
                }
                Button("Edit Bill", systemImage: "pencil") { editing = due.bill }
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
        return "\(Money.text(bill.amountCents)) · next \(DateLabel.short(next))"
    }

    private var currentMemberID: UUID? {
        UUID(uuidString: currentMember).flatMap { id in members.contains { $0.id == id } ? id : nil }
    }

    private func togglePaid(_ due: BillDue) {
        withAnimation(.snappy) {
            if due.state.isPaid {
                Ledger.unpay(due.bill, dueOn: due.date, context: context)
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

private struct BillRow: View {
    var bill: Bill
    var state: BillState
    var dueDate: Date
    var togglePaid: () -> Void

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
            }
            Spacer(minLength: 8)
            Button(action: togglePaid) {
                Text(state.isPaid ? "✓ Paid" : "Mark paid")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(state.isPaid ? Color.white : Color.primary)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
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

    private var detail: String {
        var parts = [Money.text(bill.amountCents), dueDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())]
        if case .overdue(let days) = state { parts.append(days == 1 ? "1 day late" : "\(days) days late") }
        if bill.frequency != .monthly || bill.interval > 1 {
            parts.append(BudgetMath.scheduleText(bill.record))
        }
        if bill.isAutopay { parts.append("Autopay") }
        return parts.joined(separator: " · ")
    }
}

#Preview {
    NavigationStack { BillsView() }
        .previewEnvironment()
}
