import Foundation

/// Parses Date header values: RFC 5322 (and obsolete RFC 822 forms) plus common sloppy variants such as missing
/// weekdays or seconds, two-digit years, named zones, `21-Oct-2026`, asctime order, and ISO 8601.
enum MailDateParser {
    private struct Fields {
        var day: Int?
        var month: Int?
        var year: Int?
        var hour = 0
        var minute = 0
        var second = 0
        var offsetSeconds = 0
        var numbers: [Int] = []
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// Offsets in hours for zone names (RFC 5322 §4.3 plus a few common European ones). Unknown names mean UTC,
    /// as RFC 5322 prescribes for military zones.
    private static let zoneOffsets: [String: Int] = [
        "ut": 0, "utc": 0, "gmt": 0, "z": 0,
        "est": -5, "edt": -4, "cst": -6, "cdt": -5, "mst": -7, "mdt": -6, "pst": -8, "pdt": -7,
        "bst": 1, "cet": 1, "cest": 2,
    ]

    static func parse(_ raw: String) -> Date? {
        let text = removeComments(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 256 else { return nil }

        if let date = try? Date(text, strategy: .iso8601) {
            return date
        }

        var fields = Fields()
        for token in tokenize(text) {
            apply(token, to: &fields)
        }
        return makeDate(from: fields)
    }

    private static func tokenize(_ text: String) -> [Substring] {
        text.split { $0.isWhitespace || $0 == "," }.flatMap { token -> [Substring] in
            // `21-Oct-2026`: split on dashes, but never touch a numeric zone like `-0700`.
            if token.contains(where: \.isLetter), !token.hasPrefix("-") {
                return token.split(separator: "-")
            }
            return [token]
        }
    }

    private static func apply(_ token: Substring, to fields: inout Fields) {
        if token.contains(":") {
            applyTime(token, to: &fields)
        } else if let first = token.first, first == "+" || first == "-" {
            if let offset = numericOffset(token.dropFirst()) {
                fields.offsetSeconds = first == "-" ? -offset : offset
            }
        } else if token.allSatisfy(\.isLetter) {
            let lowered = token.lowercased()
            if lowered.count >= 3, let index = months.firstIndex(of: String(lowered.prefix(3))) {
                fields.month = index + 1
            } else if let hours = zoneOffsets[lowered] {
                fields.offsetSeconds = hours * 3_600
            }
        } else if token.allSatisfy(\.isNumber), let number = Int(token) {
            fields.numbers.append(number)
        } else {
            applyNumericDate(token, to: &fields)
        }
    }

    /// `HH:MM[:SS[.fraction]]`.
    private static func applyTime(_ token: Substring, to fields: inout Fields) {
        let parts = token.split(separator: ":").map { Int($0.prefix { $0.isNumber }) }
        guard parts.count >= 2, let hour = parts[0], let minute = parts[1] else { return }
        fields.hour = hour
        fields.minute = minute
        fields.second = parts.count > 2 ? parts[2] ?? 0 : 0
    }

    /// `HHMM` or `HH:MM` after the sign.
    private static func numericOffset(_ value: Substring) -> Int? {
        let digits = value.filter(\.isNumber)
        guard digits.count == 4, let number = Int(digits) else { return nil }
        let hours = number / 100
        let minutes = number % 100
        guard hours <= 14, minutes < 60 else { return nil }
        return hours * 3_600 + minutes * 60
    }

    /// `YYYY-MM-DD`, as in `2026-10-21 10:00:00 +0000`.
    private static func applyNumericDate(_ token: Substring, to fields: inout Fields) {
        let parts = token.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] > 31 else { return }
        fields.year = parts[0]
        fields.month = parts[1]
        fields.day = parts[2]
    }

    private static func makeDate(from fields: Fields) -> Date? {
        var day = fields.day
        var year = fields.year
        if day == nil, year == nil, fields.numbers.count >= 2 {
            // "21 Oct 2026" and asctime "Oct 21 ... 2026" both yield [day, year]; "2026 Oct 21" is reversed.
            let (first, second) = (fields.numbers[0], fields.numbers[1])
            (day, year) = first > 31 ? (second, first) : (first, second)
        }
        guard let month = fields.month, let day, let year = year.map(expandYear) else { return nil }
        guard (1...12).contains(month), (1...31).contains(day), (0...23).contains(fields.hour),
            (0...59).contains(fields.minute), (0...60).contains(fields.second)
        else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = DateComponents(
            year: year,
            month: month,
            day: day,
            hour: fields.hour,
            minute: fields.minute,
            second: min(fields.second, 59)
        )
        return calendar.date(from: components)?.addingTimeInterval(TimeInterval(-fields.offsetSeconds))
    }

    /// RFC 5322 §4.3: two-digit years below 50 are 20xx, others 19xx; three-digit years add 1900.
    private static func expandYear(_ year: Int) -> Int {
        switch year {
        case 0..<50: 2000 + year
        case 50..<1000: 1900 + year
        default: year
        }
    }

    private static func removeComments(_ raw: String) -> String {
        var result = ""
        var depth = 0
        for character in raw {
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth = max(0, depth - 1)
            } else if depth == 0 {
                result.append(character)
            }
        }
        return result
    }
}
