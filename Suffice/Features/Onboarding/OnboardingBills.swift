import SwiftData
import SwiftUI

/// Step 5, Bills: the repeating payments found in the bank history, each kept or not, and any
/// bill added by hand. Tracking one adds it with its schedule and budget, and marks this
/// month's payment if it's already gone out.
struct OnboardingBills: View {
    @Environment(OnboardingFlow.self) private var flow
    @Environment(\.modelContext) private var context
    @Query(sort: \Bill.createdAt) private var bills: [Bill]
    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query(sort: \LinkedBank.createdAt) private var banks: [LinkedBank]
    @State private var showsNewBill = false

    private var found: [SpendingHistory.FoundBill] { flow.foundBills ?? [] }
    private var keptCount: Int { found.filter { flow.keptBills.contains($0.id) }.count }
    private var hasBank: Bool { !banks.isEmpty }

    private var title: String {
        switch found.count {
        case 0: "Add your bills"
        case 1: "We found a bill"
        default: "We found \(found.count) bills"
        }
    }

    private var subtitle: String {
        if !found.isEmpty {
            let names = banks.map(\.institution).filter { !$0.isEmpty }
            let source = names.isEmpty ? "bank" : names.formatted(.list(type: .and))
            return "These repeat in your \(source) transactions. Keep the ones you want reminders for."
        }
        return hasBank
            ? "We didn’t spot any repeating bills yet. Add the ones you know, and Suffice reminds you before they’re due."
            : "Rent, utilities, insurance, subscriptions: add them and Suffice reminds you before they’re due."
    }

    var body: some View {
        OnboardingStep(title: title, subtitle: subtitle) {
            if !found.isEmpty {
                OnboardingCard {
                    ForEach(found) { bill in
                        if bill.id != found.first?.id { OnboardingDivider(inset: 64) }
                        foundRow(bill)
                    }
                }
            }
            if !bills.isEmpty {
                OnboardingCard {
                    ForEach(bills) { bill in
                        if bill.id != bills.first?.id { OnboardingDivider(inset: 64) }
                        savedRow(bill)
                    }
                }
            }
            if hasBank {
                Label("Paid bills mark themselves when the payment comes in from your bank.", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: 0xC9DAF5))
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: 0x7FB2FF).opacity(0.10), in: .rect(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color(hex: 0x7FB2FF).opacity(0.22)))
            }
            OnboardingAddLink(title: found.isEmpty && bills.isEmpty ? "Add a Bill" : "Add a Bill We Missed") { showsNewBill = true }
        } controls: {
            if keptCount > 0 {
                Button(keptCount == 1 ? "Track 1 Bill" : "Track \(keptCount) Bills", action: track)
                    .buttonStyle(.onboarding())
            } else {
                Button(bills.isEmpty ? "Skip for Now" : "Continue", action: flow.next)
                    .buttonStyle(.onboarding(bills.isEmpty ? .secondary : .primary))
            }
        }
        .onAppear(perform: prepare)
        .sheet(isPresented: $showsNewBill) {
            BillEditor(bill: nil)
        }
    }

    // MARK: Rows

    private func foundRow(_ bill: SpendingHistory.FoundBill) -> some View {
        let isKept = flow.keptBills.contains(bill.id)
        let category = categoryNamed(bill.budgetName)
        return Button {
            withAnimation(.snappy) {
                if isKept { flow.keptBills.remove(bill.id) } else { flow.keptBills.insert(bill.id) }
            }
        } label: {
            HStack(spacing: 12) {
                OnboardingInitial(text: bill.name, color: category?.color ?? .blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(bill.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(schedule(bill, category: category?.name))
                        .font(.system(size: 12))
                        .foregroundStyle(OnboardingStyle.tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text((bill.isVariable ? "~" : "") + amount(bill.amountCents))
                    .font(.system(size: 15, weight: .bold))
                    .monospacedDigit()
                Image(systemName: isKept ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                    .foregroundStyle(isKept ? OnboardingStyle.accent : Color(hex: 0x636366))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isKept ? "Tracked" : "Not tracked")
        .accessibilityAddTraits(isKept ? .isSelected : [])
    }

    private func savedRow(_ bill: Bill) -> some View {
        HStack(spacing: 12) {
            OnboardingInitial(text: bill.name, color: bill.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(bill.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(BudgetMath.scheduleText(bill.record))
                    .font(.system(size: 12))
                    .foregroundStyle(OnboardingStyle.tertiaryText)
            }
            Spacer(minLength: 6)
            Text(bill.amountLabel)
                .font(.system(size: 15, weight: .bold))
                .monospacedDigit()
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(OnboardingStyle.accent)
                .frame(width: 24)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    /// "Monthly on the 1st · Home", "Monthly around the 12th · varies", "Subscription · the 18th".
    private func schedule(_ bill: SpendingHistory.FoundBill, category: String?) -> String {
        let ordinal = NumberFormatter()
        ordinal.numberStyle = .ordinal
        let day = ordinal.string(from: NSNumber(value: bill.dueDay)) ?? "\(bill.dueDay)"
        if bill.isSubscription { return "Subscription · the \(day)" }
        if bill.isVariable { return "Monthly around the \(day) · varies" }
        return ["Monthly on the \(day)", category].compactMap { $0 }.joined(separator: " · ")
    }

    /// Whole dollars when it's even ("$1,850"), cents otherwise ("$15.49").
    private func amount(_ cents: Int) -> String {
        cents % 100 == 0 ? Money.whole(cents) : Money.text(cents)
    }

    private func categoryNamed(_ name: String?) -> BudgetCategory? {
        guard let name else { return nil }
        return categories.first { $0.parentID == nil && !$0.isArchived && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: Working it out

    /// Looks for bills once. Bills are kept to start with; subscriptions aren't.
    private func prepare() {
        guard flow.foundBills == nil else { return }
        let found = SpendingHistory.findBills(SpendingHistory.items(in: context), existingNames: bills.map(\.name))
        flow.foundBills = found
        flow.keptBills = Set(found.filter { !$0.isSubscription }.map(\.id))
    }

    private func track() {
        let kept = found.filter { flow.keptBills.contains($0.id) }
        PlanSetup.track(kept, in: context)
        // They're bills now (listed below); don't offer them again on coming back.
        flow.foundBills = found.filter { !flow.keptBills.contains($0.id) }
        flow.keptBills = []
        flow.next()
    }
}
