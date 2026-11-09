import Foundation

// MARK: - BedrockHelperProtocol

/// XPC contract between the sandboxed main app and the non-sandboxed
/// Bedrock credential helper.
///
/// The helper runs as a separate, non-sandboxed XPC service bundled
/// inside `FastLang.app/Contents/XPCServices/`. It exists for one
/// reason: macOS App Sandbox blocks the sandboxed main app from
/// exec'ing third-party binaries — whatever `credential_process`
/// command the user has configured in `~/.aws/config` (this is a
/// standard AWS mechanism; a corporate SSO tool is one example, not a
/// requirement) — but the user's AWS credentials
/// require that binary to produce fresh tokens. The helper performs
/// that subprocess execution on the main app's behalf and returns the
/// JSON result over XPC.
///
/// The interface is intentionally narrow:
///
/// - `ping` — round-trip health check the main app uses to confirm
///   the helper is reachable.
/// - `fetchCredentials(profile:reply:)` — runs the credential_process
///   directive associated with the named profile and returns the
///   resulting AWS credentials JSON. Errors (missing tool, an expired
///   corporate SSO session cookie, etc. — the specific failure depends
///   on whichever credential_process tool the user has configured)
///   come back through the `errorMessage` reply parameter so the main
///   app can surface actionable guidance.
/// - `listProfiles(reply:)` — enumerates the profile names declared in
///   `~/.aws/config` and `~/.aws/credentials`, so the main app can
///   offer them as a picker instead of a free-text field.
///
/// The protocol uses `@objc` types because `NSXPCConnection` proxies
/// through the Objective-C runtime.
@objc
public protocol BedrockHelperProtocol {
    /// Returns `true` immediately. Used by the main app to verify the
    /// XPC service binary is launchable before any real auth call.
    func ping(reply: @escaping @Sendable (Bool) -> Void)

    /// Fetches AWS credentials for the named profile, either by running
    /// the profile's `credential_process` directive from `~/.aws/config`
    /// or, for profiles without one, by delegating to the AWS SDK's own
    /// profile resolver (static keys, `source_profile`/assume-role,
    /// `credential_source`, web identity, SSO, and Login).
    ///
    /// - Parameters:
    ///   - profile: The AWS profile name (without the `profile ` prefix
    ///     used by the config file). Pass `"default"` for the default
    ///     profile.
    ///   - reply: Called on completion, possibly on a different thread
    ///     than the call was made on since credential resolution may
    ///     involve a subprocess or an async network call. Exactly one
    ///     of the two parameters is non-nil:
    ///     - `credentialsJSON` carries the resolved credentials (JSON
    ///       shape `{AccessKeyId, SecretAccessKey, SessionToken,
    ///       Expiration}`).
    ///     - `errorMessage` carries a human-readable failure reason
    ///       suitable for surfacing in the UI.
    func fetchCredentials(
        profile: String,
        reply: @escaping @Sendable (_ credentialsJSON: Data?, _ errorMessage: String?) -> Void
    )

    /// Lists the AWS profile names declared in `~/.aws/config` and
    /// `~/.aws/credentials`, so the main app can present them as a
    /// picker instead of requiring the user to type a profile name.
    ///
    /// Each file's own `[default]` / `[profile NAME]` / bare `[NAME]`
    /// section-header conventions are normalized to a plain profile
    /// name. The default profile, if present, sorts first; the rest
    /// sort alphabetically. Profiles declared in both files are
    /// returned once.
    ///
    /// - Parameter reply: Called on completion. Exactly one of the two
    ///   parameters is non-nil:
    ///   - `profiles` carries the resolved, deduplicated profile names.
    ///     An empty array (not `nil`) means no AWS configuration files
    ///     were found or neither declares any profile.
    ///   - `errorMessage` carries a human-readable failure reason,
    ///     e.g. when a file fails its ownership/permission trust check.
    func listProfiles(
        reply: @escaping @Sendable (_ profiles: [String]?, _ errorMessage: String?) -> Void
    )
}
