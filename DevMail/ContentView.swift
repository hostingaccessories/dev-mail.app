import DevMailCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var selection = Set<MessageSummary.ID>()

    var body: some View {
        NavigationSplitView {
            MessageListView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                ServerStatusView()
            }
        }
        .alert(
            model.lastError?.title ?? "",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } }
            ),
            presenting: model.lastError
        ) { error in
            if error.suggestsSettings {
                Button("Open Settings") { openSettings() }
            }
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
    }

    @ViewBuilder private var detail: some View {
        if let summary = selectedSummary {
            MessageDetailView(summary: summary)
        } else if model.summaries.isEmpty {
            let configuration = model.serverConfiguration
            ContentUnavailableView(
                "No Messages",
                systemImage: "tray",
                description: Text("Send mail to SMTP server \(configuration.host):\(String(configuration.port))")
            )
        } else {
            ContentUnavailableView("No Message Selected", systemImage: "envelope")
        }
    }

    private var selectedSummary: MessageSummary? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return model.summaries.first { $0.id == id }
    }
}

#Preview {
    // Never started, so the preview doesn't touch the disk or open a port.
    ContentView()
        .environment(AppModel(directory: FileManager.default.temporaryDirectory))
}
