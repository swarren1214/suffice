import SwiftData
import SwiftUI

/// "Let us do the heavy lifting…": step 2 of onboarding, and Overview › Accounts › Add.
///
/// Connect a Bank runs Plaid through the Lifestyle API (BankSync): Sign in with Apple if needed,
/// Plaid Link, then the bank's accounts and transactions arrive. Apple Wallet (FinanceKit) waits
/// on Apple granting the entitlement, so that button says so and offers adding a card by hand.
struct ConnectView: View {
    /// The step dots during onboarding; nil when opened from Overview.
    var step: (number: Int, of: Int)?
    var onFinish: () -> Void

    @State private var notice: Notice?
    @State private var showsManual = false
    @State private var isConnecting = false
    @State private var connectError: String?
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.currentMember) private var currentMember = ""

    private enum Notice: String, Identifiable {
        case bank, wallet
        var id: String { rawValue }

        var title: String {
            self == .bank ? "Bank sync is almost here" : "Apple Wallet needs Apple's OK"
        }

        var message: String {
            switch self {
            case .bank: "Connecting a bank needs Suffice's small Plaid relay, which isn't set up yet. You can add the account by hand now and log transactions to it."
            case .wallet: "Reading Apple Card and Apple Cash uses FinanceKit, which Apple has to approve for Suffice first. You can add the card by hand now."
            }
        }
    }

    init(step: (number: Int, of: Int)?, onFinish: @escaping () -> Void) {
        self.step = step
        self.onFinish = onFinish
    }

    var body: some View {
        OnboardingPage(
            title: "Connect your accounts",
            subtitle: "Let Suffice do the heavy lifting. Transactions land in your iCloud, never on a server.",
            step: step
        ) { isShort in
            OnboardingSymbolIcon(symbol: "building.columns.fill", size: isShort ? 64 : 92)
        } content: { _ in
            VStack(alignment: .leading, spacing: 18) {
                OnboardingFeatureRow(symbol: "building.columns", title: "Your bank", detail: "Checking, savings and cards connect through Plaid.")
                OnboardingFeatureRow(symbol: "creditcard.fill", title: "Apple Card and Apple Cash", detail: "Read straight from Apple Wallet. They never leave your iPhone.")
                OnboardingFeatureRow(symbol: "square.and.pencil", title: "Or keep it by hand", detail: "Add an account and its balance, and log transactions yourself.")
            }
        } controls: { _ in
            VStack(spacing: 10) {
                OnboardingPrimaryButton(title: isConnecting ? "Connecting…" : "Connect a Bank", systemImage: "building.columns") { connectBank() }
                    .disabled(isConnecting)
                OnboardingSecondaryButton(title: "Add from Apple Wallet", systemImage: "creditcard") { notice = .wallet }
                Button(step == nil ? "Not now" : "Skip for now", action: onFinish)
                    .frame(minHeight: 44)
            }
        }
        .alert(
            notice?.title ?? "",
            isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }),
            presenting: notice
        ) { _ in
            Button("Add by Hand") { showsManual = true }
            Button("Not Now", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
        .alert("Couldn't connect", isPresented: Binding(get: { connectError != nil }, set: { if !$0 { connectError = nil } })) {
            Button("Add by Hand") { showsManual = true }
            Button("OK", role: .cancel) {}
        } message: {
            Text(connectError ?? "")
        }
        .sheet(isPresented: $showsManual) {
            AccountEditor(account: nil) { onFinish() }
        }
    }
}

extension ConnectView {
    private func connectBank() {
        isConnecting = true
        Task {
            defer { isConnecting = false }
            do {
                try await BankSync.connect(memberID: UUID(uuidString: currentMember), in: context)
                onFinish()
            } catch BankSyncError.cancelled {
                // They closed Apple's sheet or Plaid; nothing to say.
            } catch {
                connectError = error.localizedDescription
            }
        }
    }
}

#Preview {
    ConnectView(step: (2, 3)) {}
        .previewEnvironment()
}
