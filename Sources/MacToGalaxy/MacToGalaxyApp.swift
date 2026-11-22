import SwiftUI

@main
@MainActor
struct MacToGalaxyApp: App {
    @StateObject private var model = GalaxyModel()

    var body: some Scene {
        Window("Mac-to-galaxy", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 480)
                .task { await model.monitor() }
        }
        .defaultSize(width: 940, height: 590)
    }
}
