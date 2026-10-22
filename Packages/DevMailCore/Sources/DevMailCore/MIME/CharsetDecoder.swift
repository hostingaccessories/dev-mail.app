import Foundation

/// Converts bytes in a declared MIME charset to a String. Never fails: unknown or wrong labels fall back to
/// UTF-8, then Windows-1252, then ISO-8859-1 (which accepts any byte sequence).
enum CharsetDecoder {
    static func decode(_ bytes: some Sequence<UInt8>, charset: String?) -> String {
        let data = Data(bytes)
        if let charset, let encoding = encoding(forLabel: charset), let text = decode(data, encoding: encoding) {
            return text
        }
        return decodeUnlabeled(data)
    }

    /// For bytes with no declared charset, such as raw 8-bit header values.
    static func decodeUnlabeled(_ bytes: some Sequence<UInt8>) -> String {
        let data = Data(bytes)
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        // ISO-8859-1 maps every byte to the code point of the same value, so this cannot fail.
        return String(String.UnicodeScalarView(data.map { Unicode.Scalar($0) }))
    }

    static func encoding(forLabel label: String) -> String.Encoding? {
        let name = label.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'")).lowercased()
        guard !name.isEmpty, name.count <= 64 else { return nil }

        let cfEncoding = CFStringConvertIANACharSetNameToEncoding((aliases[name] ?? name) as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    private static func decode(_ data: Data, encoding: String.Encoding) -> String? {
        switch encoding {
        case .ascii:
            // Mail labelled US-ASCII frequently carries UTF-8 anyway; treat the label as a hint only.
            return nil
        case .isoLatin1:
            // Like browsers, read ISO-8859-1 as its Windows-1252 superset so "smart quotes" survive.
            return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
        default:
            return String(data: data, encoding: encoding)
        }
    }

    /// Labels seen in the wild that CoreFoundation does not recognise.
    private static let aliases: [String: String] = [
        "utf8": "utf-8",
        "latin1": "iso-8859-1",
        "latin-1": "iso-8859-1",
        "cp1252": "windows-1252",
        "win-1252": "windows-1252",
        "ansi_x3.4-1968": "us-ascii",
        "ascii": "us-ascii",
    ]
}
