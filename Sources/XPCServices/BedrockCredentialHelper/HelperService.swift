import AWSSDKIdentity
import Foundation
import OSLog
import Smithy
import SmithyIdentity

private let logger = Logger(
    subsystem: "com.aws.fastlang.bedrock-credential-helper",
    category: "service"
)

// MARK: - LlmHelperError

/// Errors the credential helper surfaces to the main app. The
/// `errorDescription` is sent back verbatim through the XPC reply's
/// `errorMessage` parameter, so it must be user-actionable.
private enum LlmHelperError: LocalizedError {
    /// `~/.aws/config` or `~/.aws/credentials` failed the
    /// ownership/permission trust check, so we refuse to trust its
    /// contents (whether that's a `credential_process` directive to
    /// execute or static/chained credentials to read).
    case untrustedFile(String)

    var errorDescription: String? {
        switch self {
        case let .untrustedFile(message): message
        }
    }
}

// MARK: - HelperService

/// XPC service implementation. Resolves AWS credentials for the
/// requested profile from `~/.aws/config` and `~/.aws/credentials` and
/// returns the resulting JSON to the sandboxed main app, via one of two
/// paths:
///
/// - **Path 1** — the profile has a `credential_process` directive: run
///   it through a login shell ourselves (`runCredentialProcess`), so we
///   keep the timeout, PATH/HOME seeding, and exit-code hints that the
///   AWS SDK's own `credential_process` support can't give us.
/// - **Path 2** — it doesn't: delegate static keys,
///   `source_profile`/assume-role chains, `credential_source` chains,
///   web identity, SSO, and Login to the AWS SDK's
///   `ProfileAWSCredentialIdentityResolver` in one call
///   (`resolveViaSDK`).
///
/// This binary runs outside App Sandbox (see `Helper.entitlements`)
/// so the `exec()` syscall against whatever `credential_process`
/// binary the user has configured (and any file reads that tool
/// performs under its own state directories — e.g. a corporate SSO
/// tool reading its own cache directory under `~/`) all succeed
/// without sandbox extensions.
public final class HelperService: NSObject, BedrockHelperProtocol, @unchecked Sendable {

    #if INTERNAL_INTERACTIVE_AUTH_ENABLED
        /// Resolves to the main app's exported `MwinitAuthProgressDelegate`
        /// proxy for the XPC connection this service was vended on, or
        /// `nil` if the connection doesn't have one wired up (e.g. a
        /// unit test, which constructs `HelperService` directly instead
        /// of through `ServiceDelegate`'s `NSXPCConnection`). Supplied by
        /// `main.swift`, which is the only place with access to the raw
        /// connection.
        private let mwinitAuthDelegateProvider: @Sendable () -> MwinitAuthProgressDelegate?

        /// Drives the interactive `mwinit -f` flow. Defaults to the real
        /// `MwinitAuthLauncher.run`; tests inject a stand-in that doesn't
        /// require the real `mwinit` binary or hardware key, mirroring the
        /// `mwinitAuthDelegateProvider` injection seam above.
        private let mwinitLauncher: @Sendable (
            _ realHome: URL,
            _ delegate: MwinitAuthProgressDelegate,
            _ completion: @escaping @Sendable (Bool, String?) -> Void
        ) -> Void
    #endif

    // Explicit and `public` because `main.swift` (in the separate
    // BedrockCredentialHelper xpc-service module) constructs this type
    // via a plain `import`, not `@testable import`. A public class's
    // synthesized default initializer is `internal`, not `public`, so
    // this must be written out.
    override public init() {
        #if INTERNAL_INTERACTIVE_AUTH_ENABLED
            mwinitAuthDelegateProvider = { nil }
            mwinitLauncher = { realHome, delegate, completion in
                MwinitAuthLauncher.run(realHome: realHome, delegate: delegate, completion: completion)
            }
        #endif
        super.init()
    }

