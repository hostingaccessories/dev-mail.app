import SwiftUI

/// The Server menu.
struct ServerCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Server") {
            Button("Start Server") {
                Task { await model.startServer() }
            }
            .disabled(model.serverState.isListening)

            Button("Stop Server") {
                Task { await model.stopServer() }
            }
            .disabled(!model.serverState.isListening)
        }
    }
}
