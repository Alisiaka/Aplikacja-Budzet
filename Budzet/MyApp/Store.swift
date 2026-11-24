import Foundation
import SwiftUI
import Combine
@MainActor
final class Store: ObservableObject {
    @Published var db = Database() { didSet { save() } }
    @Published var month = "all"
    @Published var lastMessage = ""

    private var loading = false
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("budzet.json")
    }()

    init() {
        load()
        month = months.last ?? "all"
    }

    // MARK: zapis

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let d = try? dec.decode(Database.self, from: data) {
            loading = true; db = d; loading = false
        }
    }

    private func save() {
        if loading { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(db) { try? data.write(to: fileURL, options: .atomic) }
    }

    // MARK: miesiące

    var months: [String] { Array(Set(db.txs.map { DateUtil.month($0.date) })).sorted() }

    var visible: [Tx] {
        month == "all" ? db.txs : db.txs.filter { DateUtil.month($0.date) == month }
    }

    // MARK: wyciąg

    func importStatement(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let text = Importer.decode(data) else {
            lastMessage = "Nie mogę odczytać pliku."; return
        }
        do {
            let fresh = try Importer.transactions(from: text)
            var d = db
            let known = Set(d.txs.map { $0.fingerprint })
            var seen: [String: Int] = [:]
            var added = 0
            for var t in fresh {
                let n = seen[t.fingerprint, default: 0]
                seen[t.fingerprint] = n + 1
                t.fingerprint += "#\(n)"
                if known.contains(t.fingerprint) { continue }
                d.txs.append(Classifier.classify(t, db: d))
                added += 1
            }
            Classifier.pair(&d.txs)
            db = d
            matchReceipts()
            month = months.last ?? "all"
            lastMessage = "Dodano \(added) operacji."
        } catch {
            lastMessage = "To nie wygląda na wyciąg z banku (brak nagłówka „Data operacji”)."
        }
    }

    // MARK: edycja

    func set(_ id: UUID, kind: Kind? = nil, category: String? = nil) {
        guard let i = db.txs.firstIndex(where: { $0.id == id }) else { return }
        var d = db
        if let k = kind { d.txs[i].kind = k }
        if let c = category { d.txs[i].category = c.trimmingCharacters(in: .whitespaces).lowercased() }
        d.txs[i].edited = true
        d.txs[i].note = "Twój wybór"
        let t = d.txs[i]
        if (t.kind == .expense || t.kind == .refund), !t.category.isEmpty, !t.isManual {
            d.merchantRules[Norm.merchantKey(t.merchant.isEmpty ? t.title : t.merchant)] = t.category
        }
        if t.isPerson, t.kind != .ask {
            d.personRules[Norm.personKey(t.who)] = PersonRule(kind: t.kind, category: t.category)
        }
        db = d
    }

    func addCash(date: Date, amount: Double, income: Bool, category: String) {
        let t = Tx(date: DateUtil.dayUTC(date), amount: income ? abs(amount) : -abs(amount),
                   type: "Gotówka", merchant: "gotówka", who: "", title: "",
                   kind: income ? .income : .expense,
                   category: category.trimmingCharacters(in: .whitespaces).lowercased(),
                   note: "dodane ręcznie", isManual: true, isPerson: false, edited: true)
        db.txs.append(t)
        month = DateUtil.month(t.date)
    }

    // MARK: kategorie

    func canonical() -> (String) -> String {
        var counts: [String: [String: Int]] = [:]
        for t in db.txs where !t.category.isEmpty {
            counts[Norm.ck(t.category), default: [:]][t.category, default: 0] += 1
        }
        let pick = counts.mapValues { dict in dict.max(by: { $0.value < $1.value })!.key }
        let aliases = db.aliases
        return { c in
            let k = Norm.ck(c)
            return aliases[k] ?? pick[k] ?? c
        }
    }

    func categoryNames() -> [String] {
        let canon = canonical()
        return Array(Set(db.txs.compactMap { $0.category.isEmpty ? nil : canon($0.category) })).sorted()
    }

    func suggestions() -> [Suggestion] {
        let names = categoryNames()
        var out: [Suggestion] = []
        for a in names {
            for b in names where a != b {
                let wa = Norm.ck(a).split(separator: " ")
                let wb = Norm.ck(b).split(separator: " ")
                if wa.count < wb.count && wa.allSatisfy({ wb.contains($0) }) {
                    out.append(Suggestion(from: a, into: b))
                }
            }
        }
        return Array(out.prefix(8))
    }

    func merge(_ a: String, into b: String) {
        guard a != b else { return }
        var d = db
        for (k, v) in d.aliases where v == a { d.aliases[k] = b }
        d.aliases[Norm.ck(a)] = b
        d.aliases[Norm.ck(b)] = b
        db = d
    }

    // MARK: paragony

    func saveReceipt(_ r: Receipt) {
        var d = db
        for it in r.items where !it.category.isEmpty {
            d.itemRules[ReceiptParser.itemKey(it.name)] = it.category.trimmingCharacters(in: .whitespaces).lowercased()
        }
        d.receipts.append(r)
        if r.payment == .cash {
            for p in r.parts() {
                d.txs.append(Tx(date: r.date, amount: -p.amount, type: "Gotówka", merchant: r.merchant,
                                who: "", title: "", kind: .expense, category: p.category,
                                note: "paragon (gotówka)", isManual: true, isPerson: false, edited: true,
                                receiptID: r.id))
            }
            month = DateUtil.month(r.date)
        }
        db = d
        matchReceipts()
    }

    func deleteReceipt(_ id: UUID) {
        var d = db
        d.receipts.removeAll { $0.id == id }
        d.txs.removeAll { $0.isManual && $0.receiptID == id }
        db = d
        matchReceipts()
    }

    // Paragon kartą pasuje do płatności z wyciągu: ta sama kwota, data do 3 dni różnicy.
    func matchReceipts() {
        var d = db
        for i in d.txs.indices where !d.txs[i].isManual && d.txs[i].receiptID != nil {
            d.txs[i].splits = nil
            d.txs[i].receiptID = nil
        }
        for r in d.receipts where r.payment == .card {
            let candidates = d.txs.indices.filter { i in
                let t = d.txs[i]
                return !t.isManual && t.receiptID == nil && t.splits == nil && t.kind == .expense
                    && abs(t.amount + r.total) < 0.005
                    && abs(t.date.timeIntervalSince(r.date)) <= 3 * 86400
            }
            let best = candidates.min(by: {
                abs(d.txs[$0].date.timeIntervalSince(r.date)) < abs(d.txs[$1].date.timeIntervalSince(r.date))
            })
            if let i = best {
                d.txs[i].receiptID = r.id
                d.txs[i].splits = r.parts()
            }
        }
        db = d
    }

    // MARK: podsumowanie

    struct Summary {
        var income = 0.0
        var spent = 0.0
        var saved = 0.0
        var asks = 0
        var spending: [NamedAmount] = []
        var incomes: [NamedAmount] = []
    }

    func summary() -> Summary {
        let canon = canonical()
        var s = Summary()
        var sp: [String: Double] = [:]
        var inc: [String: Double] = [:]
        for t in visible {
            let c = t.category.isEmpty ? "(bez kategorii)" : canon(t.category)
            switch t.kind {
            case .expense:
                if let parts = t.splits, !parts.isEmpty {
                    for p in parts { sp[p.category.isEmpty ? "(bez kategorii)" : canon(p.category), default: 0] += p.amount }
                } else {
                    sp[c, default: 0] -= t.amount
                }
            case .refund: sp[c, default: 0] -= t.amount
            case .income: s.income += t.amount; inc[c, default: 0] += t.amount
            case .savings: s.saved -= t.amount
            case .ask: s.asks += 1
            case .skip: break
            }
        }
        s.spent = sp.values.reduce(0, +)
        s.spending = sp.map { NamedAmount(name: $0.key, value: $0.value) }.sorted { $0.value > $1.value }
        s.incomes = inc.map { NamedAmount(name: $0.key, value: $0.value) }.sorted { $0.value > $1.value }
        return s
    }
}
