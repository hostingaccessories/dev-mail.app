import Testing

@testable import DevMailCore

struct ReadableBodyTests {
    @Test func keepsBlockStructure() {
        let html = """
            <html><head><title>Hidden</title><style>p { color: red }</style></head><body>
            <h1>Welcome,
              Jane</h1>
            <p>Thanks for signing up.<br>Your code is <b>1234</b>.</p>
            <ul><li>First</li><li>Second &amp; last</li></ul>
            <table><tr><td>Total</td><td>$42.00</td></tr></table>
            <!-- a comment -->
            <p>&copy; Acme</p>
            </body></html>
            """
        #expect(
            HTMLText.readableText(fromHTML: html) == """
                Welcome, Jane

                Thanks for signing up.
                Your code is 1234.

                • First
                • Second & last

                Total $42.00

                © Acme
                """
        )
    }

    @Test func prefersPlainTextBody() {
        var message = ParsedMessage(htmlBody: "<p>HTML</p>", textBody: "Plain\n\nText\n")
        #expect(message.readableBody == "Plain\n\nText\n")

        message.textBody = " \n"
        #expect(message.readableBody == "HTML")

        message.htmlBody = nil
        #expect(message.readableBody == nil)
    }
}
