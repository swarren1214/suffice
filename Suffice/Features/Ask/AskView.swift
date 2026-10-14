import SwiftData
import SwiftUI

/// Ask Suffice, from the ✨ button at the top of every tab: questions about the household's
/// money, answered by the on-device model from the app's own data. Type, tap a suggestion, or
/// tap the mic to talk hands free. Nothing leaves the device.
struct AskView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var engine = AskEngine.shared
    @State private var draft = ""
    @State private var showsVoice = false
    @State private var openedBudget: BudgetCategory?
    @State private var insights: [AskData.Insight] = []
    @State private var starters: [String] = []
    @FocusState private var composerFocused: Bool

    /// One line of the message field.
    private static let composerHeight: CGFloat = 46
    /// The mic and send buttons: a solid circle inside the field's height, like Messages.
    private static let buttonSize: CGFloat = 40

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if engine.messages.isEmpty {
                            welcome
                        }
                        ForEach(engine.messages) { message in
                            AskBubble(message: message, data: engine.data) { category in
                                openedBudget = category
                            } onTransfer: { move in
                                engine.resolveTransfer(message, move: move)
                            }
                            .id(message.id)
                        }
                        if engine.isThinking {
                            ThinkingBubble()
                                .id("thinking")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .readableWidth()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: engine.messages.count) {
                    guard let last = engine.messages.last?.id else { return }
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
                .onChange(of: engine.isThinking) { _, thinking in
                    if thinking { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("Ask Suffice").font(.headline)
                        Label("On this \(DeviceName.current)", systemImage: "lock")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(Brand.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
                if !engine.messages.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear") {
                            withAnimation(.snappy) { engine.reset() }
                            refresh()
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            // Asking out loud opens the full listening screen from the design.
            .fullScreenCover(isPresented: $showsVoice) {
                AskVoiceView {
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        composerFocused = true
                    }
                }
            }
            .sheet(item: $openedBudget) { category in
                BudgetSheet(category: category, month: MonthSpan(containing: .now))
            }
            .onAppear {
                engine.attach(context.container)
                engine.prewarm()
                refresh()
            }
        }
    }

    private func refresh() {
        guard let data = engine.data else { return }
        insights = data.insights()
        starters = [
            data.busiestBudgetName().map { "How much is left for \($0)?" },
            "Which bills are due this week?",
            "Where did our money go this month?",
            "Can we afford a $400 trip?",
        ].compactMap { $0 }
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Label("On-device", systemImage: "lock")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.green)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Brand.green.opacity(0.1), in: .capsule)
                Text("Ask anything about your household’s money.")
                    .font(.title2.bold())
                Text("What’s left in a budget, what’s due, where the money went, or whether something fits this month. Suffice answers on this \(DeviceName.current) and reads only your Suffice data.")
                    .font(.subheadline)
                    .foregroundStyle(Brand.secondaryText)
                if engine.availability != .available {
                    Text(engine.availability.message)
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 4)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))

            if !insights.isEmpty {
                Text("Right now")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.secondaryText)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                VStack(spacing: 0) {
                    ForEach(Array(insights.enumerated()), id: \.element.id) { index, insight in
                        if index > 0 { Divider().padding(.leading, 68) }
                        Button { ask(insight.question) } label: {
                            InsightRow(insight: insight, data: engine.data)
                        }
                        .buttonStyle(.plain)
                        .disabled(engine.isThinking)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 10) {
            if engine.messages.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(starters, id: \.self) { starter in
                            Button(starter) { ask(starter) }
                                .buttonStyle(.glass)
                                .tint(.primary)
                                .disabled(engine.isThinking)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
            }

            // The button matches the field's one-line height and stays at the bottom as it grows.
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about your money", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($composerFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .frame(minHeight: Self.composerHeight)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Self.composerHeight / 2))

                if draft.isEmpty {
                    Button {
                        composerFocused = false
                        showsVoice = true
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: Self.buttonSize, height: Self.buttonSize)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(Brand.green, in: .circle)
                    .padding(.bottom, (Self.composerHeight - Self.buttonSize) / 2)
                    .disabled(engine.availability != .available)
                    .opacity(engine.availability == .available ? 1 : 0.5)
                    .accessibilityLabel("Talk to Suffice")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .bold))
                            .frame(width: Self.buttonSize, height: Self.buttonSize)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(Brand.green, in: .circle)
                    .padding(.bottom, (Self.composerHeight - Self.buttonSize) / 2)
                    .disabled(engine.isThinking)
                    .opacity(engine.isThinking ? 0.5 : 1)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
        .readableWidth()
    }

    private func send() {
        let text = draft
        draft = ""
        ask(text)
    }

    private func ask(_ text: String) {
        Task { await engine.send(text) }
    }
}

// MARK: - Pieces

/// A "Right now" row: a budget's ring, the first bill's initial, or the month's spending.
private struct InsightRow: View {
    var insight: AskData.Insight
    var data: AskData?

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(insight.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                Text(insight.detail)
                    .font(.footnote)
                    .foregroundStyle(Brand.secondaryText)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(.rect)
        .accessibilityHint("Asks Suffice about it")
    }

    @ViewBuilder
    private var icon: some View {
        switch insight.kind {
        case .budget(let id):
            if let category = data?.category(id) {
                CategoryRing(progress: insight.progress, color: insight.progress > 1 ? .red : category.color, symbol: category.symbol, size: 40)
            }
        case .bills(let firstName):
            Text(firstName.first.map { String($0).uppercased() } ?? "?")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(MerchantColor.color(for: firstName), in: .circle)
                .accessibilityHidden(true)
        case .spending:
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Brand.green)
                .frame(width: 40, height: 40)
                .background(Brand.green.opacity(0.12), in: .circle)
                .accessibilityHidden(true)
        }
    }
}

/// One message: the question in green on the right, the answer (with its cards) on the left.
struct AskBubble: View {
    var message: AskMessage
    var data: AskData?
    var onOpen: (BudgetCategory) -> Void
    var onTransfer: (Bool) -> Void

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background(Brand.green, in: UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 22, bottomTrailingRadius: 6, topTrailingRadius: 22))
            }
        case .assistant:
            HStack {
                VStack(alignment: .leading, spacing: 10) {
                    Text(AskFormatting.attributed(message.text))
                        .fixedSize(horizontal: false, vertical: true)
                    AskCards(message: message, data: data, onOpen: onOpen, onTransfer: onTransfer)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 6, bottomTrailingRadius: 22, topTrailingRadius: 22))
                Spacer(minLength: 40)
            }
        case .notice:
            Text(message.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
    }
}

/// "Checking your budgets…" with three dots that pulse in turn.
private struct ThinkingBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                TimelineView(.animation(paused: reduceMotion)) { timeline in
                    let phase = reduceMotion ? 0 : Int(timeline.date.timeIntervalSinceReferenceDate * 3) % 3
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .fill(Color(.systemGray3).opacity(index == phase ? 1 : 0.45))
                                .frame(width: 7, height: 7)
                        }
                    }
                }
                Text("Checking your budgets…")
                    .font(.subheadline)
                    .foregroundStyle(Brand.secondaryText)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color(.secondarySystemGroupedBackground), in: UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 6, bottomTrailingRadius: 22, topTrailingRadius: 22))
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

enum AskFormatting {
    /// The reply with its **bold** amounts, or the plain text if it isn't valid Markdown.
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

#Preview {
    AskView()
        .previewEnvironment()
}
