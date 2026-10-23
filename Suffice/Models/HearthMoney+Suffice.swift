import Foundation

// Suffice's records as HearthMoney's values. HearthMoney (Services/Hearth/HearthMoney.swift,
// from ~/Developer/hearthkit) holds the budget and bill math and the Ask answers that Ember uses
// too; BudgetMath calls it, so Suffice and Ember can't disagree about a number.

extension EntryRecord {
    nonisolated var money: HearthMoney.Entry {
        HearthMoney.Entry(id: id, date: date, payee: payee, amountCents: amountCents, isIncome: kind == .income,
                          categoryID: categoryID, memberID: memberID, billID: billID, billDueDate: billDueDate,
                          splits: splits.map { HearthMoney.Part(categoryID: $0.categoryID, amountCents: $0.amountCents) },
                          stashCents: stashCents)
    }
}

extension CategoryRecord {
    nonisolated var money: HearthMoney.Category {
        HearthMoney.Category(id: id, name: name, limitCents: limitCents, parentID: parentID, startMonth: startMonth,
                             repeatsMonthly: repeatsMonthly, isArchived: isArchived, sortOrder: sortOrder)
    }
}

extension BillRecord {
    nonisolated var money: HearthMoney.Bill {
        HearthMoney.Bill(id: id, name: name, amountCents: amountCents, dueDay: dueDay,
                         frequency: HearthMoney.Bill.Frequency(rawValue: frequency.rawValue) ?? .monthly,
                         interval: interval, startDate: startDate, endDate: endDate, isAutopay: isAutopay)
    }
}

extension MonthSpan {
    nonisolated var money: HearthMoney.Span { HearthMoney.Span(start: start, end: end) }
}
