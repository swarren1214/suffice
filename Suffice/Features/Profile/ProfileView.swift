import AuthenticationServices
import SwiftData
import SwiftUI

/// Profile, from the avatar at the top right: who you are, the household, connected accounts,
/// about, the Face ID lock, and erasing everything.
struct ProfileView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppLock.self) private var lock
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query private var accounts: [Account]
    @AppStorage(SettingsKey.currentMember) private var currentMember = ""
    @AppStorage(SettingsKey.faceIDLock) private var faceIDLock = false
    @AppStorage(SettingsKey.appleUserID) private var appleUserID = ""
    @AppStorage(SettingsKey.onboarded) private var onboarded = true
    @State private var editingMe = false
    @State private var confirmsErase = false
    @State private var cloud = HouseholdSync.shared

    private var me: Member? { members.first { $0.id.uuidString == currentMember } }
    @AppStorage(SettingsKey.remindBills) private var remindBills = false
    @AppStorage(SettingsKey.remindBudgets) private var remindBudgets = false
    @AppStorage(SettingsKey.remindWeekly) private var remindWeekly = false

    private var remindersValue: String {
        let count = [remindBills, remindBudgets, remindWeekly].filter { $0 }.count
        return count == 0 ? "Off" : "\(count) on"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 6) {
                    if let me {
                        // Tap to choose, change or remove your photo; saved right away.
                        PhotoPickerAvatar(
                            name: me.name,
                            color: me.color,
                            photo: Binding(
                                get: { me.photoData },
                                set: { newValue in
                                    me.photoData = newValue
                                    try? context.save()
                                }
                            ),
                            size: 84,
                            ring: .white.opacity(0.7)
                        )
                    } else {
                        PersonAvatar(name: "?", color: .green, photo: nil, size: 84)
                            .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 3))
                            .accessibilityHidden(true)
                    }
                    Text(me?.name ?? "Set up your profile")
                        .font(.title2.bold())
                    Text(statusLine)
                        .font(.footnote)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 10)

                VStack(spacing: 0) {
                    Button { editingMe = true } label: {
                        ProfileRow(symbol: "person", color: Color(hex: 0x3D3D3D), title: "My info", value: "")
                    }
                    Divider().padding(.leading, 60)
                    NavigationLink { HouseholdView() } label: {
                        ProfileRow(symbol: "person.2", color: Color(hex: 0x7B61FF), title: "Household", value: cloud.isMember || cloud.isSharing ? "Shared" : (members.count == 1 ? "1 person" : "\(members.count) people"))
                    }
                    Divider().padding(.leading, 60)
                    NavigationLink { AccountsListView() } label: {
                        ProfileRow(symbol: "building.columns", color: Color(hex: 0x2563C9), title: "Connected accounts", value: "\(accounts.count)")
                    }
                    Divider().padding(.leading, 60)
                    #if DEBUG
                    // The iCloud Sync card below shows sync status; this page is only the
                    // CloudKit developer tools.
                    NavigationLink { CloudSyncView() } label: {
                        ProfileRow(symbol: "hammer", color: Color(hex: 0x1C8CF0), title: "CloudKit (Debug)", value: "")
                    }
                    Divider().padding(.leading, 60)
                    #endif
                    NavigationLink { AskSettingsView() } label: {
                        ProfileRow(symbol: "sparkles", color: Color(hex: 0x5B3FD9), title: "Ask Suffice", value: OnDeviceModel.availability == .available ? "" : OnDeviceModel.availability.statusText)
                    }
                    Divider().padding(.leading, 60)
                    NavigationLink { RemindersView() } label: {
                        ProfileRow(symbol: "bell.badge", color: Color(hex: 0xC25E00), title: "Reminders", value: remindersValue)
                    }
                    Divider().padding(.leading, 60)
                    NavigationLink { AboutView() } label: {
                        ProfileRow(symbol: "info.circle", color: Brand.green, title: "About Suffice", value: "v\(AppConfig.version)")
                    }
                    Divider().padding(.leading, 60)
                    HStack(spacing: 12) {
                        ProfileIcon(symbol: "faceid", color: Color(hex: 0x3D3D3D))
                        Toggle("Lock with \(lock.biometryName)", isOn: Binding(
                            get: { faceIDLock },
                            set: { faceIDLock = $0 && lock.canLock() }
                        ))
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 54)
                }
                .buttonStyle(.plain)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))

                ProfileAccount(me: me)

                SufficeSyncCard()

                NavigationLink { HearthAppsView(current: .suffice) } label: {
                    HStack(spacing: 12) {
                        HearthAppsRowLabel(current: .suffice)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(minHeight: 54)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))

                Button(role: .destructive) { confirmsErase = true } label: {
                    Label(cloud.isMember ? "Leave Household" : "Erase App Data", systemImage: cloud.isMember ? "rectangle.portrait.and.arrow.right" : "trash")
                        .fontWeight(.semibold)
                        .foregroundStyle(Brand.expenseInk)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 40)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .tint(Brand.expenseInk)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(alignment: .top) { HeaderGradient() }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Profile")
        // Pull down to fetch the latest from iCloud.
        .refreshable { await cloud.syncNow() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { editingMe = true } label: {
                    Text("Edit").foregroundStyle(.white)
                }
            }
        }
        .sheet(isPresented: $editingMe) {
            MemberEditor(member: me, isMe: true)
        }
        .alert(cloud.isMember ? "Leave the Household?" : "Erase App Data?", isPresented: $confirmsErase) {
            Button("Cancel", role: .cancel) {}
            if cloud.isMember {
                // Erasing would delete the household for both of you; leaving is the member's
                // way to clear this device.
                Button("Leave", role: .destructive) {
                    Task { await cloud.leaveHousehold() }
                }
            } else {
                Button("Erase", role: .destructive) {
                    // Disconnect banks on the API first (with the current session), then forget the
                    // session, then erase, so a new sign-in afterwards isn't signed out.
                    let itemIDs = ((try? context.fetch(FetchDescriptor<LinkedBank>())) ?? []).map(\.itemID)
                    Task {
                        for itemID in itemIDs { try? await HearthAPI.shared.disconnectBank(itemID: itemID) }
                        await HearthAPI.shared.signOut()
                        Ledger.eraseEverything(in: context)
                        appleUserID = ""
                        onboarded = false
                    }
                }
            }
        } message: {
            if cloud.isMember {
                Text("You’re in a shared household, so erasing would delete it for everyone. Leaving removes it from this \(DeviceName.current) and brings back your own budget.")
            } else if cloud.isSharing {
                Text("This disconnects your banks and removes every transaction, budget, bill, account and person from your devices, your iCloud and everyone you share the household with. It can't be undone.\(appleUserID.isEmpty ? "" : " You’ll also be signed out of the other Hearth apps on this \(DeviceName.current).")")
            } else {
                Text("This disconnects your banks and removes every transaction, budget, bill, account and person from this device\(AppConfig.cloudSyncEnabled ? " and your iCloud" : ""). It can't be undone.\(appleUserID.isEmpty ? "" : " You’ll also be signed out of the other Hearth apps on this \(DeviceName.current).")")
            }
        }
    }

    /// Where the budget lives. Who's signed in is in the account section below.
    private var statusLine: String {
        AppConfig.cloudSyncEnabled ? "iCloud sync on" : "Saved on this \(DeviceName.current)"
    }
}

