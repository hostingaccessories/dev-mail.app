import DevMailCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var selection: Set<MessageSummary.ID>

    /// Whether the selected message's headers panel is open. Kept here because it widens the window's minimum size.
    @SceneStorage("MessageDetail.showsHeaders") private var showsHeaders = false

    private static let sidebarMinimumWidth: CGFloat = 240
    private static let minimumSize = CGSize(width: 720, height: 420)

    /// `selection` is the initially selected messages; UI snapshot tests use it to open a message.
    init(selection: Set<MessageSummary.ID> = []) {
        _selection = State(initialValue: selection)
    }

    var body: some View {
        NavigationSplitView {
            MessageListView(selection: $selection)
                .navigationSplitViewColumnWidth(min: Self.sidebarMinimumWidth, ideal: 300)
        } detail: {
            detail
        }
        .frame(minWidth: minimumWidth, minHeight: Self.minimumSize.height)
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
            MessageDetailView(summary: summary, showsHeaders: $showsHeaders)
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

    /// Wide enough for the sidebar, the message and, when open, the headers panel, so no column is clipped.
    private var minimumWidth: CGFloat {
        let detail = MessageDetailView.minimumWidth(showingHeaders: showsHeaders && selectedSummary != nil)
        return max(Self.minimumSize.width, Self.sidebarMinimumWidth + detail)
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
