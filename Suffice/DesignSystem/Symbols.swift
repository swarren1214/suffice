import UIKit

/// SF Symbols offered for a budget's icon, grouped by what people budget for, each with
/// search words. Outline weights, to match the line icons inside the budget rings. Names that
/// this iOS doesn't have are dropped when the library loads, so a typo or a newer symbol never
/// shows up as a blank square.
nonisolated struct SymbolOption: Identifiable, Hashable, Sendable {
    let name: String
    /// Extra words people might search for ("rent", "mortgage" for a house).
    let keywords: String
    var id: String { name }

    /// Lowercased text the search matches against: the symbol's own words and its keywords.
    var searchText: String {
        (name.replacingOccurrences(of: ".", with: " ") + " " + keywords).lowercased()
    }

    var accessibilityName: String {
        name.replacingOccurrences(of: ".", with: " ")
    }
}

nonisolated struct SymbolSection: Identifiable, Sendable {
    let title: String
    let symbols: [SymbolOption]
    var id: String { title }
}

enum SymbolChoices {
    /// The twelve shown in the budget sheet before "More icons". The first six are the MVP v2 set.
    static let quick: [String] = [
        "house", "car", "fork.knife", "bolt", "ticket", "heart",
        "cart", "cup.and.saucer", "fuelpump", "drop", "wifi", "iphone",
    ]

    /// The whole library, minus anything this iOS can't draw.
    static let sections: [SymbolSection] = raw.compactMap { title, symbols in
        let available = symbols.filter { UIImage(systemName: $0.name) != nil }
        return available.isEmpty ? nil : SymbolSection(title: title, symbols: available)
    }

    /// Every symbol once, in library order.
    static let all: [SymbolOption] = {
        var seen = Set<String>()
        return sections.flatMap(\.symbols).filter { seen.insert($0.name).inserted }
    }()

