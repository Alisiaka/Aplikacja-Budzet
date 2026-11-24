import SwiftUI
import PhotosUI
import VisionKit

// Aparat „skaner dokumentów” (sam prostuje i przycina paragon).
struct DocumentScanner: UIViewControllerRepresentable {
    let onFinish: ([UIImage]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]) -> Void
        init(_ f: @escaping ([UIImage]) -> Void) { onFinish = f }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            onFinish((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { onFinish([]) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) { onFinish([]) }
    }
}

struct ReceiptsView: View {
    @EnvironmentObject var store: Store
    @State private var scanning = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var draft: Receipt?
    @State private var busy = false
    @State private var message = ""

    var sorted: [Receipt] { store.db.receipts.sorted { $0.date > $1.date } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if VNDocumentCameraViewController.isSupported {
                        Button { scanning = true } label: {
                            Label("Skanuj paragon aparatem", systemImage: "camera.viewfinder")
                        }
                    }
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Wybierz zdjęcie z biblioteki", systemImage: "photo")
                    }
                    if busy {
                        HStack { ProgressView(); Text("Czytam paragon…") }
                    }
                    if !message.isEmpty {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Zapisane paragony") {
                    ForEach(sorted) { r in row(r) }
                        .onDelete { idx in
                            let list = sorted
                            for i in idx { store.deleteReceipt(list[i].id) }
                        }
                }
            }
            .navigationTitle("Paragony")
            .fullScreenCover(isPresented: $scanning) {
                DocumentScanner { imgs in
                    scanning = false
                    if !imgs.isEmpty { Task { await process(imgs) } }
                }
                .ignoresSafeArea()
            }
            .sheet(item: $draft) { r in
                ReviewView(receipt: r,
                           onSave: { saved in store.saveReceipt(saved); draft = nil },
                           onCancel: { draft = nil })
            }
            .onChange(of: pickerItem) { _, new in
                guard let new else { return }
                Task {
                    if let data = try? await new.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        await process([img])
                    } else {
                        message = "Nie mogę otworzyć tego zdjęcia."
                    }
                    pickerItem = nil
                }
            }
        }
    }

    func row(_ r: Receipt) -> some View {
        let matched = store.db.txs.contains { $0.receiptID == r.id && !$0.isManual }
        let status = r.payment == .cash ? "gotówka" : (matched ? "dopasowany do wyciągu" : "czeka na wyciąg")
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(DateUtil.short(r.date)).font(.caption).foregroundStyle(.secondary)
                Text(r.merchant.isEmpty ? "paragon" : r.merchant).fontWeight(.semibold).lineLimit(1)
                Spacer()
                Text(money(r.total)).monospacedDigit()
            }
            Text("\(r.items.count) poz. · \(status)").font(.caption).foregroundStyle(.secondary)
        }
    }

    func process(_ images: [UIImage]) async {
        busy = true
        message = ""
        await Task.yield()
        var lines: [String] = []
        for img in images { lines += OCR.lines(from: img) }
        busy = false
        if lines.isEmpty {
            message = "Nie widzę tekstu na zdjęciu. Spróbuj przy lepszym świetle."
            return
        }
        draft = ReceiptParser.parse(lines, db: store.db)
    }
}

struct ReviewView: View {
    @EnvironmentObject var store: Store
    @State private var r: Receipt
    let onSave: (Receipt) -> Void
    let onCancel: () -> Void

    init(receipt: Receipt, onSave: @escaping (Receipt) -> Void, onCancel: @escaping () -> Void) {
        _r = State(initialValue: receipt)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var itemsSum: Double { r.items.reduce(0) { $0 + $1.amount } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Paragon") {
                    TextField("Sklep", text: $r.merchant)
                    DatePicker("Data", selection: $r.date, displayedComponents: .date)
                    HStack {
                        Text("Suma")
                        Spacer()
                        TextField("0,00", value: $r.total, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("Płatność", selection: $r.payment) {
                        ForEach(Payment.allCases) { p in Text(p.title).tag(p) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Pozycje") {
                    ForEach($r.items) { $item in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Nazwa", text: $item.name)
                            HStack {
                                TextField("Kwota", value: $item.amount, format: .number)
                                    .keyboardType(.decimalPad)
                                    .frame(width: 80)
                                TextField("Kategoria", text: $item.category)
                                Menu {
                                    ForEach(store.categoryNames(), id: \.self) { n in
                                        Button(n) { item.category = n }
                                    }
                                } label: {
                                    Image(systemName: "list.bullet")
                                }
                            }
                        }
                    }
                    .onDelete { r.items.remove(atOffsets: $0) }
                    Button("+ pozycja") { r.items.append(ReceiptItem(name: "", amount: 0)) }
                    let diff = ((r.total - itemsSum) * 100).rounded() / 100
                    Text(abs(diff) < 0.005
                         ? "Suma pozycji zgadza się z paragonem."
                         : "Suma pozycji: \(money(itemsSum)), na paragonie: \(money(r.total)). Różnica trafi do kategorii „inne”.")
                        .font(.footnote)
                        .foregroundStyle(abs(diff) < 0.005 ? Color.teal : Color.pink)
                }
            }
            .navigationTitle("Sprawdź paragon")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Anuluj", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Zapisz") {
                        var out = r
                        out.date = DateUtil.dayUTC(r.date)
                        out.items.removeAll { $0.name.trimmingCharacters(in: .whitespaces).isEmpty && $0.amount == 0 }
                        if out.total == 0 { out.total = (itemsSum * 100).rounded() / 100 }
                        onSave(out)
                    }
                }
            }
        }
    }
}
