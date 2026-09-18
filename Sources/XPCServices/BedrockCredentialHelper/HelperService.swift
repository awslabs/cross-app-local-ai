import Foundation
import OSLog

private let logger = Logger(
    subsystem: "com.aws.fastlang.bedrock-credential-helper",
    category: "service"
)

// MARK: - LlmHelperError

/// Errors the credential helper surfaces to the main app. The
/// `errorDescription` is sent back verbatim through the XPC reply's
/// `errorMessage` parameter, so it must be user-actionable.
private enum LlmHelperError: LocalizedError {
    /// The `~/.aws/config` failed the ownership/permission trust check,
    /// so we refuse to execute its `credential_process` directive.
    case untrustedConfig(String)

    var errorDescription: String? {
        switch self {
        case let .untrustedConfig(message): message
        }
    }
}

// MARK: - HelperService

/// XPC service implementation. Reads the user's `~/.aws/config`,
/// finds the `credential_process` directive for the requested profile,
/// executes it through a login shell, and returns the resulting JSON
/// to the sandboxed main app.
///
/// This binary runs outside App Sandbox (see `Helper.entitlements`)
/// so the `exec()` syscall against whatever `credential_process`
/// binary the user has configured (and any file reads that tool
/// performs under its own state directories — e.g. Amazon's internal
/// `isengardcli` reads `~/.midway/`) all succeed without sandbox
/// extensions.
final class HelperService: NSObject, BedrockHelperProtocol, @unchecked Sendable {

    // MARK: - Health check

    func ping(reply: @escaping (Bool) -> Void) {
        logger.debug("ping received")
        reply(true)
    }

    // MARK: - Credential fetch

    func fetchCredentials(
        profile: String,
        reply: @escaping (Data?, String?) -> Void
    ) {
        logger.info("fetchCredentials requested for profile '\(profile, privacy: .public)'")

        let realHome: URL
        do {
            realHome = try Self.resolveRealHome()
        } catch {
            logger.error("Could not resolve user home: \(error.localizedDescription)")
            reply(nil, "Could not resolve user home directory: \(error.localizedDescription)")
            return
        }

        let configPath = realHome.appendingPathComponent(".aws/config")

        // Defense-in-depth: `credential_process` is executed through a shell,
        // so we only trust the config if it is owned by the current user and
        // not writable by group/other. This mirrors the ownership checks SSH
        // makes on its config and catches a config that another account (or a
        // world-writable sync target) has tampered with, without whitelisting
        // commands (which would break legitimate tooling). See the threat
        // model, "Malicious credential_process via tampered ~/.aws/config".
        do {
            try Self.validateConfigTrust(at: configPath)
        } catch {
            logger.error("Refusing to trust \(configPath.path): \(error.localizedDescription, privacy: .public)")
            reply(nil, error.localizedDescription)
            return
        }

        let configContents: String
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

        // ~/.aws/config sections for non-default profiles are written
        // as `[profile NAME]`; the default profile is `[default]`. Try
        // both forms so callers can pass the user-facing profile name
        // without worrying about the prefix.
        let sectionName = profile == "default" ? "default" : "profile \(profile)"
        guard let command = Self.parseCredentialProcess(
            from: configContents,
            section: sectionName
        ) ?? Self.parseCredentialProcess(
            from: configContents,
            section: profile
        ) else {
            let msg = "No `credential_process` directive found for profile " +
                "'\(profile)' in \(configPath.path)."
            logger.error("\(msg, privacy: .public)")
            reply(nil, msg)
            return
        }

        logger.info("Executing credential_process for profile '\(profile, privacy: .public)'")
        Self.runCredentialProcess(
            command: command,
            realHome: realHome,
            reply: reply
        )
    }

    // MARK: - Subprocess execution

    /// Maximum time to wait for a `credential_process` invocation before
    /// forcibly terminating it. Long enough for tools that refresh a
    /// corporate SSO session (e.g. Amazon's internal midway cookie),
    /// short enough that a hung tool doesn't wedge the XPC thread — and
    /// the app's Bedrock requests — indefinitely.
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
        reply: @escaping (Data?, String?) -> Void
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-l", "-c", command]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = buildEnvironment(realHome: realHome)

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

    /// Builds the environment the subprocess inherits.
    ///
    /// Even though the helper is unsandboxed, the launchd-started
    /// process may not have a populated PATH (launchd does not source
    /// shell profiles). We seed PATH explicitly to cover the locations
    /// where credential_process tooling lives on developer Macs.
    private static func buildEnvironment(realHome: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        let candidatePaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "\(realHome.path)/.toolbox/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let prefixedPath = candidatePaths.joined(separator: ":")
        if let existing = env["PATH"], !existing.isEmpty {
            env["PATH"] = "\(prefixedPath):\(existing)"
        } else {
            env["PATH"] = prefixedPath
        }

        // credential_process tools commonly read state from a
        // per-tool directory under HOME (e.g. `~/.aws/sso/cache/`, or
        // `~/.midway/` for Amazon's internal isengardcli). Ensure HOME
        // points at the user's real home so those reads land in the
        // right place.
        env["HOME"] = realHome.path
        env["USER"] = NSUserName()
        return env
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

    /// Rejects a `~/.aws/config` we shouldn't execute commands from.
    ///
    /// Because the parsed `credential_process` directive is run through a
    /// shell, we require the file to be a regular file owned by the current
    /// user and not writable by group or other. This catches a config that a
    /// different account or a world-writable sync target has tampered with.
    /// It intentionally does *not* whitelist commands — `credential_process`
    /// tooling varies too widely — matching how the AWS CLI itself trusts the
    /// file's contents while adding an ownership/permission gate.
    ///
    /// - Parameter path: The `~/.aws/config` URL to validate.
    /// - Throws: `LlmHelperError` if the file is missing, not a regular file,
    ///   owned by another user, or group/other-writable.
    private static func validateConfigTrust(at path: URL) throws {
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        } catch {
            throw LlmHelperError.untrustedConfig(
                "Could not read attributes of \(path.path): \(error.localizedDescription)"
            )
        }

        guard (attrs[.type] as? FileAttributeType) == .typeRegular else {
            throw LlmHelperError.untrustedConfig(
                "\(path.path) is not a regular file; refusing to execute credential_process from it."
            )
        }

        // Ownership: the file must belong to the user running this helper.
        let fileOwner = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value
        guard let fileOwner, fileOwner == getuid() else {
            throw LlmHelperError.untrustedConfig(
                "\(path.path) is not owned by the current user; refusing to execute " +
                    "credential_process from a config owned by another account."
            )
        }

        // Permissions: reject if group or other can write (0o022). A tampered,
        // world-writable config is the exact case we're guarding against.
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        if perms & 0o022 != 0 {
            let octal = String(perms, radix: 8)
            throw LlmHelperError.untrustedConfig(
                "\(path.path) is writable by group or other (mode \(octal)); refusing to " +
                    "execute credential_process. Run `chmod 600 \(path.path)` and retry."
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
            // Some corporate SSO tools (e.g. Amazon's internal
            // isengardcli) print "Please run mwinit" to stderr when
            // the session cookie is missing or expired. Surface that
            // as an actionable hint when it's present, since it's the
            // most common reason credential_process fails.
            stderr.lowercased().contains("mwinit")
                ? "Run `mwinit` in a terminal to refresh your session, " +
                "then trigger generation again."
                : ""
        }
    }
}
