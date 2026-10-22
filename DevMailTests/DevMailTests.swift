import Testing

@testable import DevMail

@MainActor
struct DevMailTests {
    @Test func contentViewUsesDefaultConfiguration() {
        let view = ContentView()

        #expect(view.configuration.port == 1025)
    }
}
