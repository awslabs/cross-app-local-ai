import Foundation

/// Builds the environment a subprocess inherits when launched by this
/// unsandboxed XPC helper.
///
/// Even though the helper is unsandboxed, the launchd-started process may
/// not have a populated `PATH` (launchd does not source shell profiles). We
/// seed `PATH` explicitly to cover the locations where credential and
/// corporate-auth tooling lives on developer Macs, and point `HOME` at the
/// user's real home so per-tool state directories (e.g. `~/.aws/sso/cache/`)
/// resolve correctly.
///
/// Shared by both `HelperService`'s `credential_process` exec path and the
/// interactive re-authentication launcher (where built), since both need
/// the same PATH/HOME seeding to find and run tools the same way a user's
/// own shell would.
enum SubprocessEnvironment {
    static func build(realHome: URL) -> [String: String] {
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

        env["HOME"] = realHome.path
        env["USER"] = NSUserName()
        return env
    }
}