    #if INTERNAL_INTERACTIVE_AUTH_ENABLED
        /// Entry point for a service that can drive an interactive
        /// mwinit re-authentication when `credential_process` fails
        /// with an expired-session signature. `main.swift`'s
        /// `ServiceDelegate` supplies a closure resolving to the live
        /// XPC connection's exported `MwinitAuthProgressDelegate`
        /// proxy; tests supply a closure returning a mock delegate
        /// directly, with no XPC connection involved at all.
        ///
        /// - Parameter mwinitLauncher: Overridable for tests that need to
        ///   exercise `retryWithInteractiveMwinitAuth`'s branches without
        ///   invoking the real `mwinit` binary. Defaults to
        ///   `MwinitAuthLauncher.run`, matching production behavior. `nil`
        ///   is the default argument (rather than a closure literal that
        ///   calls `MwinitAuthLauncher.run` directly) because that type is
        ///   `internal`, and a `public` initializer can't reference an
        ///   `internal` symbol in a default argument expression; the
        ///   production closure is built inside the body instead, where
        ///   access-level restrictions on default arguments don't apply.
        public init(
            mwinitAuthDelegateProvider: @escaping @Sendable () -> MwinitAuthProgressDelegate?,
            mwinitLauncher: (
                @Sendable (
                    _ realHome: URL,
                    _ delegate: MwinitAuthProgressDelegate,
                    _ completion: @escaping @Sendable (Bool, String?) -> Void
                ) -> Void
            )? = nil
        ) {
            self.mwinitAuthDelegateProvider = mwinitAuthDelegateProvider
            self.mwinitLauncher = mwinitLauncher ?? { realHome, delegate, completion in
                MwinitAuthLauncher.run(realHome: realHome, delegate: delegate, completion: completion)
            }
            super.init()
        }
    #endif

    // MARK: - Health check

    public func ping(reply: @escaping @Sendable (Bool) -> Void) {
        logger.debug("ping received")
        reply(true)
    }

    // MARK: - Credential fetch

    public func fetchCredentials(
        profile: String,
        reply: @escaping @Sendable (Data?, String?) -> Void
    ) {
        let realHome: URL
        do {
            realHome = try Self.resolveRealHome()
        } catch {
            logger.error("Could not resolve user home: \(error.localizedDescription)")
            reply(nil, "Could not resolve user home directory: \(error.localizedDescription)")
            return
        }
        fetchCredentials(profile: profile, realHome: realHome, reply: reply)
    }

