import Foundation
import Testing
@testable import BedrockCredentialHelperCore

@Suite("HelperService")
struct HelperServiceTests {

    // MARK: - Fixture home directories

    /// Creates an isolated `realHome`-shaped temp directory (with a
    /// `.aws` subdirectory) for one test, and removes it afterward.
    private func withFixtureHome(
        config: String? = nil,
        credentials: String? = nil,
        permissions: Int16? = nil,
        _ body: (URL) async throws -> Void
    ) async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelperServiceTests-\(UUID().uuidString)")
        let awsDir = home.appendingPathComponent(".aws")
        try FileManager.default.createDirectory(at: awsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        if let config {
            let path = awsDir.appendingPathComponent("config")
            try config.write(to: path, atomically: true, encoding: .utf8)
            if let permissions {
                try FileManager.default.setAttributes(
                    [.posixPermissions: permissions],
                    ofItemAtPath: path.path
                )
            }
        }
        if let credentials {
            let path = awsDir.appendingPathComponent("credentials")
            try credentials.write(to: path, atomically: true, encoding: .utf8)
            if let permissions {
                try FileManager.default.setAttributes(
                    [.posixPermissions: permissions],
                    ofItemAtPath: path.path
                )
            }
        }

        try await body(home)
    }

    private func fetchCredentials(
        _ service: HelperService,
        profile: String,
        realHome: URL
    ) async -> (data: Data?, errorMessage: String?) {
        await withCheckedContinuation { continuation in
            service.fetchCredentials(profile: profile, realHome: realHome) { data, errorMessage in
                continuation.resume(returning: (data, errorMessage))
            }
        }
    }

    // MARK: - No AWS configuration

    @Test("replies with an error when neither config nor credentials exists")
    func noConfigurationFound() async throws {
        try await withFixtureHome { home in
            let result = await fetchCredentials(HelperService(), profile: "default", realHome: home)
            #expect(result.data == nil)
            #expect(result.errorMessage?.contains("No AWS configuration found") == true)
        }
    }

    // MARK: - Path 1: credential_process

    @Test("runs credential_process and forwards its stdout verbatim")
    func credentialProcessForwardsStdout() async throws {
        let payload = #"{"Version":1,"AccessKeyId":"AKIAFAKE","SecretAccessKey":"shh","SessionToken":"tok"}"#
        let config = """
        [profile my-process-profile]
        region = us-east-1
        credential_process = /bin/echo '\(payload)'
        """
        try await withFixtureHome(config: config, permissions: 0o600) { home in
            let result = await fetchCredentials(HelperService(), profile: "my-process-profile", realHome: home)
            #expect(result.errorMessage == nil)
            let data = try #require(result.data)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(json?["AccessKeyId"] as? String == "AKIAFAKE")
            #expect(json?["SecretAccessKey"] as? String == "shh")
        }
    }

    @Test("surfaces a non-zero credential_process exit code with its stderr")
    func credentialProcessFailureSurfacesStderr() async throws {
        let config = """
        [profile my-failing-profile]
        credential_process = /bin/sh -c 'echo custom-failure-reason >&2; exit 1'
        """
        try await withFixtureHome(config: config, permissions: 0o600) { home in
            let result = await fetchCredentials(HelperService(), profile: "my-failing-profile", realHome: home)
            #expect(result.data == nil)
            #expect(result.errorMessage?.contains("exited with status 1") == true)
            #expect(result.errorMessage?.contains("custom-failure-reason") == true)
        }
    }

    @Test("hints that the tool is missing on exit code 127")
    func credentialProcessMissingToolHint() async throws {
        let config = """
        [profile my-missing-tool-profile]
        credential_process = this-command-does-not-exist-anywhere
        """
        try await withFixtureHome(config: config, permissions: 0o600) { home in
            let result = await fetchCredentials(HelperService(), profile: "my-missing-tool-profile", realHome: home)
            #expect(result.data == nil)
            #expect(result.errorMessage?.contains("Tool not found on PATH") == true)
        }
    }

