import Foundation

enum ImportError: Error { case noHeader }

enum Importer {
    static func decode(_ data: Data) -> String? {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1250)
            ?? String(data: data, encoding: .isoLatin2)
        return text?.replacingOccurrences(of: "\u{FEFF}", with: "")
    }

    static func number(_ s: String) -> Double? {
        let t = s.replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: ",", with: ".")
        return Double(t)
    }

    static func parseCSV(_ text: String) -> [[String]] {
        let firstLine = text.prefix(while: { $0 != "\n" && $0 != "\r\n" && $0 != "\r" })
        let delim: Character = firstLine.filter({ $0 == ";" }).count > firstLine.filter({ $0 == "," }).count ? ";" : ","
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == delim {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []),
              let m = re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r]).trimmingCharacters(in: .whitespaces)
    }

    // Czyta wyciąg po nazwach kolumn (kolejność kolumn nie ma znaczenia).
    static func transactions(from text: String) throws -> [Tx] {
        let rows = parseCSV(text)
        guard let h = rows.firstIndex(where: {
            ($0.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("data operacji")
        }) else { throw ImportError.noHeader }

        let head = rows[h].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func col(_ s: String) -> Int? { head.firstIndex(where: { $0.hasPrefix(s) }) }
        guard let cType = col("typ transakcji"), let cAmt = col("kwota") else { throw ImportError.noHeader }
        let cValue = col("data waluty")
        let cFrom = col("nazwa nadawcy")
        let cTo = col("nazwa odbiorcy")
        let cDesc = col("opis transakcji") ?? (cAmt + 1)

        var out: [Tx] = []
        for r in rows[(h + 1)...] {
            guard r.count > cAmt, r.count > cType else { continue }
            let type = r[cType].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !type.isEmpty, type != "Blokada", let amt = number(r[cAmt]) else { continue }

            let desc = r[min(cDesc, r.count)...].filter { !$0.isEmpty }.joined(separator: " | ")
            let exec = firstMatch(#"Data wykonania operacji : (\d{4}-\d{2}-\d{2})"#, in: desc)
            let merch = firstMatch(#"Adres : (.*?)(?: Miasto :| \||$)"#, in: desc) ?? ""
            let title = firstMatch(#"Tytuł : (.*?)(?: {2,}| \||$)"#, in: desc) ?? ""
            let valueDate: String? = cValue.flatMap { r.count > $0 ? r[$0] : nil }
            guard let date = DateUtil.parse(exec ?? valueDate ?? "") ?? DateUtil.parse(r[0]) else { continue }

            let who = [cTo, cFrom].compactMap { $0 }
                .map { r.count > $0 ? r[$0].trimmingCharacters(in: .whitespacesAndNewlines) : "" }
                .first(where: { !$0.isEmpty }) ?? ""

            out.append(Tx(date: date, amount: amt, type: type, merchant: merch, who: who, title: title, kind: .skip,
                          fingerprint: "\(DateUtil.iso(date))|\(amt)|\(type)|\(merch)|\(who)|\(title)"))
        }
        return out
    }
}
