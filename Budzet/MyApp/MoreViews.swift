import SwiftUI
import Charts

struct MoreView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Porównanie miesięcy") { CompareView() }
                NavigationLink("Limity na kategorie") { LimitsView() }
                NavigationLink("Stałe opłaty") { RecurringView() }
                NavigationLink("Rozliczenia z ludźmi") { DebtsView() }
                NavigationLink("Cele oszczędnościowe") { GoalsView() }
                NavigationLink("Zapamiętane zasady") { RulesView() }
                NavigationLink("Eksport do Excela (CSV)") { ExportView() }
            }
            .navigationTitle("Więcej")
        }
    }
}

// MARK: Porównanie miesięcy

struct CompareView: View {
    @EnvironmentObject var store: Store
    @State private var cat = ""

    var body: some View {
        let data = store.monthlySpending(category: cat.isEmpty ? nil : cat)
        List {
            Picker("Kategoria", selection: $cat) {
                Text("Wszystkie wydatki").tag("")
                ForEach(store.categoryNames(), id: \.self) { n in Text(n).tag(n) }
            }
            Chart(data) { d in
                BarMark(x: .value("Miesiąc", d.name), y: .value("Zł", d.value))
            }
            .frame(height: 220)
            if data.count >= 2 {
                let last = data[data.count - 1]
                let prev = data[data.count - 2]
                let diff = last.value - prev.value
                Text("\(DateUtil.monthName(last.name)): \(money(last.value)). Poprzedni miesiąc: \(money(prev.value)) (\(diff >= 0 ? "więcej o" : "mniej o") \(money(abs(diff)))).")
                    .font(.footnote)
            }
        }
        .navigationTitle("Porównanie")
    }
}

// MARK: Limity

struct LimitsView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        List {
            Text("Wpisz miesięczny limit dla kategorii. Na ekranie „Podsumowanie” zobaczysz, ile limitu już wykorzystałaś (od 80% na pomarańczowo, od 100% na czerwono).")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(store.categoryNames(), id: \.self) { n in
                HStack {
                    Text(n)
                    Spacer()
                    TextField("limit", value: Binding(get: { store.db.limits[n] ?? 0 },
                                                      set: { v in store.mutate { $0.limits[n] = v > 0 ? v : nil } }),
                              format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
            }
        }
        .navigationTitle("Limity")
    }
}

// MARK: Stałe opłaty

struct RecurringView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let list = store.recurring()
        List {
            Section {
                Text("Płatności, które wracają w kolejnych miesiącach w podobnej kwocie. Kategorię dostają automatycznie z zapamiętanych zasad.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Razem co miesiąc: \(money(list.reduce(0) { $0 + $1.amount }))").fontWeight(.semibold)
            }
            Section {
                ForEach(list) { r in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(r.name).lineLimit(1)
                            Text("\(r.category.isEmpty ? "bez kategorii" : r.category) · \(r.months) mies.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(money(r.amount)).monospacedDigit()
                    }
                }
            }
        }
        .navigationTitle("Stałe opłaty")
    }
}

// MARK: Rozliczenia z ludźmi

struct DebtsView: View {
    @EnvironmentObject var store: Store
    @State private var person = ""
    @State private var amount = ""
    @State private var note = ""
    @State private var theyOwe = true

    var people: [String] { Array(Set(store.db.debts.filter { !$0.done }.map { $0.person })).sorted() }
    func balance(_ p: String) -> Double {
        store.db.debts.filter { $0.person == p && !$0.done }.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        List {
            Section("Nowy wpis") {
                TextField("Osoba", text: $person)
                Picker("Kierunek", selection: $theyOwe) {
                    Text("Winien mi").tag(true)
                    Text("Jestem winna").tag(false)
                }
                .pickerStyle(.segmented)
                TextField("Kwota", text: $amount).keyboardType(.decimalPad)
                TextField("Za co (opcjonalnie)", text: $note)
                Button("Dodaj") {
                    let p = person.trimmingCharacters(in: .whitespaces)
                    if let v = Importer.number(amount), !p.isEmpty {
                        store.mutate { $0.debts.append(Debt(person: p, amount: theyOwe ? abs(v) : -abs(v), note: note)) }
                        person = ""; amount = ""; note = ""
                    }
                }
            }
            ForEach(people, id: \.self) { p in
                Section {
                    ForEach(store.db.debts.filter { $0.person == p && !$0.done }) { d in
                        HStack {
                            Text(d.note.isEmpty ? DateUtil.short(d.date) : d.note)
                            Spacer()
                            Text(money(d.amount)).monospacedDigit()
                        }
                    }
                    Button("Rozliczone") {
                        store.mutate { db in
                            for i in db.debts.indices where db.debts[i].person == p { db.debts[i].done = true }
                        }
                    }
                } header: {
                    Text("\(p): \(balance(p) >= 0 ? "winien Ci" : "jesteś winna") \(money(abs(balance(p))))")
                }
            }
        }
        .navigationTitle("Rozliczenia")
    }
}

// MARK: Cele oszczędnościowe

struct GoalsView: View {
    @EnvironmentObject var store: Store
    @State private var name = ""
    @State private var target = ""

