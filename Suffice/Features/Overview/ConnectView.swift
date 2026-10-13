import SwiftUI

/// "Let us do the heavy lifting…": step 2 of onboarding, and Overview › Accounts › Add.
///
/// Bank sync (Plaid) and Apple Wallet (FinanceKit) aren't wired up yet: Plaid needs its small
/// relay deployed, and FinanceKit needs Apple to grant the entitlement. Until then, both buttons
/// say so plainly and offer to add the account by hand, which works today.
struct ConnectView: View {
    /// The step dots during onboarding; nil when opened from Overview.
    var step: (number: Int, of: Int)?
    var onFinish: () -> Void

    @State private var notice: Notice?
    @State private var showsManual = false

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
                OnboardingPrimaryButton(title: "Connect a Bank", systemImage: "building.columns") { notice = .bank }
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
        .sheet(isPresented: $showsManual) {
            AccountEditor(account: nil) { onFinish() }
        }
    }
}

#Preview {
    ConnectView(step: (2, 3)) {}
        .previewEnvironment()
}
