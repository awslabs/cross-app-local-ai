#if BEDROCK_ENABLED

    import AWSBedrockRuntime
    import AWSSDKIdentity
    import Foundation
    import OSLog
    import Smithy
    import SmithyIdentity

    private let logger = Logger(subsystem: "com.aws.fastlang", category: "bedrock.provider")

    // MARK: - BedrockModels

    /// Available Bedrock model IDs using cross-region inference format.
    enum BedrockModels {
        static let claudeSonnet5 = "us.anthropic.claude-sonnet-5"
        static let claudeSonnet46 = "us.anthropic.claude-sonnet-4-6"
        static let claudeSonnet45 = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
        static let claudeSonnet4 = "us.anthropic.claude-sonnet-4-20250514-v1:0"
        static let claudeHaiku45 = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
        static let amazonNovaPremier = "us.amazon.nova-premier-v1:0"
        static let amazonNova2Lite = "us.amazon.nova-2-lite-v1:0"

        static let defaultModelId = claudeSonnet5

        static func supportsTemperature(_ modelId: String) -> Bool {
            !modelId.contains("claude-sonnet-5")
        }
    }

    // MARK: - CompletionError

    /// Bedrock-specific errors with AWS error code classification.
    enum CompletionError: Error {
        case providerError(String)
        case serializationError(String)
        case streamError(String)
        case authenticationError(String)
        case throttlingError(String)
        case modelError(String)
        case validationError(String)
    }

    // MARK: - Request/Response Types

    /// Anthropic Messages API request body for Bedrock.
    struct BedrockCompletionRequest: Encodable {
        let anthropicVersion = "bedrock-2023-05-31"
        let maxTokens: UInt32
        let system: String?
        let messages: [BedrockMessage]
        let temperature: Float?

        enum CodingKeys: String, CodingKey {
            case anthropicVersion = "anthropic_version"
            case maxTokens = "max_tokens"
            case system, messages, temperature
        }
    }

    struct BedrockMessage: Codable {
        let role: String
        let content: String
    }

    struct BedrockCompletionResponse: Decodable {
        let id: String
        let content: [ContentBlock]
        let model: String
        let stopReason: String?
        let usage: BedrockUsage

        enum CodingKeys: String, CodingKey {
            case id, content, model, usage
            case stopReason = "stop_reason"
        }

        func text() -> String {
            content.filter { $0.blockType == "text" }.compactMap(\.text).joined()
        }
    }

    /// One block of a Claude Messages API response.
    ///
    /// `text` is optional because not every block type carries it: `thinking`
    /// and `redacted_thinking` blocks (extended thinking) and `tool_use`
    /// blocks have no `"text"` key at all. Decoding it as non-optional made
    /// any such block — even ones we discard via `text()`'s `"text"` filter —
    /// fail the whole response decode before the filter ever ran.
    struct ContentBlock: Decodable {
        let blockType: String
        let text: String?

        enum CodingKeys: String, CodingKey {
            case blockType = "type"
            case text
        }
    }

    struct BedrockUsage: Decodable {
        let inputTokens: UInt32
        let outputTokens: UInt32

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    /// Streaming response chunk from Bedrock.
    private struct StreamChunk: Decodable {
        let chunkType: String
        let delta: StreamDelta?

        enum CodingKeys: String, CodingKey {
            case chunkType = "type"
            case delta
        }
    }

    private struct StreamDelta: Decodable {
        let text: String?
    }

    // MARK: - BedrockProviderConfig

    struct BedrockProviderConfig {
        var modelId: String = BedrockModels.defaultModelId
        var region = "us-east-1"
        var awsProfile: String?
        var maxTokens: UInt32 = 4096
        var temperature: Float = 0.7
    }

    // MARK: - BedrockProvider

    /// AWS Bedrock LLM provider using the Anthropic Messages API.
    ///
    /// Credentials are resolved through the bundled
    /// `BedrockCredentialHelper` XPC service, which runs outside App
    /// Sandbox and is the only piece allowed to exec the user's
    /// `credential_process` directive — whatever command the user has
    /// configured in `~/.aws/config` (a corporate SSO tool like
    /// Amazon's internal `isengardcli` is one example, not a
    /// requirement; any `credential_process`-compatible binary works).
    /// The SDK consults a caching, self-refreshing resolver on each
    /// request, so expired tokens are picked up automatically without
    /// any user intervention.
    final class BedrockProvider: LlmProvider, @unchecked Sendable {
        let providerName = "AWS Bedrock"

        /// Bedrock is a remote HTTP API and already coalesces concurrent
        /// credential refreshes (`RefreshingBedrockCredentialResolver`), so
        /// multiple in-flight `generate` calls are safe.
        let supportsConcurrentRequests = true
        private let client: BedrockRuntimeClient
        private let config: BedrockProviderConfig

        /// Owned by the provider for its lifetime. Holds the XPC
        /// connection and the credential cache; refreshes itself when
        /// the SDK requests an identity whose cached value has expired
        /// or is missing.
        private let credentialResolver: RefreshingBedrockCredentialResolver

        init(config: BedrockProviderConfig) async throws {
            self.config = config

            let profileName: String = {
                if let candidate = config.awsProfile, !candidate.isEmpty {
                    return candidate
                }
                return "default"
            }()

            logger.info("Configuring Bedrock with profile '\(profileName)' in \(config.region)")

            let resolver = RefreshingBedrockCredentialResolver(profile: profileName)
            self.credentialResolver = resolver

            // Pre-flight: validate the resolver can produce credentials
            // before we hand it to the SDK. This surfaces credential
            // errors (e.g. an expired corporate SSO session — "run
            // mwinit" is Amazon's internal example of this — or a
            // missing helper) at provider construction time, where the
            // UI can present a clean message, instead of at the first
            // streaming call.
            do {
                _ = try await resolver.getIdentity()
            } catch {
                logger.error("Bedrock init failed during credential fetch: \(error.localizedDescription)")
                throw error
            }

            do {
                let sdkConfig = try await BedrockRuntimeClient.BedrockRuntimeClientConfig(
                    awsCredentialIdentityResolver: resolver,
                    region: config.region
                )
                self.client = BedrockRuntimeClient(config: sdkConfig)
            } catch {
                logger.error("Failed to construct Bedrock client: \(error.localizedDescription)")
                throw LlmError.configuration(
                    message: "Failed to initialize Bedrock client: \(error.localizedDescription)"
                )
            }

            logger.info("BedrockProvider initialized for region '\(config.region)', model '\(config.modelId)'")
        }

        // MARK: - LlmProvider

        func generate(systemPrompt: String, userPrompt: String) async throws -> String {
            let requestBody = BedrockCompletionRequest(
                maxTokens: config.maxTokens,
                system: systemPrompt,
                messages: [BedrockMessage(role: "user", content: userPrompt)],
                temperature: BedrockModels.supportsTemperature(config.modelId) ? config.temperature : nil
            )

            let bodyData: Data
            do {
                bodyData = try JSONEncoder().encode(requestBody)
            } catch {
                throw LlmError.invalidRequest(message: "Failed to encode request: \(error.localizedDescription)")
            }

            do {
                let input = InvokeModelInput(
                    body: bodyData,
                    contentType: "application/json",
                    modelId: config.modelId
                )

                logger.debug("Invoking Bedrock model '\(self.config.modelId)'...")
                let response = try await client.invokeModel(input: input)
                logger.debug("Bedrock response received")

                guard let responseBody = response.body else {
                    throw LlmError.provider(message: "Empty response body", provider: "bedrock")
                }

                let completionResponse = try JSONDecoder().decode(BedrockCompletionResponse.self, from: responseBody)
                return completionResponse.text()
            } catch let error as LlmError {
                throw error
            } catch {
                logger.error("Bedrock generate failed: \(String(describing: error))")
                throw Self.classifyError(error)
            }
        }

        func generateStream(
            systemPrompt: String,
            userPrompt: String
        ) async throws -> AsyncThrowingStream<String, Error> {
            let requestBody = BedrockCompletionRequest(
                maxTokens: config.maxTokens,
                system: systemPrompt,
                messages: [BedrockMessage(role: "user", content: userPrompt)],
                temperature: BedrockModels.supportsTemperature(config.modelId) ? config.temperature : nil
            )

            let bodyData: Data
            do {
                bodyData = try JSONEncoder().encode(requestBody)
            } catch {
                throw LlmError.invalidRequest(message: "Failed to encode request: \(error.localizedDescription)")
            }

            let input = InvokeModelWithResponseStreamInput(
                body: bodyData,
                contentType: "application/json",
                modelId: config.modelId
            )

            let response: InvokeModelWithResponseStreamOutput
            do {
                logger.debug("Invoking Bedrock streaming for model '\(self.config.modelId)'...")
                response = try await client.invokeModelWithResponseStream(input: input)
                logger.debug("Bedrock stream response received")
            } catch {
                logger.error("Bedrock stream invocation failed: \(String(describing: error))")
                throw Self.classifyError(error)
            }

            return AsyncThrowingStream { continuation in
                Task {
                    do {
                        guard let stream = response.body else {
                            continuation.finish(throwing: LlmError.provider(
                                message: "No response stream body",
                                provider: "bedrock"
                            ))
                            return
                        }

                        var sawAnyChunk = false
                        var sawAnyDelta = false
                        var totalDeltaChars = 0
                        for try await event in stream {
                            switch event {
                            case let .chunk(payload):
                                sawAnyChunk = true
                                guard let bytes = payload.bytes else {
                                    logger.warning("Bedrock stream chunk had no bytes")
                                    continue
                                }
                                do {
                                    let chunk = try JSONDecoder().decode(StreamChunk.self, from: bytes)
                                    if chunk.chunkType == "content_block_delta",
                                       let deltaText = chunk.delta?.text {
                                        sawAnyDelta = true
                                        totalDeltaChars += deltaText.count
                                        continuation.yield(deltaText)
                                    } else {
                                        // Non-delta events (message_start, ping, message_stop, etc.)
                                        // are expected and uninteresting at info level.
                                        logger.debug("Bedrock stream non-delta event type='\(chunk.chunkType)'")
                                    }
                                } catch {
                                    let raw = String(data: bytes, encoding: .utf8) ?? "<non-utf8 \(bytes.count) bytes>"
                                    logger.error(
                                        "Bedrock stream chunk decode failed: \(error.localizedDescription); raw=\(raw, privacy: .public)"
                                    )
                                }
                            case let .sdkUnknown(name):
                                logger.warning("Bedrock stream unknown event type '\(name, privacy: .public)'")
                            default:
                                // Other event types (modelStreamErrorException, validationException, etc.)
                                // - log the case and let the loop's try-catch surface AWS errors.
                                logger
                                    .warning(
                                        "Bedrock stream non-chunk event: \(String(describing: event), privacy: .public)"
                                    )
                            }
                        }
                        if !sawAnyChunk {
                            logger.error("Bedrock stream completed with no chunks at all")
                        } else if !sawAnyDelta {
                            logger.error("Bedrock stream completed with chunks but zero content_block_delta events")
                        } else {
                            logger.info("Bedrock stream complete: \(totalDeltaChars) chars across delta events")
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: Self.classifyError(error))
                    }
                }
            }
        }

        func availableModels() -> [ModelInfo] {
            Self.staticModels()
        }

        static func staticModels() -> [ModelInfo] {
            [
                ModelInfo(id: BedrockModels.claudeSonnet5, displayName: "Claude Sonnet 5 (Default)"),
                ModelInfo(id: BedrockModels.claudeSonnet46, displayName: "Claude Sonnet 4.6"),
                ModelInfo(id: BedrockModels.claudeSonnet45, displayName: "Claude Sonnet 4.5"),
                ModelInfo(id: BedrockModels.claudeSonnet4, displayName: "Claude Sonnet 4"),
                ModelInfo(id: BedrockModels.claudeHaiku45, displayName: "Claude Haiku 4.5"),
                ModelInfo(id: BedrockModels.amazonNovaPremier, displayName: "Amazon Nova Premier"),
                ModelInfo(id: BedrockModels.amazonNova2Lite, displayName: "Amazon Nova 2 Lite"),
            ]
        }

        func validate() async throws {
            // Bedrock validates on first API call; no pre-flight check available
        }

        // MARK: - Error Classification

        /// Maps AWS SDK errors to domain `LlmError` variants.
        ///
        /// Extracts the error code from the AWS SDK error type name and classifies
        /// it according to the Bedrock error taxonomy.
        static func classifyError(_ error: Error) -> LlmError {
            let description = String(describing: error)
            let lowered = description.lowercased()

            if lowered.contains("accessdeniedexception") || lowered.contains("expiredtokenexception") {
                return .authentication(message: enrichErrorMessage(description), provider: "bedrock")
            }

            if lowered.contains("throttlingexception") {
                return .rateLimit(message: enrichErrorMessage(description), retryAfterSecs: nil)
            }

            if lowered.contains("validationexception") {
                return .invalidRequest(message: enrichErrorMessage(description))
            }

            if lowered.contains("resourcenotfoundexception") {
                return .modelNotFound(modelId: "unknown", availableModels: [])
            }

            if lowered.contains("modelnotreadyexception")
                || lowered.contains("modelerrorexception")
                || lowered.contains("modeltimeoutexception")
                || lowered.contains("serviceunavailableexception") {
                return .provider(message: enrichErrorMessage(description), provider: "bedrock")
            }

            if lowered.contains("timeout") || lowered.contains("timed out") {
                return .network(message: enrichErrorMessage(description))
            }

            if lowered.contains("dispatchfailure") || lowered.contains("connection") {
                return .network(message: enrichErrorMessage(description))
            }

            return .provider(message: enrichErrorMessage(description), provider: "bedrock")
        }
    }

    // MARK: - RefreshingBedrockCredentialResolver

    /// Caching, self-refreshing `AWSCredentialIdentityResolver` backed
    /// by the bundled `BedrockCredentialHelper` XPC service.
    ///
    /// The AWS SDK calls `getIdentity` on every API request. To avoid
    /// hammering the helper (and the user's `credential_process`
    /// binary) once per request, we cache the resolved identity and
    /// only re-fetch when it's missing or about to expire. Concurrent
    /// requests that all need a refresh are coalesced into a single
    /// in-flight XPC roundtrip via `inflightTask`.
    ///
    /// Threading: state is guarded by `stateLock`. `getIdentity` is
    /// safe to call from any task; the SDK calls it from its own
    /// internal queues.
    private final class RefreshingBedrockCredentialResolver: AWSCredentialIdentityResolver, @unchecked Sendable {
        /// XPC channel to `BedrockCredentialHelper`. Created once,
        /// invalidated in `deinit`.
        private let xpcConnection: NSXPCConnection
        private let profileName: String

        /// Refresh window: if the cached identity expires within this
        /// many seconds, the next `getIdentity` call refreshes proactively.
        /// 15 minutes leaves comfortable headroom for clock skew,
        /// in-flight request latency, and laptop-wake jitter without
        /// burning extra refreshes while idle.
        private static let refreshSkew: TimeInterval = 900

        private let stateLock = NSLock()
        private var cached: AWSCredentialIdentity?
        private var inflightTask: Task<AWSCredentialIdentity, Error>?
        /// Monotonically increases each time a refresh is started.
        /// Used to detect whether the in-flight task we await is still
        /// the "current" one when the lock is reacquired post-await
        /// (Task is a value type, so we can't compare with `===`).
        private var inflightGeneration: UInt64 = 0

        init(profile: String) {
            let connection = NSXPCConnection(
                serviceName: "com.aws.fastlang.bedrock-credential-helper"
            )
            connection.remoteObjectInterface = NSXPCInterface(
                with: BedrockHelperProtocol.self
            )
            connection.resume()
            self.xpcConnection = connection
            self.profileName = profile
        }

        deinit {
            xpcConnection.invalidate()
        }

        // MARK: AWSCredentialIdentityResolver

        func getIdentity(identityProperties _: Attributes? = nil) async throws -> AWSCredentialIdentity {
            // Fast path: cached identity still has runway. Snapshot
            // under the lock, decide outside.
            let cachedSnapshot = stateLock.withLock { self.cached }
            if let cachedSnapshot, Self.isStillValid(cachedSnapshot) {
                return cachedSnapshot
            }

            // Coalesce concurrent refreshes: if another task is already
            // fetching, await its result instead of issuing a parallel
            // XPC roundtrip.
            let (task, generation): (Task<AWSCredentialIdentity, Error>, UInt64) = stateLock.withLock {
                if let existing = inflightTask {
                    return (existing, inflightGeneration)
                }
                inflightGeneration += 1
                let myGen = inflightGeneration
                let newTask = Task<AWSCredentialIdentity, Error> { [self] in
                    try await fetchFreshIdentity()
                }
                inflightTask = newTask
                return (newTask, myGen)
            }

            do {
                let identity = try await task.value
                stateLock.withLock {
                    self.cached = identity
                    // Only clear if no newer refresh has been started.
                    if inflightGeneration == generation {
                        inflightTask = nil
                    }
                }
                logger.info(
                    "Bedrock credentials refreshed for '\(self.profileName)' (expiration=\(identity.expiration?.description ?? "none"))"
                )
                return identity
            } catch {
                stateLock.withLock {
                    if inflightGeneration == generation {
                        inflightTask = nil
                    }
                }
                throw error
            }
        }

        // MARK: Cache validity

        private static func isStillValid(_ identity: AWSCredentialIdentity) -> Bool {
            guard let expiration = identity.expiration else {
                // No expiration recorded — assume long-lived (e.g., a
                // static IAM-user profile). Don't refresh.
                return true
            }
            return expiration.timeIntervalSinceNow > refreshSkew
        }

        // MARK: XPC fetch + JSON parse

        private struct ParsedCredentials {
            let accessKeyId: String
            let secretAccessKey: String
            let sessionToken: String?
            let expiration: Date?
        }

        /// JSON shape produced by AWS `credential_process` commands.
        /// See https://docs.aws.amazon.com/sdkref/latest/guide/feature-process-credentials.html
        private struct CredentialProcessOutput: Decodable {
            let version: Int?
            let accessKeyId: String
            let secretAccessKey: String
            let sessionToken: String?
            let expiration: Date?

            enum CodingKeys: String, CodingKey {
                case version = "Version"
                case accessKeyId = "AccessKeyId"
                // JSON key name from credential_process output, not a secret value.
                case secretAccessKey = "SecretAccessKey" // pragma: allowlist secret
                case sessionToken = "SessionToken"
                case expiration = "Expiration"
            }
        }

        private func fetchFreshIdentity() async throws -> AWSCredentialIdentity {
            let json = try await fetchCredentialsViaXPC()
            let parsed = try Self.parseCredentialsJSON(json)
            return AWSCredentialIdentity(
                accessKey: parsed.accessKeyId,
                secret: parsed.secretAccessKey,
                accountID: nil,
                expiration: parsed.expiration,
                sessionToken: parsed.sessionToken
            )
        }

        /// Bridges the NSXPC callback API to async/await. Both the
        /// connection's `errorHandler` and the method's `reply` can
        /// fire on a mid-call crash, so `ContinuationGuard` enforces
        /// single-resume to avoid tripping the "continuation resumed
        /// twice" precondition.
        private func fetchCredentialsViaXPC() async throws -> Data {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                let resumeGuard = ContinuationGuard(continuation)

                let proxy = xpcConnection.remoteObjectProxyWithErrorHandler { error in
                    resumeGuard.resume(throwing: LlmError.configuration(
                        message: "Bedrock helper unreachable: \(error.localizedDescription). " +
                            "Try reinstalling FastLang."
                    ))
                } as? BedrockHelperProtocol

                guard let proxy else {
                    resumeGuard.resume(throwing: LlmError.configuration(
                        message: "Bedrock helper proxy unavailable (protocol mismatch)."
                    ))
                    return
                }

                proxy.fetchCredentials(profile: profileName) { data, errorMessage in
                    if let errorMessage {
                        resumeGuard.resume(throwing: LlmError.authentication(
                            message: errorMessage,
                            provider: "bedrock"
                        ))
                        return
                    }
                    guard let data, !data.isEmpty else {
                        resumeGuard.resume(throwing: LlmError.authentication(
                            message: "Bedrock helper returned no credentials and no error.",
                            provider: "bedrock"
                        ))
                        return
                    }
                    resumeGuard.resume(returning: data)
                }
            }
        }

        private static func parseCredentialsJSON(_ data: Data) throws -> ParsedCredentials {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                let parsed = try decoder.decode(CredentialProcessOutput.self, from: data)
                return ParsedCredentials(
                    accessKeyId: parsed.accessKeyId,
                    secretAccessKey: parsed.secretAccessKey,
                    sessionToken: parsed.sessionToken,
                    expiration: parsed.expiration
                )
            } catch {
                let preview = String(data: data.prefix(256), encoding: .utf8) ?? "<non-utf8>"
                logger
                    .error("Failed to parse credential_process JSON: \(error.localizedDescription) preview=\(preview)")
                throw LlmError.authentication(
                    message: "Bedrock helper returned malformed credentials JSON: " +
                        "\(error.localizedDescription)",
                    provider: "bedrock"
                )
            }
        }
    }

    // MARK: - ContinuationGuard

    /// Single-resume wrapper for bridging `NSXPCConnection`'s
    /// dual-failure callback model to `withCheckedThrowingContinuation`.
    ///
    /// `remoteObjectProxyWithErrorHandler` and the method-level reply
    /// closure can both fire when a service crashes mid-call. Resuming
    /// a `CheckedContinuation` twice is a fatal precondition violation;
    /// this guard makes the second resume a no-op.
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

#endif
