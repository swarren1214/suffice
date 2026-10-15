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
                    NavigationLink { CloudSyncView() } label: {
                        ProfileRow(symbol: "icloud", color: Color(hex: 0x1C8CF0), title: "iCloud Sync", value: cloud.summary)
                    }
                    Divider().padding(.leading, 60)
                    if !appleUserID.isEmpty {
                        HStack(spacing: 12) {
                            ProfileIcon(symbol: "apple.logo", color: .black)
                            Text("Apple Account")
                            Spacer()
                            Text("Signed in").foregroundStyle(Brand.secondaryText)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 54)
                        .accessibilityElement(children: .combine)
                        Divider().padding(.leading, 60)
                    }
                    NavigationLink { AskSettingsView() } label: {
                        ProfileRow(symbol: "sparkles", color: Color(hex: 0x5B3FD9), title: "Ask Suffice", value: OnDeviceModel.availability == .available ? "" : OnDeviceModel.availability.statusText)
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

                if appleUserID.isEmpty {
                    ProfileSignIn()
                }

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

    private var statusLine: String {
        let signIn = appleUserID.isEmpty ? "Not signed in" : "Signed in with Apple"
        let sync = AppConfig.cloudSyncEnabled ? "iCloud sync on" : "Saved on this \(DeviceName.current)"
        return "\(signIn) · \(sync)"
    }
}

/// Sign in with Apple for someone who chose "Not now" during onboarding. Connecting a bank
/// needs it; everything else works without it.
private struct ProfileSignIn: View {
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.appleUserID) private var appleUserID = ""
    @AppStorage(SettingsKey.currentMember) private var currentMember = ""
    @State private var nonce: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 8) {
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
            .frame(height: 50)
            .clipShape(Capsule())

            Text("Sign in to connect your bank accounts. Everything else works without it.")
                .font(.footnote)
                .foregroundStyle(Brand.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .padding(.top, 4)
        .alert("Couldn't sign in", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

/// Profile › iCloud Sync: whether it's working, when it last synced, and what went wrong.
private struct CloudSyncView: View {
    @State private var cloud = HouseholdSync.shared

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
        }
        .navigationTitle("iCloud Sync")
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
