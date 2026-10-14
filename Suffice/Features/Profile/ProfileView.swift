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
                        ProfileRow(symbol: "person.2", color: Color(hex: 0x7B61FF), title: "Household", value: members.count == 1 ? "1 person" : "\(members.count) people")
                    }
                    Divider().padding(.leading, 60)
                    NavigationLink { AccountsListView() } label: {
                        ProfileRow(symbol: "building.columns", color: Color(hex: 0x2563C9), title: "Connected accounts", value: "\(accounts.count)")
                    }
                    Divider().padding(.leading, 60)
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

                Button(role: .destructive) { confirmsErase = true } label: {
                    Label("Erase App Data", systemImage: "trash")
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
        .alert("Erase App Data?", isPresented: $confirmsErase) {
            Button("Cancel", role: .cancel) {}
            Button("Erase", role: .destructive) {
                // Disconnect banks on the API first (with the current session), then forget the
                // session, then erase, so a new sign-in afterwards isn't signed out.
                let itemIDs = ((try? context.fetch(FetchDescriptor<LinkedBank>())) ?? []).map(\.itemID)
                Task {
                    for itemID in itemIDs { try? await LifestyleAPI.shared.disconnectBank(itemID: itemID) }
                    await LifestyleAPI.shared.signOut()
                    Ledger.eraseEverything(in: context)
                    appleUserID = ""
                    onboarded = false
                }
            }
        } message: {
            Text("This disconnects your banks and removes every transaction, budget, bill, account and person from this device\(AppConfig.cloudSyncEnabled ? " and your iCloud" : ""). It can't be undone.")
        }
    }

    private var statusLine: String {
        let signIn = appleUserID.isEmpty ? "Not signed in" : "Signed in with Apple"
        let sync = AppConfig.cloudSyncEnabled ? "iCloud sync on" : "Saved on this iPhone"
        return "\(signIn) · \(sync)"
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
