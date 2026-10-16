import CloudKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Profile › Household: the people in the budget, and sharing it with another Apple Account.
struct HouseholdView: View {
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @AppStorage(SettingsKey.currentMember) private var currentMember = ""
    @State private var editing: Member?
    @State private var showsNew = false
    @State private var household = HouseholdSync.shared
    @State private var confirmsLeave = false
    @Environment(\.modelContext) private var context
    /// Caloma's parents, offered when no one's been added yet (onboarding was skipped).
    @State private var calomaParents: [String] = []
    @AppStorage(CalomaFamily.dismissedKey) private var calomaDismissed = false

    var body: some View {
        List {
            Section {
                ForEach(members) { member in
                    Button { editing = member } label: {
                        HStack(spacing: 12) {
                            MemberBadge(member: member, size: 32)
                            Text(member.name).foregroundStyle(Color.primary)
                            Spacer()
                            if member.id.uuidString == currentMember {
                                Text("This \(DeviceName.current)").foregroundStyle(Color.secondary)
                            }
                        }
                    }
                    .tint(.primary)
                }
                Button("Add Person", systemImage: "person.badge.plus") { showsNew = true }
                // Not for someone who joined a household: its people arrive with the sync.
                if members.isEmpty, !household.isMember, !calomaDismissed, !calomaParents.isEmpty {
                    Button("Add \(Array(calomaParents.prefix(2)).formatted(.list(type: .and))) from Caloma", systemImage: "person.2.badge.plus") {
                        addCalomaParents()
                    }
                }
            } footer: {
                if household.isMember && currentMember.isEmpty {
                    Text("Tap your name and turn on This is me, so your transactions show your badge.")
                } else {
                    Text("Everyone here shows up on the transactions they make.")
                }
            }

            if AppConfig.cloudSyncEnabled {
                sharingSection
            }
        }
        .navigationTitle("Household")
        // Pull down to fetch the latest from iCloud, and who's in the household.
        .refreshable {
            await household.syncNow()
            await household.refreshShare()
        }
        .task { await household.refreshShare() }
        .onAppear { calomaParents = CalomaFamily.parentNames() }
        .alert("Leave the household?", isPresented: $confirmsLeave) {
            Button("Leave Household", role: .destructive) {
                Task { await household.leaveHousehold() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The shared budget is removed from your devices and your own budget comes back. \(household.ownerName ?? "The owner") can invite you again.")
        }
        .sheet(item: $editing) { member in
            MemberEditor(member: member)
        }
        .sheet(isPresented: $showsNew) {
            MemberEditor(member: nil)
        }
    }
}

extension HouseholdView {
    /// Adds Caloma's first two parents, in onboarding's colors. Tap your name afterwards and
    /// turn on This is me.
    private func addCalomaParents() {
        let colors: [MemberColor] = [.green, .purple]
        for (index, name) in calomaParents.prefix(2).enumerated() {
            context.insert(Member(name: name, color: colors[index], photoData: CalomaFamily.parentPhoto(named: name), sortOrder: index))
        }
        try? context.save()
    }

    /// Invite your partner (owner), see who's in, or leave (member).
    @ViewBuilder
    private var sharingSection: some View {
        Section {
            if household.isMember {
                Label("Shared by \(household.ownerName ?? "your partner")", systemImage: "person.2.fill")
                Button("Leave Household", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    confirmsLeave = true
                }
            } else {
                ForEach(household.participants, id: \.self) { participant in
                    HStack {
                        Text(Self.name(of: participant))
                        Spacer()
                        Text(participant.acceptanceStatus == .accepted ? "Joined" : "Invited")
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    Task { await household.presentSharing() }
                } label: {
                    Label(household.participants.isEmpty ? "Invite to Household" : "Manage Sharing",
                          systemImage: household.participants.isEmpty ? "person.crop.circle.badge.plus" : "person.2.badge.gearshape")
                }
                .disabled(household.account != .available)
            }
        } header: {
            Text("Sharing")
        } footer: {
            if household.isMember {
                Text("You and \(household.ownerName ?? "your partner") share one budget through their iCloud. Every change shows up for both of you.")
            } else if household.account != .available {
                Text("Sign in to iCloud in Settings to share your household.")
            } else {
                Text("Invite your partner with their Apple Account. You'll both see and edit one budget, end-to-end encrypted in your iCloud. Each of you connects your own banks.")
            }
        }
    }

    private static func name(of participant: CKShare.Participant) -> String {
        let identity = participant.userIdentity
        if let components = identity.nameComponents {
            let name = components.formatted(.name(style: .medium))
            if !name.isEmpty { return name }
        }
        return identity.lookupInfo?.emailAddress ?? identity.lookupInfo?.phoneNumber ?? "Invited person"
    }
}

/// Add, rename, recolor or remove a person.
struct MemberEditor: View {
    let member: Member?
    /// Opened from Profile › My info: saving makes this person "me".
    var isMe: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @AppStorage(SettingsKey.currentMember) private var currentMember = ""
    @State private var name = ""
    @State private var color: MemberColor = .green
    @State private var photo: Data?
    @State private var isThisPhone = false
    @State private var originalName = ""
    @State private var pendingDelete = false

    init(member: Member?, isMe: Bool = false) {
        self.member = member
        self.isMe = isMe
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        PhotoPickerAvatar(name: name, color: color, photo: $photo, size: 56)
                        TextField("Name", text: $name)
                            .font(.title3)
                            .textInputAutocapitalization(.words)
                    }
                    if !isMe {
                        Toggle("This is me", isOn: $isThisPhone)
                    }
                } footer: {
                    Text("Tap the picture to add a photo. The person who uses this iPhone is filled in on new transactions.")
                }
                Section("Color") {
                    HStack(spacing: 0) {
                        ForEach(MemberColor.allCases) { option in
                            Button { color = option } label: {
                                Text(name.first.map { String($0).uppercased() } ?? "A")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(option.ink)
                                    .frame(width: 36, height: 36)
                                    .background(option.background, in: .circle)
                                    .padding(3)
                                    .overlay(Circle().strokeBorder(option == color ? option.ink : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(option.name)
                            .accessibilityAddTraits(option == color ? .isSelected : [])
                        }
                    }
                }
                if member != nil {
                    Section {
                        Button("Remove \(originalName)", role: .destructive) {
                            pendingDelete = true
                            dismiss()
                        }
                    } footer: {
                        Text("Their past transactions stay in Activity.")
                    }
                }
            }
            .navigationTitle(member == nil ? "Add Person" : (isMe ? "My info" : "Edit Person"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let member {
                    name = member.name
                    originalName = member.name
                    color = member.color
                    photo = member.photoData
                    isThisPhone = currentMember == member.id.uuidString
                } else {
                    // Suggest a color nobody has yet.
                    let used = Set(members.map(\.color))
                    color = MemberColor.allCases.first { !used.contains($0) } ?? .green
                    isThisPhone = isMe || members.isEmpty
                }
            }
            .onDisappear {
                guard pendingDelete, let member else { return }
                if currentMember == member.id.uuidString { currentMember = "" }
                context.delete(member)
                try? context.save()
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let target: Member
        if let member {
            target = member
            target.name = trimmed
            target.color = color
            if target.photoData != photo { target.photoData = photo }
        } else {
            target = Member(name: trimmed, color: color, photoData: photo, sortOrder: (members.map(\.sortOrder).max() ?? -1) + 1)
            context.insert(target)
        }
        try? context.save()
        if isMe || isThisPhone {
            currentMember = target.id.uuidString
        } else if currentMember == target.id.uuidString {
            currentMember = ""
        }
        dismiss()
    }
}

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
                    Text("Banks sync when Suffice opens (at most hourly) and when you pull down on Overview. Transactions are kept in your iCloud, not on a server.")
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
                Text("Your budget lives on this iPhone and in your private iCloud. Suffice has no servers and can't see your data.")
            }
            Section {
                Text("Suffice is part of a family of apps with Sated and Hearken: simple tools for running a life, with your data kept in your own iCloud.")
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