    /// Testable entry point: identical to `fetchCredentials(profile:reply:)`
    /// but takes the `~/.aws`-containing home directory as a parameter
    /// instead of resolving the real one, so tests can point it at a
    /// temporary directory rather than the test runner's actual
    /// `~/.aws/config` and `~/.aws/credentials`.
    func fetchCredentials(
        profile: String,
        realHome: URL,
        reply: @escaping @Sendable (Data?, String?) -> Void
    ) {
        logger.info("fetchCredentials requested for profile '\(profile, privacy: .public)'")

        let configPath = realHome.appendingPathComponent(".aws/config")
        let credentialsPath = realHome.appendingPathComponent(".aws/credentials")
        let configExists = FileManager.default.fileExists(atPath: configPath.path)
        let credentialsExists = FileManager.default.fileExists(atPath: credentialsPath.path)

        guard configExists || credentialsExists else {
            let msg = "No AWS configuration found. Expected \(configPath.path) or " +
                "\(credentialsPath.path) to exist."
            logger.error("\(msg, privacy: .public)")
            reply(nil, msg)
            return
        }

        // Defense-in-depth: `credential_process` is executed through a shell,
        // and the AWS SDK resolver below reads both files directly, so we
        // only trust a file if it is owned by the current user and not
        // writable by group/other. This mirrors the ownership checks SSH
        // makes on its config and catches a file that another account (or a
        // world-writable sync target) has tampered with, without whitelisting
        // commands or profiles (which would break legitimate tooling). See
        // the threat model, "Malicious credential_process via tampered
        // ~/.aws/config".
        for path in [configPath, credentialsPath] where FileManager.default.fileExists(atPath: path.path) {
            do {
                try Self.validateFileTrust(at: path)
            } catch {
                logger.error("Refusing to trust \(path.path): \(error.localizedDescription, privacy: .public)")
                reply(nil, error.localizedDescription)
                return
            }
        }

        let configContents: String
        if configExists {
            do {
                configContents = try String(contentsOf: configPath, encoding: .utf8)
            } catch {
                logger.error("Could not read \(configPath.path): \(error.localizedDescription)")
                reply(
                    nil,
                    "Could not read \(configPath.path): \(error.localizedDescription)"
                )
                return
            }
        } else {
            configContents = ""
        }

        // `credential_process` is permitted by the AWS CLI/SDK in either
        // file, not just ~/.aws/config -- confirmed against the AWS SDK
        // Swift and CRT Swift sources, which read it as a generic
        // file-based-config key with no file restriction. Reading it here
        // too keeps such a profile on our hardened Path 1 exec below
        // instead of silently falling through to Path 2's un-hardened
        // SDK exec.
        let credentialsContents: String
        if credentialsExists {
            do {
                credentialsContents = try String(contentsOf: credentialsPath, encoding: .utf8)
            } catch {
                logger.error("Could not read \(credentialsPath.path): \(error.localizedDescription)")
                reply(
                    nil,
                    "Could not read \(credentialsPath.path): \(error.localizedDescription)"
                )
                return
            }
        } else {
            credentialsContents = ""
        }

        // ~/.aws/config sections for non-default profiles are written
        // as `[profile NAME]`; the default profile is `[default]`. Try
        // both forms so callers can pass the user-facing profile name
        // without worrying about the prefix. ~/.aws/credentials has no
        // such prefix convention -- every section, including the default
        // profile's, is the bare profile name -- so it only needs the
        // one lookup.
        let sectionName = profile == "default" ? "default" : "profile \(profile)"
        let credentialProcessCommand = Self.parseCredentialProcess(
            from: configContents,
            section: sectionName
        ) ?? Self.parseCredentialProcess(
            from: configContents,
            section: profile
        ) ?? Self.parseCredentialProcess(
            from: credentialsContents,
            section: profile
        )

        if let command = credentialProcessCommand {
            // Path 1: a `credential_process` directive is present for this
            // profile. Run it through our hardened exec path so timeout
            // enforcement, PATH/HOME seeding, and exit-code hints keep
            // working. (The AWS SDK's own credential_process support
            // discards stderr on failure, which would make those hints
            // impossible to reproduce if this were delegated too.)
            logger.info("Executing credential_process for profile '\(profile, privacy: .public)'")
            #if INTERNAL_INTERACTIVE_AUTH_ENABLED
                Self.runCredentialProcess(command: command, realHome: realHome) { data, errorMessage in
                    guard data == nil,
                          let errorMessage,
                          Self.looksLikeExpiredMwinitSession(errorMessage),
                          let delegate = self.mwinitAuthDelegateProvider() else {
                        reply(data, errorMessage)
                        return
                    }
                    self.retryWithInteractiveMwinitAuth(
                        command: command,
                        realHome: realHome,
                        delegate: delegate,
                        originalErrorMessage: errorMessage,
                        reply: reply
                    )
                }
            #else
                Self.runCredentialProcess(
                    command: command,
                    realHome: realHome,
                    reply: reply
                )
            #endif
            return
        }

        // Path 2: no `credential_process` directive for this profile.
        // Delegate the rest of the standard AWS credential chain --
        // static keys, source_profile/assume-role, credential_source, web
        // identity, SSO, and Login -- to the SDK's own resolver in a
        // single call.
        //
        // Known limitation: if this profile's source_profile chain points
        // at a *different* profile that itself has credential_process,
        // that nested step is resolved by the SDK's own un-hardened exec
        // path, not ours, since we only inspect the top-level requested
        // profile above.
        let delegatingMessage = "No credential_process for profile '\(profile)'; " +
            "delegating to AWS SDK profile resolver"
        logger.info("\(delegatingMessage, privacy: .public)")
        Self.resolveViaSDK(
            profile: profile,
            configFilePath: configExists ? configPath.path : nil,
            credentialsFilePath: credentialsExists ? credentialsPath.path : nil,
            reply: reply
        )
    }

    // MARK: - Subprocess execution

    /// Maximum time to wait for a `credential_process` invocation before
    /// forcibly terminating it. Long enough for tools that refresh a
    /// corporate SSO session cookie, short enough that a hung tool
    /// doesn't wedge the XPC thread — and the app's Bedrock requests —
    /// indefinitely.
    private static let credentialProcessTimeout: TimeInterval = 45

