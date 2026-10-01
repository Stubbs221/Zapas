import SwiftUI

@main
struct ZapasApplication: App {
    @State private var model = AppModel()
    var body: some Scene {
        MenuBarExtra {
            DiagnosticsView(model: model)
        } label: {
            Label {
                if model.showStatus { Text(model.pressureText) }
            } icon: { Image(systemName: "memorychip") }
            .accessibilityLabel("Zapas. Давление памяти: \(model.pressureText)")
        }
        .menuBarExtraStyle(.window)
    }
}