    var body: some View {
        List {
            Section("Nowy cel") {
                TextField("Nazwa", text: $name)
                TextField("Kwota docelowa", text: $target).keyboardType(.decimalPad)
                Button("Dodaj") {
                    if let v = Importer.number(target), v > 0, !name.isEmpty {
                        store.mutate { $0.goals.append(Goal(name: name, target: v)) }
                        name = ""; target = ""
                    }
                }
            }
            Section("Cele") {
                ForEach(store.db.goals) { g in GoalRow(goal: g) }
                    .onDelete { idx in
                        store.mutate { db in for i in idx.sorted(by: >) { db.goals.remove(at: i) } }
                    }
            }
            Section {
                let saved = store.db.txs.filter { $0.kind == .savings }.reduce(0) { $0 - $1.amount }
                Text("Przelane na oszczędności z wyciągów (razem): \(money(saved))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Cele")
    }
}

struct GoalRow: View {
    @EnvironmentObject var store: Store
    let goal: Goal
    @State private var add = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(goal.name).fontWeight(.semibold)
                Spacer()
                Text("\(money(goal.saved)) z \(money(goal.target))").font(.caption)
            }
            ProgressView(value: min(max(goal.saved / max(goal.target, 1), 0), 1))
            HStack {
                TextField("Dopisz wpłatę", text: $add)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                Button("Dodaj") {
                    if let v = Importer.number(add) {
                        store.mutate { db in
                            if let i = db.goals.firstIndex(where: { $0.id == goal.id }) { db.goals[i].saved += v }
                        }
                        add = ""
                    }
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

// MARK: Zapamiętane zasady

struct RulesView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        List {
            Section("Sklep → kategoria") {
                ForEach(store.db.merchantRules.keys.sorted(), id: \.self) { k in
                    HStack {
                        Text(k)
                        Spacer()
                        TextField("kategoria", text: Binding(get: { store.db.merchantRules[k] ?? "" },
                                                             set: { v in store.mutate { $0.merchantRules[k] = v.lowercased() } }))
                            .multilineTextAlignment(.trailing)
                    }
                }
                .onDelete { idx in
                    let keys = store.db.merchantRules.keys.sorted()
                    store.mutate { db in for i in idx { db.merchantRules[keys[i]] = nil } }
                }
            }
            Section("Pozycja z paragonu → kategoria") {
                ForEach(store.db.itemRules.keys.sorted(), id: \.self) { k in
                    HStack {
                        Text(k)
                        Spacer()
                        TextField("kategoria", text: Binding(get: { store.db.itemRules[k] ?? "" },
                                                             set: { v in store.mutate { $0.itemRules[k] = v.lowercased() } }))
                            .multilineTextAlignment(.trailing)
                    }
                }
                .onDelete { idx in
                    let keys = store.db.itemRules.keys.sorted()
                    store.mutate { db in for i in idx { db.itemRules[keys[i]] = nil } }
                }
            }
            Section("Osoby (przelewy)") {
                ForEach(store.db.personRules.keys.sorted(), id: \.self) { k in
                    let r = store.db.personRules[k]
                    HStack {
                        Text(k).lineLimit(1)
                        Spacer()
                        Text("\(r?.kind.title ?? "") \(r?.category ?? "")").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { idx in
                    let keys = store.db.personRules.keys.sorted()
                    store.mutate { db in for i in idx { db.personRules[keys[i]] = nil } }
                }
            }
        }
        .navigationTitle("Zasady")
    }
}

// MARK: Eksport

struct ExportView: View {
    @EnvironmentObject var store: Store
    @State private var url: URL?

    var body: some View {
        Form {
            MonthPicker()
            Button("Przygotuj plik CSV") { url = store.exportCSV() }
            if let url = url {
                ShareLink(item: url) { Label("Udostępnij lub zapisz plik", systemImage: "square.and.arrow.up") }
            }
            Text("Plik ma kolumny: miesiąc, data, rodzaj, sklep, kategoria, kwota. Otwórz go w Excelu i zrób tabelę przestawną.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("Eksport")
        .onChange(of: store.month) { _, _ in url = nil }
    }
}

// MARK: Ręczny podział płatności

struct SplitEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let tx: Tx
    @State private var parts: [Split] = []

    var total: Double { abs(tx.amount) }
    var rest: Double { ((total - parts.reduce(0) { $0 + $1.amount }) * 100).rounded() / 100 }

    var body: some View {
        NavigationStack {
            Form {
                Section("\(tx.label): \(money(total))") {
                    ForEach(parts.indices, id: \.self) { i in
                        HStack {
                            TextField("Kategoria", text: $parts[i].category)
                            TextField("Kwota", value: $parts[i].amount, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                        }
                    }
                    .onDelete { parts.remove(atOffsets: $0) }
                    Button("+ część") { parts.append(Split(category: "", amount: max(rest, 0))) }
                    Text(abs(rest) < 0.005 ? "Wszystko rozdzielone." : "Zostało do rozdzielenia: \(money(rest))")
                        .font(.footnote)
                        .foregroundStyle(abs(rest) < 0.005 ? Color.teal : Color.pink)
                }
                if tx.splits != nil {
                    Button("Usuń podział", role: .destructive) { store.setSplits(tx.id, nil); dismiss() }
                }
            }
            .navigationTitle("Podziel płatność")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Zapisz") {
                        let clean = parts.filter { $0.amount > 0 }.map {
                            Split(category: $0.category.trimmingCharacters(in: .whitespaces).lowercased(), amount: $0.amount)
                        }
                        store.setSplits(tx.id, clean.isEmpty ? nil : clean)
                        dismiss()
                    }
                    .disabled(abs(rest) > 0.005)
                }
            }
            .onAppear {
                parts = tx.splits ?? [Split(category: tx.category, amount: total)]
            }
        }
    }
}
