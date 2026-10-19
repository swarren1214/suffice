import Foundation
import OSLog
import SwiftUI

/// A year of tagged spending, ready for the Tax Year screen and the export.
struct TaxReport {
    var year: Int
    /// The year isn't over: totals run Jan 1 to today.
    var isThisYear: Bool
    var items: [TaxItem]
    var summary: TaxYearSummary
    var interest: [LoanInterestLine]
}

/// One loan's interest for the year, from its schedule.
struct LoanInterestLine: Identifiable, Hashable {
    var id: UUID
    /// "Mortgage interest".
    var title: String
    var lender: String
    var symbol: String
    var color: CategoryColor
    var cents: Int
}

/// What Tax Year › Share With Your Tax Preparer hands the share sheet: a one-page PDF summary
/// by tag, a spreadsheet of every tagged transaction (or split part), and the receipts as JPEGs
/// named by date and payee. Written to a temporary folder each time; nothing leaves the device
/// until it's shared.
@MainActor
enum TaxExport {
    private static let log = Logger(subsystem: "com.stephenwarren.suffice", category: "tax-export")

    /// The files, newest first in the spreadsheet. `receipts` are the JPEGs by transaction.
    static func files(for report: TaxReport, lookup: Lookup, receipts: [UUID: Data]) -> [URL] {
        let folder = URL.temporaryDirectory.appending(path: "Suffice Tax \(report.year)", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            log.error("Couldn't make the export folder: \(error.localizedDescription, privacy: .public)")
            return []
        }
        var urls: [URL] = []

        let pdf = folder.appending(path: "Suffice \(report.year) Tax Summary.pdf")
        if writePDF(report, lookup: lookup, to: pdf) { urls.append(pdf) }

        let csvURL = folder.appending(path: "Suffice-\(report.year)-tax.csv")
        let names = receiptNames(report, receipts: receipts)
        if (try? Data(csv(report, lookup: lookup, receiptNames: names).utf8).write(to: csvURL, options: .atomic)) != nil {
            urls.append(csvURL)
        }

        for (entryID, name) in names.sorted(by: { $0.value < $1.value }) {
            guard let data = receipts[entryID] else { continue }
            let url = folder.appending(path: name)
            if (try? data.write(to: url, options: .atomic)) != nil { urls.append(url) }
        }
        return urls
    }

    /// "2026-10-09", in this device's time zone.
    static func dayText(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
    }

    // MARK: Spreadsheet

