import DevMailCore
import SwiftUI

struct ContentView: View {
    let configuration = SMTPServerConfiguration()

    var body: some View {
        NavigationSplitView {
            List {}
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            ContentUnavailableView(
                "No Messages",
                systemImage: "tray",
                description: Text("SMTP server: \(configuration.host):\(String(configuration.port))")
            )
        }
    }
}

#Preview {
    ContentView()
}
