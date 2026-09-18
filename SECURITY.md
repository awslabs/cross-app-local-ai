# Security Considerations

This document describes accepted risks in FastLang's design and the mitigations in place for each.

## AWS `credential_process` / XPC Isolation

The Bedrock provider requires executing the user's `credential_process` directive from `~/.aws/config` to obtain short-lived AWS credentials. Because the main app runs inside App Sandbox and cannot shell out, this is delegated to a dedicated XPC service (`BedrockCredentialHelper`) that runs **outside** the sandbox.

**Why this is accepted:** The alternative is removing Bedrock support entirely. The XPC boundary ensures the main app never executes arbitrary shell commands; the helper has a strict typed interface (`fetchCredentials(profile:reply:)`) and returns only credential JSON.

**Mitigations:**

- Ownership and permission validation on `~/.aws/config` before execution (rejects files not owned by the current user or writable by group/other, mirroring SSH's trust model).
- 45-second timeout on the subprocess to prevent hung credential tools from blocking the app indefinitely.
- The main app's sandbox remains fully intact; only the helper binary is unsandboxed.
- The helper does not whitelist commands (credential tooling varies too widely), matching how the AWS CLI itself trusts the file's contents.

## SPM Supply Chain

Swift Package Manager has no centralized package registry. Dependencies resolve directly from Git URLs with no registry-side integrity checks, namespace protection, or malware scanning. This is a community-wide structural limitation of the Swift ecosystem, not specific to this project.

**Why this is accepted:** There is no stronger mechanism available today. Pinning to commit SHAs per-dependency would add significant operational overhead for marginal gain, since `Package.resolved` already locks to immutable commit SHAs.

**Mitigations:**

- All direct dependencies are pinned with `exactVersion` in `project.yml`.
- `Package.resolved` is committed to the repository, locking every dependency (direct and transitive) to a specific commit SHA.
- CI builds from the committed resolved state, never from a fresh resolve.
- A force-pushed Git tag cannot affect builds unless `Package.resolved` is explicitly re-resolved and the new SHAs are committed.

## Accessibility TCC Scope

FastLang requires the macOS Accessibility permission (TCC) to read text selections from other applications and inject LLM-generated responses. Once the user grants this permission, the app can interact with UI elements system-wide.

**Why this is accepted:** This is the core product function. The app cannot capture selected text or inject responses without Accessibility access. There is no narrower permission available on macOS for this use case.

**Mitigations:**

- App Sandbox restricts all other system access (filesystem limited to user-selected files, no outbound connections beyond network-client).
- Code signing and notarization ensure the binary has not been tampered with post-distribution.
- Gatekeeper verifies the signature on first launch.
- The app uses Accessibility exclusively for selection capture and text injection; no other UI automation is performed.