    @Test("matches [default] section without the profile prefix")
    func defaultProfileSection() async throws {
        let payload = #"{"Version":1,"AccessKeyId":"AKIADEFAULT","SecretAccessKey":"shh"}"#
        let config = """
        [default]
        region = us-east-1
        credential_process = /bin/echo '\(payload)'
        """
        try await withFixtureHome(config: config, permissions: 0o600) { home in
            let result = await fetchCredentials(HelperService(), profile: "default", realHome: home)
            let data = try #require(result.data)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(json?["AccessKeyId"] as? String == "AKIADEFAULT")
        }
    }

    /// Regression test for a profile whose `credential_process` is declared
    /// only in `~/.aws/credentials`, which the AWS CLI/SDK also permits (see
    /// `fetchCredentials`'s comment on `credentialsContents`). Before this
    /// suite's fix, `parseCredentialProcess` only inspected `configContents`,
    /// so this profile would silently fall through to Path 2's un-hardened
    /// SDK exec instead of this hardened Path 1 exec -- losing timeout
    /// enforcement, environment sanitization, and the exit-code hints.
    @Test("finds credential_process declared only in ~/.aws/credentials, with no ~/.aws/config at all")
    func credentialProcessInCredentialsFileOnlyNoConfig() async throws {
        let payload = #"{"Version":1,"AccessKeyId":"AKIACREDSFILE","SecretAccessKey":"shh"}"#
        let credentials = """
        [my-creds-file-profile]
        credential_process = /bin/echo '\(payload)'
        """
        try await withFixtureHome(credentials: credentials, permissions: 0o600) { home in
            let result = await fetchCredentials(HelperService(), profile: "my-creds-file-profile", realHome: home)
            #expect(result.errorMessage == nil)
            let data = try #require(result.data)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(json?["AccessKeyId"] as? String == "AKIACREDSFILE")
        }
    }

    /// Companion to the above: the same `~/.aws/credentials`-only
    /// `credential_process` directive still takes Path 1 when a
    /// `~/.aws/config` for the same profile also exists but doesn't declare
    /// `credential_process` itself -- i.e. the two files' directives are
    /// merged rather than the presence of a config section short-circuiting
    /// the credentials-file lookup.
    @Test(
        "finds credential_process declared only in ~/.aws/credentials even when ~/.aws/config has the profile without it"
    )
    func credentialProcessInCredentialsFileOnlyWithNonDeclaringConfig() async throws {
        let payload = #"{"Version":1,"AccessKeyId":"AKIACREDSFILE2","SecretAccessKey":"shh"}"#
        let config = """
        [profile my-creds-file-profile]
        region = us-east-1
        """
        let credentials = """
        [my-creds-file-profile]
        credential_process = /bin/echo '\(payload)'
        """
        try await withFixtureHome(config: config, credentials: credentials, permissions: 0o600) { home in
            let result = await fetchCredentials(HelperService(), profile: "my-creds-file-profile", realHome: home)
            #expect(result.errorMessage == nil)
            let data = try #require(result.data)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(json?["AccessKeyId"] as? String == "AKIACREDSFILE2")
        }
    }

    // MARK: - Path 2: SDK profile resolver (static keys)

    @Test("resolves a static-key profile via the SDK resolver when no credential_process is present")
    func staticKeyProfileResolvesViaSDK() async throws {
        let config = """
        [profile my-static-profile]
        region = us-east-1
        output = json
        """
        let credentials = """
        [my-static-profile]
        aws_access_key_id = AKIASTATICFAKE
        aws_secret_access_key = staticSecretValue
        """
        try await withFixtureHome(config: config, credentials: credentials, permissions: 0o600) { home in
            let result = await fetchCredentials(HelperService(), profile: "my-static-profile", realHome: home)
            #expect(result.errorMessage == nil)
            let data = try #require(result.data)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(json?["AccessKeyId"] as? String == "AKIASTATICFAKE")
            #expect(json?["SecretAccessKey"] as? String == "staticSecretValue")
        }
    }

