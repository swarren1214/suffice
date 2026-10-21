import AuthenticationServices
import SwiftData
import SwiftUI

/// Profile, from the photo at the top right: the shared Hearth Profile with Suffice's connected
/// accounts, tax year, receipts, Ask Suffice, reminders and the Face ID lock.
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
    @State private var cloud = HouseholdSync.shared
    @State private var family = HearthHouseholdStore.shared

    private var me: Member? { members.first { $0.id.uuidString == currentMember } }
    /// You in the household, where your details are edited for every Hearth app.
    private var myPerson: HearthMember? { family.me ?? me.flatMap(SufficeHearthHousehold.person(for:)) }
    @AppStorage(SettingsKey.remindBills) private var remindBills = false
    @AppStorage(SettingsKey.remindBudgets) private var remindBudgets = false
    @AppStorage(SettingsKey.remindWeekly) private var remindWeekly = false

    private var remindersValue: String {
        let count = [remindBills, remindBudgets, remindWeekly].filter { $0 }.count
        return count == 0 ? "Off" : "\(count) on"
    }

    var body: some View {
        // The shared Hearth Profile (HearthProfile.swift), with Suffice's own section in the middle.
        HearthProfileView(
            app: .suffice,
            profile: accountProfile,
            sync: HearthProfileSync(summary: "Your budget", sharing: syncSharing) {
                HouseholdSync.shared.syncSnapshot
            } syncNow: {
                await HouseholdSync.shared.syncNow()
            },
            erase: erase
        ) {
            Section {
                ProfileAccount(me: me)
                    .hearthAccountSectionRow()
            }
        } settings: {
            sufficeSection
        } data: {
        } about: {
        }
        // Pull down to fetch the latest from iCloud.
        .refreshable { await cloud.syncNow() }
        // Your details live in the household, for every Hearth app.
        .sheet(isPresented: $editingMe) {
            if let myPerson {
                HearthPersonEditor(member: myPerson, accent: Brand.green)
            }
        }
    }

    /// Who's signed in with Apple, for the account card at the top (nil shows Sign in with Apple).
    private var accountProfile: HearthAccountProfile? {
        guard !appleUserID.isEmpty else { return nil }
        return HearthAccountProfile(name: me?.name, email: HearthAccounts.session()?.email, photo: me.flatMap { SufficeHearthHousehold.photo(forMemberID: $0.id) })
    }

    /// Suffice's own settings.
    private var sufficeSection: some View {
        Section("Suffice") {
            if myPerson != nil {
                Button { editingMe = true } label: {
                    HearthProfileRow("My Info", systemImage: "person")
                }
            }
            NavigationLink { AccountsListView() } label: {
                HearthProfileRow("Connected Accounts", systemImage: "building.columns", value: "\(accounts.count)")
            }
            NavigationLink { TaxYearView() } label: {
                HearthProfileRow("Tax Year", systemImage: "doc.text.magnifyingglass", value: String(Calendar.current.component(.year, from: .now)))
            }
            NavigationLink { EmailConnectView() } label: {
                HearthProfileRow("Receipts from Email", systemImage: "envelope.badge", value: MailAccounts.shared.isConnected ? "On" : nil)
            }
            NavigationLink { AskSettingsView() } label: {
                HearthProfileRow("Ask Suffice", systemImage: "sparkles", value: OnDeviceModel.availability == .available ? nil : OnDeviceModel.availability.statusText)
            }
            NavigationLink { RemindersView() } label: {
                HearthProfileRow("Reminders", systemImage: "bell.badge", value: remindersValue)
            }
            Toggle(isOn: Binding(
                get: { faceIDLock },
                set: { faceIDLock = $0 && lock.canLock() }
            )) {
                Label {
                    Text("Lock with \(lock.biometryName)")
                } icon: {
                    Image(systemName: "faceid").foregroundStyle(.primary)
                }
            }
            NavigationLink { AboutView() } label: {
                HearthProfileRow("About Suffice", systemImage: "info.circle", value: "v\(AppConfig.version)")
            }
            #if DEBUG
            // The iCloud Sync page shows sync status; this page is only the CloudKit developer tools.
            NavigationLink { CloudSyncView() } label: {
                HearthProfileRow("CloudKit (Debug)", systemImage: "hammer")
            }
            #endif
        }
        .tint(.primary)
    }

    /// Who the budget is shared with: once a parent or adult in the household has joined, or when
    /// this is someone else's budget.
    private var syncSharing: HearthSyncSharing? {
        guard cloud.isMember || (cloud.isSharing && !cloud.participants.isEmpty) else { return nil }
        return HearthSyncSharing(
            label: "Your household",
            people: members.map { HearthSyncSharing.Person(id: $0.id.uuidString, initial: $0.initial, colorHex: $0.color.inkHex) }
        )
    }

    /// Erase App Data, or Leave Household for a member (erasing would delete the family's budget
    /// for everyone; leaving is a member's way to clear this device).
    private var erase: HearthProfileErase {
        if cloud.isMember {
            return HearthProfileErase(
                app: .suffice,
                title: "Leave Household",
                question: "Leave the Household?",
                message: "You’re in your family’s budget, so erasing would delete it for everyone. Leaving the household removes it from every Hearth app on this \(DeviceName.current) and brings back your own budget.",
                confirm: "Leave",
                symbol: "rectangle.portrait.and.arrow.right"
            ) {
                await family.leave()
            }
        }
        let signOutNote = appleUserID.isEmpty ? "" : " You’ll also be signed out of the other Hearth apps on this \(DeviceName.current)."
        let message = cloud.isSharing
            ? "This disconnects your banks and removes every transaction, budget, bill, account and person from your devices, your iCloud and everyone you share the household with. It can't be undone.\(signOutNote)"
            : "This disconnects your banks and removes every transaction, budget, bill, account and person from this device\(AppConfig.cloudSyncEnabled ? " and your iCloud" : ""). It can't be undone.\(signOutNote)"
        return HearthProfileErase(app: .suffice, title: "Erase App Data", question: "Erase App Data?", message: message) {
            // Disconnect banks on the API first (with the current session), then forget the
            // session, then erase, so a new sign-in afterwards isn't signed out.
            let itemIDs = ((try? context.fetch(FetchDescriptor<LinkedBank>())) ?? []).map(\.itemID)
            for itemID in itemIDs { try? await HearthAPI.shared.disconnectBank(itemID: itemID) }
            await HearthAPI.shared.signOut()
            Ledger.eraseEverything(in: context)
            appleUserID = ""
            onboarded = false
            HearthProfilePresenter.shared.dismiss()
        }
    }
}

