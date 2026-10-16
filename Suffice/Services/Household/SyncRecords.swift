import CloudKit
import Foundation
import SwiftData

/// A model that household sync carries to CloudKit, one record per model. Records are named
/// "<Type>.<uuid>" so a record ID alone says what it is. Every field goes in `encryptedValues`
/// (end-to-end encrypted with the iCloud account's keys); a member's photo is an asset, which
/// CloudKit encrypts on its own.
protocol SyncedModel: PersistentModel {
    static var recordType: String { get }
    var id: UUID { get }
    /// Writes every synced field onto the record.
    func write(to record: CKRecord)
    /// Reads them back. Fields a record doesn't have (from an older version) keep their value.
    func read(from record: CKRecord)
    /// An empty one, to fill from a record.
    static func blank() -> Self
    static func find(_ id: UUID, in context: ModelContext) -> Self?
}

enum SyncRegistry {
    static let types: [any SyncedModel.Type] = [
        Member.self, BudgetCategory.self, LedgerEntry.self, Bill.self, Account.self, LinkedBank.self, PayeeRule.self,
    ]

    static func type(named name: String) -> (any SyncedModel.Type)? {
        types.first { $0.recordType == name }
    }

    static func recordName(type: String, id: UUID) -> String {
        "\(type).\(id.uuidString)"
    }

    /// "LedgerEntry.6F1C…" → ("LedgerEntry", 6F1C…).
    static func parse(_ recordName: String) -> (type: String, id: UUID)? {
        guard let dot = recordName.firstIndex(of: ".") else { return nil }
        let type = String(recordName[..<dot])
        guard let id = UUID(uuidString: String(recordName[recordName.index(after: dot)...])) else { return nil }
        return (type, id)
    }

    /// The record names of everything on this device, for the first upload.
    static func allRecordNames(in context: ModelContext) -> [String] {
        types.flatMap { names(of: $0, in: context) }
    }

    private static func names<T: SyncedModel>(of type: T.Type, in context: ModelContext) -> [String] {
        ((try? context.fetch(FetchDescriptor<T>())) ?? []).map { recordName(type: T.recordType, id: $0.id) }
    }

    /// The model a record name points at, if it's on this device.
    static func model(named recordName: String, in context: ModelContext) -> (any SyncedModel)? {
        guard let parsed = parse(recordName), let type = type(named: parsed.type) else { return nil }
        return find(type, id: parsed.id, in: context)
    }

    private static func find<T: SyncedModel>(_ type: T.Type, id: UUID, in context: ModelContext) -> (any SyncedModel)? {
        T.find(id, in: context)
    }

    /// Creates or updates the local model from a record. Returns false for unknown types.
    @discardableResult
    static func apply(_ record: CKRecord, in context: ModelContext) -> Bool {
        guard let parsed = parse(record.recordID.recordName), let type = type(named: parsed.type) else { return false }
        upsert(type, id: parsed.id, record: record, in: context)
        return true
    }

    private static func upsert<T: SyncedModel>(_ type: T.Type, id: UUID, record: CKRecord, in context: ModelContext) {
        if let existing = T.find(id, in: context) {
            existing.read(from: record)
        } else {
            let model = T.blank()
            model.setID(id)
            model.read(from: record)
            context.insert(model)
        }
    }

    /// Deletes the local model a deleted record stood for.
    static func delete(recordName: String, in context: ModelContext) {
        if let model = model(named: recordName, in: context) {
            context.delete(model)
        }
    }
}

private extension SyncedModel {
    /// Gives a blank model the record's ID. Every synced model's `id` is settable.
    func setID(_ id: UUID) {
        switch self {
        case let model as Member: model.id = id
        case let model as BudgetCategory: model.id = id
        case let model as LedgerEntry: model.id = id
        case let model as Bill: model.id = id
        case let model as Account: model.id = id
        case let model as LinkedBank: model.id = id
        case let model as PayeeRule: model.id = id
        default: assertionFailure("Unknown synced model \(Self.self)")
        }
    }
}

// MARK: - Field helpers

