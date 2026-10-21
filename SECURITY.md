# Security Considerations

This document describes accepted risks in FastLang's design and the mitigations in place for each.

## AWS `credential_process` / XPC Isolation

The Bedrock provider resolves AWS credentials from the user's `~/.aws/config` and `~/.aws/credentials` via one of two paths, both run outside App Sandbox in a dedicated XPC service (`BedrockCredentialHelper`) because the sandboxed main app cannot shell out:

- **`credential_process` profiles** are executed through our own hardened exec path, which preserves a timeout, PATH/HOME seeding, and exit-code hints that the AWS SDK's own `credential_process` support doesn't give us (it discards stderr on failure).
- **Everything else** — static keys, `source_profile`/assume-role chains, `credential_source` chains, web identity, SSO, and Login — is delegated in one call to the AWS SDK's own `ProfileAWSCredentialIdentityResolver`, instead of being hand-parsed.

**Why this is accepted:** The alternative is removing Bedrock support entirely. The XPC boundary ensures the main app never executes arbitrary shell commands; the helper has a strict typed interface (`fetchCredentials(profile:reply:)`) and returns only credential JSON.

**Mitigations:**

- Ownership and permission validation on both `~/.aws/config` and `~/.aws/credentials` before either path reads them (rejects files not owned by the current user or writable by group/other, mirroring SSH's trust model) — the SDK resolver reads both files directly, not just the one holding the `credential_process` directive.
- 45-second timeout on both the `credential_process` subprocess and the SDK resolver call, so neither a hung credential tool nor a stalled STS/SSO network call can block the app indefinitely.
- The main app's sandbox remains fully intact; only the helper binary is unsandboxed.
- The helper does not whitelist commands or profiles (credential tooling varies too widely), matching how the AWS CLI itself trusts the file's contents.
- A known limitation: if a profile's `source_profile` chain points at a *different* profile that itself has `credential_process`, that nested step is resolved by the SDK's own un-hardened exec path, since only the top-level requested profile is inspected for `credential_process` before delegating.
- A known limitation: the ownership/permission check resolves symlinks (`FileManager.attributesOfItem` follows them), so a symlinked `~/.aws/config` or `~/.aws/credentials` is trusted based on its resolved target's ownership and permissions rather than being rejected outright.
- A known limitation: trust validation covers only `~/.aws/config` and `~/.aws/credentials` themselves. It does not extend to files referenced indirectly by a profile -- a `sso_session` section, a `web_identity_token_file` path, or cached SSO tokens under `~/.aws/sso/cache/` -- which the SDK resolver reads without an equivalent ownership/permission check.

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
