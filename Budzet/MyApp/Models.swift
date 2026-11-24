import Foundation

enum Kind: String, Codable, CaseIterable, Identifiable {
    case expense, income, refund, savings, skip, ask
    var id: String { rawValue }
    var title: String {
        switch self {
        case .expense: return "Wydatek"
        case .income: return "Przychód"
        case .refund: return "Zwrot (zmniejsza kategorię)"
        case .savings: return "Oszczędności"
        case .skip: return "Pomiń"
        case .ask: return "— wybierz —"
        }
    }
}

struct Tx: Identifiable, Codable, Hashable {
    var id = UUID()
    var date: Date
    var amount: Double
    var type: String
    var merchant: String
    var who: String
    var title: String
    var kind: Kind
    var category = ""
    var note = ""
    var isManual = false
    var isPerson = false
    var edited = false
    var fingerprint = ""
    var splits: [Split]? = nil
    var receiptID: UUID? = nil

    var label: String {
        [merchant, who, title, type].first(where: { !$0.isEmpty }) ?? type
    }
}

struct PersonRule: Codable, Hashable {
    var kind: Kind
    var category: String
}

struct Database: Codable {
    var txs: [Tx] = []
    var merchantRules: [String: String] = [:]
    var personRules: [String: PersonRule] = [:]
    var aliases: [String: String] = [:]
    var itemRules: [String: String] = [:]
    var receipts: [Receipt] = []
    var limits: [String: Double] = [:]
    var goals: [Goal] = []
    var debts: [Debt] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case txs, merchantRules, personRules, aliases, itemRules, receipts, limits, goals, debts
    }

    // Stare zapisy (bez paragonów) nadal się wczytują.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        txs = try c.decodeIfPresent([Tx].self, forKey: .txs) ?? []
        merchantRules = try c.decodeIfPresent([String: String].self, forKey: .merchantRules) ?? [:]
        personRules = try c.decodeIfPresent([String: PersonRule].self, forKey: .personRules) ?? [:]
        aliases = try c.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
        itemRules = try c.decodeIfPresent([String: String].self, forKey: .itemRules) ?? [:]
        receipts = try c.decodeIfPresent([Receipt].self, forKey: .receipts) ?? []
        limits = try c.decodeIfPresent([String: Double].self, forKey: .limits) ?? [:]
        goals = try c.decodeIfPresent([Goal].self, forKey: .goals) ?? []
        debts = try c.decodeIfPresent([Debt].self, forKey: .debts) ?? []
    }
}

struct Goal: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var target: Double
    var saved: Double = 0
}

// amount > 0: ktoś jest Ci winien, amount < 0: Ty jesteś winna.
struct Debt: Identifiable, Codable, Hashable {
    var id = UUID()
    var person: String
    var amount: Double
    var note: String = ""
    var date = Date()
    var done = false
}

struct Split: Codable, Hashable {
    var category: String
    var amount: Double
}

enum Payment: String, Codable, CaseIterable, Identifiable {
    case card, cash
    var id: String { rawValue }
    var title: String { self == .card ? "Karta / BLIK" : "Gotówka" }
}

struct ReceiptItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var amount: Double
    var category = ""
}

struct Receipt: Identifiable, Codable, Hashable {
    var id = UUID()
    var date: Date
    var merchant: String
    var total: Double
    var payment: Payment
    var items: [ReceiptItem]

    // Pozycje zsumowane po kategoriach. Różnica do sumy z paragonu trafia do „inne”.
    func parts() -> [Split] {
        var g: [String: Double] = [:]
        for it in items {
            let c = it.category.trimmingCharacters(in: .whitespaces).lowercased()
            g[c.isEmpty ? "inne" : c, default: 0] += it.amount
        }
        var p = g.map { Split(category: $0.key, amount: ($0.value * 100).rounded() / 100) }
            .filter { abs($0.amount) > 0.004 }
            .sorted { $0.amount > $1.amount }
        let diff = ((total - p.reduce(0) { $0 + $1.amount }) * 100).rounded() / 100
        if diff > 0.005 {
            p.append(Split(category: "inne", amount: diff))
        } else if diff < -0.005, !p.isEmpty {
            p[0].amount = ((p[0].amount + diff) * 100).rounded() / 100
        }
        return p
    }
}

struct NamedAmount: Identifiable {
    let name: String
    let value: Double
    var id: String { name }
}

struct Suggestion: Hashable {
    let from: String
    let into: String
}

enum Norm {
    // Prosty „stemmer”: gra/gry -> „gr”, przejazd/przejazdy -> „przejazd”.
    static func stem(_ w: String) -> String {
        for suf in ["ów", "ami", "ach", "om"] where w.hasSuffix(suf) && w.count > suf.count + 1 {
            return String(w.dropLast(suf.count))
        }
        if let l = w.last, "aeiouyąę".contains(l), w.count > 2 {
            return String(w.dropLast())
        }
        return w
    }

    // Klucz kategorii: kolejność słów nie ma znaczenia („ubezpieczenie laptop” = „laptop ubezpieczenie”).
    static func ck(_ s: String) -> String {
        let seps = CharacterSet(charactersIn: " +,;/-")
        return s.lowercased()
            .components(separatedBy: seps)
            .filter { !$0.isEmpty }
            .map { stem($0) }
            .sorted()
            .joined(separator: " ")
    }

    // Klucz sklepu: pierwszy „słowny” człon nazwy (ŻABKA Z4698 K.1 -> ŻABKA).
    static func merchantKey(_ s: String) -> String {
        let up = s.uppercased()
        let seps = CharacterSet(charactersIn: " .*/")
        for tok in up.components(separatedBy: seps) {
            let clean = String(tok.filter { $0.isLetter || $0.isNumber })
            if clean.filter({ $0.isLetter }).count >= 3 { return clean }
        }
        return up.trimmingCharacters(in: .whitespaces)
    }

    static func personKey(_ s: String) -> String {
        s.uppercased().trimmingCharacters(in: .whitespaces)
    }
}

enum DateUtil {
    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static let formats = ["yyyy-MM-dd", "dd.MM.yyyy", "dd/MM/yyyy"]
    private static let formatters: [DateFormatter] = DateUtil.formats.map { f in
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = f
        return df
    }

    static func parse(_ s: String) -> Date? {
        let t = String(s.trimmingCharacters(in: .whitespaces).prefix(10))
        for df in formatters {
            if let d = df.date(from: t) { return d }
        }
        return nil
    }

    static func iso(_ d: Date) -> String { formatters[0].string(from: d) }

    static func month(_ d: Date) -> String {
        let c = cal.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    static func monthName(_ key: String) -> String {
        guard let d = parse(key + "-01") else { return key }
        let df = DateFormatter()
        df.locale = Locale(identifier: "pl_PL")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "LLLL yyyy"
        return df.string(from: d)
    }

    static func short(_ d: Date) -> String {
        let df = DateFormatter()
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "dd.MM"
        return df.string(from: d)
    }

    // Data wybrana w DatePickerze (czas lokalny) -> północ UTC tego samego dnia.
    static func dayUTC(_ d: Date) -> Date {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return cal.date(from: c) ?? d
    }
}
