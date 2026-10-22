import Foundation

/// Failures reported by `MessageStore`.
public enum MessageStoreError: Error, Sendable, Equatable {
    /// No stored message has this ID.
    case messageNotFound(UUID)

    /// A message with this ID is already stored.
    case duplicateMessage(UUID)

    /// The messages folder could not be created or secured.
    case directoryUnavailable(path: String, reason: String)

    /// A message file could not be written, updated or deleted.
    case writeFailed(path: String, reason: String)

    /// A message file could not be read.
    case readFailed(path: String, reason: String)
}

extension MessageStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .messageNotFound:
            "The message could not be found."
        case .duplicateMessage:
            "The message has already been saved."
        case .directoryUnavailable(let path, let reason):
            "The messages folder at \(path) is unavailable: \(reason)"
        case .writeFailed(let path, let reason):
            "Could not write \(path): \(reason)"
        case .readFailed(let path, let reason):
            "Could not read \(path): \(reason)"
        }
    }
}
