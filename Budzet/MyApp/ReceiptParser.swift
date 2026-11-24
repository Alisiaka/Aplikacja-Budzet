import UIKit
import Vision

// MARK: Rozpoznawanie tekstu (Apple Vision, działa na telefonie)

enum OCR {
    static func orientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch o {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    // Zwraca linie tekstu od góry do dołu (nazwa i cena z jednego wiersza są łączone).
    static func lines(from image: UIImage) -> [String] {
        guard let cg = image.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        if let langs = try? request.supportedRecognitionLanguages(), langs.contains("pl-PL") {
            request.recognitionLanguages = ["pl-PL", "en-US"]
        } else {
            request.automaticallyDetectsLanguage = true
        }
        let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation(image.imageOrientation), options: [:])
        try? handler.perform([request])
        let observations: [VNRecognizedTextObservation] = request.results ?? []

        var pieces: [(text: String, box: CGRect)] = []
        for o in observations {
            if let top = o.topCandidates(1).first { pieces.append((top.string, o.boundingBox)) }
        }
        pieces.sort { $0.box.midY > $1.box.midY }

        var rows: [[(text: String, box: CGRect)]] = []
        for p in pieces {
            if let first = rows.last?.first,
               abs(first.box.midY - p.box.midY) < max(first.box.height, p.box.height) * 0.6 {
                rows[rows.count - 1].append(p)
            } else {
                rows.append([p])
            }
        }
        return rows.map { row in
            row.sorted { $0.box.minX < $1.box.minX }.map { $0.text }.joined(separator: " ")
        }
    }
}

// MARK: Czytanie paragonu (data, suma, pozycje, kategorie)

enum ReceiptParser {
    static func fold(_ s: String) -> String {
        s.replacingOccurrences(of: "ł", with: "l")
            .replacingOccurrences(of: "Ł", with: "L")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pl_PL"))
            .uppercased()
    }

