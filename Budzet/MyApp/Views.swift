import SwiftUI
import UniformTypeIdentifiers

func money(_ v: Double) -> String {
    v.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "pl_PL"))) + " zł"
}

struct ContentView: View {
    var body: some View {
        TabView {
            SummaryView().tabItem { Label("Podsumowanie", systemImage: "chart.bar") }
            OperationsView().tabItem { Label("Operacje", systemImage: "list.bullet") }
            ReceiptsView().tabItem { Label("Paragony", systemImage: "doc.text.viewfinder") }
            AddView().tabItem { Label("Dodaj", systemImage: "plus.circle") }
            MoreView().tabItem { Label("Więcej", systemImage: "ellipsis.circle") }
        }
    }
}

struct MonthPicker: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Picker("Miesiąc", selection: $store.month) {
            ForEach(store.months, id: \.self) { m in
                Text(DateUtil.monthName(m)).tag(m)
            }
            Text("Wszystkie miesiące").tag("all")
        }
        .pickerStyle(.menu)
    }
}

// MARK: Podsumowanie

struct SummaryView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let s = store.summary()
        let balance = s.income - s.spent
        NavigationStack {
            List {
                Section { MonthPicker() }
                Section("Podsumowanie") {
                    line("Przychody", s.income)
                    line("Wydatki", s.spent)
                    line(balance >= 0 ? "Zysk" : "Strata", abs(balance))
                    line("Odłożone na oszczędności", s.saved)
                }
                Section("Wydatki według kategorii") { bars(s.spending, color: .pink, limits: store.db.limits) }
                Section("Przychody według kategorii") { bars(s.incomes, color: .teal) }
            }
            .navigationTitle("Budżet")
        }
    }

    func line(_ title: String, _ value: Double) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(money(value)).monospacedDigit().fontWeight(.semibold)
        }
    }

    func bars(_ items: [NamedAmount], color: Color, limits: [String: Double] = [:]) -> some View {
        let mx = max(items.map { abs($0.value) }.max() ?? 1, 1)
        return ForEach(items) { item in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.name)
                    Spacer()
                    Text(money(item.value)).monospacedDigit()
                }
                GeometryReader { g in
                    Capsule().fill(color)
                        .frame(width: g.size.width * CGFloat(max(item.value, 0) / mx), height: 6)
                }
                .frame(height: 6)
                if let lim = limits[item.name], lim > 0 {
                    let pct = item.value / lim
                    Text("\(Int(pct * 100))% limitu (\(money(lim)))")
                        .font(.caption)
                        .foregroundStyle(pct >= 1 ? Color.red : (pct >= 0.8 ? Color.orange : Color.secondary))
                }
            }
        }
    }
}

// MARK: Operacje

struct OperationsView: View {
    @EnvironmentObject var store: Store
    @State private var showSkipped = false

    var body: some View {
        let list = ordered(store.visible.filter { showSkipped || $0.kind != .skip })
        NavigationStack {
            List {
                Section {
                    MonthPicker()
                    Toggle("Pokaż też pominięte", isOn: $showSkipped)
                }
                Section {
                    ForEach(list) { t in TxRow(tx: t) }
                }
            }
            .navigationTitle("Operacje")
        }
    }

    func ordered(_ a: [Tx]) -> [Tx] {
        a.sorted { x, y in
            if (x.kind == .ask) != (y.kind == .ask) { return x.kind == .ask }
            return x.date > y.date
        }
    }
}

struct TxRow: View {
    @EnvironmentObject var store: Store
    let tx: Tx
    @State private var cat = ""
    @State private var splitting = false

    var hasSplit: Bool { tx.kind == .expense && !(tx.splits ?? []).isEmpty }
    var splitInfo: [String] {
        guard hasSplit, let sp = tx.splits else { return [] }
        return ["paragon: " + sp.map { "\($0.category) \(money($0.amount))" }.joined(separator: "; ")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(DateUtil.short(tx.date)).font(.caption).foregroundStyle(.secondary)
                Text(tx.label).fontWeight(.semibold).lineLimit(2)
                Spacer()
                Text(money(tx.amount)).monospacedDigit()
                    .foregroundStyle(tx.amount < 0 ? Color.pink : Color.teal)
            }
            Text(([tx.type, tx.note] + splitInfo).filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Rodzaj", selection: Binding(get: { tx.kind }, set: { store.set(tx.id, kind: $0) })) {
                    ForEach(Kind.allCases) { k in Text(k.title).tag(k) }
                }
                .labelsHidden()
                if tx.kind != .skip && tx.kind != .savings && !hasSplit {
                    TextField("Kategoria", text: $cat)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { store.set(tx.id, category: cat) }
                    Menu {
                        ForEach(store.categoryNames(), id: \.self) { n in
                            Button(n) { cat = n; store.set(tx.id, category: n) }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                }
                if tx.kind == .expense {
                    Button { splitting = true } label: { Image(systemName: "scissors") }
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $splitting) { SplitEditor(tx: tx).environmentObject(store) }
        .listRowBackground(tx.kind == .ask ? Color.orange.opacity(0.18) : nil)
        .onAppear { cat = tx.category }
    }
}

// MARK: Dodaj

struct AddView: View {
    @EnvironmentObject var store: Store
    @State private var picking = false
    @State private var date = Date()
    @State private var amount = ""
    @State private var income = false
    @State private var cat = ""
    @State private var mergeA = ""
    @State private var mergeB = ""
    @State private var importMode = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Wyciąg z banku") {
                    Button("Wczytaj wyciąg (CSV)") { importMode = 0; picking = true }
                    Button("Wczytaj mój Excel z budżetem (CSV)") { importMode = 1; picking = true }
                    if !store.lastMessage.isEmpty {
                        Text(store.lastMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Gotówka") {
                    Picker("Rodzaj", selection: $income) {
                        Text("Wydatek").tag(false)
                        Text("Przychód").tag(true)
                    }
                    .pickerStyle(.segmented)
                    DatePicker("Data", selection: $date, displayedComponents: .date)
                    TextField("Kwota", text: $amount).keyboardType(.decimalPad)
                    TextField("Kategoria", text: $cat)
                    Button("Dodaj") {
                        if let v = Importer.number(amount) {
                            store.addCash(date: date, amount: v, income: income, category: cat)
                            amount = ""; cat = ""
                        }
                    }
                }
                Section("Scalanie kategorii") {
                    Text("Podobne nazwy (np. „gra” i „gry”) łączą się same.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(store.suggestions(), id: \.self) { s in
                        Button("\(s.from) → \(s.into)") { store.merge(s.from, into: s.into) }
                    }
                    Picker("Scal", selection: $mergeA) {
                        Text("—").tag("")
                        ForEach(store.categoryNames(), id: \.self) { Text($0).tag($0) }
                    }
                    Picker("w", selection: $mergeB) {
                        Text("—").tag("")
                        ForEach(store.categoryNames(), id: \.self) { Text($0).tag($0) }
                    }
                    Button("Scal") {
                        store.merge(mergeA, into: mergeB)
                        mergeA = ""; mergeB = ""
                    }
                    .disabled(mergeA.isEmpty || mergeB.isEmpty || mergeA == mergeB)
                }
            }
            .navigationTitle("Dodaj")
            .fileImporter(isPresented: $picking,
                          allowedContentTypes: [.commaSeparatedText, .plainText, .data],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    urls.forEach { importMode == 0 ? store.importStatement(from: $0) : store.importExcel(from: $0) }
                }
            }
        }
    }
}
