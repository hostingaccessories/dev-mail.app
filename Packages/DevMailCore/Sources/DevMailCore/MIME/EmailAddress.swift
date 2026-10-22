/// A single mailbox from an address header such as From or To.
public struct EmailAddress: Sendable, Hashable {
    /// Decoded display name, if the header supplied one.
    public var name: String?

    /// The address itself, e.g. `jane@example.com`. Not validated.
    public var address: String

    public init(name: String? = nil, address: String) {
        self.name = name
        self.address = address
    }

    /// `Name <address>` when there is a display name, otherwise just the address.
    public var displayString: String {
        guard let name, !name.isEmpty else { return address }
        return "\(name) <\(address)>"
    }
}
