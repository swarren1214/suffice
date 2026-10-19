import Foundation
import FoundationModels
import OSLog
import PDFKit
import UIKit
import WebKit

/// What the on-device model read from a bill or a receipt.
@Generable
nonisolated struct DocumentReading {
    @Guide(description: "receipt: something already bought or paid. bill: a statement asking for a payment by a due date. other: neither.", .anyOf(["receipt", "bill", "other"]))
    var kind: String

    @Guide(description: "The business as a person would say it, for example \"Amazon\" or \"Santaquin City Utilities\"")
    var merchant: String

    @Guide(description: "For a receipt, the total paid; for a bill, the amount due now. In dollars, for example 142.86. 0 when it isn't shown.")
    var total: Double

    @Guide(description: "For a receipt, the date it was paid; for a bill, the due date. As YYYY-MM-DD, or empty.")
    var date: String

    @Guide(description: "For a bill, the first day of the service or billing period, as YYYY-MM-DD, or empty")
    var periodStart: String

    @Guide(description: "For a bill, the last day of the service or billing period, as YYYY-MM-DD, or empty")
    var periodEnd: String

    @Guide(description: "A receipt's items or a bill's charges, each with its amount in dollars. Leave out subtotals, totals, tax lines, payments and balances.")
    var lines: [DocumentLine]
}

@Generable
nonisolated struct DocumentLine {
    @Guide(description: "As printed, for example \"Water\" or \"Office visit\"")
    var name: String

    @Guide(description: "In dollars, for example 58.10")
    var amount: Double
}

/// A reading turned into cents and dates.
nonisolated struct ReadDocument: Sendable {
    nonisolated enum Kind: String, Sendable { case receipt, bill, other }

    var kind: Kind
    var merchant: String
    var totalCents: Int
    var date: Date?
    var periodStart: Date?
    var periodEnd: Date?
    var lines: [StatementCharge]
}

/// Reads bills and receipts on the device: the text of a PDF, a photo (Vision) or an email's
/// HTML, then Apple's on-device model for the business, amount, date and lines. Nothing leaves
/// the device.
enum DocumentReader {
    nonisolated enum Failure: LocalizedError, Sendable {
        case unavailable(String)
        case unreadable
        case failed

        var errorDescription: String? {
            switch self {
            case .unavailable(let message): message
            case .unreadable: "Suffice couldn’t find any text in this. Try a clearer scan or the PDF."
            case .failed: "Suffice couldn’t read this just now. You can still fill it in by hand."
            }
        }
    }

    private static let log = Logger(subsystem: "com.stephenwarren.suffice", category: "documents")

    static var isAvailable: Bool { OnDeviceModel.availability == .available }

    /// The text of a PDF (its own text, or Vision on its first pages when it's a scan) or of a
    /// photo.
    static func text(of data: Data, type: String) async throws -> String {
        if type == "pdf" {
            // Parsing and drawing a PDF is slow: off the main thread.
            let own: String? = await Task.detached(priority: .userInitiated) {
                guard let document = PDFDocument(data: data) else { return nil }
                return (0..<min(document.pageCount, 3))
                    .compactMap { document.page(at: $0)?.string }
                    .joined(separator: "\n")
            }.value
            guard let own else { throw Failure.unreadable }
            if own.trimmingCharacters(in: .whitespacesAndNewlines).count > 40 { return own }
            // A scanned PDF: read its first page as a picture.
            guard let image = await DocumentImage.jpegInBackground(fromPDF: data, maxPages: 1) else { throw Failure.unreadable }
            return try await ReceiptText.lines(from: image).joined(separator: "\n")
        }
        return try await ReceiptText.lines(from: data).joined(separator: "\n")
    }

