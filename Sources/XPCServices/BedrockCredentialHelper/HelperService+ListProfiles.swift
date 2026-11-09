import Foundation
import OSLog

private let logger = Logger(
    subsystem: "com.aws.fastlang.bedrock-credential-helper",
    category: "service.list-profiles"
)

// MARK: - HelperService + Profile listing

extension HelperService {

    public func listProfiles(
        reply: @escaping @Sendable (_ profiles: [String]?, _ errorMessage: String?) -> Void
    ) {
        let realHome: URL
        do {
            realHome = try Self.resolveRealHome()
        } catch {
            logger.error("Could not resolve user home: \(error.localizedDescription, privacy: .public)")
            reply(nil, "Could not resolve user home directory: \(error.localizedDescription)")
            return
        }
        Self.listProfiles(realHome: realHome, reply: reply)
    }

    /// Testable entry point: identical to `listProfiles(reply:)` but
    /// takes the `~/.aws`-containing home directory as a parameter
    /// instead of resolving the real one, so tests can point it at a
    /// temporary directory rather than the test runner's actual
    /// `~/.aws/config` and `~/.aws/credentials`.
    static func listProfiles(
        realHome: URL,
        reply: @escaping @Sendable (_ profiles: [String]?, _ errorMessage: String?) -> Void
    ) {
        let configPath = realHome.appendingPathComponent(".aws/config")
        let credentialsPath = realHome.appendingPathComponent(".aws/credentials")
        let configExists = FileManager.default.fileExists(atPath: configPath.path)
        let credentialsExists = FileManager.default.fileExists(atPath: credentialsPath.path)

        guard configExists || credentialsExists else {
            reply([], nil)
            return
        }

        // Same ownership/permission trust check `fetchCredentials` applies
        // before reading either file. See `validateFileTrust`'s doc comment
        // for the threat this guards against.
        for path in [configPath, credentialsPath] where FileManager.default.fileExists(atPath: path.path) {
            do {
                try validateFileTrust(at: path)
            } catch {
                logger.error("Refusing to trust \(path.path): \(error.localizedDescription, privacy: .public)")
                reply(nil, error.localizedDescription)
                return
            }
        }

        var profileNames: Set<String> = []

        if configExists {
            do {
                let contents = try String(contentsOf: configPath, encoding: .utf8)
                profileNames.formUnion(parseProfileNames(from: contents, stripProfilePrefix: true))
            } catch {
                logger.error("Could not read \(configPath.path): \(error.localizedDescription)")
                reply(nil, "Could not read \(configPath.path): \(error.localizedDescription)")
                return
            }
        }

        if credentialsExists {
            do {
                let contents = try String(contentsOf: credentialsPath, encoding: .utf8)
                profileNames.formUnion(parseProfileNames(from: contents, stripProfilePrefix: false))
            } catch {
                logger.error("Could not read \(credentialsPath.path): \(error.localizedDescription)")
                reply(nil, "Could not read \(credentialsPath.path): \(error.localizedDescription)")
                return
            }
        }

        // The default profile, when present, is the natural first choice
        // in a picker; the rest sort alphabetically for predictability.
        let sortedProfiles = profileNames.sorted { lhs, rhs in
            if lhs == rhs { return false }
            if lhs == "default" { return true }
            if rhs == "default" { return false }
            return lhs < rhs
        }
        logger.info("listProfiles found \(sortedProfiles.count) profile(s)")
        reply(sortedProfiles, nil)
    }

    /// Collects AWS profile names from `~/.aws/config`-or-`credentials`
    /// style INI contents by walking `[...]` section headers — the same
    /// line-scanning approach `parseCredentialProcess` uses to find a
    /// `credential_process` key inside one named section, applied here
    /// to every section header instead of one.
    ///
    /// - Parameter stripProfilePrefix: `true` for `~/.aws/config`, whose
    ///   non-default sections are written `[profile NAME]`; `false` for
    ///   `~/.aws/credentials`, where every section — including the
    ///   default profile's — is the bare profile name.
    private static func parseProfileNames(
        from contents: String,
        stripProfilePrefix: Bool
    ) -> [String] {
        var names: [String] = []
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { continue }
            var name = String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespaces)

            if stripProfilePrefix {
                // ~/.aws/config also has non-profile section types —
                // "[sso-session NAME]" and "[services NAME]" — and a
                // bare "[NAME]" other than "default" isn't valid config
                // syntax. Only "[default]" and "[profile NAME]" name an
                // actual profile.
                if name == "default" {
                    // No prefix to strip.
                } else if name.hasPrefix("profile ") {
                    name = String(name.dropFirst("profile ".count))
                        .trimmingCharacters(in: .whitespaces)
                } else {
                    continue
                }
            }

            guard !name.isEmpty else { continue }
            names.append(name)
        }
        return names
    }
}
