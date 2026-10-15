import SwiftData
import SwiftUI
import UIKit

/// Profile › About Suffice › Check Logos: loads a few logos the way the app does and shows
/// what happened at each step, so a missing logo can be traced on the device itself.
struct LogoCheckView: View {
    @Environment(\.modelContext) private var context
    @State private var results: [Check] = []
    @State private var isRunning = false

    struct Check: Identifiable {
        let id = UUID()
        var title: String
        var detail: String
        var passed: Bool
        var image: UIImage?
    }

    var body: some View {
        List {
            Section {
                Button(isRunning ? "Checking…" : "Run Check", systemImage: "stethoscope") {
                    Task { await run() }
                }
                .disabled(isRunning)
            } footer: {
                Text("Tests Logo.dev and the logos saved on your transactions. Screenshot the results if logos aren't showing.")
            }
            if !results.isEmpty {
                Section("Results") {
                    ForEach(results) { check in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(check.passed ? .green : .red)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(check.title).font(.subheadline.weight(.semibold))
                                Text(check.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: 0)
                            if let image = check.image {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 36, height: 36)
                                    .background(Color.white, in: .rect(cornerRadius: 8))
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Check Logos")
    }

    private func run() async {
        isRunning = true
        defer { isRunning = false }
        results = []

        let key = AppConfig.logoDevPublishableKey
        results.append(Check(
            title: "Logo.dev key in this build",
            detail: key.isEmpty ? "Missing: the build has no key." : "Present (\(key.count) characters, starts with \(key.prefix(3))).",
            passed: !key.isEmpty
        ))

        // A bank logo, built exactly as Overview builds it.
        if let url = BankLogo.url(name: "Chase", domain: nil) {
            results.append(await fetch("Chase logo (Logo.dev)", url))
        } else {
            results.append(Check(title: "Chase logo (Logo.dev)", detail: "No URL could be made (key missing?).", passed: false))
        }

        // The logos saved on transactions.
        let entries = (try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.externalID != nil }))) ?? []
        let withLogo = entries.filter { $0.logoURL != nil }
        results.append(Check(
            title: "Bank transactions with a saved logo",
            detail: "\(withLogo.count) of \(entries.count) bank-synced transactions have one.",
            passed: !withLogo.isEmpty
        ))
        for entry in withLogo.prefix(3) {
            guard let text = entry.logoURL, let url = URL(string: text) else { continue }
            results.append(await fetch(entry.payee, url))
        }

        // The cached path the app itself uses.
        if let url = BankLogo.url(name: "Chase", domain: nil) {
            let image = await LogoStore.shared.image(for: url)
            results.append(Check(
                title: "App's logo loader (Chase)",
                detail: image.map { "Loaded and fitted: \(Int($0.size.width))×\(Int($0.size.height))." } ?? "Returned nothing.",
                passed: image != nil,
                image: image
            ))
        }
    }

    /// Downloads one logo and fits it, reporting each step.
    private func fetch(_ title: String, _ url: URL) async -> Check {
        let host = url.host() ?? "?"
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "?"
            guard status == 200 else {
                return Check(title: title, detail: "\(host): HTTP \(status), \(type), \(data.count) bytes.", passed: false)
            }
            guard UIImage(data: data) != nil else {
                return Check(title: title, detail: "\(host): HTTP 200 but not an image (\(type), \(data.count) bytes).", passed: false)
            }
            let fitted = await Task.detached(priority: .utility) { LogoFitting.fitted(data) }.value
            return Check(
                title: title,
                detail: "\(host): HTTP 200, \(type), \(data.count) bytes. " + (fitted == nil ? "Fitting returned nothing." : "Fitted fine."),
                passed: fitted != nil,
                image: fitted
            )
        } catch {
            return Check(title: title, detail: "\(host): \(error.localizedDescription)", passed: false)
        }
    }
}
