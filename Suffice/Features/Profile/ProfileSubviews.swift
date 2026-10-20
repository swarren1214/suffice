import CloudKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Profile › Connected accounts: banks connected through Plaid (sync, sign in again,
/// disconnect), then every account.
struct AccountsListView: View {
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \LinkedBank.createdAt) private var banks: [LinkedBank]
    @Query private var entries: [LedgerEntry]
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.currentMember) private var currentMember = ""
    @State private var editing: Account?
    @State private var showsConnect = false
    @State private var working: UUID?
    @State private var problem: String?
    @State private var disconnecting: LinkedBank?
    /// Syncing and signing in to a bank again need Suffice Plus or Hearth+.
    @State private var showsPaywall = false
    @State private var purchases = HearthPurchases.shared

    var body: some View {
        let records = entries.map(\.record)
        List {
            if !banks.isEmpty {
                Section {
                    ForEach(banks) { bank in
                        HStack(spacing: 12) {
                            InstitutionLogo(name: bank.institution, colorHex: 0x0E3E8C, size: 34, domain: bank.institutionDomain)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(bank.institution)
                                Text(status(of: bank))
                                    .font(.footnote)
                                    .foregroundStyle(bank.needsReconnect ? Brand.expenseInk : Color.secondary)
                            }
                            Spacer()
                            if working == bank.id {
                                ProgressView()
                            } else if bank.needsReconnect {
                                Button("Sign In") { run(bank) { try await BankSync.reconnect(bank, memberID: memberID, in: context) } }
                                    .buttonStyle(.glass)
                            } else {
                                Button("Sync", systemImage: "arrow.clockwise") { run(bank) { try await BankSync.sync(bank, memberID: memberID, in: context) } }
                                    .labelStyle(.iconOnly)
                            }
                        }
                        .swipeActions {
                            Button("Disconnect", role: .destructive) { disconnecting = bank }
                        }
                        .contextMenu {
                            Button("Disconnect", menuIcon: "xmark.circle", role: .destructive) { disconnecting = bank }
                        }
                    }
                } header: {
                    Text("Banks")
                } footer: {
                    if purchases.isUnlocked {
                        Text("Banks sync when Suffice opens (at most hourly) and when you pull down on Overview. Transactions are kept in your iCloud, not on a server.")
                    } else {
                        Text("Everything these banks brought in stays. Syncing new transactions comes with Suffice Plus or Hearth+.")
                    }
                }
            }
            Section {
                ForEach(accounts) { account in
                    Button { editing = account } label: {
                        HStack(spacing: 12) {
                            InstitutionLogo(name: account.institution.isEmpty ? account.name : account.institution, colorHex: account.colorHex, isCard: account.kind == .credit, size: 34, domain: account.institutionDomain)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.displayName).foregroundStyle(Color.primary)
                                Text("\(account.kind.name) · \(account.source.label)\(account.includeInBudget ? "" : " · Hidden")")
                                    .font(.footnote)
                                    .foregroundStyle(Color.secondary)
                            }
                            Spacer()
                            Text(Money.text(BudgetMath.balance(of: account.record, entries: records)))
                                .foregroundStyle(Color.secondary)
                                .monospacedDigit()
                        }
                    }
                    // Plain text, not the app's green tint that list buttons get.
                    .tint(.primary)
                }
                Button("Add Account", systemImage: "plus") { showsConnect = true }
            }
        }
        .navigationTitle("Connected accounts")
        // Pull down to fetch the latest from iCloud.
        .refreshable { await HouseholdSync.shared.syncNow() }
        .alert("Couldn't sync", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
        .alert("Disconnect \(disconnecting?.institution ?? "this bank")?", isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) {
                guard let bank = disconnecting else { return }
                run(bank) { try await BankSync.disconnect(bank, in: context) }
            }
        } message: {
            Text("Its accounts stay as manual accounts with their transactions; new ones stop arriving.")
        }
        .sheet(item: $editing) { account in
            AccountEditor(account: account)
        }
        .sheet(isPresented: $showsConnect) {
            ConnectView(step: nil) { showsConnect = false }
        }
        .hearthPaywall(isPresented: $showsPaywall, feature: BankSync.paywallFeature)
    }
}

extension AccountsListView {
    private var memberID: UUID? { UUID(uuidString: currentMember) }

    private func status(of bank: LinkedBank) -> String {
        if bank.needsReconnect { return "Needs you to sign in again" }
        guard let synced = bank.lastSynced else { return "Not synced yet" }
        return "Synced \(synced.formatted(.relative(presentation: .named)))"
    }

    private func run(_ bank: LinkedBank, _ work: @escaping () async throws -> Void) {
        working = bank.id
        Task {
            defer { working = nil }
            do {
                try await work()
            } catch BankSyncError.cancelled {
            } catch BankSyncError.needsPlan {
                showsPaywall = true
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// Profile › About Suffice: version, where the data lives, export, credits.
struct AboutView: View {
    @Environment(\.modelContext) private var context
    @State private var csv = ""

    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: AppConfig.version)
                LabeledContent("Data", value: AppConfig.cloudSyncEnabled ? "Your iCloud" : "This iPhone")
                ShareLink(item: CSVExport(text: csv), preview: SharePreview("Suffice transactions")) {
                    Label("Export Transactions as CSV", systemImage: "square.and.arrow.up")
                }
                NavigationLink {
                    LogoCheckView()
                } label: {
                    Label("Check Logos", systemImage: "photo.badge.checkmark")
                }
            } footer: {
                Text("Your budget lives on your devices and in your private iCloud. Connecting a bank and signing in use Hearth’s server: bank accounts and transactions pass through it from Plaid to your devices, and it keeps the bank connection, not your budget.")
            }
            Section {
                Link(destination: URL(string: "https://hearthapps.com/privacy")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                Link(destination: URL(string: "https://hearthapps.com/terms")!) {
                    Label("Terms of Use", systemImage: "doc.text")
                }
                Link(destination: URL(string: "https://hearthapps.com/support")!) {
                    Label("Help & Support", systemImage: "questionmark.circle")
                }
                Link(destination: URL(string: "mailto:support@hearthapps.com")!) {
                    Label("Email support@hearthapps.com", systemImage: "envelope")
                }
            }
            Section {
                Text("Suffice is part of Hearth, a family of apps with BigTable, Sated, Caloma and Hearken: simple tools for running a home, with your data kept in your own iCloud.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About Suffice")
        .onAppear { csv = Ledger.csv(in: context) }
    }
}

/// The transactions as a .csv file for the share sheet.
nonisolated struct CSVExport: Transferable {
    var text: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { export in
            Data(export.text.utf8)
        }
        .suggestedFileName("Suffice Transactions.csv")
    }
}
