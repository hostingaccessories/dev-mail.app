import AppKit
import DevMailCore
import Foundation

/// Fixture messages covering the list and detail layouts: HTML with an inline image, remote content and attachments;
/// plain text; long subjects; read and unread.
enum SnapshotFixtures {
    static let htmlSubject = "Welcome to Acme — confirm your email address"
    static let textSubject = "Your password reset code"
    static let readSubject = "Weekly digest: 12 new comments on your posts"

    static func messages() -> [ReceivedMessage] {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        return [
            message(subject: htmlSubject, from: "Acme <hello@acme.example>", body: htmlBody(), at: now),
            message(
                subject: textSubject,
                from: "Acme Security <security@acme.example>",
                body: textBody(),
                at: now - 300
            ),
            message(
                subject: readSubject,
                from: "Acme Notifications <notify@acme.example>",
                body: plainPart("You have 12 new comments."),
                at: now - 3_600
            ),
            message(
                subject: "Invoice INV-2026-0042 for October is now available and ready to download from your account",
                from: "billing@acme.example",
                body: plainPart("Your invoice is attached."),
                at: now - 86_400
            ),
            message(
                subject: "",
                from: "noreply@acme.example",
                body: plainPart("A message without a subject."),
                at: now - 172_800
            ),
        ]
    }

    private static func message(subject: String, from: String, body: String, at date: Date) -> ReceivedMessage {
        let headers = [
            "From: \(from)",
            "To: Jane Developer <jane@example.test>",
            "Subject: \(subject)",
            "Date: \(rfc5322Date(date))",
            "MIME-Version: 1.0",
        ]
        let raw = (headers.joined(separator: "\r\n") + "\r\n" + body).replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        return ReceivedMessage(
            envelopeSender: "bounce@acme.example",
            recipients: ["jane@example.test", "bcc-audit@example.test"],
            data: Data(raw.utf8),
            receivedAt: date
        )
    }

    private static func plainPart(_ text: String) -> String {
        "Content-Type: text/plain; charset=utf-8\n\n\(text)\n"
    }

    private static func textBody() -> String {
        plainPart(
            """
            Hi Jane,

            Someone asked to reset the password for your Acme account. Your code is:

                482 913

            It expires in 15 minutes. If you didn't ask for this, you can ignore this email.

            — The Acme team
            """
        )
    }

    private static let welcomeHTML = """
        <!DOCTYPE html>
        <html><body style="font-family: -apple-system, sans-serif; margin: 0; padding: 24px; color: #222">
          <img src="cid:logo@acme.example" width="48" height="48" alt="Acme">
          <h1 style="font-size: 22px">Confirm your email address</h1>
          <p>Thanks for signing up, Jane. Confirm your address to finish creating your account.</p>
          <p><a href="https://acme.example/confirm?token=abc123"
                style="display: inline-block; background: #3b6ef5; color: white; padding: 10px 18px;
                       border-radius: 6px; text-decoration: none">Confirm email</a></p>
          <p style="color: #777; font-size: 12px">If the button doesn't work, paste this link into your browser:
             https://acme.example/confirm?token=abc123</p>
          <img src="https://tracker.acme.example/open.gif" width="1" height="1" alt="">
        </body></html>
        """

    private static func htmlBody() -> String {
        let text = "Thanks for signing up, Jane. Confirm your address: https://acme.example/confirm?token=abc123"
        let csv = "date,amount\n2026-10-01,42.00\n"
        return """
            Content-Type: multipart/mixed; boundary="mixed"

            --mixed
            Content-Type: multipart/related; boundary="related"

            --related
            Content-Type: multipart/alternative; boundary="alt"

            --alt
            Content-Type: text/plain; charset=utf-8

            \(text)
            --alt
            Content-Type: text/html; charset=utf-8

            \(welcomeHTML)
            --alt--
            --related
            Content-Type: image/png
            Content-ID: <logo@acme.example>
            Content-Transfer-Encoding: base64

            \(logoPNG().base64EncodedString(options: .lineLength76Characters))
            --related--
            --mixed
            Content-Type: application/pdf; name="welcome-guide.pdf"
            Content-Disposition: attachment; filename="welcome-guide.pdf"
            Content-Transfer-Encoding: base64

            \(Data("%PDF-1.4\n%%EOF\n".utf8).base64EncodedString())
            --mixed
            Content-Type: text/csv; name="usage.csv"
            Content-Disposition: attachment; filename="usage.csv"

            \(csv)
            --mixed--

            """
    }

    private static func logoPNG() -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 48,
            pixelsHigh: 48,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let bitmap, let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.systemIndigo.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 48, height: 48), xRadius: 10, yRadius: 10).fill()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }

    private static func rfc5322Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}
