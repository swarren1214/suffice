import Foundation
import FoundationModels
import OSLog
import SwiftData

/// Shares the family's grocery receipts with BigTable, so a shop can be put away in its pantry
/// (HearthReceipts, through the Hearth app group). Only receipts on grocery charges are read:
/// those in a groceries budget, ones the bank calls groceries, or from a grocery store. Each is
/// read once on the device (Vision for the text, Apple's on-device model for the items) and
/// remembered, so nothing is read twice and nothing leaves the device.
enum GroceryReceipts {
    private static let log = Logger(subsystem: "com.stephenwarren.suffice", category: "grocery-receipts")
    private static let days = 30
    /// Reading takes a few seconds each: a handful per visit keeps it out of the way.
    private static let readsPerRun = 3

    private static let grocers = [
        "costco", "walmart", "kroger", "safeway", "aldi", "trader joe", "whole foods", "target", "smith's", "smiths",
        "sam's club", "sams club", "winco", "publix", "h-e-b", "heb", "wegmans", "albertsons", "sprouts", "instacart",
        "harmons", "fred meyer", "ralphs", "food lion", "meijer", "hy-vee", "giant", "stop & shop", "market basket",
    ]

    private static var isRunning = false

    /// Reads any new grocery receipts and shares the last 30 days. Safe to call often.
    @MainActor
    static func refresh(in context: ModelContext, now: Date = .now) async {
        guard !ScreenshotMode.isOn, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let since = now.addingTimeInterval(-Double(days) * 86_400)
        let entries = ((try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.date > since }))) ?? [])
            .filter { $0.kindRaw == EntryKind.expense.rawValue && $0.receiptData != nil }
        let categories = (try? context.fetch(FetchDescriptor<BudgetCategory>())) ?? []
        let groceryParents = Set(categories.filter { BigTableGroceries.isGroceries($0.name) }.map(\.id))
        let groceryIDs = groceryParents.union(categories.filter { $0.parentID.map { groceryParents.contains($0) } ?? false }.map(\.id))
        let grocery = entries.filter { entry in
            if let id = entry.categoryID, groceryIDs.contains(id) { return true }
            if (entry.bankCategory ?? "").uppercased().contains("GROCER") { return true }
            let payee = entry.payee.lowercased()
            return grocers.contains { payee.contains($0) }
        }

        var cache = ReceiptCache.load()
        var reads = 0
        if OnDeviceModel.availability == .available {
            for entry in grocery.sorted(by: { $0.date > $1.date }) where reads < readsPerRun {
                guard let data = entry.receiptData else { continue }
                let key = entry.id.uuidString
                guard cache.readings[key]?.size != data.count else { continue }
                reads += 1
                if let lines = await read(data, store: entry.payee) {
                    cache.readings[key] = ReceiptCache.Reading(size: data.count, lines: lines)
                } else {
                    // Don't try a receipt that couldn't be read again until it changes.
                    cache.readings[key] = ReceiptCache.Reading(size: data.count, lines: [])
                }
            }
        }

        let ids = Set(grocery.map { $0.id.uuidString })
        cache.readings = cache.readings.filter { ids.contains($0.key) }
        cache.save()

        let receipts: [HearthReceipt] = grocery.compactMap { entry in
            guard let lines = cache.readings[entry.id.uuidString]?.lines, !lines.isEmpty else { return nil }
            return HearthReceipt(
                id: entry.id.uuidString,
                store: entry.payee,
                purchasedAt: entry.date,
                total: Double(entry.amountCents) / 100,
                source: entry.receiptSourceRaw == "email" ? "email" : "photo",
                lines: lines
            )
        }
        .sorted { $0.purchasedAt > $1.purchasedAt }
        if receipts.isEmpty {
            Hearth.remove(HearthReceipts.self, from: .suffice)
        } else {
            Hearth.publish(HearthReceipts(receipts: receipts), from: .suffice)
        }
    }

    /// The items on a receipt photo: what each is, how much, and whether it's food.
    private static func read(_ data: Data, store: String) async -> [HearthReceiptLine]? {
        guard let text = try? await ReceiptText.lines(from: data), text.count >= 2 else { return nil }
        let session = LanguageModelSession(instructions: """
            You read grocery receipts for a family's pantry app. For each item bought, give the line as \
            printed, a plain shopping name ("Eggs", "Shredded mozzarella", "Paper towels"), its price, \
            how much in all when the line says (a 24 count is 24 each; "10#" or "10 LB" is 10 lb; two \
            of a 24 count is 48 each), the unit, and whether it's food or drink. Leave out subtotal, \
            tax, total, savings, coupons, deposits, payment and change lines.
            """)
        do {
            let response = try await session.respond(
                to: "Store: \(store)\nReceipt:\n" + text.prefix(90).joined(separator: "\n"),
                generating: GroceryReceiptReading.self,
                options: GenerationOptions(temperature: 0.1)
            )
            return response.content.items.compactMap { item in
                let raw = item.raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty || !name.isEmpty else { return nil }
                let unit = item.unit?.trimmingCharacters(in: .whitespaces).lowercased()
                return HearthReceiptLine(
                    raw: raw.isEmpty ? name.uppercased() : raw,
                    price: item.price > 0 ? item.price : nil,
                    name: name.isEmpty ? raw : name,
                    quantity: item.quantity.flatMap { $0 > 0 ? $0 : nil },
                    unit: (unit?.isEmpty ?? true) ? nil : unit,
                    isFood: item.isFood
                )
            }
        } catch {
            log.notice("Couldn't read a grocery receipt: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// Receipts already read, by transaction, so each is read once. Application Support, this
/// device only.
nonisolated private struct ReceiptCache: Codable {
    nonisolated struct Reading: Codable {
        /// The receipt's size when read: a new photo means a new reading.
        var size: Int
        var lines: [HearthReceiptLine]
    }

    var readings: [String: Reading] = [:]

    private static var url: URL {
        URL.applicationSupportDirectory.appending(path: "grocery-receipts.json", directoryHint: .notDirectory)
    }

    static func load() -> ReceiptCache {
        guard let data = try? Data(contentsOf: url), let cache = try? JSONDecoder().decode(ReceiptCache.self, from: data) else { return ReceiptCache() }
        return cache
    }

    func save() {
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

@Generable
nonisolated struct GroceryReceiptReading {
    @Guide(description: "Each item bought, in the receipt's order")
    var items: [GroceryReceiptItem]
}

@Generable
nonisolated struct GroceryReceiptItem {
    @Guide(description: "The line as printed, like \"KS ORG EGGS 24CT\"")
    var raw: String
    @Guide(description: "A plain shopping name, like \"Eggs\"")
    var name: String
    @Guide(description: "The price in dollars")
    var price: Double
    @Guide(description: "How much in all, when the line says")
    var quantity: Double?
    @Guide(description: "The unit for the quantity: each, lb, oz, gal, qt, can, jar or bag")
    var unit: String?
    @Guide(description: "True for food and drink, false for paper goods, cleaning, batteries and the like")
    var isFood: Bool
}
