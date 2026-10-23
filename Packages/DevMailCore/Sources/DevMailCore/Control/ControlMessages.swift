import Foundation

/// The version of the request and response format shared by the app and the `dev-mail` command. Bump it whenever a
/// change would make an older client or app misread a message.
public enum ControlProtocol {
    public static let version = 1
}

/// A command sent by the `dev-mail` tool to the running app.
///
/// Message IDs are strings so the tool can pass a unique prefix of a UUID, as shown by `mail list`.
public enum ControlRequest: Codable, Sendable, Equatable {
    /// Messages newest first, optionally filtered like the app's search field.
    case listMessages(query: String?, limit: Int?, unreadOnly: Bool)
    case showMessage(id: String)
    case deleteMessages(ids: [String])
    case deleteAllMessages
    case serverStatus
    case startServer
    case stopServer
    case getSettings

    /// Applies the non-`nil` fields. Without `confirmDeletion`, a change that would delete messages is refused with
    /// `confirmationRequired`.
    case updateSettings(ControlSettingsPatch, confirmDeletion: Bool)
}

/// The app's reply to a `ControlRequest`.
public enum ControlResponse: Codable, Sendable, Equatable {
    case messages([MessageSummary])

    /// A message's summary and its original bytes, for the tool to parse and display.
    case message(MessageSummary, raw: Data)

    case deleted(count: Int)
    case status(ControlServerStatus)
    case settings(ControlSettings)

    /// The settings change would delete `count` messages and was not applied.
    case confirmationRequired(count: Int)

    /// The request failed; `reason` is meant for the user.
    case failure(reason: String)
}

/// The SMTP server's state and a summary of the stored messages.
public struct ControlServerStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case listening, stopped, failed
    }

    public var state: State

    /// The address the server listens on, or is configured to listen on when it isn't running.
    public var host: String
    public var port: UInt16

    /// Why the server failed, when `state` is `failed`.
    public var failureReason: String?

    public var messageCount: Int
    public var unreadCount: Int
    public var messagesDirectory: String

    public init(
        state: State,
        host: String,
        port: UInt16,
        failureReason: String? = nil,
        messageCount: Int,
        unreadCount: Int,
        messagesDirectory: String
    ) {
        self.state = state
        self.host = host
        self.port = port
        self.failureReason = failureReason
        self.messageCount = messageCount
        self.unreadCount = unreadCount
        self.messagesDirectory = messagesDirectory
    }
}

/// The app's settings as the tool shows them. Retention limits keep their number while switched off, as in the app.
public struct ControlSettings: Codable, Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public var limitsMessageCount: Bool
    public var maxMessageCount: Int
    public var limitsMessageAge: Bool
    public var maxAgeInDays: Int
    public var showsMenuBarItem: Bool
    public var hidesDockIcon: Bool
    public var opensAtLogin: Bool

    public init(
        host: String,
        port: UInt16,
        limitsMessageCount: Bool,
        maxMessageCount: Int,
        limitsMessageAge: Bool,
        maxAgeInDays: Int,
        showsMenuBarItem: Bool,
        hidesDockIcon: Bool,
        opensAtLogin: Bool
    ) {
        self.host = host
        self.port = port
        self.limitsMessageCount = limitsMessageCount
        self.maxMessageCount = maxMessageCount
        self.limitsMessageAge = limitsMessageAge
        self.maxAgeInDays = maxAgeInDays
        self.showsMenuBarItem = showsMenuBarItem
        self.hidesDockIcon = hidesDockIcon
        self.opensAtLogin = opensAtLogin
    }
}

/// Settings to change; `nil` fields are left as they are. The app validates every value.
public struct ControlSettingsPatch: Codable, Sendable, Equatable {
    public var host: String?
    public var port: UInt16?
    public var limitsMessageCount: Bool?
    public var maxMessageCount: Int?
    public var limitsMessageAge: Bool?
    public var maxAgeInDays: Int?
    public var showsMenuBarItem: Bool?
    public var hidesDockIcon: Bool?
    public var opensAtLogin: Bool?

    public init(
        host: String? = nil,
        port: UInt16? = nil,
        limitsMessageCount: Bool? = nil,
        maxMessageCount: Int? = nil,
        limitsMessageAge: Bool? = nil,
        maxAgeInDays: Int? = nil,
        showsMenuBarItem: Bool? = nil,
        hidesDockIcon: Bool? = nil,
        opensAtLogin: Bool? = nil
    ) {
        self.host = host
        self.port = port
        self.limitsMessageCount = limitsMessageCount
        self.maxMessageCount = maxMessageCount
        self.limitsMessageAge = limitsMessageAge
        self.maxAgeInDays = maxAgeInDays
        self.showsMenuBarItem = showsMenuBarItem
        self.hidesDockIcon = hidesDockIcon
        self.opensAtLogin = opensAtLogin
    }

    public var isEmpty: Bool {
        self == Self()
    }
}

// MARK: - Wire format

/// One request or response on the control socket: a single line of JSON with the protocol version alongside the body,
/// so either side can report a version mismatch before trying to decode a body it may not understand.
struct ControlEnvelope<Body: Codable & Sendable>: Codable, Sendable {
    var version: Int
    var body: Body

    init(_ body: Body, version: Int = ControlProtocol.version) {
        self.version = version
        self.body = body
    }
}

/// Just the version of an envelope, decodable whatever its body.
struct ControlEnvelopeVersion: Decodable {
    var version: Int
}

enum ControlCoding {
    /// The longest request line the app accepts. Requests are small; this only bounds a misbehaving client.
    static let maxRequestLength = 64 * 1024

    static func encode(_ value: some Encodable) throws -> Data {
        // JSON escapes newlines inside strings, so the encoded value is always a single line.
        var data = try JSONEncoder().encode(value)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