    /// Symbols whose name, keywords or section match every word typed.
    static func search(_ query: String) -> [SymbolOption] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return all }
        var seen = Set<String>()
        return sections.flatMap { section in
            section.symbols.filter { option in
                let text = option.searchText + " " + section.title.lowercased()
                return words.allSatisfy { text.contains($0) }
            }
        }
        .filter { seen.insert($0.name).inserted }
    }

    private static func s(_ name: String, _ keywords: String = "") -> SymbolOption {
        SymbolOption(name: name, keywords: keywords)
    }

    private static let raw: [(String, [SymbolOption])] = [
        ("Home", [
            s("house", "home rent mortgage"),
            s("building.2", "apartment rent condo"),
            s("key", "rent lease deposit"),
            s("bed.double", "bedroom furniture hotel"),
            s("sofa", "furniture couch living room"),
            s("chair.lounge", "furniture patio"),
            s("lamp.table", "furniture decor"),
            s("washer", "laundry appliance"),
            s("refrigerator", "appliance fridge kitchen"),
            s("oven", "appliance kitchen"),
            s("microwave", "appliance kitchen"),
            s("fan", "appliance cooling"),
            s("air.conditioner.horizontal", "cooling hvac ac"),
            s("heater.vertical", "heating hvac"),
            s("hammer", "repairs maintenance tools diy"),
            s("wrench.and.screwdriver", "repairs maintenance tools"),
            s("paintbrush", "paint decor renovation"),
            s("paintbrush.pointed", "art decor"),
            s("spigot", "plumbing water"),
            s("shower", "bathroom plumbing"),
            s("bathtub", "bathroom"),
            s("toilet", "bathroom plumbing"),
            s("trash", "garbage waste disposal"),
            s("sprinkler.and.droplets", "lawn yard irrigation"),
            s("tree", "yard landscaping garden"),
            s("leaf", "garden lawn yard"),
            s("camera.macro", "garden plants flowers"),
            s("door.left.hand.closed", "door security"),
            s("lock", "security alarm"),
            s("lightbulb", "lights electric"),
            s("powerplug", "electric"),
            s("shippingbox", "moving storage packages"),
            s("archivebox", "storage"),
        ]),
        ("Bills & utilities", [
            s("bolt", "electric power energy utility"),
            s("flame", "gas heating utility"),
            s("drop", "water utility"),
            s("wifi", "internet broadband"),
            s("antenna.radiowaves.left.and.right", "cable internet"),
            s("iphone", "phone cell mobile"),
            s("phone", "phone landline"),
            s("tv", "cable streaming television"),
            s("doc.text", "bill statement invoice"),
            s("envelope", "mail bill postage"),
            s("calendar", "subscription recurring"),
            s("repeat", "subscription recurring"),
            s("icloud", "cloud storage subscription"),
            s("server.rack", "hosting web"),
            s("trash.circle", "garbage waste"),
            s("sun.max", "solar"),
        ]),
        ("Food & drink", [
            s("cart", "groceries supermarket food"),
            s("basket", "groceries market"),
            s("bag", "groceries shopping"),
            s("fork.knife", "dining out restaurant eating"),
            s("takeoutbag.and.cup.and.straw", "takeout fast food delivery"),
            s("cup.and.saucer", "coffee cafe tea"),
            s("mug", "coffee tea"),
            s("wineglass", "wine alcohol bar drinks"),
            s("waterbottle", "drinks water"),
            s("birthday.cake", "dessert bakery party"),
            s("carrot", "groceries produce vegetables"),
            s("fish", "seafood groceries"),
            s("frying.pan", "cooking kitchen"),
            s("refrigerator", "groceries"),
            s("popcorn", "snacks movies"),
            s("leaf", "vegetarian vegan produce"),
            s("storefront", "market shop local"),
        ]),
        ("Transportation", [
            s("car", "auto vehicle"),
            s("car.side", "auto vehicle"),
            s("car.2", "auto vehicles family"),
            s("fuelpump", "gas fuel"),
            s("ev.charger", "electric charging ev"),
            s("bolt.car", "electric ev"),
            s("steeringwheel", "driving auto"),
            s("wrench.adjustable", "auto repair maintenance mechanic"),
            s("parkingsign", "parking"),
            s("road.lanes", "tolls driving"),
            s("bus", "transit public transport"),
            s("tram", "train transit"),
            s("train.side.front.car", "train transit"),
            s("bicycle", "bike cycling"),
            s("scooter", "scooter"),
            s("motorcycle", "motorbike"),
            s("figure.walk", "walking"),
            s("airplane", "flights travel"),
            s("ferry", "boat travel"),
            s("sailboat", "boat"),
            s("truck.box", "moving delivery"),
            s("box.truck", "moving delivery"),
        ]),
        ("Shopping", [
            s("bag", "shopping retail"),
            s("cart", "shopping"),
            s("handbag", "shopping fashion"),
            s("tshirt", "clothes clothing apparel"),
            s("shoe", "shoes clothing"),
            s("eyeglasses", "glasses vision"),
            s("sunglasses", "accessories"),
            s("watch.analog", "jewelry accessories"),
            s("crown", "luxury"),
            s("gift", "gifts presents holidays christmas"),
            s("giftcard", "gift card"),
            s("tag", "sale shopping"),
            s("shippingbox", "online orders amazon packages"),
            s("storefront", "shop store"),
            s("hanger", "clothes dry cleaning"),
        ]),
        ("Health", [
            s("heart", "health wellness"),
            s("cross.case", "medical doctor first aid"),
            s("stethoscope", "doctor medical"),
            s("pills", "pharmacy medicine prescriptions"),
            s("syringe", "vaccines medical"),
            s("bandage", "first aid"),
            s("brain.head.profile", "therapy mental health counseling"),
            s("eye", "vision eye care"),
            s("mouth", "dental dentist"),
            s("ear", "hearing"),
            s("lungs", "health"),
            s("figure.run", "fitness exercise running"),
            s("dumbbell", "gym fitness"),
            s("figure.yoga", "yoga fitness"),
            s("bed.double", "sleep"),
            s("allergens", "allergy"),
            s("cross", "hospital medical"),
        ]),
        ("Personal care", [
            s("scissors", "haircut salon barber"),
            s("comb", "hair salon"),
            s("sparkles", "beauty cosmetics spa"),
            s("hands.sparkles", "nails manicure spa"),
            s("drop.circle", "skincare"),
            s("figure.mind.and.body", "massage spa wellness"),
            s("person", "personal me"),
            s("face.smiling", "fun personal"),
        ]),
        ("Kids & family", [
            s("figure.2.and.child.holdinghands", "family kids children"),
            s("figure.and.child.holdinghands", "kids childcare parent"),
            s("stroller", "baby"),
            s("teddybear", "toys kids baby"),
            s("balloon", "party birthday"),
            s("backpack", "school kids"),
            s("pencil.and.ruler", "school supplies"),
            s("graduationcap", "education tuition college school"),
            s("book", "books reading school"),
            s("puzzlepiece", "toys games"),
            s("soccerball", "kids sports activities"),
            s("music.note", "lessons music"),
            s("house.and.flag", "daycare school"),
            s("person.2", "family couple"),
            s("person.3", "family group"),
            s("heart.circle", "love family"),
        ]),
        ("Pets", [
            s("pawprint", "pets dog cat vet"),
            s("dog", "dog pet"),
            s("cat", "cat pet"),
            s("bird", "bird pet"),
            s("fish", "fish pet aquarium"),
            s("hare", "rabbit pet"),
            s("tortoise", "turtle pet"),
            s("cross.case", "vet"),
        ]),
        ("Fun & entertainment", [
            s("ticket", "events concerts movies tickets"),
            s("film", "movies cinema"),
            s("popcorn", "movies"),
            s("tv", "streaming netflix shows"),
            s("play.rectangle", "streaming youtube video"),
            s("music.note", "music spotify concerts"),
            s("headphones", "music audio podcasts"),
            s("gamecontroller", "games gaming video games"),
            s("dice", "games board games"),
            s("puzzlepiece", "hobbies games"),
            s("book", "books reading kindle"),
            s("books.vertical", "books library"),
            s("newspaper", "news subscription magazine"),
            s("camera", "photography hobbies"),
            s("paintpalette", "art hobbies crafts"),
            s("theatermasks", "theater shows"),
            s("guitars", "music instruments"),
            s("pianokeys", "music lessons instruments"),
            s("party.popper", "party celebration"),
            s("figure.dance", "dance"),
        ]),
        ("Sports & outdoors", [
            s("figure.run", "running"),
            s("figure.hiking", "hiking outdoors"),
            s("figure.skiing.downhill", "skiing ski pass"),
            s("figure.snowboarding", "snowboarding"),
            s("figure.golf", "golf"),
            s("figure.pool.swim", "swimming pool"),
            s("figure.outdoor.cycle", "cycling bike"),
            s("figure.climbing", "climbing gym"),
            s("figure.fishing", "fishing"),
            s("tent", "camping outdoors"),
            s("mountain.2", "outdoors mountains hiking"),
            s("tennis.racket", "tennis pickleball"),
            s("basketball", "sports"),
            s("football", "sports"),
            s("baseball", "sports"),
            s("soccerball", "sports"),
            s("volleyball", "sports"),
            s("trophy", "sports competition"),
        ]),
        ("Travel", [
            s("airplane", "flights travel vacation"),
            s("suitcase", "travel luggage vacation"),
            s("suitcase.rolling", "travel luggage"),
            s("beach.umbrella", "vacation beach"),
            s("bed.double", "hotel lodging"),
            s("building", "hotel"),
            s("map", "travel trips"),
            s("globe.americas", "travel international"),
            s("globe.europe.africa", "travel international"),
            s("binoculars", "sightseeing"),
            s("camera", "travel photos"),
            s("passport", "travel passport visa"),
            s("car.rear", "road trip rental car"),
            s("sailboat", "cruise boat"),
            s("mountain.2", "trips"),
        ]),
        ("Money", [
            s("dollarsign.circle", "money cash"),
            s("dollarsign", "money"),
            s("banknote", "cash money"),
            s("creditcard", "credit card debt payments"),
            s("building.columns", "bank"),
            s("percent", "interest fees"),
            s("chart.line.uptrend.xyaxis", "investing stocks"),
            s("chart.pie", "investing allocation"),
            s("chart.bar", "investing"),
            s("bitcoinsign.circle", "crypto bitcoin"),
            s("shield", "insurance protection"),
            s("umbrella", "insurance emergency fund rainy day"),
            s("lock.shield", "insurance security"),
            s("doc.text.magnifyingglass", "taxes accounting"),
            s("list.clipboard", "taxes paperwork"),
            s("signature", "loans contracts"),
            s("arrow.down.circle", "savings deposit"),
            s("arrow.up.circle", "withdrawal"),
            s("arrow.left.arrow.right", "transfer"),
            s("arrow.triangle.2.circlepath", "refunds recurring"),
            s("scalemass", "legal"),
            s("briefcase", "business work"),
            s("star", "goals"),
            s("flag", "goals milestone"),
            s("target", "goals savings target"),
        ]),
        ("Work & education", [
            s("briefcase", "work business"),
            s("laptopcomputer", "computer tech work"),
            s("desktopcomputer", "computer tech"),
            s("printer", "office printing"),
            s("paperclip", "office supplies"),
            s("pencil", "office school supplies"),
            s("graduationcap", "tuition education college"),
            s("books.vertical", "textbooks"),
            s("building.2", "office coworking"),
            s("person.crop.rectangle", "id professional"),
            s("doc", "documents"),
        ]),
        ("Tech", [
            s("iphone", "phone"),
            s("ipad", "tablet"),
            s("laptopcomputer", "computer"),
            s("applewatch", "watch"),
            s("airpods", "headphones"),
            s("headphones", "audio"),
            s("tv", "television"),
            s("hifispeaker", "speaker audio"),
            s("gamecontroller", "gaming"),
            s("camera", "camera"),
            s("keyboard", "computer accessories"),
            s("externaldrive", "storage backup"),
            s("cpu", "computer parts"),
            s("app.badge", "apps subscriptions"),
            s("cloud", "cloud storage"),
        ]),
        ("Giving", [
            s("heart", "giving charity donations"),
            s("hands.and.sparkles", "charity giving"),
            s("gift", "gifts"),
            s("building.columns", "church tithing"),
            s("person.2", "community"),
            s("globe", "charity world"),
            s("hand.raised", "volunteering"),
            s("leaf", "environment"),
            s("sparkles", "tithing offerings"),
        ]),
        ("Other", [
            s("square.grid.2x2", "misc other everything"),
            s("ellipsis.circle", "misc other"),
            s("questionmark.circle", "unknown"),
            s("star", "favorite"),
            s("bookmark", "saved"),
            s("bell", "reminders"),
            s("clock", "time"),
            s("calendar", "events"),
            s("mappin.and.ellipse", "places"),
            s("sun.max", "summer"),
            s("snowflake", "winter holidays"),
            s("moon.stars", "night"),
            s("cloud.rain", "rainy day"),
            s("bolt.heart", "energy"),
            s("tree", "christmas holidays"),
            s("flame", "candles"),
            s("smoke", "smoking"),
            s("wand.and.stars", "magic fun money"),
        ]),
    ]
}