    /// Runs `command` through `/bin/bash -l -c` with a sanitized
    /// environment that mirrors a typical interactive shell: Homebrew
    /// + Toolbox bin paths first, then the system default, with `HOME`
    /// pointing at the user's real home (not any sandbox container
    /// the helper may have inherited via launchd).
    ///
    /// On failure the stderr is captured and returned as the error
    /// message so the main app can surface a real reason rather than
    /// just an exit code.
    private static func runCredentialProcess(
        command: String,
        realHome: URL,
        reply: @escaping @Sendable (Data?, String?) -> Void
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-l", "-c", command]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = SubprocessEnvironment.build(realHome: realHome)

        // Signalled when the subprocess exits so we can bound the wait
        // below. Must be installed before `run()`.
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            logger.error("Process.run() failed: \(error.localizedDescription)")
            reply(nil, "Failed to launch /bin/bash: \(error.localizedDescription)")
            return
        }

        // Guard against a hung credential_process (network stall, a tool
        // prompting on stdin, a deadlock, or a full stdout pipe) blocking
        // this XPC thread — and therefore every Bedrock request — forever.
        // If it doesn't finish within the timeout, terminate it and return
        // an actionable error instead of hanging.
        if finished.wait(timeout: .now() + credentialProcessTimeout) == .timedOut {
            logger.error(
                "credential_process exceeded \(Int(Self.credentialProcessTimeout))s; terminating"
            )
            process.terminate()
            reply(
                nil,
                "credential_process for this AWS profile timed out after " +
                    "\(Int(Self.credentialProcessTimeout))s. The tool may be waiting on the " +
                    "network or for input. Run your credential_process command " +
                    "directly in a terminal (refreshing any corporate SSO session " +
                    "it depends on first) and try again."
            )
            return
        }

        let exitCode = process.terminationStatus
        if exitCode != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(
                data: stderrData.prefix(2048),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hint = exitCodeHint(for: exitCode, stderr: stderr)
            let message = "credential_process exited with status \(exitCode)." +
                (stderr.isEmpty ? "" : "\n\nstderr:\n\(stderr)") +
                (hint.isEmpty ? "" : "\n\n\(hint)")
            logger.error("credential_process failed: exit=\(exitCode), stderr=\(stderr, privacy: .public)")
            reply(nil, message)
            return
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard !stdoutData.isEmpty else {
            logger.error("credential_process returned empty stdout")
            reply(nil, "credential_process succeeded but returned no output.")
            return
        }

        logger.info("credential_process succeeded, \(stdoutData.count) bytes returned")
        reply(stdoutData, nil)
    }

    #if INTERNAL_INTERACTIVE_AUTH_ENABLED

        // MARK: - Interactive mwinit re-authentication

        /// Drives an interactive `mwinit -f` re-authentication through
        /// `MwinitAuthLauncher`, then retries the original
        /// `credential_process` command exactly once if it succeeds.
        /// Called only when `fetchCredentials` has already confirmed
        /// the failure looks like an expired mwinit session and the
        /// main app has an `MwinitAuthProgressDelegate` proxy exported
        /// on this connection.
        ///
        /// - Parameters:
        ///   - command: The original `credential_process` command,
        ///     re-run unchanged once `mwinit` succeeds.
        ///   - realHome: Passed through to both `MwinitAuthLauncher`
        ///     and the retried `credential_process` run.
        ///   - delegate: Forwards PIN/touch prompts to the main app.
        ///   - originalErrorMessage: The `credential_process` failure
        ///     that triggered this retry, surfaced verbatim if `mwinit`
        ///     itself fails rather than inventing a new message.
        ///   - reply: Called exactly once with the retried
        ///     `credential_process` outcome, or `originalErrorMessage`
        ///     if `mwinit` didn't succeed.
        private func retryWithInteractiveMwinitAuth(
            command: String,
            realHome: URL,
            delegate: MwinitAuthProgressDelegate,
            originalErrorMessage: String,
            reply: @escaping @Sendable (Data?, String?) -> Void
        ) {
            logger.info(
                "credential_process failure looks like an expired mwinit session; starting interactive re-authentication"
            )
            mwinitLauncher(realHome, delegate) { success, mwinitErrorMessage in
                guard success else {
                    reply(nil, mwinitErrorMessage ?? originalErrorMessage)
                    return
                }
                logger.info("Interactive mwinit re-authentication succeeded; retrying credential_process")
                Self.runCredentialProcess(command: command, realHome: realHome, reply: reply)
            }
        }

