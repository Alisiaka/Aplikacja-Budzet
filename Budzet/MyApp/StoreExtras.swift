import Foundation

extension Store {
    func mutate(_ f: (inout Database) -> Void) {
        var d = db
        f(&d)
        db = d
    }

    // MARK: Twój Excel (nauka kategorii + gotówka spoza wyciągu)

    struct ExcelRow {
        let date: Date
        let amount: Double
        let cat: String
    }

    static func parseExcelCSV(_ text: String) -> [ExcelRow] {
        let rows = Importer.parseCSV(text)
        guard let h = rows.firstIndex(where: { r in
            let l = r.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            return l.contains("data") && l.contains("nazwa")
        }) else { return [] }
        let head = rows[h].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func col(_ names: [String]) -> Int? { head.firstIndex(where: { names.contains($0) }) }
        guard let cD = col(["data"]), let cN = col(["nazwa"]) else { return [] }
        let cK = col(["kwota"]), cW = col(["wydatki"]), cZ = col(["zarobki", "zrobki"])
        var out: [ExcelRow] = []
        for r in rows[(h + 1)...] {
            guard r.count > max(cD, cN), let date = DateUtil.parse(r[cD]) else { continue }
            func val(_ c: Int?) -> Double? {
                guard let c = c, r.count > c else { return nil }
                return Importer.number(r[c])
            }
            guard let amt = val(cK) ?? val(cW) ?? val(cZ) else { continue }
            out.append(ExcelRow(date: date, amount: amt, cat: r[cN].trimmingCharacters(in: .whitespaces).lowercased()))
        }
        return out
    }

    func importExcel(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let text = Importer.decode(data) else {
            lastMessage = "Nie mogę odczytać pliku."; return
        }
        let ex = Store.parseExcelCSV(text)
        if ex.isEmpty { lastMessage = "Nie widzę w pliku kolumn „data” i „nazwa”."; return }

        var d = db
        let exMonths = Set(ex.map { DateUtil.month($0.date) })
        let negCats = Set(ex.filter { $0.amount < 0 }.map { $0.cat })
        let live: [Kind] = [.expense, .refund, .income, .ask]
        var used = Set<Int>()
        var learn: [String: [String: Int]] = [:]
        var matched = 0

        // 1) Operacje z wyciągu, które mają parę w Excelu: bierzemy Twoją kategorię.
        for i in d.txs.indices where !d.txs[i].isManual && live.contains(d.txs[i].kind) {
            let t = d.txs[i]
            let found = ex.indices.first(where: {
                !used.contains($0) && abs(ex[$0].amount - t.amount) < 0.005
                    && abs(ex[$0].date.timeIntervalSince(t.date)) <= 3 * 86400
            })
            guard let j = found else { continue }
            used.insert(j); matched += 1
            let e = ex[j]
            d.txs[i].category = e.cat
            if t.kind == .ask { d.txs[i].kind = e.amount < 0 ? .expense : (negCats.contains(e.cat) ? .refund : .income) }
            d.txs[i].note = "z Twojego Excela"
            d.txs[i].edited = true
            if !t.merchant.isEmpty, d.txs[i].kind == .expense || d.txs[i].kind == .refund {
                learn[Norm.merchantKey(t.merchant), default: [:]][e.cat, default: 0] += 1
            }
        }
        for (k, cats) in learn {
            if let best = cats.max(by: { $0.value < $1.value })?.key { d.merchantRules[k] = best }
        }

        // 2) Przelewy od/do osób, których nie ma w Excelu (w miesiącach z Excela): pomijasz je.
        for i in d.txs.indices where !d.txs[i].isManual && d.txs[i].kind == .ask
            && exMonths.contains(DateUtil.month(d.txs[i].date)) {
            d.txs[i].kind = .skip
            d.txs[i].note = "nie ma w Twoim Excelu, więc pomijam"
            d.txs[i].edited = true
        }

        // 3) Wpisy z Excela bez pary na wyciągu (gotówka itp.): dodajemy jako ręczne.
        var added = 0
        let stmtMonths = Set(d.txs.filter { !$0.isManual }.map { DateUtil.month($0.date) })
        let known = Set(d.txs.map { $0.fingerprint })
        var seen: [String: Int] = [:]
        for j in ex.indices where !used.contains(j) {
            let e = ex[j]
            let m = DateUtil.month(e.date)
            guard stmtMonths.contains(m) else { continue }
            var amt = e.amount
            var note = "z Excela (poza wyciągiem)"
            if amt > 0 {
                let covered = d.txs.filter {
                    !$0.isManual && $0.kind == .income && DateUtil.month($0.date) == m && Norm.ck($0.category) == Norm.ck(e.cat)
                }.reduce(0) { $0 + $1.amount }
                if covered > 0 {
                    if amt <= covered + 0.005 { continue }
                    amt -= covered
                    note = "z Excela (różnica względem wyciągu)"
                }
            }
            let base = "excel|\(DateUtil.iso(e.date))|\(e.amount)|\(e.cat)"
            let n = seen[base, default: 0]
            seen[base] = n + 1
            let fp = base + "#\(n)"
            if known.contains(fp) { continue }
            d.txs.append(Tx(date: e.date, amount: amt, type: "Gotówka", merchant: "gotówka", who: "", title: "",
                            kind: amt < 0 ? .expense : .income, category: e.cat, note: note,
                            isManual: true, isPerson: false, edited: true, fingerprint: fp))
            added += 1
        }
        db = d
        matchReceipts()
        lastMessage = "Excel: dopasowano \(matched) operacji z wyciągu, dodano \(added) wpisów spoza wyciągu (gotówka). Wczytaj najpierw wyciąg danego miesiąca."
    }

