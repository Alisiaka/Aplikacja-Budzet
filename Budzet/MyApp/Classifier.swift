import Foundation

// Twoje zasady z wyciągu: co jest wydatkiem, przychodem, a co ani stratą, ani zyskiem.
enum Classifier {
    static func classify(_ tx: Tx, db: Database) -> Tx {
        var t = tx
        let ty = t.type.lowercased()
        let hay = (t.merchant + " " + t.who + " " + t.title).lowercased()
        t.isPerson = ty.hasPrefix("przelew") && !ty.contains("na konto")

        if ty.contains("wpłata gotówki") {
            t.kind = .skip; t.note = "wpłata we wpłatomacie"
        } else if hay.contains("xtb") || hay.contains("oszczęd") {
            t.kind = .savings; t.note = "przelew na oszczędności"
        } else if ty == "przelew na konto" && t.amount > 0 {
            t.kind = .income; t.category = "wypłata"
        } else if t.isPerson {
            if let r = db.personRules[Norm.personKey(t.who)] {
                t.kind = r.kind; t.category = r.category; t.note = "zapamiętane"
            } else {
                t.kind = .ask
            }
        } else {
            t.kind = t.amount > 0 ? .refund : .expense
        }

        if t.category.isEmpty, t.kind == .expense || t.kind == .refund,
           let c = db.merchantRules[Norm.merchantKey(t.merchant.isEmpty ? t.title : t.merchant)] {
            t.category = c; t.note = "zapamiętane"
        }
        return t
    }

    // Płatność + zwrot albo ta sama kwota w dwie strony (do 10 dni różnicy) zerują się.
    static func pair(_ txs: inout [Tx]) {
        let pairable: [Kind] = [.expense, .refund, .ask]
        let idx = txs.indices.filter { !txs[$0].isManual && !txs[$0].edited && pairable.contains(txs[$0].kind) }
        var used = Set<Int>()
        for a in idx where !used.contains(a) {
            let match = idx.first(where: { b in
                b != a && !used.contains(b)
                    && abs(txs[b].amount + txs[a].amount) < 0.005
                    && abs(txs[b].date.timeIntervalSince(txs[a].date)) <= 10 * 86400
            })
            if let b = match {
                used.insert(a); used.insert(b)
                let refund = (txs[a].type + txs[b].type).lowercased().contains("zwrot")
                let why = refund ? "płatność i zwrot się zerują" : "ta sama kwota w dwie strony"
                for i in [a, b] { txs[i].kind = .skip; txs[i].note = why }
            }
        }
    }
}