/// Profile › Account: the shared Hearth account section (HearthAccount.swift). Signed out, it
/// offers Sign in with Apple (connecting a bank needs it; everything else works without it);
/// signed in, it shows who and Sign Out, which signs out of every Hearth app on this device.
private struct ProfileAccount: View {
    let me: Member?
    @AppStorage(SettingsKey.appleUserID) private var appleUserID = ""
    @State private var confirmsSignOut = false

    private var profile: HearthAccountProfile? {
        guard !appleUserID.isEmpty else { return nil }
        return HearthAccountProfile(name: me?.name, email: HearthAccounts.session()?.email, photo: me?.photoData)
    }

    var body: some View {
        HearthAccountSection(
            app: .suffice,
            profile: profile,
            pitch: "Sign in to connect your bank accounts and use one account across Suffice, BigTable and Sated. Everything else works without it."
        ) {
            ProfileAppleButton()
        } onSignOut: {
            confirmsSignOut = true
        }
        .alert("Sign out of Suffice?", isPresented: $confirmsSignOut) {
            Button("Sign Out", role: .destructive) {
                Task {
                    await HearthAPI.shared.signOut()
                    withAnimation { appleUserID = "" }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your bank accounts stop updating until you sign in again, and you’re also signed out of your other Hearth apps on this \(DeviceName.current). Your budget stays on this \(DeviceName.current)\(AppConfig.cloudSyncEnabled ? " and in iCloud" : "").")
        }
    }
}

/// Sign in with Apple for someone who chose "Not now" during onboarding.
private struct ProfileAppleButton: View {
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.appleUserID) private var appleUserID = ""
    @AppStorage(SettingsKey.currentMember) private var currentMember = ""
    @State private var nonce: String?
    @State private var errorMessage: String?

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            request.requestedScopes = [.fullName]
            do {
                nonce = try HearthAPI.prepareAppleRequest(request)
            } catch {
                errorMessage = error.localizedDescription
            }
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                    errorMessage = "Apple did not return a usable credential. Please try again."
                    return
                }
                let token = credential.identityToken
                let requestNonce = nonce
                let userID = credential.user
                let fullName = credential.fullName
                let email = credential.email
                Task { @MainActor in
                    do {
                        try await HearthAPI.shared.signInWithApple(identityToken: token, nonce: requestNonce, appleUserID: userID, fullName: fullName, email: email)
                        withAnimation { appleUserID = userID }
                        // Banks you connected on another device start syncing here too.
                        await BankSync.syncAll(memberID: UUID(uuidString: currentMember), in: context)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            case .failure(let error as ASAuthorizationError) where error.code == .canceled:
                break
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .modifier(AdaptiveSignInStyle())
        .alert("Couldn't sign in", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

#if DEBUG
/// Profile › CloudKit (Debug): iCloud diagnostics and the development schema tool. Everyone
/// else sees sync status on the iCloud Sync card on Profile.
private struct CloudSyncView: View {
    @State private var cloud = HouseholdSync.shared
    @State private var isSeeding = false
    @State private var seedResult: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: cloud.summary)
                LabeledContent("iCloud Account", value: accountText)
                if let last = cloud.lastSynced {
                    LabeledContent("Last Synced") {
                        Text(last, format: .relative(presentation: .named))
                    }
                }
            } footer: {
                Text(cloud.isMember
                     ? "You’re in a shared household: it syncs through the iCloud of the person who shared it, with every change end-to-end encrypted."
                     : "Your budget syncs through your private iCloud to your devices, and to anyone you share the household with, with every change end-to-end encrypted. Changes usually arrive within a minute while Suffice is open.")
            }
            if let error = cloud.lastError {
                Section("Last Problem") {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Section {
                Button(isSeeding ? "Creating…" : "Create Development Schema", systemImage: "hammer") {
                    isSeeding = true
                    Task {
                        seedResult = await cloud.seedDevelopmentSchema()
                        isSeeding = false
                    }
                }
                .disabled(isSeeding)
                if let seedResult {
                    Text(seedResult)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Developer")
            } footer: {
                Text("Debug builds only. Saves one of every record type to CloudKit's Development environment so the whole schema can be deployed to Production.")
            }
        }
        .navigationTitle("CloudKit (Debug)")
        .refreshable { await cloud.syncNow() }
        .task { await cloud.refreshAccount() }
    }

    private var accountText: String {
        switch cloud.account {
        case .checking: "Checking…"
        case .available: "Signed in"
        case .noAccount: "Not signed in"
        case .restricted: "Restricted"
        case .unavailable: "Unavailable"
        }
    }
}
#endif

/// The shared iCloud Sync card, filled in from household sync, on Profile.
private struct SufficeSyncCard: View {
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @State private var cloud = HouseholdSync.shared

    var body: some View {
        HearthSyncCard(app: .suffice, snapshot: cloud.syncSnapshot, summary: "Your budget", sharing: sharing) {
            await HouseholdSync.shared.syncNow()
        }
    }

    /// Who the budget is shared with: once someone has been invited, or when this is someone
    /// else's household.
    private var sharing: HearthSyncSharing? {
        guard cloud.isMember || (cloud.isSharing && !cloud.participants.isEmpty) else { return nil }
        return HearthSyncSharing(
            label: members.count > 2 ? "Your household" : "Your partner",
            people: members.map { HearthSyncSharing.Person(id: $0.id.uuidString, initial: $0.initial, colorHex: $0.color.inkHex) }
        )
    }
}

private extension MemberColor {
    /// `ink` as 0xRRGGBB, for the iCloud Sync card's initials.
    var inkHex: UInt32 {
        switch self {
        case .green: 0x035F1C
        case .purple: 0x5B3FB0
        case .blue: 0x1F5FA8
        case .orange: 0xA34A12
        case .pink: 0xA3245A
        case .teal: 0x0F6E69
        }
    }
}

/// A Profile row: colored icon square, title, value and chevron.
private struct ProfileRow: View {
    var symbol: String
    var color: Color
    var title: String
    var value: String

    var body: some View {
        HStack(spacing: 12) {
            ProfileIcon(symbol: symbol, color: color)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(Brand.secondaryText)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 54)
        .contentShape(.rect)
    }
}

private struct ProfileIcon: View {
    var symbol: String
    var color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(color, in: .rect(cornerRadius: 9))
            .accessibilityHidden(true)
    }
}

#Preview {
    NavigationStack { ProfileView() }
        .previewEnvironment()
}
