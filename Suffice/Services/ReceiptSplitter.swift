import Foundation
import FoundationModels
import OSLog
import UIKit
import Vision

/// Split From This Receipt: reads a receipt photo on the device and suggests how its charge
/// splits across budgets. Vision reads the text; Apple's on-device model sorts each item into
/// one of the household's budgets; the item prices are added up per budget and scaled to the
/// charge, so tax and discounts are spread by size (SplitMath.fromItems). Nothing leaves the
/// device. The person checks and changes the suggestion before saving it.
enum ReceiptSplitter {
    nonisolated enum Failure: LocalizedError, Sendable {
        case unavailable(String)
        case unreadable
        case noItems
        case failed

        var errorDescription: String? {
            switch self {
            case .unavailable(let message): message
            case .unreadable: "Suffice couldn’t read this receipt. Try scanning it again in good light."
            case .noItems: "Suffice couldn’t find the items on this receipt. You can still split it by hand."
            case .failed: "Suffice couldn’t suggest a split just now. You can still split it by hand."
            }
        }
    }

    private static let log = Logger(subsystem: "com.stephenwarren.suffice", category: "receipt-split")

    /// Whether the suggestion can run here.
    static var isAvailable: Bool { OnDeviceModel.availability == .available }

    /// Suggested parts for a charge of `totalCents`, from its receipt photo.
    static func suggest(receipt: Data, totalCents: Int, categories: [BudgetCategory]) async throws -> [EntrySplit] {
        let availability = OnDeviceModel.availability
        guard availability == .available else { throw Failure.unavailable(availability.message) }

        let lines = try await ReceiptText.lines(from: receipt)
        guard lines.count >= 2 else { throw Failure.unreadable }

        // The budgets to choose from, by the name the model sees: "Food › Groceries".
        let live = categories.filter { !$0.isArchived }
        var choices: [(name: String, id: UUID)] = []
        for parent in live.filter({ $0.parentID == nil }).sorted(by: { $0.sortOrder < $1.sortOrder }) {
            choices.append((parent.name, parent.id))
            for child in live.filter({ $0.parentID == parent.id }).sorted(by: { $0.sortOrder < $1.sortOrder }) {
                choices.append(("\(parent.name) › \(child.name)", child.id))
            }
        }
        guard !choices.isEmpty else { throw Failure.noItems }

        let session = LanguageModelSession(instructions: """
            You sort the items on a store receipt into a household's budgets. Use only the budget \
            names you're given, exactly as written, and prefer a subcategory ("Food › Groceries") \
            when one fits. Read each item's price from the receipt. Leave out subtotal, tax, \
            total, savings, payment, card and change lines.
            """)
        // The model's window is small: the first lines of a long receipt carry the items.
        let receiptText = lines.prefix(90).joined(separator: "\n")
        let prompt = """
            Budgets:
            \(choices.map { "- \($0.name)" }.joined(separator: "\n"))

            Receipt:
            \(receiptText)
            """
        let reading: ReceiptReading
        do {
            reading = try await session.respond(to: prompt, generating: ReceiptReading.self, options: GenerationOptions(temperature: 0.1)).content
        } catch {
            log.error("Receipt split failed: \(String(describing: error), privacy: .public)")
            throw Failure.failed
        }

        let items: [(categoryID: UUID?, cents: Int)] = reading.items.compactMap { item in
            let cents = Int((item.price * 100).rounded())
            guard cents > 0 else { return nil }
            return (match(item.budget, in: choices), cents)
        }
        let parts = SplitMath.fromItems(items, total: totalCents)
        guard !parts.isEmpty else { throw Failure.noItems }
        return parts
    }

    /// The budget a name the model gave means: exact, then ignoring case and spacing, then the
    /// subcategory or budget name on its own.
    private static func match(_ name: String, in choices: [(name: String, id: UUID)]) -> UUID? {
        func key(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .filter { $0.isLetter || $0.isNumber }
        }
        let wanted = key(name)
        guard !wanted.isEmpty else { return nil }
        if let exact = choices.first(where: { key($0.name) == wanted }) { return exact.id }
        // "Groceries" for "Food › Groceries".
        if let last = choices.first(where: { key($0.name.components(separatedBy: "›").last ?? "") == wanted }) { return last.id }
        return choices.first { key($0.name).contains(wanted) || wanted.contains(key($0.name)) }?.id
    }
}

@Generable
nonisolated struct ReceiptReading {
    @Guide(description: "Each item bought, in the receipt's order. Leave out subtotal, tax, total, savings, payment and change lines.")
    var items: [ReceiptItemReading]
}

@Generable
nonisolated struct ReceiptItemReading {
    @Guide(description: "The item as printed, for example \"KS PAPER TOWEL\"")
    var name: String

    @Guide(description: "The item's price in dollars, for example 18.99")
    var price: Double

    @Guide(description: "The budget it belongs in: exactly one of the budget names given")
    var budget: String
}

/// The text of a receipt photo, a line at a time, read on the device.
nonisolated enum ReceiptText {
    /// Lines top to bottom. Vision reads an item's name and its price as separate pieces of
    /// text, so pieces at the same height are joined into one line, left to right.
    static func lines(from data: Data) async throws -> [String] {
        guard let image = UIImage(data: data)?.cgImage else { return [] }
        // Off the main thread: reading a full-size photo takes a moment.
        let observations: [VNRecognizedTextObservation] = try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            return request.results ?? []
        }.value

        // Vision's boxes run 0…1 from the bottom left; sort top to bottom, then group by height.
        let pieces = observations.compactMap { observation -> (y: CGFloat, x: CGFloat, height: CGFloat, text: String)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return (box.midY, box.minX, box.height, text)
        }.sorted { $0.y > $1.y }

        var rows: [[(y: CGFloat, x: CGFloat, height: CGFloat, text: String)]] = []
        for piece in pieces {
            if let last = rows.last?.first, abs(last.y - piece.y) < max(last.height, piece.height) * 0.6 {
                rows[rows.count - 1].append(piece)
            } else {
                rows.append([piece])
            }
        }
        return rows.map { row in row.sorted { $0.x < $1.x }.map(\.text).joined(separator: "  ") }
    }
}
