import Foundation
import FoundationModels
import OSLog
import SwiftData

// MARK: - Tools

nonisolated struct BudgetsTool: Tool {
    let name = "getBudgets"
    let description = "Gets every budget and subcategory for a month: planned, spent and left."
    let data: AskData

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "0 for this month, 1 for last month", .range(0...12))
        var monthsAgo: Int
    }

    func call(arguments: Arguments) async throws -> String {
        await data.budgetsText(monthsAgo: arguments.monthsAgo)
    }
}

nonisolated struct BudgetTool: Tool {
    let name = "getBudget"
    let description = "Gets one budget in detail: planned, spent, left, its subcategories, biggest payees, and last month at this point."
    let data: AskData

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The budget's name, for example \"Dining Out\" or \"Groceries\"")
        var name: String
        @Guide(description: "0 for this month, 1 for last month", .range(0...12))
        var monthsAgo: Int
    }

    func call(arguments: Arguments) async throws -> String {
        await data.budgetText(named: arguments.name, monthsAgo: arguments.monthsAgo)
    }
}

nonisolated struct BillsTool: Tool {
    let name = "getBills"
    let description = "Gets the bills due in the next days, which are paid, and any that are late."
    let data: AskData

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "How many days ahead: 7 for this week, 30 for the month", .range(1...60))
        var days: Int
    }

    func call(arguments: Arguments) async throws -> String {
        await data.billsText(days: arguments.days)
    }
}

nonisolated struct SpendingTool: Tool {
    let name = "getSpending"
    let description = "Gets where the money went in a month: total spent and income, by budget, and by person."
    let data: AskData

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "0 for this month, 1 for last month", .range(0...12))
        var monthsAgo: Int
    }

    func call(arguments: Arguments) async throws -> String {
        await data.spendingText(monthsAgo: arguments.monthsAgo)
    }
}

nonisolated struct TransactionsTool: Tool {
    let name = "findTransactions"
    let description = "Finds transactions by payee, note or budget, with their total."
    let data: AskData

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "A payee or word to look for, for example \"Costco\" or \"coffee\"")
        var search: String
        @Guide(description: "How many months back to look, 0 for this month only", .range(0...12))
        var monthsBack: Int
    }

    func call(arguments: Arguments) async throws -> String {
        await data.transactionsText(matching: arguments.search, monthsBack: arguments.monthsBack)
    }
}

nonisolated struct AffordTool: Tool {
    let name = "checkAffordability"
    let description = "Gets what's left this month (in budgets, after bills, and cash) to judge whether a purchase fits."
    let data: AskData

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The purchase in whole dollars", .range(1...10_000_000))
        var dollars: Int
    }

    func call(arguments: Arguments) async throws -> String {
        await data.affordabilityText(dollars: arguments.dollars)
    }
}

// MARK: - Replies

@Generable
nonisolated struct AskReply {
    @Guide(description: "The spoken answer: one or two short, conversational sentences, under 35 words, leading with the answer. Amounts come from tool results, rounded to whole dollars.")
    var text: String

    @Guide(description: "When the answer is mainly about one budget, its exact name from the tool results. Otherwise empty.")
    var budget: String

    @Guide(description: "True only when the person asks where the money went or for a spending breakdown.")
    var showsBreakdown: Bool

    @Guide(description: "Only when the person asks to move money from one budget to another: the budget to take it from. Otherwise empty.")
    var moveFrom: String

    @Guide(description: "Only when moving money: the budget to give it to. Otherwise empty.")
    var moveTo: String

    @Guide(description: "Only when moving money: whole dollars to move. Otherwise 0.", .range(0...10_000_000))
    var moveDollars: Int
}

/// One message in the Ask conversation. Cards hold IDs, not numbers: they're drawn from the
/// live data, so they're always right even if the model got a figure wrong.
struct AskMessage: Identifiable, Hashable {
    enum Role { case user, assistant, notice }
    enum TransferState { case proposed, moved, dismissed }

    let id = UUID()
    var role: Role
    var text: String
    /// A budget card: its ring, spent of planned, biggest payees, and Open.
    var budgetID: UUID?
    /// A spending breakdown chart for this month.
    var breakdown: MonthSpan?
    /// A proposed move between budgets, with Move and Not Now.
    var transfer: AskData.Transfer?
    var transferState: TransferState = .proposed
}

/// The Ask conversation, on Apple's on-device model with tools over the household's data.
@Observable
final class AskEngine {
    static let shared = AskEngine()

    private(set) var messages: [AskMessage] = []
    private(set) var isThinking = false
    /// Set by the Ask sheet from the app's model container.
    private(set) var data: AskData?

