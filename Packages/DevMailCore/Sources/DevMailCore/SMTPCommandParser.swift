import Foundation

/// Parsing helpers for SMTP command arguments.
enum SMTPCommandParser {
    /// Splits a command line into its uppercased verb and the trimmed remainder.
    static func splitCommand(_ line: String) -> (verb: String, argument: String) {
        guard let space = line.firstIndex(of: " ") else {
            return (line.trimmingCharacters(in: .whitespaces).uppercased(), "")
        }
        let verb = line[..<space].uppercased()
        let argument = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
        return (verb, argument)
    }

    static func isValidBase64(_ text: String) -> Bool {
        !text.isEmpty && Data(base64Encoded: text) != nil
    }

    /// Parses `FROM:<address> PARAM=value ...` or `TO:<address> ...`. Returns an empty address for `<>`.
    static func parsePath(_ argument: String, prefix: String) -> (address: String, parameters: [String])? {
        guard argument.uppercased().hasPrefix(prefix) else { return nil }
        let remainder = argument.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)

        var address: String
        let parameterText: Substring
        if remainder.hasPrefix("<") {
            guard let closing = remainder.firstIndex(of: ">") else { return nil }
            address = String(remainder[remainder.index(after: remainder.startIndex)..<closing])
            parameterText = remainder[remainder.index(after: closing)...]
        } else {
            // Be lenient with clients that omit the angle brackets.
            let parts = remainder.split(separator: " ", maxSplits: 1)
            guard let first = parts.first else { return nil }
            address = String(first)
            parameterText = parts.count > 1 ? parts[1] : ""
        }

        // Drop an obsolete source route such as "@relay.example:user@example.com".
        if address.hasPrefix("@"), let colon = address.firstIndex(of: ":") {
            address = String(address[address.index(after: colon)...])
        }
        let parameters = parameterText.split(separator: " ").map(String.init)
        return (address, parameters)
    }

    static func sizeParameter(_ parameters: [String]) -> Int? {
        for parameter in parameters where parameter.uppercased().hasPrefix("SIZE=") {
            return Int(parameter.dropFirst("SIZE=".count))
        }
        return nil
    }
}
