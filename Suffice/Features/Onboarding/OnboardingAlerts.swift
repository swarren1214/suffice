import SwiftData
import SwiftUI

/// Step 6, Stay on track: which reminders to turn on (Profile › Reminders later), and the
/// Face ID lock. Turn On Reminders asks for notification permission.
struct OnboardingAlerts: View {
    @Environment(OnboardingFlow.self) private var flow
    @Environment(\.modelContext) private var context
    @Environment(AppLock.self) private var lock
    @Query(sort: \Bill.createdAt) private var bills: [Bill]
    @AppStorage(SettingsKey.remindBills) private var remindBills = false
    @AppStorage(SettingsKey.remindBudgets) private var remindBudgets = false
    @AppStorage(SettingsKey.remindWeekly) private var remindWeekly = false
    @AppStorage(SettingsKey.faceIDLock) private var faceIDLock = false
    @State private var billsOn = true
    @State private var budgets = true
    @State private var weekly = false
    @State private var faceID = true
    @State private var isWorking = false

    private var anyReminder: Bool { billsOn || budgets || weekly }
    /// The bill in the sample notification: the next one that isn't on autopay.
    private var sample: Bill? {
        bills.filter { $0.isActive && !$0.isAutopay }
            .min { (BudgetMath.nextDue(of: $0.record) ?? .distantFuture) < (BudgetMath.nextDue(of: $1.record) ?? .distantFuture) }
    }

    var body: some View {
        OnboardingStep(
            title: "Stay on track",
            subtitle: "A few quiet nudges, so nothing sneaks up on you. Change them anytime in Profile."
        ) {
            notificationPreview
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            OnboardingCard {
                toggleRow("calendar.badge.clock", Color(hex: 0x2563C9), "Bills coming due", "The morning before, unless it’s on autopay", $billsOn)
                OnboardingDivider(inset: 62)
                toggleRow("chart.pie.fill", Color(hex: 0xC25E00), "Budgets running low", "When a budget passes 80%, or goes over", $budgets)
                OnboardingDivider(inset: 62)
                toggleRow("calendar", Color(hex: 0x5B3FD9), "Sunday check-in", "What you spent this week, and what’s left", $weekly)
                if lock.canLock() {
                    OnboardingDivider(inset: 62)
                    toggleRow(lock.biometryName == "Touch ID" ? "touchid" : "faceid", Color(hex: 0x3D3D3D), "Lock with \(lock.biometryName)", "Hide balances until it’s you", $faceID)
                }
            }
        } controls: {
            Button(anyReminder ? "Turn On Reminders" : "Continue", action: turnOn)
                .buttonStyle(.onboarding())
                .disabled(isWorking)
            Button("Not Now") {
                remindBills = false
                remindBudgets = false
                remindWeekly = false
                Task { await Reminders.refresh(context) }
                flow.next()
            }
            .buttonStyle(.onboarding(.plain))
        }
        .onAppear {
            faceID = lock.canLock()
        }
    }

    private var notificationPreview: some View {
        let name = sample?.name ?? "Rent"
        let amount = sample?.amountLabel ?? Money.text(185_000)
        return HStack(alignment: .top, spacing: 10) {
            Image("SufficeMark")
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("\(name) is due tomorrow")
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text("9:00 AM")
                        .font(.system(size: 12))
                        .foregroundStyle(OnboardingStyle.secondaryText)
                }
                Text("\(amount). Tap to mark it paid once it’s done.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: 0xD1D1D6))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 320)
        .background(.white.opacity(0.12), in: .rect(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Example reminder: \(name) is due tomorrow")
    }

    private func toggleRow(_ symbol: String, _ tint: Color, _ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(tint, in: .rect(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(OnboardingStyle.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(Brand.greenBright)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func turnOn() {
        isWorking = true
        if faceID, lock.canLock() { faceIDLock = true }
        remindBills = billsOn
        remindBudgets = budgets
        remindWeekly = weekly
        if budgets { Reminders.markBudgetsSeen(context) }
        Task {
            if anyReminder { await Reminders.requestPermission() }
            await Reminders.refresh(context)
            isWorking = false
            flow.next()
        }
    }
}