        /// Whether `text` (stderr from a failed `credential_process`, or
        /// the composed error message built from it) indicates an expired
        /// mwinit-backed corporate SSO session.
        ///
        /// Gated behind `INTERNAL_INTERACTIVE_AUTH_ENABLED`: this check
        /// drives both the automatic interactive-reauth trigger above and
        /// `exitCodeHint`'s internal-build manual "run mwinit" hint, so
        /// they share one source of truth instead of drifting.
        ///
        /// Deliberately matches specific known phrases rather than the
        /// bare substring "mwinit": this check gates an automatic
        /// interactive PIN/hardware-key-touch prompt, so a credential_process
        /// that merely emits "mwinit" somewhere in its stderr (adversarial
        /// or otherwise) must not be able to trigger it. "run mwinit" covers
        /// the documented real-world phrasing some corporate SSO tools use;
        /// the "mwinit -f"/"mwinit -o" forms cover tools that print the
        /// literal command instead.
        private static func looksLikeExpiredMwinitSession(_ text: String) -> Bool {
            let lowered = text.lowercased()
            let triggerPhrases = ["run mwinit", "mwinit -f", "mwinit -o"]
            return triggerPhrases.contains { lowered.contains($0) }
        }
    #endif

    // MARK: - SDK profile resolution (Path 2)

    /// Maximum time to wait for the AWS SDK's profile resolver before
    /// giving up. Covers static-key lookups (effectively instant) as
    /// well as network-bound paths (STS assume-role, SSO token refresh)
    /// that could otherwise hang the XPC call indefinitely.
    private static let sdkResolveTimeout: TimeInterval = 45

    /// Resolves `profile` via the AWS SDK's own
    /// `ProfileAWSCredentialIdentityResolver`, which internally handles
    /// static keys, `source_profile`/assume-role chains,
    /// `credential_source` chains, web identity, SSO, and Login -- in
    /// that priority order -- without any custom parsing on our side.
    ///
    /// Unlike `runCredentialProcess`, this never execs a subprocess or
    /// opens a browser: SSO/Login only read cached token files under
    /// `realHome` and refresh them over HTTPS when expired.
    ///
    /// `configFilePath`/`credentialsFilePath` are `nil` when the
    /// corresponding file doesn't exist on disk, matching
    /// `ProfileAWSCredentialIdentityResolver`'s own documented fallback
    /// (env var, then `~/.aws/config` or `~/.aws/credentials`) rather than
    /// pointing it at a path we already know is missing.
    private static func resolveViaSDK(
        profile: String,
        configFilePath: String?,
        credentialsFilePath: String?,
        reply: @escaping @Sendable (Data?, String?) -> Void
    ) {
        let resolver = ProfileAWSCredentialIdentityResolver(
            profileName: profile,
            configFilePath: configFilePath,
            credentialsFilePath: credentialsFilePath
        )

        Task {
            do {
                let identity = try await withTimeout(seconds: sdkResolveTimeout) {
                    try await resolver.getIdentity(identityProperties: nil)
                }
                let data = try encodeCredentials(identity)
                logger.info("SDK profile resolution succeeded for '\(profile, privacy: .public)'")
                reply(data, nil)
            } catch {
                let message = describeSDKResolutionFailure(error, profile: profile)
                logger.error(
                    "SDK profile resolution failed for '\(profile, privacy: .public)': \(message, privacy: .public)"
                )
                reply(nil, message)
            }
        }
    }