extension CKRecord {
    func text(_ key: String) -> String? { encryptedValues[key] }
    func int(_ key: String) -> Int? { encryptedValues[key] }
    func double(_ key: String) -> Double? { encryptedValues[key] }
    func bool(_ key: String) -> Bool? { encryptedValues[key] }
    func date(_ key: String) -> Date? { encryptedValues[key] }
    func uuid(_ key: String) -> UUID? { text(key).flatMap(UUID.init(uuidString:)) }

    func put(_ key: String, _ value: String?) { encryptedValues[key] = value }
    func put(_ key: String, _ value: Int?) { encryptedValues[key] = value }
    func put(_ key: String, _ value: Double?) { encryptedValues[key] = value }
    func put(_ key: String, _ value: Bool?) { encryptedValues[key] = value }
    func put(_ key: String, _ value: Date?) { encryptedValues[key] = value }
    func put(_ key: String, _ value: UUID?) { encryptedValues[key] = value?.uuidString }
}

/// Member photos go up as CKAssets, which need a file that lasts until the upload finishes.
enum SyncAssetFiles {
    static func url(for id: UUID, kind: String = "photo") -> URL {
        let folder = URL.cachesDirectory.appending(path: "HouseholdAssets", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "\(id.uuidString)-\(kind).jpg")
    }

    /// Writes `data` as the record's asset under `key`, or clears it.
    static func put(_ data: Data?, on record: CKRecord, key: String, id: UUID) {
        if let data {
            let url = url(for: id, kind: key)
            if (try? data.write(to: url, options: .atomic)) != nil {
                record[key] = CKAsset(fileURL: url)
            }
        } else {
            record.setObject(nil, forKey: key)
        }
    }

