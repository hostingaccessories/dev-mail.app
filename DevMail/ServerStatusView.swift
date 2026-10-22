import DevMailCore
import SwiftUI

/// Toolbar item showing whether the SMTP server is listening, with a button to start or stop it.
struct ServerStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(indicatorColor)
                    .accessibilityHidden(true)
                Text(model.serverState.statusText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .help(model.serverState.statusText)

            if model.serverState.isListening {
                Button("Stop") {
                    Task { await model.stopServer() }
                }
            } else {
                Button("Start") {
                    Task { await model.startServer() }
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private var indicatorColor: Color {
        switch model.serverState {
        case .listening: .green
        case .stopped: .secondary
        case .failed: .red
        }
    }
}

extension SMTPServer.State {
    var isListening: Bool {
        if case .listening = self { return true }
        return false
    }

    var statusText: String {
        switch self {
        case .listening(let host, let port):
            "Listening on \(host):\(String(port))"
        case .stopped:
            "Stopped"
        case .failed(let error):
            error.localizedDescription
        }
    }
}