    /// Races `operation` against a `seconds`-long timer and throws
    /// `SDKResolutionTimeout` if the timer wins. The loser is cancelled.
    ///
    /// Not `private`, matching the `fetchCredentials(profile:realHome:reply:)`
    /// "testable entry point" convention elsewhere in this file: unit tests
    /// call this directly via `@testable import` to verify the timeout
    /// actually elapses on schedule, independent of the AWS SDK resolver
    /// `resolveViaSDK` otherwise couples it to.
    ///
    /// Deliberately avoids `withThrowingTaskGroup`: a task group's
    /// enclosing call doesn't return until every child task has actually
    /// finished -- cancelled or not -- so if `operation` doesn't observe
    /// cooperative cancellation (plausible here; see `fetchCredentials`'s
    /// "Known limitation" comment on nested `credential_process` chains
    /// resolved via the SDK's own un-hardened exec path), the whole call
    /// blocks well past `seconds` instead of returning on time. Racing an
    /// unstructured `Task` against a timer through a single-resolution
    /// guard -- the same `NSLock`-protected pattern used elsewhere in
    /// this XPC service for racing completion handlers -- lets this
    /// reply on time regardless. The loser is cancelled but left to
    /// keep running in the background rather than block this call,
    /// matching how a hung `credential_process` is handled elsewhere
    /// in this file.
    static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let resumeGuard = ResumeGuard()

