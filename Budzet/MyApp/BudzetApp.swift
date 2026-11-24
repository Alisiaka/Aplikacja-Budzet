import SwiftUI

@main
struct BudzetApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store)
        }
    }
}
