import Foundation

// MARK: - Service Delegate

/// Accepts incoming XPC connections from the main FastLang app and
/// wires each one up to a fresh `HelperService` instance.
///
/// Marked `@unchecked Sendable` because `NSXPCListenerDelegate` is
/// thread-safe by Apple's contract: the system invokes
/// `shouldAcceptNewConnection` serially. We don't store mutable state
/// in the delegate itself, so the unchecked annotation is honest.
final class ServiceDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    func listener(
        _: NSXPCListener,
        shouldAcceptNewConnection conn: NSXPCConnection
    ) -> Bool {
        let svc = HelperService()
        conn.exportedInterface = NSXPCInterface(with: BedrockHelperProtocol.self)
        conn.exportedObject = svc
        conn.resume()
        return true
    }
}

// MARK: - Entry Point

//
// A file literally named `main.swift` is the conventional XPC service
// entry point: Swift allows top-level statements without the `@main`
// attribute (which is mutually exclusive with top-level code in the
// same module). `NSXPCListener.service().resume()` blocks the
// process; launchd manages lifecycle from there.

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
