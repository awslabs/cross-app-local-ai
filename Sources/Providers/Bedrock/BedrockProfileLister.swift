#if BEDROCK_ENABLED

    import Foundation
    import OSLog

    private let logger = Logger(subsystem: "com.aws.fastlang", category: "bedrock-profile-lister")

    // MARK: - BedrockProfileListerError

    /// Errors surfaced by `BedrockProfileLister.listAvailableProfiles()`.
    enum BedrockProfileListerError: LocalizedError {
        /// The XPC connection to the credential helper failed or the
        /// helper process crashed mid-call.
        case helperUnreachable(String)
        /// `remoteObjectProxyWithErrorHandler` returned an object that
        /// doesn't conform to `BedrockHelperProtocol`.
        case protocolMismatch
        /// `listProfiles` replied with an error, e.g. a file failed its
        /// ownership/permission trust check.
        case listFailed(String)

        var errorDescription: String? {
            switch self {
            case let .helperUnreachable(message):
                "Bedrock helper unreachable: \(message). Try reinstalling FastLang."
            case .protocolMismatch:
                "Bedrock helper proxy unavailable (protocol mismatch)."
            case let .listFailed(message):
                message
            }
        }
    }

    // MARK: - BedrockProfileLister

    /// One-shot XPC client that asks `BedrockCredentialHelper` for the AWS
    /// profile names declared in `~/.aws/config` and `~/.aws/credentials`,
    /// so Settings can offer them as a picker instead of a free-text field.
    ///
    /// Unlike `BedrockProvider`'s `RefreshingBedrockCredentialResolver`,
    /// this makes a single call and tears the connection down immediately
    /// after — there's no credential caching or refresh concern for a
    /// one-shot profile listing.
    enum BedrockProfileLister {
        /// Fetches the current AWS profile names via the Bedrock credential
        /// helper's `listProfiles` XPC method.
        ///
        /// - Returns: Profile names, with the default profile (if any)
        ///   sorted first. Empty when no AWS configuration files exist.
        /// - Throws: `BedrockProfileListerError` if the helper is
        ///   unreachable or the underlying file read/trust check fails.
        static func listAvailableProfiles() async throws -> [String] {
            let connection = NSXPCConnection(
                serviceName: "com.aws.fastlang.bedrock-credential-helper"
            )
            connection.remoteObjectInterface = NSXPCInterface(
                with: BedrockHelperProtocol.self
            )
            connection.resume()
            defer { connection.invalidate() }

            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
                let resumeGuard = ContinuationGuard(continuation)

                let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                    resumeGuard
                        .resume(throwing: BedrockProfileListerError.helperUnreachable(error.localizedDescription))
                } as? BedrockHelperProtocol

                guard let proxy else {
                    resumeGuard.resume(throwing: BedrockProfileListerError.protocolMismatch)
                    return
                }

                proxy.listProfiles { profiles, errorMessage in
                    if let errorMessage {
                        resumeGuard.resume(throwing: BedrockProfileListerError.listFailed(errorMessage))
                        return
                    }
                    resumeGuard.resume(returning: profiles ?? [])
                }
            }
        }

        // MARK: - ContinuationGuard

        /// Single-resume wrapper for bridging `NSXPCConnection`'s
        /// dual-failure callback model to `withCheckedThrowingContinuation`.
        ///
        /// `remoteObjectProxyWithErrorHandler` and the method-level reply
        /// closure can both fire when the service crashes mid-call.
        /// Resuming a `CheckedContinuation` twice is a fatal precondition
        /// violation; this guard makes the second resume a no-op. Mirrors
        /// `BedrockProvider`'s private `ContinuationGuard`, duplicated here
        /// because that one is file-private.
        private final class ContinuationGuard<T: Sendable>: @unchecked Sendable {
            private var continuation: CheckedContinuation<T, Error>?
            private let lock = NSLock()

            init(_ continuation: CheckedContinuation<T, Error>) {
                self.continuation = continuation
            }

            func resume(returning value: sending T) {
                lock.withLock {
                    continuation?.resume(returning: value)
                    continuation = nil
                }
            }

            func resume(throwing error: Error) {
                lock.withLock {
                    continuation?.resume(throwing: error)
                    continuation = nil
                }
            }
        }
    }

#endif
