import PhotosUI
import SwiftUI
import UIKit

/// A person's round avatar: their photo when they have one, otherwise a photo another Hearth
/// app has of someone with their name (`HearthPhotos`), otherwise their initial on their pale
/// color. Used everywhere a household member appears.
struct PersonAvatar: View {
    var name: String
    var color: MemberColor
    var photo: Data?
    var size: CGFloat = 30

    var body: some View {
        Group {
            if let image = MemberPhoto.image(from: photo) ?? (photo == nil ? HearthPhotos.shared.image(forName: name) : nil) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(name.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(color.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(color.background)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }
}

extension PersonAvatar {
    init(member: Member, size: CGFloat = 30) {
        self.init(name: member.name, color: member.color, photo: member.photoData, size: size)
    }
}

/// An avatar you can tap to choose a photo from the library, with a small camera badge.
/// Remove Photo appears in a menu once there is one.
struct PhotoPickerAvatar: View {
    var name: String
    var color: MemberColor
    @Binding var photo: Data?
    var size: CGFloat = 44
    /// An optional ring around the photo, like the white one on Profile.
    var ring: Color?

    @State private var item: PhotosPickerItem?
    @State private var showsPicker = false
    @State private var isLoading = false

    init(name: String, color: MemberColor, photo: Binding<Data?>, size: CGFloat = 44, ring: Color? = nil) {
        self.name = name
        self.color = color
        self._photo = photo
        self.size = size
        self.ring = ring
    }

    var body: some View {
        Menu {
            Button(photo == nil ? "Choose Photo" : "Change Photo", menuIcon: "photo.on.rectangle") {
                showsPicker = true
            }
            if photo != nil {
                Button("Remove Photo", menuIcon: "trash", role: .destructive) {
                    withAnimation { photo = nil }
                }
            }
        } label: {
            PersonAvatar(name: name, color: color, photo: photo, size: size)
                .overlay {
                    if let ring {
                        Circle().strokeBorder(ring, lineWidth: 3)
                    }
                }
                .overlay {
                    if isLoading {
                        Circle().fill(.black.opacity(0.3))
                        ProgressView().tint(.white)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: max(size * 0.2, 9), weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: max(size * 0.4, 18), height: max(size * 0.4, 18))
                        .background(Brand.green, in: .circle)
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                        .offset(x: 3, y: 3)
                }
        }
        .buttonStyle(.plain)
        // Menu icons in the same color as their text.
        .tint(.primary)
        .photosPicker(isPresented: $showsPicker, selection: $item, matching: .images)
        .accessibilityLabel(photo == nil ? "Add a photo of \(name.isEmpty ? "this person" : name)" : "Photo of \(name). Change or remove")
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            isLoading = true
            Task {
                let data = try? await newItem.loadTransferable(type: Data.self)
                let prepared = data.flatMap(MemberPhoto.prepare)
                await MainActor.run {
                    if let prepared { withAnimation { photo = prepared } }
                    isLoading = false
                    item = nil
                }
            }
        }
    }
}

/// Profile photos are shrunk to a small square JPEG before they're saved, so they sync through
/// CloudKit quickly and cheaply (SwiftData stores them as CKAssets, outside the record).
nonisolated enum MemberPhoto {
    /// The longest side, in pixels. Avatars are never shown larger than 84 pt (252 px at 3×).
    static let maxPixels: CGFloat = 400

    /// A center-cropped square JPEG of the picked image, or nil if it isn't an image.
    static func prepare(_ data: Data) -> Data? {
        guard let source = UIImage(data: data) else { return nil }
        let side = min(source.size.width, source.size.height)
        let scale = min(1, maxPixels / max(side, 1))
        let target = CGSize(width: side * scale, height: side * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let square = renderer.image { _ in
            let drawSize = CGSize(width: source.size.width * scale, height: source.size.height * scale)
            let origin = CGPoint(x: (target.width - drawSize.width) / 2, y: (target.height - drawSize.height) / 2)
            source.draw(in: CGRect(origin: origin, size: drawSize))
        }
        return square.jpegData(compressionQuality: 0.8)
    }

    /// Decoded photos, kept so lists don't decode the same JPEG on every redraw.
    private static let cache = NSCache<NSData, UIImage>()

    static func image(from data: Data?) -> UIImage? {
        guard let data else { return nil }
        let key = data as NSData
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
