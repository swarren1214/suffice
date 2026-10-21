import Foundation
import SwiftData
import UIKit

/// Keeps Suffice's budgeting people (`Member`) in step with the Hearth household. Suffice always
/// has a household (a household of one is fine), and people are added and edited only there.
/// Parents and adults budget, so they become Suffice members; kids stay in the household. The
/// household is the source of truth for names, colors and photos; what only Suffice knows (who
/// made a transaction, spending by person, who uses this device) stays on Suffice's `Member`,
/// linked through `appIDs["suffice"]`.
///
/// Suffice's own people go into the household once, when it's created: the setup screen
/// (`HearthHouseholdSetupView`) builds it from what every Hearth app published, Suffice's members
/// included (`HearthHousehold.publish`), with their ids as the link. After that nothing here adds
/// people to the household.
@MainActor
enum SufficeHearthHousehold {
    private static let photoNamesKey = "hearth.household.sufficePhotos"

    /// The household person for a Suffice member.
    static func person(for member: Member) -> HearthMember? {
        HearthHouseholdStore.shared.member(app: .suffice, appID: member.id.uuidString)
    }

    /// A Suffice member's photo: the one set on their household person, and only that one.
    /// Every avatar in Suffice draws from here, so it always matches the household.
    static func photo(forMemberID id: UUID) -> Data? {
        guard let name = HearthHouseholdStore.shared.member(app: .suffice, appID: id.uuidString)?.photo else { return nil }
        return Hearth.photo(named: name)
    }

    /// The decoded household photo for a Suffice member. Photo file names change with the photo,
    /// so they're safe cache keys.
    static func image(forMemberID id: UUID) -> UIImage? {
        guard let name = HearthHouseholdStore.shared.member(app: .suffice, appID: id.uuidString)?.photo else { return nil }
        if let cached = imageCache.object(forKey: name as NSString) { return cached }
        guard let data = Hearth.photo(named: name), let image = UIImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: name as NSString)
        return image
    }

    private static let imageCache = NSCache<NSString, UIImage>()

    /// The Suffice member for a household person, among `members`.
    static func member(for person: HearthMember, among members: [Member]) -> Member? {
        let ids = Set(members.map(\.id.uuidString))
        guard let id = HearthHouseholdStore.shared.localID(of: person, app: .suffice, among: ids) else { return nil }
        return members.first { $0.id.uuidString == id }
    }

    static func sync(in context: ModelContext) {
        let store = HearthHouseholdStore.shared
        // Not while the budget is switching or the family's is still arriving: people on the
        // way would be made twice.
        guard store.exists, !ScreenshotMode.isOn, HouseholdSync.shared.isSettled else { return }
        let members = (try? context.fetch(FetchDescriptor<Member>())) ?? []
        var byID = Dictionary(members.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        var photoNames = UserDefaults.standard.dictionary(forKey: photoNamesKey) as? [String: String] ?? [:]
        var changed = false
        // Only someone who can change everyone adds people, so two phones don't both make one.
        let mayAdd = store.canEditEveryone

        let ids = Set(byID.keys)
        var claimed = Set(store.snapshot.members.compactMap { store.localID(of: $0, app: .suffice, among: ids) })
        // Parents and adults budget; kids aren't in the budget.
        for person in store.snapshot.members where person.role != .kid {
            let target: Member
            if let id = store.localID(of: person, app: .suffice, among: ids), let linked = byID[id] {
                target = linked
            } else if let match = members.first(where: { !claimed.contains($0.id.uuidString) && HearthNames.normalized($0.name) == HearthNames.normalized(person.name) }) {
                // Someone Suffice already has by name.
                target = match
                claimed.insert(match.id.uuidString)
                if store.canEditEveryone { store.linkHere(person, app: .suffice, localID: match.id.uuidString) }
            } else {
                // Someone already linked to a Suffice member (in the budget, or on its way) isn't
                // made again.
                guard !person.isArchived, mayAdd, person.appID(.suffice) == nil else { continue }
                target = Member(name: person.trimmedName, color: memberColor(person.colorHex), sortOrder: person.sortOrder)
                context.insert(target)
                byID[target.id.uuidString] = target
                claimed.insert(target.id.uuidString)
                store.linkHere(person, app: .suffice, localID: target.id.uuidString)
                changed = true
            }
            let name = person.trimmedName
            if !name.isEmpty, target.name != name { target.name = name; changed = true }
            let color = memberColor(person.colorHex)
            if target.color != color { target.color = color; changed = true }
            let key = target.id.uuidString
            if photoNames[key] != person.photo {
                target.photoData = person.photo.flatMap(Hearth.photo(named:))
                photoNames[key] = person.photo
                changed = true
            }
        }

        UserDefaults.standard.set(photoNames, forKey: photoNamesKey)
        if changed { try? context.save() }
        followMe(store, among: Set(byID.keys))
    }

    /// "This is me" follows the household's `me`: the Suffice member linked to them is the one
    /// filled in on new transactions. A device that picked someone in Suffice before the
    /// household knew tells the household once.
    private static func followMe(_ store: HearthHouseholdStore, among ids: Set<String>) {
        let defaults = UserDefaults.standard
        let current = defaults.string(forKey: SettingsKey.currentMember) ?? ""
        if let me = store.me {
            guard let id = store.localID(of: me, app: .suffice, among: ids) else { return }
            if id != current { defaults.set(id, forKey: SettingsKey.currentMember) }
        } else if store.hasLoaded, store.account != .checking, !current.isEmpty,
                  let person = store.member(app: .suffice, appID: current), !person.isArchived, person.role != .kid {
            store.claim(person.id)
        }
    }

    /// Suffice's six member colors, as Hearth palette colors.
    static func hex(_ color: MemberColor) -> UInt32 {
        switch color {
        case .green: 0x1E9E6A
        case .purple: 0x8E4EC6
        case .blue: 0x0A7AFF
        case .orange: 0xE8650F
        case .pink: 0xE0284F
        case .teal: 0x0E8C99
        }
    }

    /// The Suffice color nearest a household color.
    static func memberColor(_ hex: UInt32) -> MemberColor {
        func parts(_ value: UInt32) -> (Double, Double, Double) {
            (Double((value >> 16) & 0xFF), Double((value >> 8) & 0xFF), Double(value & 0xFF))
        }
        let (r, g, b) = parts(hex)
        return MemberColor.allCases.min { lhs, rhs in
            let (r1, g1, b1) = parts(Self.hex(lhs)), (r2, g2, b2) = parts(Self.hex(rhs))
            return (r - r1) * (r - r1) + (g - g1) * (g - g1) + (b - b1) * (b - b1)
                < (r - r2) * (r - r2) + (g - g2) * (g - g2) + (b - b2) * (b - b2)
        } ?? .green
    }
}
