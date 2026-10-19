import SwiftData
import SwiftUI

/// Suffice's section on a person's page in Household (`\.hearthPersonExtras`, set on the root):
/// what the budget knows about them, when they're one of its people.
struct SufficePersonExtras: View {
    let person: HearthMember
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.currentMember) private var currentMember = ""

    var body: some View {
        if let member = SufficeHearthHousehold.member(for: person, among: members) {
            let month = monthSpending(of: member.id)
            Section {
                LabeledContent("Spent This Month", value: Money.whole(month.cents))
                LabeledContent("Transactions This Month", value: "\(month.count)")
                LabeledContent("Badge") {
                    HStack(spacing: 8) {
                        Text(member.color.name)
                        MemberBadge(member: member, size: 26)
                    }
                }
                if member.id.uuidString == currentMember {
                    Label {
                        Text("Uses this \(DeviceName.current)")
                    } icon: {
                        Image(systemName: "iphone")
                    }
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Suffice")
            } footer: {
                Text("Their badge marks the transactions they make. The person using this \(DeviceName.current) is filled in on new ones.")
            }
        } else if person.role == .kid {
            Section("Suffice") {
                Text("Kids aren’t part of the budget.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Their expenses this month, in total and how many.
    private func monthSpending(of id: UUID) -> (cents: Int, count: Int) {
        let span = MonthSpan(containing: .now)
        let memberID: UUID? = id
        let start = span.start
        let end = span.end
        let descriptor = FetchDescriptor<LedgerEntry>(predicate: #Predicate { entry in
            entry.memberID == memberID && entry.date >= start && entry.date < end
        })
        let entries = ((try? context.fetch(descriptor)) ?? []).filter { $0.kind == .expense }
        return (entries.reduce(0) { $0 + $1.amountCents }, entries.count)
    }
}
