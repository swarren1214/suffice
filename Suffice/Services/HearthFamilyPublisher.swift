import Foundation
import Observation
import SwiftData
import UIKit

/// Suffice's side of sharing people with the other Hearth apps on this device (see
/// `Services/Hearth/HearthShared.swift`): it publishes the household (names, colors, photos, and
/// who "This is me" is) so BigTable, Caloma and Hearken can show Suffice's photos, and it keeps
/// `HearthPhotos` fresh for people who have a photo in another app but not here.
enum HearthHousehold {
    private static var pending: Task<Void, Never>?
    private static var changeObserver: NSObjectProtocol?

    /// The shared file written for each member's photo, and the photo it was made from, so
    /// publishing again (after every save) doesn't re-encode photos that haven't changed.
    private struct SharedPhotoFile {
        var fingerprint: PhotoFingerprint
        var file: String
    }

    private struct PhotoFingerprint: Equatable {
        var count: Int
        var hash: Int

        init(_ data: Data) {
            count = data.count
            hash = data.hashValue
        }
    }

    private static var sharedPhotoFiles: [UUID: SharedPhotoFile] = [:]
    /// The photo files kept last time, so old ones are cleaned up only when something changed.
    private static var keptPhotoFiles: Set<String>?

    /// Publishes now and follows the other apps' changes while Suffice is open. Call once.
    static func start(_ container: ModelContainer) {
        guard changeObserver == nil, !ScreenshotMode.isOn else { return }
        Hearth.startObservingChanges()
        changeObserver = NotificationCenter.default.addObserver(forName: Hearth.didChange, object: nil, queue: .main) { _ in
            Task { @MainActor in HearthPhotos.shared.reset() }
        }
        publish(in: container.mainContext)
    }

    /// Coalesces bursts of saves into one publish.
    static func schedule(_ container: ModelContainer) {
        guard !ScreenshotMode.isOn else { return }
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            publish(in: container.mainContext)
        }
    }

    /// Shares the household (everyone as an adult, their colors and photos, and who this device
    /// belongs to). Unchanged households aren't rewritten.
    static func publish(in context: ModelContext) {
        guard !ScreenshotMode.isOn else { return }
        let members = (try? context.fetch(FetchDescriptor<Member>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        var photoChanged = false
        let shared = members.compactMap { member -> HearthFamily.Member? in
            let name = member.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let (photo, changed) = sharedPhoto(for: member)
            if changed { photoChanged = true }
            return HearthFamily.Member(
                id: member.id.uuidString,
                name: name,
                role: "adult",
                colorHex: colorHex(member.color),
                birthday: nil,
                likes: nil,
                dislikes: nil,
                photo: photo
            )
        }
        let current = UserDefaults.standard.string(forKey: SettingsKey.currentMember)
        let me = shared.first { $0.id == current }?.id
        let published = Hearth.publish(HearthFamily(name: nil, members: shared, dietaryRestrictions: nil, me: me), from: .suffice)
        // A new photo under the same file name doesn't change the family file, so say so.
        if photoChanged && !published { Hearth.postChange() }

        let keep = Set(shared.compactMap(\.photo))
        if keep != keptPhotoFiles {
            Hearth.removePhotos(from: .suffice, except: keep)
            keptPhotoFiles = keep
        }
        let ids = Set(members.map(\.id))
        sharedPhotoFiles = sharedPhotoFiles.filter { ids.contains($0.key) }
    }

    /// The member's photo in the shared folder (a square JPEG of at most 400 px, from
    /// `MemberPhoto.prepare`), and whether it was written just now.
    private static func sharedPhoto(for member: Member) -> (file: String?, changed: Bool) {
        guard let data = member.photoData else {
            sharedPhotoFiles[member.id] = nil
            return (nil, false)
        }
        let fingerprint = PhotoFingerprint(data)
        if let saved = sharedPhotoFiles[member.id], saved.fingerprint == fingerprint,
           let url = Hearth.photosDirectory?.appending(path: saved.file, directoryHint: .notDirectory),
           FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            return (saved.file, false)
        }
        guard let jpeg = MemberPhoto.prepare(data),
              let file = Hearth.savePhoto(jpeg, memberID: member.id.uuidString, from: .suffice) else {
            sharedPhotoFiles[member.id] = nil
            return (nil, false)
        }
        sharedPhotoFiles[member.id] = SharedPhotoFile(fingerprint: fingerprint, file: file)
        return (file, true)
    }

    /// The badge's ink color as 0xRRGGBB (matches `MemberColor.ink`).
    private static func colorHex(_ color: MemberColor) -> UInt32 {
        switch color {
        case .green: 0x035F1C
        case .purple: 0x5B3FB0
        case .blue: 0x1F5FA8
        case .orange: 0xA34A12
        case .pink: 0xA3245A
        case .teal: 0x0F6E69
        }
    }
}

/// Photos the other Hearth apps have of people who don't have one in Suffice (Caloma's photo of
/// your partner, BigTable's of you), by name. Each name is read from the shared folder once and
/// kept until another app shares something (`Hearth.didChange`), so drawing an avatar never
/// touches the disk.
@MainActor
@Observable
final class HearthPhotos {
    static let shared = HearthPhotos()

    /// Bumped when the cache is cleared, so avatars that showed a shared photo redraw.
    private(set) var generation = 0
    /// By normalized name; a nil image means there's no shared photo for that name.
    @ObservationIgnored private var images: [String: UIImage?] = [:]

    func image(forName name: String) -> UIImage? {
        _ = generation
        guard !ScreenshotMode.isOn else { return nil }
        let key = HearthNames.normalized(name)
        guard !key.isEmpty else { return nil }
        if let cached = images[key] { return cached }
        let image = Hearth.sharedPhoto(forName: name, excluding: .suffice).flatMap { UIImage(data: $0) }
        images.updateValue(image, forKey: key)
        return image
    }

    func reset() {
        guard !images.isEmpty else { return }
        images = [:]
        generation += 1
    }
}