    private var session: LanguageModelSession?
    private let log = Logger(subsystem: "com.stephenwarren.suffice", category: "ask")

    var availability: OnDeviceModel.Availability { OnDeviceModel.availability }

    func attach(_ container: ModelContainer) {
        guard data?.container !== container else { return }
        data = AskData(container: container)
        session = nil
    }

    static var instructions: String {
        """
        You are Suffice, a friendly money helper for a couple, talking with them out loud. \
        Today is \(Date.now.formatted(date: .complete, time: .omitted)).

        How to answer:
        - Talk like a friend: one or two short sentences, under 35 words. Lead with the answer.
        - No lists, no greetings, no "let me know if…", no repeating the question.
        - Round to whole dollars unless the cents matter. Say "you" for the household.

        Rules:
        - Get every number from a tool first. Never guess an amount.
        - getBudget for one budget, getBudgets for all, getBills for bills, getSpending for where money went, findTransactions for a store or payee, checkAffordability for "can we afford".
        - To move money between budgets, check getBudgets, then fill moveFrom, moveTo and moveDollars. Don't say it's done; they confirm it.
        - No investment, tax, legal or credit advice. Only talk about their money in Suffice.
        """
    }

    func prewarm() {
        guard availability == .available, session == nil, data != nil else { return }
        let session = makeSession()
        session?.prewarm()
        self.session = session
    }

    private func makeSession() -> LanguageModelSession? {
        guard let data else { return nil }
        return LanguageModelSession(
            tools: [
                BudgetsTool(data: data), BudgetTool(data: data), BillsTool(data: data),
                SpendingTool(data: data), TransactionsTool(data: data), AffordTool(data: data),
            ],
            instructions: Self.instructions
        )
    }

    func send(_ text: String) async {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isThinking else { return }
        messages.append(AskMessage(role: .user, text: question))

        guard availability == .available else {
            messages.append(AskMessage(role: .notice, text: availability.message))
            return
        }
        guard let data else {
            messages.append(AskMessage(role: .notice, text: "Suffice couldn't read your budget just now. Close Ask and open it again."))
            return
        }
        isThinking = true
        defer { isThinking = false }

        do {
            let reply = try await respond(to: question, retrying: true)
            var message = AskMessage(role: .assistant, text: reply.text.trimmingCharacters(in: .whitespacesAndNewlines))
            let budgetName = reply.budget.trimmingCharacters(in: .whitespaces)
            if !budgetName.isEmpty, let category = data.findCategory(budgetName) {
                message.budgetID = category.id
            }
            if reply.showsBreakdown {
                message.breakdown = MonthSpan(containing: .now)
                message.budgetID = nil
            }
            if reply.moveDollars > 0, let transfer = data.transfer(from: reply.moveFrom, to: reply.moveTo, dollars: reply.moveDollars) {
                message.transfer = transfer
                message.budgetID = nil
            }
            messages.append(message)
        } catch {
            log.error("Ask failed: \(String(describing: error), privacy: .public)")
            messages.append(AskMessage(role: .notice, text: Self.message(for: error)))
        }
    }

    private func respond(to question: String, retrying: Bool) async throws -> AskReply {
        guard let session = session ?? makeSession() else { throw CancellationError() }
        self.session = session
        do {
            return try await session.respond(to: question, generating: AskReply.self, options: GenerationOptions(temperature: 0.3)).content
        } catch {
            // A long conversation filled the model's context: start a fresh session and ask again.
            guard retrying, Self.isContextFull(error) else { throw error }
            self.session = makeSession()
            return try await respond(to: question, retrying: false)
        }
    }

    private static func isContextFull(_ error: Error) -> Bool {
        guard let error = error as? LanguageModelSession.GenerationError else { return false }
        if case .exceededContextWindowSize = error { return true }
        return false
    }

    static func message(for error: Error) -> String {
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation:
                return "Suffice can't help with that one. Ask about your budgets, bills or spending."
            case .exceededContextWindowSize:
                return "This conversation got too long. Tap Clear and ask again."
            default:
                break
            }
        }
        return "Suffice couldn't answer just now. Try asking again."
    }

    /// Move or Not Now on a proposed move.
    func resolveTransfer(_ message: AskMessage, move: Bool) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }), let transfer = message.transfer else { return }
        if move {
            guard data?.apply(transfer) == true else {
                messages.append(AskMessage(role: .notice, text: "That move doesn't fit anymore. Ask again to see the current amounts."))
                return
            }
            messages[index].transferState = .moved
        } else {
            messages[index].transferState = .dismissed
        }
    }

    func reset() {
        messages = []
        session = nil
    }
}