    /// Reads `text` (from a file, a photo or an email). `context` is what's known about where it
    /// came from: an email's sender and subject.
    static func read(_ text: String, context: String = "", today: Date = .now) async throws -> ReadDocument {
        let availability = OnDeviceModel.availability
        guard availability == .available else { throw Failure.unavailable(availability.message) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { throw Failure.unreadable }

        let session = LanguageModelSession(instructions: """
            You read bills and receipts for a household budget. Read amounts exactly as printed. \
            Dates are YYYY-MM-DD; today is \(today.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())), so a \
            date without a year is the nearest one to today. Use the business's everyday name.
            """)
        // The model's window is small; the top of a bill or receipt carries what matters.
        let prompt = """
            \(context.isEmpty ? "" : context + "\n\n")\(String(trimmed.prefix(3_000)))
            """
        let reading: DocumentReading
        do {
            reading = try await session.respond(to: prompt, generating: DocumentReading.self, options: GenerationOptions(temperature: 0.1)).content
        } catch {
            log.error("Reading a document failed: \(String(describing: error), privacy: .public)")
            throw Failure.failed
        }
        return convert(reading)
    }

    nonisolated static func convert(_ reading: DocumentReading) -> ReadDocument {
        func cents(_ dollars: Double) -> Int { Int((dollars * 100).rounded()) }
        return ReadDocument(
            kind: ReadDocument.Kind(rawValue: reading.kind) ?? .other,
            merchant: reading.merchant.trimmingCharacters(in: .whitespacesAndNewlines),
            totalCents: max(cents(reading.total), 0),
            date: EmailText.date(reading.date),
            periodStart: EmailText.date(reading.periodStart),
            periodEnd: EmailText.date(reading.periodEnd),
            lines: reading.lines.compactMap { line in
                let amount = cents(line.amount)
                let name = line.name.trimmingCharacters(in: .whitespaces)
                return amount != 0 && !name.isEmpty ? StatementCharge(name: name, amountCents: amount) : nil
            }
        )
    }
}

/// Bills and receipts as pictures: a PDF's first pages as one JPEG (what a transaction's
/// receipt holds), and an HTML email drawn into a PDF.
enum DocumentImage {
    /// `jpeg(fromPDF:)` off the main thread.
    nonisolated static func jpegInBackground(fromPDF data: Data, maxPages: Int = 2) async -> Data? {
        await Task.detached(priority: .userInitiated) { jpeg(fromPDF: data, maxPages: maxPages) }.value
    }

    /// The first `maxPages` pages, stacked, as a JPEG about 1,200 points wide at most.
    nonisolated static func jpeg(fromPDF data: Data, maxPages: Int = 2) -> Data? {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { return nil }
        let pages = (0..<min(document.pageCount, maxPages)).compactMap { document.page(at: $0) }
        let sizes = pages.map { $0.bounds(for: .mediaBox).size }
        let width = sizes.map(\.width).max() ?? 612
        let scale = min(2, 1_200 / max(width, 1))
        let height = sizes.reduce(0) { $0 + $1.height }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width * scale, height: height * scale), format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: width * scale, height: height * scale)))
            var y: CGFloat = 0
            for (page, size) in zip(pages, sizes) {
                let cg = context.cgContext
                cg.saveGState()
                // PDF pages draw from the bottom left; flip each into its slot.
                cg.translateBy(x: 0, y: (y + size.height) * scale)
                cg.scaleBy(x: scale, y: -scale)
                page.draw(with: .mediaBox, to: cg)
                cg.restoreGState()
                y += size.height
            }
        }
        return image.jpegData(compressionQuality: 0.75)
    }

    /// An HTML email drawn as a PDF by WebKit, off screen. Remote images are blocked (no
    /// tracking pixels load), so receipts are mostly their text and layout.
    @MainActor
    static func pdf(fromHTML html: String) async -> Data? {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 800), configuration: configuration)
        // Nothing from the internet loads: WebKit itself blocks every http(s) request
        // (images, styles, fonts, tracking pixels), whatever the HTML says.
        if let rules = await blockRemoteRules() {
            configuration.userContentController.add(rules)
        }
        let loader = HTMLLoader()
        webView.navigationDelegate = loader
        // Remote images and styles stay off (no tracking pixels): their addresses are taken out
        // before it loads, and there's no base URL for relative ones.
        let quiet = html
            .replacingOccurrences(of: "(src|srcset|background)\\s*=\\s*([\"'])\\s*https?:", with: "data-off-$1=$2http:", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "url\\(\\s*([\"']?)https?:", with: "url($1about:", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<link[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<base[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        webView.loadHTMLString(quiet, baseURL: nil)
        // A page that never finishes (WebKit's process ended) gives up after 10 seconds.
        Task { @MainActor [loader] in
            try? await Task.sleep(for: .seconds(10))
            loader.giveUp()
        }
        guard await loader.finished() else { return nil }
        return try? await webView.pdf(configuration: WKPDFConfiguration())
    }

    /// One content rule: block every http(s) load. Compiled once.
    @MainActor private static var compiledRules: WKContentRuleList?

    @MainActor
    private static func blockRemoteRules() async -> WKContentRuleList? {
        if let compiledRules { return compiledRules }
        let json = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        let list = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "suffice.blockRemote", encodedContentRuleList: json)
        compiledRules = list
        return list
    }

    /// Waits for one page load, and refuses any navigation away from it.
    private final class HTMLLoader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Bool, Never>?
        private var result: Bool?

        func finished() async -> Bool {
            if let result { return result }
            return await withCheckedContinuation { continuation = $0 }
        }

        private func finish(_ value: Bool) {
            guard result == nil else { return }
            result = value
            continuation?.resume(returning: value)
            continuation = nil
        }

        func giveUp() { finish(false) }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(false) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            // The email itself (about:blank) loads; links, refreshes and redirects don't.
            navigationAction.request.url?.scheme == "about" ? .allow : .cancel
        }
    }
}
