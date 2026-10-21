import AuthenticationServices
import SwiftData
import SwiftUI

/// Profile › Receipts from Email: what it does, the mailboxes (Gmail and Outlook, read-only),
/// and the choices (attach sure matches on their own, read bills too, how far back to look).
struct EmailConnectView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var accounts = MailAccounts.shared
    @State private var scanner = ReceiptScanner.shared
    @AppStorage(EmailSettingsKey.attachWhenSure) private var attachWhenSure = true
    @AppStorage(EmailSettingsKey.findBills) private var findBills = true
    @AppStorage(EmailSettingsKey.lookBackDays) private var lookBackDays = 90
    @State private var connecting: MailProvider?
    @State private var disconnecting: MailProvider?
    @State private var problem: String?

    var body: some View {
        GreenScreen("Receipts from Email") {
            GlassCard {
                Text("Every emailed receipt, on the transaction it belongs to")
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    point("envelope", "Only receipts, orders and bills", "Suffice searches for those and never opens the rest of your mail.")
                    point("iphone", "Read on this \(DeviceName.current)", "Apple’s on-device model finds the store, total and date. No server reads your email.")
                    point("checkmark", "Matched to your transactions", "The receipt lands on the purchase it paid for, like a scanned one.")
                }
            }

            SectionTitle("Your email")
            VStack(spacing: 0) {
                ForEach(MailProvider.allCases) { provider in
                    providerRow(provider)
                    Divider().padding(.leading, 68)
                }
                otherEmailRow
            }
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))

            if let problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(Brand.expenseInk)
                    .padding(.horizontal, 6)
            }

            SectionTitle("What Suffice does")
            VStack(spacing: 0) {
                toggleRow("Attach when it’s sure", "Same amount, store and day. Close calls wait for you.", isOn: $attachWhenSure)
                Divider().padding(.leading, 16)
                toggleRow("Find bills too", "Reads a bill’s amount and due date into Bills", isOn: $findBills)
                Divider().padding(.leading, 16)
                HStack {
                    Text("Look back")
                    Spacer()
                    ChoicePopoverButton(sections: [[30, 90, 180].map { days in
                        ChoiceItem(id: "\(days)", title: "\(days) days", isSelected: days == lookBackDays) { lookBackDays = days }
                    }]) {
                        HStack(spacing: 4) {
                            Text("\(lookBackDays) days")
                            Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
            }
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))

            if accounts.isConnected {
                NavigationLink {
                    EmailReceiptsView()
                } label: {
                    Text("See What It Found")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 54)
                        .background(Brand.green, in: .capsule)
                }
                .buttonStyle(.plain)
            }

            Text("Suffice asks your email only for messages that look like receipts, orders and bills, reads them on this \(DeviceName.current), and keeps just the receipt. It never sends, changes or deletes mail. Disconnect any time; receipts already attached stay.")
                .font(.footnote)
                .foregroundStyle(Brand.secondaryText)
                .padding(.horizontal, 6)
        }
        .alert(
            "Disconnect \(disconnecting?.name ?? "email")?",
            isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
            presenting: disconnecting
        ) { provider in
            Button("Disconnect", role: .destructive) {
                accounts.disconnect(provider)
                if !accounts.isConnected { scanner.forgetFound(in: context) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Suffice stops reading it. Receipts already attached to transactions stay.")
        }
    }

    // MARK: Rows

    private func point(_ symbol: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.footnote.weight(.bold))
                .foregroundStyle(Brand.green)
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.6), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func providerRow(_ provider: MailProvider) -> some View {
        let address = accounts.connected[provider]
        return HStack(spacing: 12) {
            Text(String(provider.name.prefix(1)))
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(provider == .gmail ? Color(hex: 0xC8102E) : Color(hex: 0x0E5FA8), in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                Text(address.map { "Connected · \($0)" } ?? (provider.isConfigured ? "Read-only access to receipts" : "Not set up in this build yet"))
                    .font(.caption.weight(address == nil ? .regular : .semibold))
                    .foregroundStyle(address == nil ? Brand.secondaryText : CategoryColor.green.ink)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if connecting == provider {
                ProgressView()
            } else if address != nil {
                Button("Disconnect") { disconnecting = provider }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(Color(.systemGray5), in: .capsule)
                    .buttonStyle(.plain)
            } else {
                TintedCapsuleButton(title: "Connect", systemImage: nil) {
                    Task { await connect(provider) }
                }
                .disabled(!provider.isConfigured || connecting != nil)
                .opacity(provider.isConfigured ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 68)
    }

    /// iCloud Mail and others have no way in: share the receipt or bill instead.
    private var otherEmailRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("@")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color(hex: 0x5B5B60), in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("iCloud and other email")
                Text("Share a bill or receipt PDF to Suffice from Mail (Share › Suffice), and Suffice reads it.")
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleRow(_ title: String, _ hint: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 64)
    }

    // MARK: Connecting

    /// Signs in through the system's web sheet (Suffice never sees the password), then reads
    /// the mailbox for the first time.
    private func connect(_ provider: MailProvider) async {
        problem = nil
        connecting = provider
        defer { connecting = nil }
        do {
            let request = try accounts.request(for: provider)
            let callback = try await webAuthenticationSession.authenticate(
                using: request.url,
                callbackURLScheme: provider.callbackScheme,
                preferredBrowserSession: .ephemeral
            )
            try await accounts.finish(request, callback: callback)
            Task { await scanner.scan(in: context) }
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // Closed the sheet: nothing to say.
        } catch {
            problem = error.localizedDescription
        }
    }
}

// MARK: - What it found

/// Email Receipts: how many were found, the close matches to check (Attach or Not This One),
/// the ones attached on their own, and the ones still waiting for their transaction. Pull down
/// to read the mailboxes again.
struct EmailReceiptsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \FoundReceipt.paidOn, order: .reverse) private var found: [FoundReceipt]
    @Query private var entries: [LedgerEntry]
    @State private var scanner = ReceiptScanner.shared
    @State private var accounts = MailAccounts.shared
    @State private var opened: LedgerEntry?
    @State private var showsAllAttached = false

    init() {
        let start = Calendar.current.date(byAdding: .day, value: -200, to: .now) ?? .distantPast
        _entries = Query(filter: #Predicate<LedgerEntry> { $0.date >= start })
    }

    var body: some View {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let checks = found.filter { $0.status == .check }
        let attached = found.filter { $0.status == .attached }
        let waiting = found.filter { $0.status == .waiting }

        GreenScreen("Email Receipts") {
            GlassCard {
                GlassCardHeader(title: accounts.isConnected ? "Found in \(accounts.connected.keys.map(\.name).sorted().joined(separator: " and "))" : "Found in your email", note: scanNote)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    GlassFigure(text: "\(checks.count + attached.count + waiting.count)")
                        .fixedSize()
                    Text("receipts")
                        .font(.headline)
                        .foregroundStyle(Brand.greenInk)
                }
                HStack(spacing: 8) {
                    GlassTile(title: "Attached", value: "\(attached.count)")
                    GlassTile(title: "To check", value: "\(checks.count)")
                    GlassTile(title: "Waiting", value: "\(waiting.count)")
                }
            }

            if scanner.isScanning {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(scanner.progress ?? "Checking your email…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
            } else if let problem = scanner.problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(Brand.expenseInk)
                    .padding(.horizontal, 6)
            }

            if !checks.isEmpty {
                SectionTitle("Check these")
                ForEach(checks) { receipt in
                    CheckCard(receipt: receipt, entry: receipt.entryID.flatMap { byID[$0] }) {
                        if let entry = receipt.entryID.flatMap({ byID[$0] }) {
                            withAnimation(.snappy) {
                                scanner.attach(receipt, to: entry)
                                try? context.save()
                            }
                        }
                    } reject: {
                        withAnimation(.snappy) { scanner.reject(receipt, in: context) }
                    }
                }
            }

            SectionTitle("Attached on their own")
            if attached.isEmpty {
                EmptyCard(systemName: "envelope.open", title: "Nothing attached yet", message: accounts.isConnected ? "Pull down to check your email. Receipts land on their transactions as the bank sends them." : "Connect your email to bring in receipts.")
            } else {
                let shown = showsAllAttached ? attached : Array(attached.prefix(5))
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, receipt in
                        Button {
                            opened = receipt.entryID.flatMap { byID[$0] }
                        } label: {
                            FoundRow(receipt: receipt, detail: attachedDetail(receipt, entry: receipt.entryID.flatMap { byID[$0] }), showsChevron: true)
                        }
                        .buttonStyle(.plain)
                        if index < shown.count - 1 { Divider().padding(.leading, 64) }
                    }
                    if attached.count > 5 {
                        Divider()
                        Button(showsAllAttached ? "Show Fewer" : "See All \(attached.count)") {
                            withAnimation(.snappy) { showsAllAttached.toggle() }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 50)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
            }

            if !waiting.isEmpty {
                SectionTitle("No transaction yet")
                CardList(items: waiting, inset: 64) { receipt in
                    FoundRow(receipt: receipt, detail: "\(receipt.paidOn.formatted(.dateTime.month(.abbreviated).day())) · waiting for the bank", showsChevron: false)
                }
            }

            Text("Receipts wait here \(ReceiptScanner.waitDays) days for their transaction. Bills Suffice finds go to Bills.")
                .font(.footnote)
                .foregroundStyle(Brand.secondaryText)
                .padding(.horizontal, 6)
        }
        .refreshable { await scanner.scan(in: context) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Check Now", systemImage: "arrow.clockwise") {
                    Task { await scanner.scan(in: context) }
                }
                .disabled(scanner.isScanning || !accounts.isConnected)
            }
        }
        .sheet(item: $opened) { entry in
            TransactionSheet(entry: entry)
        }
        .task { scanner.rematch(in: context) }
    }

    private var scanNote: String? {
        guard let last = scanner.lastScan else { return "Last \(scanner.lookBackDays) days" }
        return "Checked \(last.formatted(.relative(presentation: .named)))"
    }

    private func attachedDetail(_ receipt: FoundReceipt, entry: LedgerEntry?) -> String {
        var parts = [receipt.paidOn.formatted(.dateTime.month(.abbreviated).day())]
        if let entry, entry.taxTag.isTagged { parts.append(entry.taxTag.shortName) }
        if entry?.isSplit == true { parts.append("split") }
        return parts.joined(separator: " · ")
    }
}

