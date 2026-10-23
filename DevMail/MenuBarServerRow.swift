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
                Text(status)
                    .font(.caption)
                    .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Toggle("", isOn: isRunning)
                .toggleStyle(MenuSwitchToggleStyle())
                .labelsHidden()
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

    /// The address is already shown above, so only the failure needs details.
    private var status: String {
        switch model.serverState {
        case .listening: "Listening"
        case .stopped: "Stopped"
        case .failed: model.serverState.statusText
        }
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

/// A switch that is green while on, like Control Center's. The system switch draws gray in a menu because the menu's
/// window is never key, and it ignores `tint` there.
private struct MenuSwitchToggleStyle: ToggleStyle {
    private static let size = CGSize(width: 32, height: 18)
    private static let knobInset: CGFloat = 2

    func makeBody(configuration: Configuration) -> some View {
        let knobDiameter = Self.size.height - Self.knobInset * 2
        Capsule()
            .fill(configuration.isOn ? AnyShapeStyle(.green) : AnyShapeStyle(.quaternary))
            .frame(width: Self.size.width, height: Self.size.height)
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .frame(width: knobDiameter, height: knobDiameter)
                    .padding(Self.knobInset)
            }
            .animation(.snappy(duration: 0.15), value: configuration.isOn)
            .contentShape(Capsule())
            .onTapGesture { configuration.isOn.toggle() }
    }
}
