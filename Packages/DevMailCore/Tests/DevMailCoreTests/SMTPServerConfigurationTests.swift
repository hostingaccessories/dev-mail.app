import Testing

@testable import DevMailCore

struct SMTPServerConfigurationTests {
    @Test func defaultsToLoopback() {
        let config = SMTPServerConfiguration()

        #expect(config.host == "127.0.0.1")
        #expect(config.port == 1025)
    }
}
