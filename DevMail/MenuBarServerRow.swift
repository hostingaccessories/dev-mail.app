import DevMailCore
import SwiftUI

/// The first row of the menu bar item's menu: the server address and status, with a switch to start or stop it.
struct MenuBarServerRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(address)
                    .font(.headline.monospacedDigit())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.serverState.statusText)
                    .font(.caption)
                    .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Toggle("", isOn: isRunning)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("SMTP Server")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("SMTP server \(address)")
    }

    /// The listening address, or the configured one while stopped or failed.
    private var address: String {
        if case .listening(let host, let port) = model.serverState {
            return MenuBarController.addressLabel(host: host, port: port)
        }
        let configuration = model.serverConfiguration
        return MenuBarController.addressLabel(host: configuration.host, port: configuration.port)
    }

    private var isFailed: Bool {
        if case .failed = model.serverState { return true }
        return false
    }

    private var isRunning: Binding<Bool> {
        Binding {
            model.serverState.isListening
        } set: { isOn in
            Task {
                if isOn {
                    await model.startServer()
                } else {
                    await model.stopServer()
                }
            }
        }
    }
}
