import Foundation
import Network

/// Reasons the SMTP server can fail to start or stop listening.
public enum SMTPServerError: Error, Sendable, Equatable {
    /// Another process is already listening on the port.
    case addressInUse(port: UInt16)

    /// The system refused to let the server bind to the port.
    case permissionDenied(port: UInt16)

    /// Any other listener failure, with the system's description.
    case listenerFailed(reason: String)

    init(_ error: any Error, port: UInt16) {
        switch error as? NWError {
        case .posix(.EADDRINUSE):
            self = .addressInUse(port: port)
        case .posix(.EACCES), .posix(.EPERM):
            self = .permissionDenied(port: port)
        default:
            self = .listenerFailed(reason: String(describing: error))
        }
    }
}

extension SMTPServerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .addressInUse(let port):
            "Port \(port) is already in use by another application."
        case .permissionDenied(let port):
            "Permission denied when listening on port \(port)."
        case .listenerFailed(let reason):
            "The SMTP server could not listen for connections: \(reason)"
        }
    }
}
