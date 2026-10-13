import Foundation

/// Categories, members and accounts by ID, built once per view update from @Query results.
struct Lookup {
    var categories: [UUID: BudgetCategory]
    var members: [UUID: Member]
    var accounts: [UUID: Account]

    init(categories: [BudgetCategory] = [], members: [Member] = [], accounts: [Account] = []) {
        self.categories = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.members = Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.accounts = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func category(_ id: UUID?) -> BudgetCategory? { id.flatMap { categories[$0] } }
    func member(_ id: UUID?) -> Member? { id.flatMap { members[$0] } }
    func account(_ id: UUID?) -> Account? { id.flatMap { accounts[$0] } }

    /// The top-level budget for a category or subcategory.
    func budget(for id: UUID?) -> BudgetCategory? {
        guard let category = category(id) else { return nil }
        return category.parentID.flatMap { categories[$0] } ?? category
    }

    /// The subcategory, when the ID is one.
    func subcategory(for id: UUID?) -> BudgetCategory? {
        guard let category = category(id), category.parentID != nil else { return nil }
        return category
    }
}
