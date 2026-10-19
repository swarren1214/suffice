import Foundation

/// An email that might hold a receipt or a bill: its subject, sender, date, body and any PDFs.
nonisolated struct MailMessage: Sendable {
    var provider: MailProvider
    var id: String
    var subject: String
    var sender: String
    var date: Date
    var html: String
    var text: String
    var pdfs: [(name: String, data: Data)]
    /// Opens the message in the mailbox on the web.
    var webLink: String

    /// The body as plain text, for reading.
    var plainText: String {
        let fromHTML = html.isEmpty ? "" : EmailText.plainText(fromHTML: html)
        return fromHTML.count >= text.count ? fromHTML : text
    }
}

/// Reads mail through Gmail's API or Microsoft Graph, with the read-only access the person
/// granted. Only messages that look like receipts, orders and bills are asked for; nothing in
/// the mailbox is ever changed.
nonisolated enum MailClient {
    nonisolated enum Failure: LocalizedError, Sendable {
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .http(let code): "The mailbox didn’t answer (\(code)). Try again in a bit."
            }
        }
    }

    /// The words that find receipts, orders and bills without the rest of the mail.
    static let searchWords = ["receipt", "invoice", "order confirmation", "your order", "payment received", "thank you for your payment", "statement", "your bill", "amount due"]

    /// The IDs of messages since `since` that look like receipts or bills, newest first, at
    /// most `limit`.
    static func search(_ provider: MailProvider, since: Date, limit: Int, accessToken: String) async throws -> [String] {
        switch provider {
        case .gmail: try await gmailSearch(since: since, limit: limit, token: accessToken)
        case .outlook: try await graphSearch(since: since, limit: limit, token: accessToken)
        }
    }

    static func message(_ provider: MailProvider, id: String, accessToken: String) async throws -> MailMessage {
        switch provider {
        case .gmail: try await gmailMessage(id, token: accessToken)
        case .outlook: try await graphMessage(id, token: accessToken)
        }
    }

    /// The address a mailbox signed in as.
    static func address(of provider: MailProvider, accessToken: String) async throws -> String {
        switch provider {
        case .gmail:
            nonisolated struct Profile: Decodable { var emailAddress: String }
            return try await get(URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!, token: accessToken, as: Profile.self).emailAddress
        case .outlook:
            nonisolated struct Me: Decodable { var mail: String?; var userPrincipalName: String? }
            let me = try await get(URL(string: "https://graph.microsoft.com/v1.0/me?$select=mail,userPrincipalName")!, token: accessToken, as: Me.self)
            return me.mail ?? me.userPrincipalName ?? "Outlook"
        }
    }

    // MARK: Gmail

    private static func gmailSearch(since: Date, limit: Int, token: String) async throws -> [String] {
        let days = max(1, Int(Date.now.timeIntervalSince(since) / 86_400) + 1)
        let words = searchWords.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        let query = "newer_than:\(days)d -in:spam -in:trash -category:social {\(words)}"
        nonisolated struct Page: Decodable {
            nonisolated struct Ref: Decodable { var id: String }
            var messages: [Ref]?
            var nextPageToken: String?
        }
        var ids: [String] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
            components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "maxResults", value: "100")]
                + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            let page = try await get(components.url!, token: token, as: Page.self)
            ids += (page.messages ?? []).map(\.id)
            pageToken = page.nextPageToken
        } while pageToken != nil && ids.count < limit
        return Array(ids.prefix(limit))
    }

    private nonisolated struct GmailPart: Decodable {
        nonisolated struct Header: Decodable { var name: String; var value: String }
        nonisolated struct Body: Decodable { var data: String?; var attachmentId: String?; var size: Int? }
        var mimeType: String?
        var filename: String?
        var headers: [Header]?
        var body: Body?
        var parts: [GmailPart]?
    }

    private static func gmailMessage(_ id: String, token: String) async throws -> MailMessage {
        nonisolated struct Message: Decodable {
            var id: String
            var internalDate: String?
            var payload: GmailPart
        }
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=full")!
        let message = try await get(url, token: token, as: Message.self)
        let headers = message.payload.headers ?? []
        func header(_ name: String) -> String { headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? "" }

        var html = ""
        var text = ""
        var pdfRefs: [(name: String, attachmentID: String)] = []
        func walk(_ part: GmailPart) {
            let type = (part.mimeType ?? "").lowercased()
            let name = part.filename ?? ""
            if type == "application/pdf" || name.lowercased().hasSuffix(".pdf"), let attachment = part.body?.attachmentId {
                pdfRefs.append((name.isEmpty ? "Attachment.pdf" : name, attachment))
            } else if type == "text/html", html.isEmpty, let data = part.body?.data.flatMap(decodeBase64URL) {
                html = String(decoding: data, as: UTF8.self)
            } else if type == "text/plain", text.isEmpty, let data = part.body?.data.flatMap(decodeBase64URL) {
                text = String(decoding: data, as: UTF8.self)
            }
            part.parts?.forEach(walk)
        }
        walk(message.payload)

        var pdfs: [(name: String, data: Data)] = []
        nonisolated struct Attachment: Decodable { var data: String }
        for ref in pdfRefs.prefix(2) {
            let attachmentURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)/attachments/\(ref.attachmentID)")!
            if let attachment = try? await get(attachmentURL, token: token, as: Attachment.self), let data = decodeBase64URL(attachment.data) {
                pdfs.append((ref.name, data))
            }
        }
        let date = message.internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .now
        return MailMessage(
            provider: .gmail,
            id: id,
            subject: header("Subject"),
            sender: senderName(header("From")),
            date: date,
            html: html,
            text: text,
            pdfs: pdfs,
            webLink: "https://mail.google.com/mail/u/0/#all/\(id)"
        )
    }

    // MARK: Microsoft Graph

    private static func graphSearch(since: Date, limit: Int, token: String) async throws -> [String] {
        nonisolated struct Page: Decodable {
            nonisolated struct Ref: Decodable { var id: String; var receivedDateTime: Date? }
            var value: [Ref]
            var nextLink: String?
            enum CodingKeys: String, CodingKey { case value, nextLink = "@odata.nextLink" }
        }
        let search = searchWords.map { $0.contains(" ") ? "\\\"\($0)\\\"" : $0 }.joined(separator: " OR ")
        var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me/messages")!
        components.queryItems = [
            URLQueryItem(name: "$search", value: "\"\(search)\""),
            URLQueryItem(name: "$select", value: "id,receivedDateTime"),
            URLQueryItem(name: "$top", value: "50"),
        ]
        var next: URL? = components.url
        var ids: [String] = []
        // Search results come by relevance, so dates are filtered here, over at most 10 pages.
        var pages = 0
        while let url = next, ids.count < limit, pages < 10 {
            pages += 1
            let page = try await get(url, token: token, as: Page.self)
            ids += page.value.filter { ($0.receivedDateTime ?? .now) >= since }.map(\.id)
            next = page.nextLink.flatMap(URL.init(string:))
            if page.value.isEmpty { break }
        }
        return Array(ids.prefix(limit))
    }

    private static func graphMessage(_ id: String, token: String) async throws -> MailMessage {
        nonisolated struct Message: Decodable {
            nonisolated struct Body: Decodable { var contentType: String; var content: String }
            nonisolated struct From: Decodable {
                nonisolated struct Address: Decodable { var name: String?; var address: String? }
                var emailAddress: Address
            }
            var id: String
            var subject: String?
            var receivedDateTime: Date?
            var hasAttachments: Bool?
            var webLink: String?
            var body: Body?
            var from: From?
        }
        let encoded = id.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
        let url = URL(string: "https://graph.microsoft.com/v1.0/me/messages/\(encoded)?$select=id,subject,receivedDateTime,hasAttachments,webLink,body,from")!
        let message = try await get(url, token: token, as: Message.self, headers: ["Prefer": "outlook.body-content-type=\"html\""])

        var pdfs: [(name: String, data: Data)] = []
        if message.hasAttachments == true {
            nonisolated struct Attachments: Decodable {
                nonisolated struct Item: Decodable { var name: String?; var contentType: String?; var contentBytes: String? }
                var value: [Item]
            }
            let attachmentsURL = URL(string: "https://graph.microsoft.com/v1.0/me/messages/\(encoded)/attachments")!
            if let attachments = try? await get(attachmentsURL, token: token, as: Attachments.self) {
                for item in attachments.value where item.contentType == "application/pdf" || (item.name ?? "").lowercased().hasSuffix(".pdf") {
                    if let bytes = item.contentBytes, let data = Data(base64Encoded: bytes) {
                        pdfs.append((item.name ?? "Attachment.pdf", data))
                    }
                    if pdfs.count == 2 { break }
                }
            }
        }
        let isHTML = message.body?.contentType.lowercased() == "html"
        return MailMessage(
            provider: .outlook,
            id: message.id,
            subject: message.subject ?? "",
            sender: message.from?.emailAddress.name ?? message.from?.emailAddress.address ?? "",
            date: message.receivedDateTime ?? .now,
            html: isHTML ? message.body?.content ?? "" : "",
            text: isHTML ? "" : message.body?.content ?? "",
            pdfs: pdfs,
            webLink: message.webLink ?? ""
        )
    }

    // MARK: Helpers

    private static func get<T: Decodable>(_ url: URL, token: String, as type: T.Type, headers: [String: String] = [:]) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.http(status) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter().date(from: text) { return date }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Not a date")
        }
        return try decoder.decode(T.self, from: data)
    }

    /// Gmail's base64url, without padding.
    static func decodeBase64URL(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    /// "Santaquin City <billing@santaquin.gov>" → "Santaquin City".
    static func senderName(_ from: String) -> String {
        let name = from.components(separatedBy: "<").first?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespaces)) ?? ""
        if !name.isEmpty { return name }
        return from.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }
}
