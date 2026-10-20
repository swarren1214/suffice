import PhotosUI
import SwiftUI
import UIKit
import VisionKit

/// What the receipt row asked for. The camera, photo picker and viewer are presented from the
/// sheet (`receiptPresenter`), not from the row: presenting from inside a Form row closes the
/// presentation as soon as the row redraws, which dropped the picker and froze the camera.
enum ReceiptRequest: Identifiable, Hashable {
    case camera, library, viewer
    var id: Self { self }
}

/// The receipt on the transaction sheet: scan one with the camera (edges found, straightened
/// and cropped, like scanning in Notes) or pick a photo; then see it, replace it or remove it.
///
/// Empty, it's a dashed card inviting a scan. With a receipt, it's a large preview of the top
/// of the receipt with its actions on glass.
struct ReceiptSection: View {
    @Binding var receipt: Data?
    var isPreparing: Bool
    var request: (ReceiptRequest) -> Void

    /// A smaller copy for the preview, made once per receipt rather than decoding the full
    /// photo on every redraw.
    @State private var preview: UIImage?

    private let corner: CGFloat = 26

    var body: some View {
        Section {
            Group {
                if isPreparing {
                    preparing
                } else if receipt != nil {
                    attached
                } else {
                    empty
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .task(id: receipt) {
            guard let receipt else {
                preview = nil
                return
            }
            preview = await Task.detached(priority: .userInitiated) {
                UIImage(data: receipt)?.preparingThumbnail(of: CGSize(width: 1000, height: 1400))
            }.value
        }
    }

    // MARK: Empty

    private var empty: some View {
        VStack(spacing: 16) {
            Image(systemName: "receipt")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Brand.green)
                .frame(width: 56, height: 56)
                .background(Brand.green.opacity(0.12), in: .circle)

            VStack(spacing: 4) {
                Text("Add a Receipt")
                    .font(.headline)
                Text("Keep the paper trail with this transaction.")
                    .font(.footnote)
                    .foregroundStyle(Brand.secondaryText)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                if ReceiptCamera.isAvailable {
                    Button { request(.camera) } label: {
                        Label("Scan", systemImage: "camera.viewfinder")
                            .fontWeight(.semibold)
                            // White icon and text: left to the tint, the icon came out green on
                            // the green button.
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Brand.green)
                }
                Button { request(.library) } label: {
                    Label("Upload", systemImage: "square.and.arrow.up")
                        .fontWeight(.semibold)
                        .foregroundStyle(Brand.green)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: corner))
        .overlay(
            RoundedRectangle(cornerRadius: corner)
                .strokeBorder(Brand.green.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
        )
    }

    // MARK: Attached

    private var attached: some View {
        ZStack(alignment: .bottom) {
            // The top of the receipt, where the store and total usually are. Tap to see it all.
            Button { request(.viewer) } label: {
                Group {
                    if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color(.tertiarySystemFill)
                            .overlay { ProgressView() }
                    }
                }
                .frame(height: 240, alignment: .top)
                .frame(maxWidth: .infinity)
                .clipped()
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View receipt")

            HStack(spacing: 10) {
                Label("Receipt", systemImage: "receipt")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Menu {
                    if ReceiptCamera.isAvailable {
                        Button("Scan a New One", menuIcon: "camera.viewfinder") { request(.camera) }
                    }
                    Button("Upload a New One", menuIcon: "square.and.arrow.up") { request(.library) }
                    Divider()
                    Button("Remove Receipt", menuIcon: "trash", role: .destructive) {
                        withAnimation(.snappy) { receipt = nil }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .accessibilityLabel("Receipt options")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            )
        }
        .overlay(alignment: .topTrailing) {
            Button { request(.viewer) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .padding(12)
            .accessibilityLabel("View receipt full screen")
        }
        .clipShape(.rect(cornerRadius: corner))
        .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    // MARK: Preparing

    private var preparing: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Adding receipt…")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Brand.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: corner))
    }
}

extension View {
    /// The camera, photo picker and full-screen viewer for the receipt row. Apply it to the
    /// sheet's Form (outside any row).
    func receiptPresenter(receipt: Binding<Data?>, request: Binding<ReceiptRequest?>, isPreparing: Binding<Bool>) -> some View {
        modifier(ReceiptPresenter(receipt: receipt, request: request, isPreparing: isPreparing))
    }
}

private struct ReceiptPresenter: ViewModifier {
    @Binding var receipt: Data?
    @Binding var request: ReceiptRequest?
    @Binding var isPreparing: Bool
    @State private var pickerItem: PhotosPickerItem?

    func body(content: Content) -> some View {
        content
            .photosPicker(
                isPresented: Binding(
                    get: { request == .library },
                    set: { if !$0, request == .library { request = nil } }
                ),
                selection: $pickerItem,
                matching: .images
            )
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                pickerItem = nil
                isPreparing = true
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    await use(data.flatMap(UIImage.init(data:)))
                }
            }
            .fullScreenCover(item: Binding(
                get: { request == .library ? nil : request },
                set: { request = $0 }
            )) { which in
                switch which {
                case .camera:
                    ReceiptCamera { image in
                        request = nil
                        guard let image else { return }
                        isPreparing = true
                        Task { await use(image) }
                    }
                    .ignoresSafeArea()
                case .viewer:
                    ReceiptViewer(data: receipt)
                case .library:
                    EmptyView()
                }
            }
    }

    private func use(_ image: UIImage?) async {
        defer { isPreparing = false }
        guard let image else { return }
        let data = await Task.detached(priority: .userInitiated) { ReceiptImage.jpeg(from: image) }.value
        withAnimation { receipt = data }
    }
}

/// Receipts are kept as JPEGs no larger than they need to be to read the small print.
nonisolated enum ReceiptImage {
    static let longestSide: CGFloat = 2000

    static func jpeg(from image: UIImage) -> Data? {
        let size = image.size
        let scale = min(1, longestSide / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.75)
    }
}

// MARK: - Camera

/// The document scanner when the device has it (finds and straightens the receipt), otherwise
/// the plain camera. Calls back with the photo, or nil when cancelled.
private struct ReceiptCamera: UIViewControllerRepresentable {
    var done: (UIImage?) -> Void

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> UIViewController {
        if VNDocumentCameraViewController.isSupported {
            let scanner = VNDocumentCameraViewController()
            scanner.delegate = context.coordinator
            return scanner
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        /// The scanner can report more than once (save, then dismiss); only the first counts.
        private var finished = false

        init(done: @escaping (UIImage?) -> Void) {
            self.done = done
        }

        private func finish(_ image: UIImage?) {
            guard !finished else { return }
            finished = true
            done(image)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            // A receipt is one page; a long one scanned in parts keeps the first.
            finish(scan.pageCount > 0 ? scan.imageOfPage(at: 0) : nil)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            finish(nil)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            finish(nil)
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            finish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            finish(nil)
        }
    }
}

// MARK: - Viewer

/// The receipt full screen: pinch to zoom, double-tap to zoom in or out, share it.
private struct ReceiptViewer: View {
    var data: Data?

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                if let image {
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: proxy.size.width * zoom, height: proxy.size.height * zoom)
                    }
                    .defaultScrollAnchor(.center)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in zoom = min(max(lastZoom * value.magnification, 1), 5) }
                            .onEnded { _ in lastZoom = zoom }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.snappy) { zoom = zoom > 1 ? 1 : 2.5 }
                        lastZoom = zoom
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.black)
            .navigationTitle("Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton("Close") { dismiss() }
                }
                if let image {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("Receipt", image: Image(uiImage: image)))
                    }
                }
            }
        }
        .task {
            guard let data else { return }
            image = await Task.detached(priority: .userInitiated) { UIImage(data: data) }.value
        }
    }
}