    static func matches(_ pattern: String, in s: String) -> [NSTextCheckingResult] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s))
    }

    static func substr(_ s: String, _ r: NSRange) -> String {
        guard let rr = Range(r, in: s) else { return "" }
        return String(s[rr])
    }

    static func amounts(_ s: String) -> [Double] {
        matches(#"-?\d{1,6}[.,]\d{2}"#, in: s).compactMap {
            Double(substr(s, $0.range).replacingOccurrences(of: ",", with: "."))
        }
    }

    // Klucz pozycji do zapamiętywania kategorii: dwa pierwsze „słowa” nazwy.
    static func itemKey(_ name: String) -> String {
        let words = fold(name).components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 3 }
        return words.prefix(2).joined(separator: " ")
    }

    static func findDate(_ lines: [String]) -> Date? {
        for l in lines {
            if let m = matches(#"(20\d{2})[-./](\d{2})[-./](\d{2})"#, in: l).first {
                let s = substr(l, m.range(at: 1)) + "-" + substr(l, m.range(at: 2)) + "-" + substr(l, m.range(at: 3))
                if let d = DateUtil.parse(s) { return d }
            }
            if let m = matches(#"(\d{2})[-./](\d{2})[-./](20\d{2})"#, in: l).first {
                let s = substr(l, m.range(at: 3)) + "-" + substr(l, m.range(at: 2)) + "-" + substr(l, m.range(at: 1))
                if let d = DateUtil.parse(s) { return d }
            }
        }
        return nil
    }

    static func findTotal(_ lines: [String]) -> Double? {
        for key in ["DO ZAPLATY", "SUMA PLN", "RAZEM", "SUMA"] {
            for (i, l) in lines.enumerated() where fold(l).contains(key) {
                if let a = amounts(l).last { return a }
                if i + 1 < lines.count, let a = amounts(lines[i + 1]).last { return a }
            }
        }
        return nil
    }

    static func findMerchant(_ lines: [String]) -> String {
        for l in lines.prefix(6) {
            let fl = fold(l)
            if fl.contains("PARAGON") || fl.contains("NIP") { continue }
            if l.filter({ $0.isLetter }).count >= 3 { return l.trimmingCharacters(in: .whitespaces) }
        }
        return ""
    }

    static func parseItems(_ lines: [String]) -> [ReceiptItem] {
        let f = lines.map { fold($0) }
        var start = 0
        if let h = f.firstIndex(where: { $0.contains("PARAGON") }) { start = h + 1 }
        var end = lines.count
        if let e = f.indices.first(where: {
            $0 >= start && (f[$0].contains("SPRZEDAZ") || f[$0].contains("SUMA") || f[$0].contains("DO ZAPLATY"))
        }) { end = e }
        if start >= end { return [] }

        let skip = ["PTU", "NIP", "KASJER", "PARAGON", "RESZTA", "GOTOWKA", "KARTA", "NR SYS", "ROZLICZENIE"]
        var out: [ReceiptItem] = []
        for i in start..<end {
            let line = lines[i]
            let fl = f[i]
            guard let amt = amounts(line).last else { continue }
            if fl.contains("RABAT") || fl.contains("UPUST") {
                if !out.isEmpty { out[out.count - 1].amount += -abs(amt) }
                continue
            }
            if skip.contains(where: { fl.contains($0) }) { continue }

            var name = line
            if let m = matches(#"\s\d+([.,]\d+)?\s*(szt\.?|SZT\.?|kg|KG)?\s*[xX×*]\s*\d"#, in: line).first,
               let r = Range(m.range, in: line) {
                name = String(line[..<r.lowerBound])
            } else if let m = matches(#"-?\d{1,6}[.,]\d{2}"#, in: line).last, let r = Range(m.range, in: line) {
                name = String(line[..<r.lowerBound])
            }
            name = name.trimmingCharacters(in: .whitespaces)
            name = name.replacingOccurrences(of: #"[-\s][A-G]$"#, with: "", options: .regularExpression)
            guard name.filter({ $0.isLetter }).count >= 2 else { continue }
            out.append(ReceiptItem(name: name, amount: amt))
        }
        return out
    }

    static let keywords: [(String, [String])] = [
        ("palenie", ["LIQUID", "VAPE", "PAPIEROS", "TYTON", "SNUS"]),
        ("alkohol", ["PIWO", "WODKA", "WINO", "WHISKY", "WHISKEY", "LIKIER", "BROWAR"]),
        ("kosmetyki", ["SZAMPON", "DEZODORANT", "KREM", "PASTA DO ZEB", "MYDLO", "TUSZ", "PUDER", "PODKLAD", "BALSAM"]),
        ("jedzenie", ["NAPOJ", "DRINK", "SPRITE", "COLA", "WODA", "SOK ", "CHLEB", "BULKA", "MLEKO", "SER ",
                      "JOGURT", "MASLO", "JAJ", "LODY", "LODEM", "BATON", "CZEKOLAD", "CHIPS", "KAWA", "HERBATA",
                      "SZYNKA", "KURCZAK", "MAKARON", "RYZ", "OWOC", "WARZYW", "PIZZA", "KANAPKA"])
    ]

    static func merchantCategory(_ merchant: String, db: Database) -> String {
        for tok in merchant.components(separatedBy: " ") {
            if let c = db.merchantRules[Norm.merchantKey(tok)] { return c }
        }
        return ""
    }

    static func category(for name: String, merchantDefault: String, db: Database) -> String {
        if let c = db.itemRules[itemKey(name)] { return c }
        let f = fold(name) + " "
        for (cat, words) in keywords where words.contains(where: { f.contains($0) }) { return cat }
        return merchantDefault
    }

    static func parse(_ lines: [String], db: Database) -> Receipt {
        let merchant = findMerchant(lines)
        let mDefault = merchantCategory(merchant, db: db)
        var items = parseItems(lines)
        for i in items.indices {
            items[i].category = category(for: items[i].name, merchantDefault: mDefault, db: db)
        }
        let sum = items.reduce(0) { $0 + $1.amount }
        let total = findTotal(lines) ?? ((sum * 100).rounded() / 100)
        let all = lines.map { fold($0) }.joined(separator: " ")
        let payment: Payment = all.contains("KART") ? .card : (all.contains("GOTOWK") ? .cash : .card)
        return Receipt(date: findDate(lines) ?? DateUtil.dayUTC(Date()), merchant: merchant,
                       total: total, payment: payment, items: items)
    }
}