    // MARK: ręczny podział płatności

    func setSplits(_ id: UUID, _ parts: [Split]?) {
        mutate { d in
            guard let i = d.txs.firstIndex(where: { $0.id == id }) else { return }
            d.txs[i].splits = parts
            d.txs[i].receiptID = nil
            d.txs[i].edited = true
        }
    }

    // MARK: wydatki w miesiącach (porównanie)

    func spending(in txs: [Tx]) -> [String: Double] {
        let canon = canonical()
        var sp: [String: Double] = [:]
        for t in txs {
            let c = t.category.isEmpty ? "(bez kategorii)" : canon(t.category)
            if t.kind == .expense {
                if let parts = t.splits, !parts.isEmpty {
                    for p in parts { sp[p.category.isEmpty ? "(bez kategorii)" : canon(p.category), default: 0] += p.amount }
                } else {
                    sp[c, default: 0] -= t.amount
                }
            } else if t.kind == .refund {
                sp[c, default: 0] -= t.amount
            }
        }
        return sp
    }

    func monthlySpending(category: String?) -> [NamedAmount] {
        months.map { m in
            let sp = spending(in: db.txs.filter { DateUtil.month($0.date) == m })
            let v = category.map { sp[$0] ?? 0 } ?? sp.values.reduce(0, +)
            return NamedAmount(name: m, value: v)
        }
    }

    // MARK: stałe opłaty

    struct Recurring: Identifiable {
        let id: String
        let name: String
        let amount: Double
        let months: Int
        let category: String
    }

    func recurring() -> [Recurring] {
        var g: [String: [Tx]] = [:]
        for t in db.txs where t.kind == .expense && !t.isManual {
            g[Norm.merchantKey(t.merchant.isEmpty ? t.title : t.merchant), default: []].append(t)
        }
        let canon = canonical()
        var out: [Recurring] = []
        for (k, list) in g {
            let months = Set(list.map { DateUtil.month($0.date) })
            let amts = list.map { abs($0.amount) }
            guard months.count >= 2, let mx = amts.max(), let mn = amts.min(), mx > 0,
                  (mx - mn) / mx <= 0.1, list.count <= months.count + 1 else { continue }
            out.append(Recurring(id: k, name: list[0].label, amount: amts.reduce(0, +) / Double(amts.count),
                                 months: months.count, category: list[0].category.isEmpty ? "" : canon(list[0].category)))
        }
        return out.sorted { $0.amount > $1.amount }
    }

    // MARK: eksport

    func exportCSV() -> URL? {
        let canon = canonical()
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["Miesiąc;Data;Rodzaj;Sklep;Kategoria;Kwota"]
        for t in visible.sorted(by: { $0.date < $1.date }) where t.kind != .skip {
            let parts: [Split] = (t.kind == .expense ? t.splits : nil) ?? [Split(category: t.category, amount: abs(t.amount))]
            for p in parts {
                let v = (t.amount < 0 ? -1.0 : 1.0) * abs(p.amount)
                lines.append([DateUtil.month(t.date), DateUtil.iso(t.date), t.kind.title, q(t.label),
                              q(p.category.isEmpty ? "" : canon(p.category)),
                              String(format: "%.2f", v).replacingOccurrences(of: ".", with: ",")].joined(separator: ";"))
            }
        }
        let text = "\u{FEFF}" + lines.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("budzet-\(month).csv")
        do { try text.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
    }
}