    /// The bytes of the record's asset under `key`.
    static func data(from record: CKRecord, key: String) -> Data? {
        (record[key] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
    }
}

// MARK: - Models

extension Member: SyncedModel {
    static var recordType: String { "Member" }
    static func blank() -> Member { Member(name: "", color: .green) }
    static func find(_ id: UUID, in context: ModelContext) -> Member? {
        var descriptor = FetchDescriptor<Member>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func write(to record: CKRecord) {
        record.put("name", name)
        record.put("colorRaw", colorRaw)
        record.put("sortOrder", sortOrder)
        record.put("createdAt", createdAt)
        if let photoData {
            let url = SyncAssetFiles.url(for: id)
            if (try? photoData.write(to: url, options: .atomic)) != nil {
                record["photo"] = CKAsset(fileURL: url)
            }
        } else {
            record.setObject(nil, forKey: "photo")
        }
    }

    func read(from record: CKRecord) {
        if let value = record.text("name") { name = value }
        if let value = record.text("colorRaw") { colorRaw = value }
        if let value = record.int("sortOrder") { sortOrder = value }
        if let value = record.date("createdAt") { createdAt = value }
        let photo = (record["photo"] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
        if photo != photoData { photoData = photo }
    }
}

extension BudgetCategory: SyncedModel {
    static var recordType: String { "BudgetCategory" }
    static func blank() -> BudgetCategory { BudgetCategory(name: "", symbol: "house.fill", color: .orange, limitCents: 0) }
    static func find(_ id: UUID, in context: ModelContext) -> BudgetCategory? {
        var descriptor = FetchDescriptor<BudgetCategory>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func write(to record: CKRecord) {
        record.put("name", name)
        record.put("symbol", symbol)
        record.put("colorRaw", colorRaw)
        record.put("limitCents", limitCents)
        record.put("parentID", parentID)
        record.put("startMonth", startMonth)
        record.put("repeatsMonthly", repeatsMonthly)
        record.put("sortOrder", sortOrder)
        record.put("isArchived", isArchived)
        record.put("createdAt", createdAt)
    }

    func read(from record: CKRecord) {
        if let value = record.text("name") { name = value }
        if let value = record.text("symbol") { symbol = value }
        if let value = record.text("colorRaw") { colorRaw = value }
        if let value = record.int("limitCents") { limitCents = value }
        parentID = record.uuid("parentID")
        if let value = record.date("startMonth") { startMonth = value }
        if let value = record.bool("repeatsMonthly") { repeatsMonthly = value }
        if let value = record.int("sortOrder") { sortOrder = value }
        if let value = record.bool("isArchived") { isArchived = value }
        if let value = record.date("createdAt") { createdAt = value }
    }
}

extension LedgerEntry: SyncedModel {
    static var recordType: String { "LedgerEntry" }
    static func blank() -> LedgerEntry { LedgerEntry(payee: "", amountCents: 0) }
    static func find(_ id: UUID, in context: ModelContext) -> LedgerEntry? {
        var descriptor = FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func write(to record: CKRecord) {
        record.put("date", date)
        record.put("payee", payee)
        record.put("amountCents", amountCents)
        record.put("kindRaw", kindRaw)
        record.put("categoryID", categoryID)
        record.put("memberID", memberID)
        record.put("accountID", accountID)
        record.put("note", note)
        record.put("billID", billID)
        record.put("billDueDate", billDueDate)
        record.put("isReviewed", isReviewed)
        record.put("latitude", latitude)
        record.put("longitude", longitude)
        record.put("placeName", placeName)
        record.put("placeAddress", placeAddress)
        record.put("externalID", externalID)
        record.put("logoURL", logoURL)
        record.put("createdAt", createdAt)
        SyncAssetFiles.put(receiptData, on: record, key: "receipt", id: id)
    }

    func read(from record: CKRecord) {
        if let value = record.date("date") { date = value }
        if let value = record.text("payee") { payee = value }
        if let value = record.int("amountCents") { amountCents = value }
        if let value = record.text("kindRaw") { kindRaw = value }
        categoryID = record.uuid("categoryID")
        memberID = record.uuid("memberID")
        accountID = record.uuid("accountID")
        if let value = record.text("note") { note = value }
        billID = record.uuid("billID")
        billDueDate = record.date("billDueDate")
        if let value = record.bool("isReviewed") { isReviewed = value }
        latitude = record.double("latitude")
        longitude = record.double("longitude")
        placeName = record.text("placeName")
        placeAddress = record.text("placeAddress")
        externalID = record.text("externalID")
        logoURL = record.text("logoURL")
        if let value = record.date("createdAt") { createdAt = value }
        let receipt = SyncAssetFiles.data(from: record, key: "receipt")
        if receipt != receiptData { receiptData = receipt }
    }
}

extension Bill: SyncedModel {
    static var recordType: String { "Bill" }
    static func blank() -> Bill { Bill(name: "", amountCents: 0, dueDay: 1) }
    static func find(_ id: UUID, in context: ModelContext) -> Bill? {
        var descriptor = FetchDescriptor<Bill>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func write(to record: CKRecord) {
        record.put("name", name)
        record.put("amountCents", amountCents)
        record.put("isVariable", isVariable)
        record.put("minCents", minCents)
        record.put("maxCents", maxCents)
        record.put("dueDay", dueDay)
        record.put("frequencyRaw", frequencyRaw)
        record.put("interval", interval)
        record.put("startDate", startDate)
        record.put("endDate", endDate)
        record.put("colorRaw", colorRaw)
        record.put("categoryID", categoryID)
        record.put("isAutopay", isAutopay)
        record.put("isSubscription", isSubscription)
        record.put("isActive", isActive)
        record.put("note", note)
        record.put("createdAt", createdAt)
    }

    func read(from record: CKRecord) {
        if let value = record.text("name") { name = value }
        if let value = record.int("amountCents") { amountCents = value }
        if let value = record.bool("isVariable") { isVariable = value }
        minCents = record.int("minCents")
        maxCents = record.int("maxCents")
        if let value = record.int("dueDay") { dueDay = value }
        if let value = record.text("frequencyRaw") { frequencyRaw = value }
        if let value = record.int("interval") { interval = value }
        if let value = record.date("startDate") { startDate = value }
        endDate = record.date("endDate")
        if let value = record.text("colorRaw") { colorRaw = value }
        categoryID = record.uuid("categoryID")
        if let value = record.bool("isAutopay") { isAutopay = value }
        if let value = record.bool("isSubscription") { isSubscription = value }
        if let value = record.bool("isActive") { isActive = value }
        if let value = record.text("note") { note = value }
        if let value = record.date("createdAt") { createdAt = value }
    }
}

extension Account: SyncedModel {
    static var recordType: String { "Account" }
    static func blank() -> Account { Account(institution: "", name: "", kind: .checking, balanceCents: 0) }
    static func find(_ id: UUID, in context: ModelContext) -> Account? {
        var descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func write(to record: CKRecord) {
        record.put("institution", institution)
        record.put("institutionDomain", institutionDomain)
        record.put("name", name)
        record.put("mask", mask)
        record.put("kindRaw", kindRaw)
        record.put("sourceRaw", sourceRaw)
        record.put("balanceCents", balanceCents)
        record.put("balanceDate", balanceDate)
        record.put("includeInBudget", includeInBudget)
        record.put("colorHex", colorHex)
        record.put("plaidItemID", plaidItemID)
        record.put("plaidAccountID", plaidAccountID)
        record.put("sortOrder", sortOrder)
        record.put("createdAt", createdAt)
    }

    func read(from record: CKRecord) {
        if let value = record.text("institution") { institution = value }
        institutionDomain = record.text("institutionDomain")
        if let value = record.text("name") { name = value }
        if let value = record.text("mask") { mask = value }
        if let value = record.text("kindRaw") { kindRaw = value }
        if let value = record.text("sourceRaw") { sourceRaw = value }
        if let value = record.int("balanceCents") { balanceCents = value }
        if let value = record.date("balanceDate") { balanceDate = value }
        if let value = record.bool("includeInBudget") { includeInBudget = value }
        if let value = record.int("colorHex") { colorHex = value }
        plaidItemID = record.text("plaidItemID")
        plaidAccountID = record.text("plaidAccountID")
        if let value = record.int("sortOrder") { sortOrder = value }
        if let value = record.date("createdAt") { createdAt = value }
    }
}

extension LinkedBank: SyncedModel {
    static var recordType: String { "LinkedBank" }
    static func blank() -> LinkedBank { LinkedBank(itemID: "", institution: "", connectedByAppleID: "") }
    static func find(_ id: UUID, in context: ModelContext) -> LinkedBank? {
        var descriptor = FetchDescriptor<LinkedBank>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func write(to record: CKRecord) {
        record.put("itemID", itemID)
        record.put("institution", institution)
        record.put("institutionDomain", institutionDomain)
        record.put("cursor", cursor)
        record.put("lastSynced", lastSynced)
        record.put("needsReconnect", needsReconnect)
        record.put("connectedByAppleID", connectedByAppleID)
        record.put("createdAt", createdAt)
    }

    func read(from record: CKRecord) {
        if let value = record.text("itemID") { itemID = value }
        if let value = record.text("institution") { institution = value }
        institutionDomain = record.text("institutionDomain")
        if let value = record.text("cursor") { cursor = value }
        lastSynced = record.date("lastSynced")
        if let value = record.bool("needsReconnect") { needsReconnect = value }
        if let value = record.text("connectedByAppleID") { connectedByAppleID = value }
        if let value = record.date("createdAt") { createdAt = value }
    }
}

extension PayeeRule: SyncedModel {
    static var recordType: String { "PayeeRule" }
    static func blank() -> PayeeRule { PayeeRule(payee: "", categoryID: nil) }
    static func find(_ id: UUID, in context: ModelContext) -> PayeeRule? {
        var descriptor = FetchDescriptor<PayeeRule>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func write(to record: CKRecord) {
        record.put("payeeKey", payeeKey)
        record.put("categoryID", categoryID)
        record.put("createdAt", createdAt)
    }

    func read(from record: CKRecord) {
        if let value = record.text("payeeKey") { payeeKey = value }
        categoryID = record.uuid("categoryID")
        if let value = record.date("createdAt") { createdAt = value }
    }
}
