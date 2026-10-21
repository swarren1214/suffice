import SwiftData
import SwiftUI
import UIKit

/// Profile › Reminders: the nudges onboarding's Stay on track screen turns on.
struct RemindersView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.remindBills) private var bills = false
    @AppStorage(SettingsKey.remindBudgets) private var budgets = false
    @AppStorage(SettingsKey.remindWeekly) private var weekly = false
    @State private var isDenied = false

    var body: some View {
        Form {
            if isDenied {
                Section {
                    Button("Turn On Notifications in Settings", systemImage: "bell.slash") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .tint(.primary)
                } footer: {
                    Text("Notifications are off for Suffice, so these reminders can’t appear.")
                }
            }
            Section {
                Toggle(isOn: changing($bills)) {
                    ReminderLabel(title: "Bills coming due", detail: "9 AM the day before, unless it’s on autopay or already paid")
                }
                Toggle(isOn: changing($budgets, onTurnOn: { Reminders.markBudgetsSeen(context) })) {
                    ReminderLabel(title: "Budgets running low", detail: "When a budget passes 80%, and if it goes over")
                }
                Toggle(isOn: changing($weekly)) {
                    ReminderLabel(title: "Sunday check-in", detail: "Sunday at 6 PM: what you spent this week, and what’s left")
                }
            } footer: {
                Text("Reminders are worked out on this \(DeviceName.current) from your budget. Each of you chooses your own.")
            }
        }
        .navigationTitle("Reminders")
        .task { isDenied = await Reminders.isDenied() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { isDenied = await Reminders.isDenied() } }
        }
    }

    /// A toggle binding that asks for notification permission the first time one is turned on,
    /// and reschedules after every change.
    private func changing(_ setting: Binding<Bool>, onTurnOn: (() -> Void)? = nil) -> Binding<Bool> {
        Binding {
            setting.wrappedValue
        } set: { on in
            if on { onTurnOn?() }
            setting.wrappedValue = on
            Task {
                if on {
                    await Reminders.requestPermission()
                    isDenied = await Reminders.isDenied()
                }
                await Reminders.refresh(context)
            }
        }
    }
}

private struct ReminderLabel: View {
    var title: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
