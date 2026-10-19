import Foundation
import Observation
import OSLog
import SwiftData

/// Receipts from Email's choices, on this device.
nonisolated enum EmailSettingsKey {
    /// Attach a receipt on its own when the match is sure (same amount, store and day).
    static let attachWhenSure = "email.attachWhenSure"
    /// Read bills too, and save them as statements on Bills.
    static let findBills = "email.findBills"
    /// How many days back to look, the first time and for receipts waiting on the bank.
    static let lookBackDays = "email.lookBackDays"
    /// When a mailbox was last read all the way through.
    static func lastScan(_ provider: MailProvider) -> String { "email.lastScan.\(provider.rawValue)" }
    /// When any mailbox was last checked, for "Checked 2 hours ago".
    static let lastCheck = "email.lastCheck"
}

/// Finds receipts and bills in the connected mailboxes and puts them where they belong: each
/// receipt on the transaction it paid for (`ReceiptMatcher`), each bill on Bills as a statement.
/// Every message is read on this device; a message is read once (`FoundReceipt` and
/// `BillStatement.emailID` remember it).
@Observable
final class ReceiptScanner {
    static let shared = ReceiptScanner()

    private(set) var isScanning = false
    /// What the last scan ran into, for the Email Receipts screen.
    private(set) var problem: String?
    /// "Reading 12 of 40"
    private(set) var progress: String?

    @ObservationIgnored private let log = Logger(subsystem: "com.stephenwarren.suffice", category: "receipts")
    @ObservationIgnored private let defaults = UserDefaults.standard

    /// The most messages read in one scan: each takes the on-device model a moment.
    static let perScan = 60
    /// The most message IDs asked for at once (cheap; only the unread are opened).
    static let searchLimit = 500
    /// Receipts wait this long for their transaction.
    static let waitDays = 30

    private init() {}

    var attachWhenSure: Bool { defaults.object(forKey: EmailSettingsKey.attachWhenSure) as? Bool ?? true }
    var findsBills: Bool { defaults.object(forKey: EmailSettingsKey.findBills) as? Bool ?? true }
    var lookBackDays: Int { (defaults.object(forKey: EmailSettingsKey.lookBackDays) as? Int).map { max($0, 7) } ?? 90 }
    /// When the mailboxes were last checked.
    var lastScan: Date? { defaults.object(forKey: EmailSettingsKey.lastCheck) as? Date }

    private func lastScan(_ provider: MailProvider) -> Date? {
        defaults.object(forKey: EmailSettingsKey.lastScan(provider)) as? Date
    }

    /// Reads the mailboxes when it's been a few hours (opening the app).
    func scanIfStale(in context: ModelContext) async {
        guard MailAccounts.shared.isConnected, !ScreenshotMode.isOn else { return }
        if let lastScan, Date.now.timeIntervalSince(lastScan) < 6 * 3_600 {
            rematch(in: context)
            return
        }
        await scan(in: context)
    }

