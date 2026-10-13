import Foundation

/// Bank logos from Logo.dev, by the bank's website domain. Banks connected through Plaid come
/// with their domain; for the rest (accounts added by hand, banks connected before domains
/// were saved), common US banks and card issuers are matched by name.
enum BankLogo {
    static func url(name: String, domain: String?) -> URL? {
        guard let domain = domain ?? knownDomain(for: name) else { return nil }
        return MerchantLogo.url(plaidLogo: nil, domain: domain)
    }

    /// The domain for a bank's name, matched loosely ("Chase", "JPMorgan Chase Bank" → chase.com).
    static func knownDomain(for name: String) -> String? {
        let key = name.lowercased()
        guard !key.isEmpty else { return nil }
        return known.first { needle, _ in key.contains(needle) }?.1
    }

    /// Checked in order, so the more specific names come first.
    private static let known: [(String, String)] = [
        ("american express", "americanexpress.com"), ("amex", "americanexpress.com"),
        ("bank of america", "bankofamerica.com"), ("wells fargo", "wellsfargo.com"),
        ("capital one", "capitalone.com"), ("chase", "chase.com"), ("citibank", "citi.com"), ("citi", "citi.com"),
        ("u.s. bank", "usbank.com"), ("us bank", "usbank.com"), ("pnc", "pnc.com"), ("truist", "truist.com"),
        ("td bank", "td.com"), ("ally", "ally.com"), ("discover", "discover.com"), ("schwab", "schwab.com"),
        ("fidelity", "fidelity.com"), ("vanguard", "vanguard.com"), ("navy federal", "navyfederal.org"),
        ("usaa", "usaa.com"), ("sofi", "sofi.com"), ("marcus", "marcus.com"), ("goldman", "marcus.com"),
        ("apple card", "apple.com"), ("synchrony", "synchrony.com"), ("barclays", "barclaysus.com"),
        ("citizens", "citizensbank.com"), ("fifth third", "53.com"), ("huntington", "huntington.com"),
        ("regions", "regions.com"), ("keybank", "key.com"), ("m&t", "mtb.com"), ("bmo", "bmo.com"),
        ("zions", "zionsbank.com"), ("mountain america", "macu.com"), ("america first", "americafirst.com"),
        ("chime", "chime.com"), ("venmo", "venmo.com"), ("paypal", "paypal.com"), ("cash app", "cash.app"),
        ("robinhood", "robinhood.com"), ("wealthfront", "wealthfront.com"), ("betterment", "betterment.com"),
        ("pentagon federal", "penfed.org"), ("penfed", "penfed.org"), ("first tech", "firsttechfed.com"),
    ]
}