/// Profile › Account: the shared Hearth account section (HearthAccount.swift). Signed out, it
/// offers Sign in with Apple (connecting a bank needs it; everything else works without it);
/// signed in, it shows who and Sign Out, which signs out of every Hearth app on this device, and
/// Delete Account, which deletes the Hearth account on the server, erases Suffice's data the way
/// Erase App Data does, and signs out everywhere.
private struct ProfileAccount: View {
    let me: Member?
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.appleUserID) private var appleUserID = ""
    @AppStorage(SettingsKey.onboarded) private var onboarded = true
    @State private var confirmsSignOut = false
    @State private var confirmsDelete = false
    @State private var isDeleting = false
    @State private var deleteError: String?
    @State private var cloud = HouseholdSync.shared
    @State private var family = HearthHouseholdStore.shared

    private var profile: HearthAccountProfile? {
        guard !appleUserID.isEmpty else { return nil }
        return HearthAccountProfile(name: me?.name, email: HearthAccounts.session()?.email, photo: me.flatMap { SufficeHearthHousehold.photo(forMemberID: $0.id) })
    }

    /// Delete Account is only offered to someone signed in with Apple, never to the anonymous
    /// session.
    private var onDeleteAccount: (() -> Void)? {
        guard !appleUserID.isEmpty else { return nil }
        return { if !isDeleting { confirmsDelete = true } }
    }

    var body: some View {
        HearthAccountSection(
            app: .suffice,
            profile: profile,
            pitch: "Sign in to connect your bank accounts and use one account across every Hearth app. Everything else works without it.",
            signInButton: { ProfileAppleButton() },
            onSignOut: { confirmsSignOut = true },
            onDeleteAccount: onDeleteAccount
        )
        .alert("Delete Your Hearth Account?", isPresented: $confirmsDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Account", role: .destructive) { deleteAccount() }
        } message: {
            Text(deleteMessage)
        }
        .alert("Couldn't Delete Your Account", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
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

    /// What Delete Account removes, matching what Erase App Data (or Leave Household) does here.
    private var deleteMessage: String {
        let account = "This permanently deletes your Hearth account for every Hearth app, with your bank connections, your BigTable and Hearken data, and your sign-in. Subscriptions bought through the App Store are managed in Settings › Apple Account › Subscriptions."
        let here: String
        if cloud.isMember {
            here = "You’ll also leave your family’s household, which removes its budget from every Hearth app on this \(DeviceName.current)."
        } else if cloud.isSharing {
            here = "Every transaction, budget, bill, account and person is also removed from your devices, your iCloud and everyone you share the household with."
        } else {
            here = "Every transaction, budget, bill, account and person is also removed from this \(DeviceName.current)\(AppConfig.cloudSyncEnabled ? " and your iCloud" : "")."
        }
        return "\(account) \(here) You’ll be signed out of every Hearth app on this \(DeviceName.current). This can’t be undone."
    }

    /// Deletes the account on the server first; only when that worked, erases Suffice's data the
    /// way Profile › Erase App Data does (the server already disconnected the banks, so no
    /// per-bank calls are made with the deleted account) and signs out of every Hearth app.
    private func deleteAccount() {
        guard !isDeleting else { return }
        isDeleting = true
        Task {
            defer { isDeleting = false }
            do {
                try await HearthAPI.shared.deleteAccount()
            } catch let failure as HearthAPI.APIFailure where failure.code == "HOUSEHOLD_HAS_MEMBERS" {
                deleteError = "Remove the other people from your household in BigTable first."
                return
            } catch {
                deleteError = FriendlyError.message(for: error, fallback: "Your account couldn’t be deleted just now. Nothing was removed. Try again in a moment.")
                return
            }
            let wasMember = cloud.isMember
            if wasMember {
                // Erasing would delete the family's budget for everyone; leaving clears this device.
                await family.leave()
            } else {
                Ledger.eraseEverything(in: context)
            }
            await HearthAPI.shared.signOut()
            withAnimation { appleUserID = "" }
            if !wasMember { onboarded = false }
        }
    }
}

/// Sign in with Apple for someone who chose "Not now" during onboarding. Also the paywall's
/// "link your account" button (`HearthPurchases.configure(signInButton:)`).
struct ProfileAppleButton: View {
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
                errorMessage = FriendlyError.message(for: error, fallback: "Sign in with Apple couldn’t start. Try again.")
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
                        errorMessage = FriendlyError.message(for: error, fallback: "Suffice couldn’t finish signing you in. Try again in a moment.")
                    }
                }
            case .failure(let error as ASAuthorizationError) where error.code == .canceled:
                break
            case .failure:
                errorMessage = "Sign in with Apple didn’t finish. Try again."
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
/// else sees sync status in Profile › iCloud Sync.
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
                     ? "You’re in your family’s budget: it syncs through the iCloud of the person who shared the household, with every change end-to-end encrypted."
                     : "Your budget syncs through your private iCloud (the Hearth container’s Budget zone) to your devices, and to the parents and adults in your household, with every change end-to-end encrypted. Changes usually arrive within a minute while Suffice is open.")
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
                .tint(.primary)
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

#Preview {
    NavigationStack { ProfileView() }
        .previewEnvironment()
}
