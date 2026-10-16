import SwiftUI

/// The cards under an answer, from the Ask designs: one budget (ring, spent of planned, biggest
/// payees, Open), where the money went (bars by budget, split by person), or a proposed move
/// between budgets (Move and Not Now). Every number is read from the data when it's drawn.
struct AskCards: View {
    var message: AskMessage
    var data: AskData?
    var onOpen: (BudgetCategory) -> Void
    var onTransfer: (Bool) -> Void

    var body: some View {
        if let data {
            if let id = message.budgetID, let category = data.category(id) {
                BudgetAnswerCard(category: category, data: data, onOpen: { onOpen(category) })
            }
            if let month = message.breakdown {
                BreakdownCard(breakdown: data.breakdown(in: month))
            }
            if let transfer = message.transfer {
                TransferCard(transfer: transfer, state: message.transferState, data: data, onTransfer: onTransfer)
            }
        }
    }
}

/// The fill behind a card inside an answer.
private let cardFill = Color(.tertiarySystemGroupedBackground)

private struct BudgetAnswerCard: View {
    var category: BudgetCategory
    var data: AskData
    var onOpen: () -> Void

    var body: some View {
        let month = MonthSpan(containing: .now)
        let status = data.status(of: category.id, in: month)
        let payees = data.topPayees(in: category, month: month)

        VStack(alignment: .leading, spacing: 10) {
            if let status {
                HStack(spacing: 12) {
                    CategoryRing(progress: status.progress, color: status.isOver ? .red : category.color, symbol: category.symbol, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.name)
                            .font(.subheadline.weight(.semibold))
                        Text(status.limitCents > 0 ? "\(Money.text(status.spentCents)) of \(Money.text(status.limitCents))" : "\(Money.text(status.spentCents)) spent")
                            .font(.footnote)
                            .foregroundStyle(Brand.secondaryText)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 8)
                    if status.limitCents > 0 {
                        Text(status.leftCents >= 0 ? "\(Money.text(status.leftCents)) left" : "\(Money.text(-status.leftCents)) over")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(status.leftCents >= 0 ? Brand.green : Brand.expenseInk)
                            .monospacedDigit()
                    }
                }
                .padding(12)
                .background(cardFill, in: .rect(cornerRadius: 16))
                .accessibilityElement(children: .combine)
            }

            if !payees.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Biggest this month")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.secondaryText)
                        .padding(.bottom, 4)
                    ForEach(Array(payees.enumerated()), id: \.element) { index, payee in
                        if index > 0 { Divider() }
                        HStack {
                            Text(payee.count > 1 ? "\(payee.name) · \(payee.count) visits" : payee.name)
                                .lineLimit(1)
                            Spacer()
                            Text(Money.text(payee.cents)).monospacedDigit()
                        }
                        .font(.subheadline)
                        .padding(.vertical, 6)
                    }
                }
            }

            Button(action: onOpen) {
                Text("Open \(category.name)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.green)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 40)
                    .background(cardFill, in: .capsule)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct BreakdownCard: View {
    var breakdown: AskData.Breakdown

    var body: some View {
        let largest = max(breakdown.rows.map(\.cents).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 10) {
            if breakdown.rows.isEmpty {
                Text("Nothing spent yet in \(breakdown.month.start.formatted(.dateTime.month(.wide))).")
                    .font(.footnote)
                    .foregroundStyle(Brand.secondaryText)
            } else {
                VStack(spacing: 8) {
                    ForEach(breakdown.rows) { row in
                        HStack(spacing: 8) {
                            Text(row.name)
                                .font(.footnote)
                                .foregroundStyle(Brand.secondaryText)
                                .lineLimit(1)
                                .frame(width: 82, alignment: .leading)
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color(.systemGray5))
                                    Capsule()
                                        .fill(row.color.color)
                                        .frame(width: max(10, proxy.size.width * Double(row.cents) / Double(largest)))
                                }
                            }
                            .frame(height: 10)
                            Text(Money.whole(row.cents))
                                .font(.footnote.weight(.semibold))
                                .monospacedDigit()
                                .frame(width: 64, alignment: .trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(row.name), \(Money.text(row.cents))")
                    }
                }
                .padding(12)
                .background(cardFill, in: .rect(cornerRadius: 16))
            }
            if breakdown.people.count > 1 {
                Text(breakdown.people.map { "\($0.name): \(Money.whole($0.cents))" }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(Brand.secondaryText)
                    .monospacedDigit()
            }
        }
    }
}

private struct TransferCard: View {
    var transfer: AskData.Transfer
    var state: AskMessage.TransferState
    var data: AskData
    var onTransfer: (Bool) -> Void

    var body: some View {
        let source = data.category(transfer.fromID)
        let target = data.category(transfer.toID)
        VStack(alignment: .leading, spacing: 10) {
            if state == .proposed, let amounts = data.amounts(for: transfer) {
                HStack(spacing: 10) {
                    side(source?.name ?? "Budget", from: amounts.from.0, to: amounts.from.1, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Brand.secondaryText)
                    side(target?.name ?? "Budget", from: amounts.to.0, to: amounts.to.1, alignment: .trailing)
                }
                .padding(12)
                .background(cardFill, in: .rect(cornerRadius: 16))
                Text("Changes their monthly amounts.")
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
                HStack(spacing: 8) {
                    Button { onTransfer(true) } label: {
                        Text("Move \(Money.whole(transfer.cents))")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Brand.green)
                    Button { onTransfer(false) } label: {
                        Text("Not now")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.green)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 40)
                            .background(cardFill, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            } else if state == .moved {
                Label("Moved \(Money.whole(transfer.cents)) from \(source?.name ?? "the budget") to \(target?.name ?? "the budget")", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.green)
            } else if state == .dismissed {
                Text("Nothing moved.")
                    .font(.footnote)
                    .foregroundStyle(Brand.secondaryText)
            }
        }
    }

    private func side(_ name: String, from: Int, to: Int, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text("\(Money.whole(from)) → \(Money.whole(to))")
                .font(.footnote)
                .foregroundStyle(Brand.secondaryText)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}
