import CloudKit
import SwiftData
import SwiftUI

/// Step 2, Budget with your partner: invites them to the household (iCloud sharing, through
/// Apple's sheet). Only shown when a partner was named.
struct OnboardingPartner: View {
    @Environment(OnboardingFlow.self) private var flow
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @State private var household = HouseholdSync.shared

    private var name: String { flow.partner ?? "your partner" }
    private var invited: Bool { !household.participants.isEmpty }
    private var canInvite: Bool { household.account == .available }
    private var noICloud: Bool { [.noAccount, .restricted, .unavailable].contains(household.account) }

    var body: some View {
        OnboardingStep(
            title: "Budget with \(name)",
            subtitle: "Invite \(name) with their Apple Account and you’ll both see and edit the same budget."
        ) {
            together
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            OnboardingCard {
                point("arrow.triangle.2.circlepath", "Every change, on both phones", "A coffee \(name) logs shows up on yours a moment later.")
                OnboardingDivider(inset: 62)
                point("building.columns.fill", "Each of you connects your own banks", "Bank sign-ins stay with whoever connected them. The transactions land in your shared budget.")
                OnboardingDivider(inset: 62)
                point("lock.fill", "Private to the two of you", "End-to-end encrypted in your iCloud. Suffice has no servers that see it.")
            }
            if invited {
                status("checkmark.circle.fill", OnboardingStyle.accent, "Invitation sent. \(name) joins by opening it on their iPhone.")
            } else if noICloud {
                status("icloud.slash", Color(hex: 0xFF9F57), "Sign in to iCloud in Settings to invite \(name). You can also invite them later from Profile › Household.")
            }
        } controls: {
            if invited {
                Button("Continue", action: flow.next)
                    .buttonStyle(.onboarding())
                Button("Manage Invitation") { Task { await household.presentSharing() } }
                    .buttonStyle(.onboarding(.plain))
            } else {
                Button {
                    Task { await household.presentSharing() }
                } label: {
                    Label("Invite \(name)", systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.onboarding())
                .disabled(!canInvite || household.isWorking)
                Button("Just Me for Now", action: flow.next)
                    .buttonStyle(.onboarding(.plain))
            }
        }
        .task {
            await household.refreshAccount()
            await household.refreshShare()
        }
    }

    /// The two of you, overlapping, over "One budget in your iCloud".
    private var together: some View {
        let me = members.first { $0.id == flow.myID }
        let partner = members.first { $0.id == flow.partnerID }
        return VStack(spacing: 14) {
            HStack(spacing: -18) {
                avatar(me.map { PersonAvatar(member: $0, size: 84) } ?? PersonAvatar(name: flow.myName, color: .green, photo: flow.myPhoto, size: 84))
                avatar(partner.map { PersonAvatar(member: $0, size: 84) } ?? PersonAvatar(name: name, color: .purple, photo: flow.partnerPhoto, size: 84))
            }
            Label("One budget in your iCloud", systemImage: "lock.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: 0xBFF0CB))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(OnboardingStyle.green.opacity(0.35), in: .capsule)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(flow.myName) and \(name), one budget in your iCloud")
    }

    private func avatar(_ view: PersonAvatar) -> some View {
        view.overlay(Circle().strokeBorder(.black, lineWidth: 4))
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OnboardingStyle.accent)
                .frame(width: 32, height: 32)
                .background(OnboardingStyle.accent.opacity(0.14), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(OnboardingStyle.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }

    private func status(_ symbol: String, _ color: Color, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 6)
    }
}