    @Test("resolves a static-key default profile with no ~/.aws/config at all")
    func staticKeyDefaultProfileWithOnlyCredentialsFile() async throws {
        let credentials = """
        [default]
        aws_access_key_id = AKIANOCONFIGFAKE
        aws_secret_access_key = noConfigSecret
        """
        try await withFixtureHome(credentials: credentials, permissions: 0o600) { home in
            let result = await fetchCredentials(HelperService(), profile: "default", realHome: home)
            #expect(result.errorMessage == nil)
            let data = try #require(result.data)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(json?["AccessKeyId"] as? String == "AKIANOCONFIGFAKE")
        }
    }

    @Test("surfaces an actionable error when the SDK resolver cannot find the profile")
    func sdkResolverFailureSurfacesMessage() async throws {
        let config = """
        [profile some-other-profile]
        region = us-east-1
        """
        try await withFixtureHome(config: config, permissions: 0o600) { home in
            let result = await fetchCredentials(HelperService(), profile: "nonexistent-profile", realHome: home)
            #expect(result.data == nil)
            #expect(result.errorMessage?.contains("Failed to resolve AWS credentials") == true)
        }
    }

    // MARK: - File trust validation

    @Test("refuses to trust a world-writable ~/.aws/config")
    func rejectsWorldWritableConfig() async throws {
        let config = """
        [profile my-static-profile]
        region = us-east-1
        """
        try await withFixtureHome(config: config, permissions: 0o666) { home in
            let result = await fetchCredentials(HelperService(), profile: "my-static-profile", realHome: home)
            #expect(result.data == nil)
            #expect(result.errorMessage?.contains("writable by group or other") == true)
        }
    }

    @Test("refuses to trust a world-writable ~/.aws/credentials")
    func rejectsWorldWritableCredentials() async throws {
        let credentials = """
        [default]
        aws_access_key_id = AKIAFAKE
        aws_secret_access_key = shh
        """
        try await withFixtureHome(credentials: credentials, permissions: 0o666) { home in
            let result = await fetchCredentials(HelperService(), profile: "default", realHome: home)
            #expect(result.data == nil)
            #expect(result.errorMessage?.contains("writable by group or other") == true)
        }
    }

    // MARK: - ping

    @Test("ping replies true")
    func pingRepliesTrue() async {
        let result = await withCheckedContinuation { continuation in
            HelperService().ping { isAlive in
                continuation.resume(returning: isAlive)
            }
        }
        #expect(result == true)
    }

    // MARK: - withTimeout

    @Test("withTimeout returns the operation's result when it finishes before the deadline")
    func withTimeoutReturnsFastResult() async throws {
        let result = try await HelperService.withTimeout(seconds: 5) { "done" }
        #expect(result == "done")
    }

    @Test("withTimeout propagates the operation's own error when it fails before the deadline")
    func withTimeoutPropagatesOperationError() async {
        struct SomeError: Error {}
        await #expect(throws: SomeError.self) {
            try await HelperService.withTimeout(seconds: 5) {
                throw SomeError()
            }
        }
    }

    /// Regression test for the bug this suite's single-resolution-guard
    /// rewrite of `withTimeout` fixed: the previous `withThrowingTaskGroup`
    /// implementation didn't actually return until every child task
    /// finished, even after `cancelAll()`, so a non-cancellation-aware
    /// `operation` (simulated here with the raw POSIX `sleep(_:)` call,
    /// which ignores `Task` cancellation entirely, standing in for a
    /// blocking subprocess exec inside the SDK resolver) made the call
    /// block for the operation's full duration instead of the much
    /// shorter `seconds` budget. This asserts `withTimeout` now throws
    /// `SDKResolutionTimeout` promptly regardless.
    ///
    /// Uses POSIX `sleep(_:)` rather than `Thread.sleep(forTimeInterval:)`:
    /// the latter is `@available(*, noasync)` and the compiler now
    /// rejects it lexically inside an `async` closure, even though this
    /// closure's whole point is to model synchronous, cancellation-blind
    /// blocking work.
    @Test("withTimeout throws promptly even when the operation ignores cancellation")
    func withTimeoutThrowsPromptlyWhenOperationIgnoresCancellation() async {
        let start = ContinuousClock.now
        await #expect(throws: HelperService.SDKResolutionTimeout.self) {
            try await HelperService.withTimeout(seconds: 0.2) {
                sleep(5)
                return "unreachable"
            }
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(2))
    }
}
