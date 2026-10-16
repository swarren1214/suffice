import SwiftData
import SwiftUI

/// Step 3, Bring in your accounts: banks through Plaid, Apple Card and Apple Cash, or an
/// account kept by hand. What comes in feeds the suggested plan and found bills next.
struct OnboardingConnect: View {
    @Environment(OnboardingFlow.self) private var flow
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \LinkedBank.createdAt) private var banks: [LinkedBank]
    @Query(filter: #Predicate<LedgerEntry> { $0.externalID != nil }) private var bankEntries: [LedgerEntry]
    @AppStorage(SettingsKey.currentMember) private var currentMember = ""
    @State private var isConnecting = false
    @State private var connectError: String?
    @State private var walletNotice = false
    @State private var showsManual = false

    private var manualAccounts: [Account] { accounts.filter { $0.source == .manual } }

    var body: some View {
        OnboardingStep(
            title: "Bring in your accounts",
            subtitle: "Transactions come in on their own, so the plan we suggest next is based on how you really spend."
        ) {
            if !banks.isEmpty || !manualAccounts.isEmpty || isConnecting {
                connected
            }
            OnboardingCard {
                option("building.columns.fill", Color(hex: 0x2563C9),
                       banks.isEmpty ? "Connect a Bank" : "Connect Another Bank",
                       "Checking, savings and cards, through Plaid") { connectBank() }
                    .disabled(isConnecting)
                OnboardingDivider(inset: 66)
                option("creditcard.fill", .black, "Apple Card & Apple Cash", "Read from Wallet, never leaves your \(DeviceName.current)") { walletNotice = true }
                OnboardingDivider(inset: 66)
                option("square.and.pencil", Color(hex: 0x3D3D3D), "Add One by Hand", "Cash, or a bank you’d rather not link") { showsManual = true }
            }
        } controls: {
            Button(accounts.isEmpty ? "Skip for Now" : "Continue", action: flow.next)
                .buttonStyle(.onboarding(accounts.isEmpty ? .secondary : .primary))
                .disabled(isConnecting)
            Text("Your bank sign-in goes to Plaid, never to Suffice. Transactions are kept only in your iCloud.")
                .font(.system(size: 12))
                .foregroundStyle(OnboardingStyle.tertiaryText)
                .multilineTextAlignment(.center)
        }
        .alert("Apple Wallet needs Apple’s OK", isPresented: $walletNotice) {
            Button("Add by Hand") { showsManual = true }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Reading Apple Card and Apple Cash uses FinanceKit, which Apple has to approve for Suffice first. You can add the card by hand now.")
        }
        .alert("Couldn’t connect", isPresented: Binding(get: { connectError != nil }, set: { if !$0 { connectError = nil } })) {
            Button("Add by Hand") { showsManual = true }
            Button("OK", role: .cancel) {}
        } message: {
            Text(connectError ?? "")
        }
        .sheet(isPresented: $showsManual) {
            AccountEditor(account: nil)
        }
    }

    // MARK: Connected

    private var connected: some View {
        OnboardingCard {
            ForEach(Array(banks.enumerated()), id: \.element.id) { index, bank in
                if index > 0 { OnboardingDivider(inset: 70) }
                accountRow(
                    name: bank.institution,
                    domain: bank.institutionDomain,
                    detail: accounts.filter { $0.plaidItemID == bank.itemID }.map(\.name).formatted(.list(type: .and)),
                    badge: "Connected"
                )
            }
            ForEach(Array(manualAccounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 || !banks.isEmpty { OnboardingDivider(inset: 70) }
                accountRow(name: account.displayName, domain: nil, detail: account.kind.name, badge: "Added")
            }
            if isConnecting {
                if !banks.isEmpty || !manualAccounts.isEmpty { OnboardingDivider(inset: 0) }
                HStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Bringing in your transactions…")
                        .font(.system(size: 14))
                        .foregroundStyle(OnboardingStyle.secondaryText)
                    Spacer()
                }
                .padding(16)
            } else if !bankEntries.isEmpty {
                OnboardingDivider(inset: 0)
                HStack {
                    Text("\(bankEntries.count) transactions · last \(historyDays) days")
                        .foregroundStyle(OnboardingStyle.tertiaryText)
                    Spacer()
                    Text("\(Money.whole(cash)) cash")
                        .fontWeight(.semibold)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private var historyDays: Int {
        guard let oldest = bankEntries.map(\.date).min() else { return 0 }
        return max(1, Calendar.current.dateComponents([.day], from: oldest, to: .now).day ?? 0)
    }

    private var cash: Int {
        BudgetMath.totalCash(accounts.map(\.record), entries: bankEntries.map(\.record))
    }

    private func accountRow(name: String, domain: String?, detail: String, badge: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(.white)
                Text(name.prefix(1).uppercased())
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color(hex: 0x0E3E8C))
                if let url = BankLogo.url(name: name, domain: domain) {
                    MerchantLogoImage(url: url, size: 42)
                }
            }
            .frame(width: 42, height: 42)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 16, weight: .semibold))
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(OnboardingStyle.tertiaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Label(badge, systemImage: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(OnboardingStyle.accent)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(OnboardingStyle.accent.opacity(0.14), in: .capsule)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func option(_ symbol: String, _ tint: Color, _ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(tint, in: .rect(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(tint == .black ? 0.2 : 0)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 16, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(OnboardingStyle.tertiaryText)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(hex: 0x8E8E93))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func connectBank() {
        isConnecting = true
        Task {
            defer { isConnecting = false }
            do {
                try await BankSync.connect(memberID: UUID(uuidString: currentMember), in: context)
                // New history: work the plan and bills out again.
                flow.planRows = nil
                flow.foundBills = nil
            } catch BankSyncError.cancelled {
                // They closed Apple's sheet or Plaid.
            } catch {
                connectError = error.localizedDescription
            }
        }
    }
}
