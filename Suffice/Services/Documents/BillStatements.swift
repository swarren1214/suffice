import Foundation
import OSLog
import SwiftData
import UIKit

/// Bills as they arrive: a PDF or photo shared to Suffice, a scanned paper bill, or a bill found
/// in a connected mailbox. Each is read on the device and saved as a `BillStatement` for its
/// bill, waiting on Bills for someone to look it over.
@MainActor
enum BillStatements {
    private static let log = Logger(subsystem: "com.stephenwarren.suffice", category: "statements")

    /// Reads a bill and saves it as a new statement (not yet reviewed). Its bill is the one
    /// whose name matches who it's from; without one it waits for someone to pick. Saves.
    @discardableResult
    static func add(_ data: Data, type: String, fileName: String, sender: String = "", source: StatementSource, emailID: String = "", reading: ReadDocument? = nil, in context: ModelContext) async throws -> BillStatement {
        let read: ReadDocument
        if let reading {
            read = reading
        } else {
            let text = try await DocumentReader.text(of: data, type: type)
            read = try await DocumentReader.read(text, context: sender.isEmpty ? "" : "From: \(sender)")
        }
        let bills = ((try? context.fetch(FetchDescriptor<Bill>())) ?? []).filter(\.isActive)
        let bill = StatementMath.bill(named: read.merchant.isEmpty ? sender : read.merchant, in: bills.map(\.record))
            ?? StatementMath.bill(named: sender, in: bills.map(\.record))
        let due = read.date
            ?? bill.flatMap { BudgetMath.nextDue(of: $0) }
            ?? Calendar.current.date(byAdding: .day, value: 14, to: .now)
            ?? .now
        let statement = BillStatement(billID: bill?.id, amountCents: read.totalCents, dueDate: due, source: source)
        statement.periodStart = read.periodStart
        statement.periodEnd = read.periodEnd
        statement.charges = read.lines
        statement.sender = sender.isEmpty ? read.merchant : sender
        statement.fileName = fileName
        statement.documentData = data
        statement.documentType = type
        statement.emailID = emailID
        context.insert(statement)
        try? context.save()
        log.info("Read a bill")
        return statement
    }

    /// A statement already saved for this email, so it's never read twice.
    static func exists(emailID: String, in context: ModelContext) -> Bool {
        guard !emailID.isEmpty else { return false }
        let descriptor = FetchDescriptor<BillStatement>(predicate: #Predicate { $0.emailID == emailID })
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    static func records(in context: ModelContext) -> [StatementRecord] {
        ((try? context.fetch(FetchDescriptor<BillStatement>())) ?? []).map(\.record)
    }

    /// What's due on one due date of a bill: its statement's amount, or the bill's.
    static func amount(for bill: Bill, dueOn due: Date, in context: ModelContext) -> Int {
        StatementMath.amount(for: bill.record, dueOn: due, statements: records(in: context))
    }
}

/// A file opened in Suffice (Share › Suffice, or Open in Suffice from Files or Mail), waiting
/// to be read as a bill.
struct IncomingDocument: Identifiable, Equatable {
    let id = UUID()
    var data: Data
    /// "pdf" or "jpeg".
    var type: String
    var fileName: String

    /// A PDF or an image from a file the system handed over. Images become JPEGs.
    static func load(_ url: URL) -> IncomingDocument? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Files opened in Suffice are copied to Documents/Inbox; once read, the copy goes.
        if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
        let name = url.lastPathComponent
        if url.pathExtension.lowercased() == "pdf" || data.starts(with: Array("%PDF".utf8)) {
            return IncomingDocument(data: data, type: "pdf", fileName: name)
        }
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.8) else { return nil }
        return IncomingDocument(data: jpeg, type: "jpeg", fileName: name)
    }
}