/// One found receipt: the store's initial, name, a detail line and the amount.
private struct FoundRow: View {
    let receipt: FoundReceipt
    var detail: String
    var showsChevron: Bool

    var body: some View {
        HStack(spacing: 12) {
            MerchantAvatar(name: receipt.merchant.isEmpty ? receipt.sender : receipt.merchant, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(receipt.merchant.isEmpty ? receipt.sender : receipt.merchant)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(Money.text(receipt.totalCents))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 62)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// A close match: the receipt next to the transaction, why it needs a look, and Attach or
/// Not This One.
private struct CheckCard: View {
    let receipt: FoundReceipt
    let entry: LedgerEntry?
    var attach: () -> Void
    var reject: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    MerchantAvatar(name: receipt.merchant.isEmpty ? receipt.sender : receipt.merchant, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(receipt.merchant.isEmpty ? receipt.sender : receipt.merchant)
                            .font(.headline)
                        Text("“\(receipt.subject)” · \(receipt.receivedAt.formatted(.dateTime.month(.abbreviated).day()))")
                            .font(.caption)
                            .foregroundStyle(Brand.secondaryText)
                            .lineLimit(2)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { sides }
                    VStack(spacing: 8) { sides }
                }
                if !receipt.reason.isEmpty {
                    Text(receipt.reason)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(CategoryColor.yellow.ink)
                }
                HStack(spacing: 8) {
                    Button(action: attach) {
                        Text("Attach")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 36)
                            .background(Brand.green, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .disabled(entry == nil)
                    Button(action: reject) {
                        Text("Not This One")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .background(Color(.systemGray5), in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var sides: some View {
        side("Receipt", Money.text(receipt.totalCents), receipt.paidOn.formatted(.dateTime.month(.abbreviated).day()))
        side("Transaction", entry.map { Money.text($0.amountCents) } ?? "—", entry.map { "\($0.date.formatted(.dateTime.month(.abbreviated).day())) · \($0.payee)" } ?? "")
    }

    private func side(_ title: String, _ amount: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(amount).font(.headline).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.systemGray6), in: .rect(cornerRadius: 14))
    }
}

#Preview {
    NavigationStack { EmailConnectView() }
        .previewEnvironment()
}