    /// Reads new messages from every connected mailbox, then matches what's waiting.
    func scan(in context: ModelContext) async {
        guard !isScanning, DocumentReader.isAvailable else {
            if !DocumentReader.isAvailable { problem = OnDeviceModel.availability.message }
            return
        }
        isScanning = true
        problem = nil
        defer {
            isScanning = false
            progress = nil
        }
        let started = Date.now
        for provider in MailProvider.allCases where MailAccounts.shared.connected[provider] != nil {
            // Since this mailbox was last read through (a day's overlap), or as far back as
            // chosen the first time. Messages already read are skipped (`seen`).
            let since = lastScan(provider).map { $0.addingTimeInterval(-86_400) }
                ?? Calendar.current.date(byAdding: .day, value: -lookBackDays, to: .now)
                ?? .now
            do {
                let token = try await MailAccounts.shared.accessToken(for: provider)
                let ids = try await MailClient.search(provider, since: since, limit: Self.searchLimit, accessToken: token)
                let unread = ids.filter { !seen($0, provider: provider, in: context) }
                let fresh = unread.prefix(Self.perScan)
                var allRead = unread.count <= Self.perScan && ids.count < Self.searchLimit
                for (index, id) in fresh.enumerated() {
                    progress = "Reading \(index + 1) of \(fresh.count)"
                    do {
                        let message = try await MailClient.message(provider, id: id, accessToken: token)
                        let saved = await take(message, in: context)
                        if !saved { allRead = false }
                    } catch {
                        allRead = false
                        log.error("Couldn't read a message: \(error.localizedDescription, privacy: .public)")
                    }
                }
                // Only moves forward once nothing is left behind; the rest waits for next time.
                if allRead { defaults.set(started, forKey: EmailSettingsKey.lastScan(provider)) }
            } catch {
                problem = error.localizedDescription
                log.error("Scanning \(provider.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        defaults.set(Date.now, forKey: EmailSettingsKey.lastCheck)
        rematch(in: context)
    }

    // MARK: One message

    /// Reads one message and saves what it is: a bill, a receipt, or (so it isn't read again)
    /// nothing. False when the model couldn't read it just now, so it's tried again next time.
    private func take(_ message: MailMessage, in context: ModelContext) async -> Bool {
        let found = FoundReceipt(provider: message.provider.rawValue, messageID: message.id)
        found.subject = message.subject
        found.sender = message.sender
        found.receivedAt = message.date
        found.webLink = message.webLink
        found.paidOn = message.date

        // A PDF attached is usually the receipt or the bill itself; else the email's body.
        var pdfText = ""
        if let pdf = message.pdfs.first {
            pdfText = (try? await DocumentReader.text(of: pdf.data, type: "pdf")) ?? ""
        }
        let body = message.plainText
        let text = pdfText.count > 80 ? pdfText : body
        // Marketing that slipped through the search has no amount to read.
        guard text.range(of: "\\$\\s?[0-9]", options: .regularExpression) != nil else {
            found.status = .dismissed
            context.insert(found)
            try? context.save()
            return true
        }
        let reading: ReadDocument
        do {
            reading = try await DocumentReader.read(text, context: "From: \(message.sender)\nSubject: \(message.subject)", today: message.date)
        } catch DocumentReader.Failure.unavailable {
            // The model is off or still downloading: not saved, so it's read next time.
            return false
        } catch {
            // Nothing the model could read (or it declined): don't try this one again.
            found.status = .dismissed
            context.insert(found)
            try? context.save()
            return true
        }

        switch reading.kind {
        case .bill where findsBills:
            let document: (data: Data, type: String, name: String)?
            if let pdf = message.pdfs.first {
                document = (pdf.data, "pdf", pdf.name)
            } else if let rendered = await DocumentImage.pdf(fromHTML: Self.html(of: message)) {
                document = (rendered, "pdf", "\(message.subject.isEmpty ? "Bill" : message.subject).pdf")
            } else {
                document = nil
            }
            if let document, !BillStatements.exists(emailID: message.id, in: context) {
                _ = try? await BillStatements.add(document.data, type: document.type, fileName: document.name, sender: message.sender, source: .email, emailID: message.id, reading: reading, in: context)
            }
            // Remembered as seen; the bill lives on as a statement.
            found.merchant = reading.merchant
            found.totalCents = reading.totalCents
            found.status = .dismissed
            found.reason = "A bill"
        case .receipt where reading.totalCents > 0:
            found.merchant = reading.merchant.isEmpty ? message.sender : reading.merchant
            found.totalCents = reading.totalCents
            found.paidOn = reading.date ?? message.date
            found.status = .waiting
            if let pdf = message.pdfs.first {
                found.imageData = await DocumentImage.jpegInBackground(fromPDF: pdf.data)
            } else if let rendered = await DocumentImage.pdf(fromHTML: Self.html(of: message)) {
                found.imageData = await DocumentImage.jpegInBackground(fromPDF: rendered)
            }
        default:
            found.status = .dismissed
        }
        context.insert(found)
        try? context.save()
        return true
    }

    /// The email as HTML; a plain-text one is escaped so it shows as written.
    private static func html(of message: MailMessage) -> String {
        guard message.html.isEmpty else { return message.html }
        let escaped = message.text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<pre style=\"white-space: pre-wrap; font: 14px -apple-system\">\(escaped)</pre>"
    }

    private func seen(_ id: String, provider: MailProvider, in context: ModelContext) -> Bool {
        let name = provider.rawValue
        let descriptor = FetchDescriptor<FoundReceipt>(predicate: #Predicate { $0.messageID == id && $0.provider == name })
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0 || BillStatements.exists(emailID: id, in: context)
    }

    // MARK: Matching

    /// Matches the receipts waiting (or still to check) against the transactions now in the
    /// budget: sure matches attach (when that's on), close ones wait to be checked, and receipts
    /// with nothing after 30 days stop waiting. No network. Saves.
    func rematch(in context: ModelContext, calendar: Calendar = .current) {
        let open = ((try? context.fetch(FetchDescriptor<FoundReceipt>())) ?? [])
            .filter { $0.status == .waiting || $0.status == .check }
        guard !open.isEmpty else { return }
        let start = calendar.date(byAdding: .day, value: -(lookBackDays + ReceiptMatcher.daysAfter), to: .now) ?? .distantPast
        let entries = (try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.date >= start }))) ?? []
        // Transactions that already have a receipt aren't matched again. (Asked of the store,
        // so the receipt images themselves aren't loaded.)
        let withReceipts = (try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.date >= start && $0.receiptData != nil }))) ?? []
        var taken = Set(withReceipts.map(\.id))
        let records = entries.map(\.record)
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for found in open.sorted(by: { $0.paidOn < $1.paidOn }) {
            switch ReceiptMatcher.match(found.candidate, entries: records, taken: taken, calendar: calendar) {
            case .sure(let id):
                if attachWhenSure, let entry = byID[id] {
                    attach(found, to: entry)
                    taken.insert(id)
                } else {
                    found.status = .check
                    found.entryID = id
                    found.reason = "Same amount, store and day"
                }
            case .check(let id, let reason):
                found.status = .check
                found.entryID = id
                found.reason = reason.text
            case .none:
                found.entryID = nil
                found.status = found.paidOn < (calendar.date(byAdding: .day, value: -Self.waitDays, to: .now) ?? .distantPast) ? .dismissed : .waiting
            }
        }
        try? context.save()
    }

    /// Puts a receipt on its transaction. Doesn't save.
    func attach(_ found: FoundReceipt, to entry: LedgerEntry) {
        if let image = found.imageData { entry.receiptData = image }
        entry.receiptSourceRaw = "email"
        entry.receiptLink = found.webLink
        found.entryID = entry.id
        found.status = .attached
        found.reason = ""
    }

    /// "Not This One": it goes back to waiting for a different transaction, or away.
    func reject(_ found: FoundReceipt, in context: ModelContext) {
        found.status = .dismissed
        found.entryID = nil
        try? context.save()
    }

    /// Takes a receipt back off its transaction; it won't be attached again. Doesn't save.
    func detach(from entry: LedgerEntry, in context: ModelContext) {
        let id: UUID? = entry.id
        let found = (try? context.fetch(FetchDescriptor<FoundReceipt>(predicate: #Predicate { $0.entryID == id }))) ?? []
        for receipt in found {
            receipt.status = .dismissed
            receipt.entryID = nil
        }
        entry.receiptData = nil
        entry.receiptSourceRaw = ""
        entry.receiptLink = ""
    }

    /// Forgets everything read from the mailboxes (Disconnect All). Receipts already attached
    /// stay on their transactions.
    func forgetFound(in context: ModelContext) {
        for found in (try? context.fetch(FetchDescriptor<FoundReceipt>())) ?? [] {
            context.delete(found)
        }
        for provider in MailProvider.allCases {
            defaults.removeObject(forKey: EmailSettingsKey.lastScan(provider))
        }
        defaults.removeObject(forKey: EmailSettingsKey.lastCheck)
        try? context.save()
    }
}
