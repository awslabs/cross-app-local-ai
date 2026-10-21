import BedrockCredentialHelperCore
import Foundation

// MARK: - Service Delegate

#if INTERNAL_INTERACTIVE_AUTH_ENABLED
    /// Weakly-held, `Sendable` box around an `NSXPCConnection`, so it can be
    /// captured by the `@Sendable` closure `HelperService` requires for its
    /// `mwinitAuthDelegateProvider`.
    ///
    /// `NSXPCConnection` itself doesn't conform to `Sendable`, but its
    /// proxy-vending methods are part of XPC's cross-thread contract: a
    /// listener's exported object methods (and therefore the reply
    /// closures that later call back into this box) can run on any
    /// thread, so Apple's own API surface is already designed to have
    /// `remoteObjectProxyWithErrorHandler` invoked from somewhere other
    /// than the thread that created the connection. The `weak` reference
    /// mirrors `main.swift`'s prior `[weak conn]` capture: this box must
    /// not keep the connection alive past the point `ServiceDelegate`
    /// would otherwise let it deallocate.
    private final class WeakXPCConnectionBox: @unchecked Sendable {
        private weak var connection: NSXPCConnection?

        init(_ connection: NSXPCConnection) {
            self.connection = connection
        }

        func remoteAuthProgressDelegate() -> MwinitAuthProgressDelegate? {
            connection?.remoteObjectProxyWithErrorHandler { _ in
                // No-op: a failure here just means no delegate was
                // available this round, which the caller already
                // handles as a nil result.
            } as? MwinitAuthProgressDelegate
        }
    }
#endif

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
        conn.exportedInterface = NSXPCInterface(with: BedrockHelperProtocol.self)

        let svc: HelperService
        #if INTERNAL_INTERACTIVE_AUTH_ENABLED
            // The main app exports its own MwinitAuthProgressDelegate
            // conformer on this same connection (see BedrockProvider's
            // client-side setup); this is the reverse-direction
            // interface the helper uses to obtain a callable proxy for
            // it when an interactive mwinit re-authentication is needed.
            conn.remoteObjectInterface = NSXPCInterface(with: MwinitAuthProgressDelegate.self)
            let connectionBox = WeakXPCConnectionBox(conn)
            svc = HelperService(mwinitAuthDelegateProvider: {
                connectionBox.remoteAuthProgressDelegate()
            })
        #else
            svc = HelperService()
        #endif

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
