import CloudKit
import SwiftData
import SwiftUI

/// All set: what Suffice is keeping an eye on now, then Show Me Around (the tour) or Jump
/// Right In.
struct OnboardingReady: View {
    /// Finishes onboarding; true to start the tour.
    var finish: (_ tour: Bool) -> Void

    @Environment(OnboardingFlow.self) private var flow
    @Environment(AppRouter.self) private var router
    @Query private var categories: [BudgetCategory]
    @Query private var bills: [Bill]
    @Query private var accounts: [Account]
    @Query(sort: \LinkedBank.createdAt) private var banks: [LinkedBank]
    @AppStorage(SettingsKey.remindBills) private var remindBills = false
    @State private var household = HouseholdSync.shared
    @State private var appeared = false

    init(finish: @escaping (_ tour: Bool) -> Void) {
        self.finish = finish
    }

    private var monthName: String { router.month.start.formatted(.dateTime.month(.wide)) }

    private var planned: Int {
        BudgetMath.statuses(categories.map(\.record), entries: [], in: router.month).reduce(0) { $0 + $1.limitCents }
    }

    private var rows: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if planned > 0 { rows.append(("Budgets for \(monthName)", Money.whole(planned))) }
        let active = bills.filter(\.isActive)
        if !active.isEmpty {
            let reminded = active.filter { !$0.isAutopay }.count
            rows.append(remindBills && reminded > 0 ? ("Bills with reminders", "\(reminded)") : ("Bills", "\(active.count)"))
        }
        if !accounts.isEmpty {
            let value: String
            if banks.count == 1, let bank = banks.first?.institution, !bank.isEmpty {
                value = "\(bank) · \(accounts.count)"
            } else {
                value = "\(accounts.count)"
            }
            rows.append(("Accounts", value))
        }
        if let partner = flow.partner {
            let joined = household.participants.contains { $0.acceptanceStatus == .accepted }
            if joined {
                rows.append(("Shared with", partner))
            } else if !household.participants.isEmpty {
                rows.append(("Shared with", "\(partner) (invited)"))
            }
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 24)
            ZStack {
                Circle().stroke(OnboardingStyle.accent.opacity(0.18), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: appeared ? 1 : 0)
                    .stroke(OnboardingStyle.accent, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "checkmark")
                    .font(.system(size: 60, weight: .bold))
                    .foregroundStyle(.white)
                    .scaleEffect(appeared ? 1 : 0.4)
                    .opacity(appeared ? 1 : 0)
            }
            .frame(width: 150, height: 150)
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(flow.myName.isEmpty ? "You’re all set" : "You’re all set, \(flow.myName.trimmingCharacters(in: .whitespaces))")
                    .font(.system(size: 34, weight: .heavy))
                    .tracking(-0.5)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(planned > 0 ? "\(monthName) is planned. Here’s what Suffice is keeping an eye on." : "Plan the month whenever you’re ready, from the Budget tab.")
                    .font(.system(size: 16))
                    .foregroundStyle(OnboardingStyle.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !rows.isEmpty {
                OnboardingCard {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { OnboardingDivider(inset: 16) }
                        HStack {
                            Text(row.label).font(.system(size: 15))
                            Spacer()
                            Text(row.value).font(.system(size: 15, weight: .bold))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            Spacer(minLength: 16)

            VStack(spacing: 10) {
                Button { finish(true) } label: {
                    Label("Show Me Around", systemImage: "hand.point.up.left.fill")
                }
                .buttonStyle(.onboarding(.white))
                Button("Jump Right In") { finish(false) }
                    .buttonStyle(.onboarding(.plain))
            }
            .padding(.bottom, 12)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .frame(maxWidth: OnboardingStyle.columnWidth)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.4),
                    .init(color: Color(hex: 0x06401A), location: 0.78),
                    .init(color: Color(hex: 0x0B6B2A), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .task {
            withAnimation(.spring(duration: 0.9, bounce: 0.3).delay(0.15)) { appeared = true }
            await household.refreshShare()
        }
        .sensoryFeedback(.success, trigger: appeared)
    }
}

/// After joining someone's household: which of its people is you, so your transactions get
/// your badge. Shown once, from the tabs, as soon as the household's people have arrived.
struct WhoAreYouSheet: View {
    var members: [Member]
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.currentMember) private var currentMember = ""
    @State private var addingMe = false

    init(members: [Member]) {
        self.members = members
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(members) { member in
                        Button {
                            currentMember = member.id.uuidString
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                PersonAvatar(member: member, size: 40)
                                Text(member.name).foregroundStyle(Color.primary)
                            }
                        }
                    }
                    Button("I’m Not Listed", systemImage: "person.badge.plus") { addingMe = true }
                } footer: {
                    Text("The transactions you add get your badge. Change it anytime in Profile › Household.")
                }
            }
            .navigationTitle("Which one is you?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                }
            }
            .sheet(isPresented: $addingMe, onDismiss: { if !currentMember.isEmpty { dismiss() } }) {
                MemberEditor(member: nil, isMe: true)
            }
        }
        .presentationDetents([.medium, .large])
    }
}
