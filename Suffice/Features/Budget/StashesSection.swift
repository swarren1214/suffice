import SwiftData
import SwiftUI

/// Budget › Stashes: money set aside month by month for the costs that come once or twice a
/// year. A suggestion card for a rare bill without one, then each stash with its ring, what's
/// stashed of its target, its date, its monthly amount and where it stands. Tapping one opens it.
struct StashesSection: View {
    @Query(sort: \Stash.sortOrder) private var stashes: [Stash]
    @Query private var moves: [StashMove]
    @Query(filter: #Predicate<LedgerEntry> { $0.stashID != nil }) private var paid: [LedgerEntry]
    @Query(filter: #Predicate<Bill> { $0.isActive == true }) private var bills: [Bill]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @State private var settings = PlanningSettings.shared
    @State private var opened: StashSheetItem?

    var body: some View {
        let active = stashes.filter { !$0.isArchived }
        let moveRecords = moves.map(\.record)
        let paidRecords = paid.map(\.record)
        let suggestion = StashMath.suggestions(
            bills: bills.map(\.record),
            stashes: stashes.map(\.record),
            dismissed: settings.dismissedSuggestions
        ).first

        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "Stashes") {
                TintedCapsuleButton(title: "Add", systemImage: "plus") {
                    opened = StashSheetItem(stash: nil, draft: StashDraft())
                }
                .accessibilityLabel("Add a stash")
            }

            if let suggestion, let bill = bills.first(where: { $0.id == suggestion.billID }) {
                SuggestionCard(suggestion: suggestion) {
                    opened = StashSheetItem(stash: nil, draft: .forBill(bill, due: suggestion.dueDate))
                } dismiss: {
                    withAnimation(.snappy) { settings.dismissSuggestion(for: suggestion.billID) }
                }
            }

            if active.isEmpty {
                if suggestion == nil {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Plan for the yearly bills")
                                .font(.headline)
                            Text("Insurance, registration, Christmas: stash a little each month, and when the bill comes it’s already covered instead of landing on one month’s budget.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                CardList(items: active, inset: 72) { stash in
                    Button {
                        opened = StashSheetItem(stash: stash, draft: StashDraft(stash))
                    } label: {
                        StashRow(stash: stash, summary: StashMath.summary(stash.record, moves: moveRecords, entries: paidRecords))
                    }
                    .buttonStyle(.plain)
                }

                Text(footnote(active))
                    .font(.footnote)
                    .foregroundStyle(Brand.secondaryText)
                    .padding(.horizontal, 6)
            }
        }
        .sheet(item: $opened) { item in
            StashEditor(stash: item.stash, initial: item.draft)
        }
    }

    /// "Stashes count in the plan each month… The money stays in Ally Savings until the bill comes."
    private func footnote(_ active: [Stash]) -> String {
        let places = Set(active.compactMap(\.accountID))
        let place = places.count == 1 ? accounts.first { $0.id == places.first }?.displayName : nil
        return "Stashes count in the plan each month, so Left to spend already accounts for them. The money stays in \(place ?? "your accounts") until the bill comes."
    }
}

/// One stash: its ring and icon, name, stashed of target and date, monthly amount and status.
private struct StashRow: View {
    var stash: Stash
    var summary: StashSummary

    var body: some View {
        HStack(spacing: 12) {
            CategoryRing(progress: summary.progress(targetCents: stash.targetCents), color: stash.color, symbol: stash.symbol, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(stash.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(Money.whole(summary.balanceCents)) stashed of \(Money.whole(stash.targetCents)) · \(dueText)")
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
                    .monospacedDigit()
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if summary.monthlyCents > 0 {
                    Text("\(Money.whole(summary.monthlyCents))/mo")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
                StashStatusPill(status: summary.status)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 72)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stash.name)
        .accessibilityValue("\(Money.whole(summary.balanceCents)) of \(Money.whole(stash.targetCents)), due \(dueText). \(summary.monthlyCents > 0 ? "\(Money.whole(summary.monthlyCents)) a month. " : "")\(summary.status.label)")
        .accessibilityHint("Opens the stash")
    }

    /// "Dec 15" this year, "Jun 2027" after.
    private var dueText: String {
        Calendar.current.isDate(stash.dueDate, equalTo: .now, toGranularity: .year)
            ? stash.dueDate.formatted(.dateTime.month(.abbreviated).day())
            : stash.dueDate.formatted(.dateTime.month(.abbreviated).year())
    }
}

/// "On track" in green, "Behind $52" in orange, "Fully stashed" in green, "Due" in blue.
struct StashStatusPill: View {
    var status: StashStatus
    @Environment(\.colorScheme) private var colorScheme

    private var palette: CategoryColor {
        switch status {
        case .onTrack, .funded: .green
        case .behind: .orange
        case .due: .blue
        }
    }

    var body: some View {
        let isDark = colorScheme == .dark
        Text(status.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isDark ? palette.color : palette.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(isDark ? palette.color.opacity(0.22) : palette.tint, in: .capsule)
            .monospacedDigit()
    }
}

/// "Home insurance is due in March": a rare bill worth stashing for, with Stash $276/mo and
/// Not Now.
private struct SuggestionCard: View {
    var suggestion: StashSuggestion
    var accept: () -> Void
    var dismiss: () -> Void

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.green)
                    .frame(width: 36, height: 36)
                    .background(Brand.greenPale, in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(suggestion.name) is due in \(suggestion.dueDate.formatted(.dateTime.month(.wide)))")
                        .font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { buttons }
                        VStack(alignment: .leading, spacing: 8) { buttons }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        Button(action: accept) {
            Text("Stash \(Money.whole(suggestion.monthlyCents))/mo")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .background(Brand.green, in: .capsule)
        }
        .buttonStyle(.plain)
        Button(action: dismiss) {
            Text("Not Now")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(Color(.systemGray5), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    /// "It's $1,380 a year. Stashing $276 a month from now covers it without touching March's
    /// budget, then $115 a month after that."
    private var message: String {
        let month = suggestion.dueDate.formatted(.dateTime.month(.wide))
        let every = suggestion.repeatsYearly ? " a year" : ""
        return "It’s \(Money.whole(suggestion.amountCents))\(every). Stashing \(Money.whole(suggestion.monthlyCents)) a month from now covers it without touching \(month)’s budget, then \(Money.whole(suggestion.afterCents)) a month after that."
    }
}