            let workTask = Task {
                do {
                    let result = try await operation()
                    if resumeGuard.markResumed() {
                        continuation.resume(returning: result)
                    }
                } catch {
                    if resumeGuard.markResumed() {
                        continuation.resume(throwing: error)
                    }
                }
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if resumeGuard.markResumed() {
                    workTask.cancel()
                    continuation.resume(throwing: SDKResolutionTimeout())
                }
            }
        }
    }

    /// Thrown by `withTimeout` when `operation` doesn't finish in time.
    struct SDKResolutionTimeout: Error {}

    /// Lock-protected single-resolution guard for `withTimeout`'s race
    /// between `operation` and its timeout timer, mirroring the same
    /// single-resolution-guard pattern used elsewhere in this XPC
    /// service for racing completion handlers: both competing `Task`s
    /// can call `markResumed()` concurrently, but only the first call
    /// returns `true`, so `continuation.resume` is guaranteed to fire
    /// exactly once.
    private final class ResumeGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false

        func markResumed() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return false }
            resumed = true
            return true
        }
    }

    /// Wire shape expected by `BedrockProvider.CredentialProcessOutput`
    /// -- the same JSON a `credential_process` tool would print to
    /// stdout -- so no changes are needed on the main-app side to
    /// consume credentials resolved via either path.
    private struct SDKCredentialPayload: Encodable {
        let version = 1
        let accessKeyId: String
        let secretAccessKey: String
        let sessionToken: String?
        let expiration: Date?

        enum CodingKeys: String, CodingKey {
            case version = "Version"
            case accessKeyId = "AccessKeyId"
            // Field name mirrors the credential_process JSON spec, not a secret value.
            case secretAccessKey = "SecretAccessKey" // pragma: allowlist secret
            case sessionToken = "SessionToken"
            case expiration = "Expiration"
        }
    }

    private static func encodeCredentials(_ identity: AWSCredentialIdentity) throws -> Data {
        let payload = SDKCredentialPayload(
            accessKeyId: identity.accessKey,
            secretAccessKey: identity.secret,
            sessionToken: identity.sessionToken,
            expiration: identity.expiration
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    /// Turns an SDK resolution failure into a user-actionable message.
    private static func describeSDKResolutionFailure(_ error: Error, profile: String) -> String {
        if error is SDKResolutionTimeout {
            return "Resolving AWS credentials for profile '\(profile)' timed out after " +
                "\(Int(sdkResolveTimeout))s. If this profile uses SSO, run " +
                "`aws sso login --profile \(profile)` in a terminal and try again."
        }
        if let resolverError = error as? AWSCredentialIdentityResolverError {
            switch resolverError {
            case let .failedToResolveAWSCredentials(message):
                return "Failed to resolve AWS credentials for profile '\(profile)': \(message)"
            }
        }
        return "Failed to resolve AWS credentials for profile '\(profile)': \(error.localizedDescription)"
    }

    // MARK: - INI parsing

    /// Walks an INI-style file looking for `credential_process = ...`
    /// inside the section header `[<section>]`. Returns the trimmed
    /// command on the right-hand side, or `nil` if either the section
    /// is missing or it doesn't declare a credential_process.
    private static func parseCredentialProcess(
        from contents: String,
        section: String
    ) -> String? {
        var inTargetSection = false

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
                continue
            }

            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                let name = String(trimmed.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                inTargetSection = name == section
                continue
            }

            guard inTargetSection else { continue }

            if trimmed.hasPrefix("credential_process") {
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                return String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }

        return nil
    }

    // MARK: - Config trust validation

    /// Rejects a `~/.aws/config` or `~/.aws/credentials` file we shouldn't
    /// trust the contents of.
    ///
    /// `credential_process` directives are run through a shell, and static
    /// keys / profile chains in either file are read by the AWS SDK and fed
    /// straight into Bedrock requests, so we require each file to be a
    /// regular file owned by the current user and not writable by group or
    /// other. This catches a file that a different account or a
    /// world-writable sync target has tampered with. It intentionally does
    /// *not* whitelist commands or profiles — `credential_process` tooling
    /// varies too widely — matching how the AWS CLI itself trusts file
    /// contents while adding an ownership/permission gate.
    ///
    /// - Parameter path: The `~/.aws/config` or `~/.aws/credentials` URL to validate.
    /// - Throws: `LlmHelperError` if the file is missing, not a regular file,
    ///   owned by another user, or group/other-writable.
    private static func validateFileTrust(at path: URL) throws {
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        } catch {
            throw LlmHelperError.untrustedFile(
                "Could not read attributes of \(path.path): \(error.localizedDescription)"
            )
        }

        guard (attrs[.type] as? FileAttributeType) == .typeRegular else {
            throw LlmHelperError.untrustedFile(
                "\(path.path) is not a regular file; refusing to trust its contents."
            )
        }

        // Ownership: the file must belong to the user running this helper.
        let fileOwner = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value
        guard let fileOwner, fileOwner == getuid() else {
            throw LlmHelperError.untrustedFile(
                "\(path.path) is not owned by the current user; refusing to trust " +
                    "a file owned by another account."
            )
        }

        // Permissions: reject if group or other can write (0o022). A tampered,
        // world-writable file is the exact case we're guarding against.
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        if perms & 0o022 != 0 {
            let octal = String(perms, radix: 8)
            throw LlmHelperError.untrustedFile(
                "\(path.path) is writable by group or other (mode \(octal)); refusing to " +
                    "trust it. Run `chmod 600 \(path.path)` and retry."
            )
        }
    }

    // MARK: - Home resolution

    /// Returns the user's real home directory by reading the local
    /// directory record via `getpwuid`. Avoids `NSHomeDirectory()` and
    /// `FileManager.homeDirectoryForCurrentUser`, which can be
    /// redirected by launchd / sandbox container settings.
    private static func resolveRealHome() throws -> URL {
        if let pw = getpwuid(getuid()), let cString = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: cString))
        }
        throw NSError(
            domain: "com.aws.fastlang.bedrock-credential-helper",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "getpwuid returned nil"]
        )
    }

    // MARK: - Diagnostic hints

    /// One-line hint for common credential_process exit codes. The
    /// hint is appended to the error message we send back to the main
    /// app so the user sees actionable guidance, not just numbers.
    private static func exitCodeHint(for exitCode: Int32, stderr: String) -> String {
        switch exitCode {
        case 127:
            "Tool not found on PATH. Confirm your configured " +
                "credential_process binary is installed at /opt/homebrew/bin, " +
                "/usr/local/bin, or ~/.toolbox/bin."
        case 126:
            "Command found but not executable (permissions?)."
        default:
            #if INTERNAL_INTERACTIVE_AUTH_ENABLED
                // Some corporate SSO tools print a "run mwinit" style
                // phrase to stderr when the session cookie is missing
                // or expired. Surface that as an actionable hint when
                // it's present, since it's the most common reason
                // credential_process fails for internal builds wired
                // up to interactive re-authentication.
                looksLikeExpiredMwinitSession(stderr)
                    ? "Run `mwinit` in a terminal to refresh your session, " +
                    "then trigger generation again."
                    : ""
            #else
                ""
            #endif
        }
    }
}