    /// date, payee, amount, tag, budget, member, account, note and receipt file for each tagged
    /// transaction or split part.
    static func csv(_ report: TaxReport, lookup: Lookup, receiptNames: [UUID: String]) -> String {
        func field(_ text: String) -> String { "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        var lines = ["date,payee,amount,tag,budget,member,account,note,receipt"]
        for item in report.items.sorted(by: { ($0.date, $0.partIndex) < ($1.date, $1.partIndex) }) {
            let budget = [lookup.budget(for: item.categoryID)?.name, lookup.subcategory(for: item.categoryID)?.name]
                .compactMap { $0 }
                .joined(separator: " › ")
            var note = item.note
            if item.isPart { note = [note, "Part of a split charge"].filter { !$0.isEmpty }.joined(separator: " · ") }
            lines.append([
                dayText(item.date),
                field(item.payee),
                String(format: "%.2f", Double(item.cents) / 100),
                field(item.tag.name),
                field(budget),
                field(lookup.member(item.memberID)?.name ?? ""),
                field(lookup.account(item.accountID)?.displayName ?? ""),
                field(note),
                field(receiptNames[item.entryID] ?? ""),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// "2026-10-09 Intermountain Health.jpg", numbered when two land on the same name.
    static func receiptNames(_ report: TaxReport, receipts: [UUID: Data]) -> [UUID: String] {
        var names: [UUID: String] = [:]
        var used: Set<String> = []
        for item in report.items.sorted(by: { $0.date < $1.date }) where receipts[item.entryID] != nil && names[item.entryID] == nil {
            let payee = item.payee
                .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
                .joined(separator: "-")
                .trimmingCharacters(in: .whitespaces)
            let base = "\(dayText(item.date)) \(payee.isEmpty ? "Receipt" : payee)"
            var name = "\(base).jpg"
            var number = 2
            while used.contains(name) {
                name = "\(base) \(number).jpg"
                number += 1
            }
            used.insert(name)
            names[item.entryID] = name
        }
        return names
    }

    // MARK: PDF

    /// One page, as tall as the summary needs, drawn from the print layout.
    private static func writePDF(_ report: TaxReport, lookup: Lookup, to url: URL) -> Bool {
        let renderer = ImageRenderer(content: TaxSummaryPrint(report: report).environment(\.colorScheme, .light))
        renderer.proposedSize = ProposedViewSize(width: 612, height: nil)
        var wrote = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: CGSize(width: 612, height: max(size.height, 792)))
            guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            pdf.beginPDFPage(nil)
            // Top-aligned on a page at least letter height.
            pdf.translateBy(x: 0, y: box.height - size.height)
            draw(pdf)
            pdf.endPDFPage()
            pdf.closePDF()
            wrote = true
        }
        return wrote
    }
}

/// The PDF's layout: the year's totals by tag, receipts, loan interest, and the note that
/// Suffice doesn't give tax advice. Black on white, for printing.
struct TaxSummaryPrint: View {
    var report: TaxReport

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tax Year \(String(report.year))")
                    .font(.system(size: 26, weight: .bold))
                Text(report.isThisYear
                     ? "Tagged spending from January 1 to \(Date.now.formatted(date: .long, time: .omitted)), from Suffice."
                     : "Tagged spending for \(String(report.year)), from Suffice.")
                    .font(.system(size: 12))
                    .foregroundStyle(.gray)
            }

            HStack(spacing: 28) {
                figure("Tagged", Money.text(report.summary.totalCents))
                figure("Transactions", "\(report.summary.transactions)")
                figure("With a receipt", "\(report.summary.withReceipt) of \(report.summary.transactions)")
            }

            VStack(alignment: .leading, spacing: 0) {
                row("Tag", "Transactions", "Without a receipt", "Total", header: true)
                ForEach(report.summary.tags) { line in
                    row(line.tag.name, "\(line.count)", "\(line.missingReceipts)", Money.text(line.totalCents))
                }
            }

            if !report.interest.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    row("From loans", "Lender", "", "Interest", header: true)
                    ForEach(report.interest) { line in
                        row(line.title, line.lender, "", Money.text(line.cents))
                    }
                    Text("Loan interest is estimated from each loan’s schedule. The lender’s Form 1098 is the official figure.")
                        .font(.system(size: 10))
                        .foregroundStyle(.gray)
                        .padding(.top, 6)
                }
            }

            Text("The attached spreadsheet lists every tagged transaction, with its receipt’s file name. Suffice doesn’t give tax advice; ask your tax preparer what you can deduct.")
                .font(.system(size: 11))
                .foregroundStyle(.gray)
        }
        .foregroundStyle(.black)
        .padding(40)
        .frame(width: 612, alignment: .leading)
        .background(.white)
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundStyle(.gray)
            Text(value).font(.system(size: 16, weight: .semibold)).monospacedDigit()
        }
    }

    private func row(_ a: String, _ b: String, _ c: String, _ d: String, header: Bool = false) -> some View {
        HStack {
            Text(a).frame(maxWidth: .infinity, alignment: .leading)
            Text(b).frame(width: 110, alignment: .trailing)
            Text(c).frame(width: 110, alignment: .trailing)
            Text(d).frame(width: 100, alignment: .trailing)
        }
        .font(.system(size: 11, weight: header ? .semibold : .regular))
        .monospacedDigit()
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.gray.opacity(header ? 0.6 : 0.2)).frame(height: header ? 1 : 0.5)
        }
    }
}
