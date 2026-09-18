#if BEDROCK_ENABLED

    import Foundation
    import Testing
    @testable import FastLang

    @Suite("BedrockProvider")
    struct BedrockProviderTests {

        // MARK: - Request Serialization

        @Test("request serializes with correct anthropic_version")
        func requestHasCorrectVersion() throws {
            let request = BedrockCompletionRequest(
                maxTokens: 1024,
                system: "You are a helpful assistant",
                messages: [BedrockMessage(role: "user", content: "Hello")],
                temperature: 0.7
            )

            let data = try JSONEncoder().encode(request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            #expect(json?["anthropic_version"] as? String == "bedrock-2023-05-31")
        }

        @Test("request serializes max_tokens as snake_case")
        func requestHasSnakeCaseMaxTokens() throws {
            let request = BedrockCompletionRequest(
                maxTokens: 2048,
                system: nil,
                messages: [BedrockMessage(role: "user", content: "Hi")],
                temperature: nil
            )

            let data = try JSONEncoder().encode(request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            #expect(json?["max_tokens"] as? Int == 2048)
            #expect(json?["maxTokens"] == nil)
        }

        @Test("request includes system when provided")
        func requestIncludesSystem() throws {
            let request = BedrockCompletionRequest(
                maxTokens: 1024,
                system: "Be concise",
                messages: [BedrockMessage(role: "user", content: "Summarize")],
                temperature: 0.5
            )

            let data = try JSONEncoder().encode(request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            #expect(json?["system"] as? String == "Be concise")
        }

        @Test("request omits system when nil")
        func requestOmitsNilSystem() throws {
            let request = BedrockCompletionRequest(
                maxTokens: 1024,
                system: nil,
                messages: [BedrockMessage(role: "user", content: "Hello")],
                temperature: nil
            )

            let data = try JSONEncoder().encode(request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            #expect(json?["system"] == nil || json?["system"] is NSNull)
        }

        @Test("request messages have correct structure")
        func requestMessagesStructure() throws {
            let request = BedrockCompletionRequest(
                maxTokens: 512,
                system: nil,
                messages: [
                    BedrockMessage(role: "user", content: "What is Swift?"),
                ],
                temperature: 0.7
            )

            let data = try JSONEncoder().encode(request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let messages = json?["messages"] as? [[String: Any]]

            #expect(messages?.count == 1)
            #expect(messages?.first?["role"] as? String == "user")
            #expect(messages?.first?["content"] as? String == "What is Swift?")
        }

        // MARK: - Response Deserialization

        @Test("response parses valid JSON")
        func responseDeserializesValid() throws {
            let json = """
            {
                "id": "msg_123",
                "content": [
                    {"type": "text", "text": "Hello, world!"}
                ],
                "model": "claude-3-sonnet",
                "stop_reason": "end_turn",
                "usage": {
                    "input_tokens": 10,
                    "output_tokens": 5
                }
            }
            """
            let data = Data(json.utf8)
            let response = try JSONDecoder().decode(BedrockCompletionResponse.self, from: data)

            #expect(response.id == "msg_123")
            #expect(response.text() == "Hello, world!")
            #expect(response.model == "claude-3-sonnet")
            #expect(response.stopReason == "end_turn")
            #expect(response.usage.inputTokens == 10)
            #expect(response.usage.outputTokens == 5)
        }

        @Test("response concatenates multiple text blocks")
        func responseConcatenatesBlocks() throws {
            let json = """
            {
                "id": "msg_456",
                "content": [
                    {"type": "text", "text": "Part 1 "},
                    {"type": "text", "text": "Part 2"}
                ],
                "model": "claude-3-sonnet",
                "stop_reason": null,
                "usage": {
                    "input_tokens": 20,
                    "output_tokens": 10
                }
            }
            """
            let data = Data(json.utf8)
            let response = try JSONDecoder().decode(BedrockCompletionResponse.self, from: data)

            #expect(response.text() == "Part 1 Part 2")
        }

        @Test("response decodes a leading thinking block and returns only the text block")
        func responseDecodesLeadingThinkingBlock() throws {
            let json = """
            {
                "id": "msg_think",
                "content": [
                    {"type": "thinking", "thinking": "Reasoning about the answer..."},
                    {"type": "text", "text": "Final answer."}
                ],
                "model": "claude-sonnet-5",
                "stop_reason": "end_turn",
                "usage": {
                    "input_tokens": 30,
                    "output_tokens": 12
                }
            }
            """
            let data = Data(json.utf8)
            let response = try JSONDecoder().decode(BedrockCompletionResponse.self, from: data)

            #expect(response.text() == "Final answer.")
        }

        @Test("response handles empty content array")
        func responseHandlesEmptyContent() throws {
            let json = """
            {
                "id": "msg_789",
                "content": [],
                "model": "claude-3-sonnet",
                "stop_reason": "end_turn",
                "usage": {
                    "input_tokens": 5,
                    "output_tokens": 0
                }
            }
            """
            let data = Data(json.utf8)
            let response = try JSONDecoder().decode(BedrockCompletionResponse.self, from: data)

            #expect(response.text().isEmpty)
        }

        // MARK: - Error Classification

        @Test("classifies AccessDeniedException as authentication error")
        func classifyAccessDenied() {
            let error = NSError(domain: "AWS", code: 403, userInfo: [
                NSLocalizedDescriptionKey: "AccessDeniedException: User not authorized",
            ])
            let classified = BedrockProvider.classifyError(error)

            if case .authentication = classified {
                // expected
            } else {
                Issue.record("Expected authentication error, got \(classified)")
            }
        }

        @Test("classifies ExpiredTokenException as authentication error")
        func classifyExpiredToken() {
            let error = NSError(domain: "AWS", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "ExpiredTokenException: Token expired",
            ])
            let classified = BedrockProvider.classifyError(error)

            if case .authentication = classified {
                // expected
            } else {
                Issue.record("Expected authentication error, got \(classified)")
            }
        }

        @Test("classifies ThrottlingException as rate limit")
        func classifyThrottling() {
            let error = NSError(domain: "AWS", code: 429, userInfo: [
                NSLocalizedDescriptionKey: "ThrottlingException: Too many requests",
            ])
            let classified = BedrockProvider.classifyError(error)

            if case .rateLimit = classified {
                // expected
            } else {
                Issue.record("Expected rateLimit error, got \(classified)")
            }
        }

        @Test("classifies ValidationException as invalid request")
        func classifyValidation() {
            let error = NSError(domain: "AWS", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "ValidationException: Invalid model parameter",
            ])
            let classified = BedrockProvider.classifyError(error)

            if case .invalidRequest = classified {
                // expected
            } else {
                Issue.record("Expected invalidRequest error, got \(classified)")
            }
        }

        @Test("classifies ResourceNotFoundException as model not found")
        func classifyResourceNotFound() {
            let error = NSError(domain: "AWS", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "ResourceNotFoundException: Model not found",
            ])
            let classified = BedrockProvider.classifyError(error)

            if case .modelNotFound = classified {
                // expected
            } else {
                Issue.record("Expected modelNotFound error, got \(classified)")
            }
        }

        @Test("classifies timeout as network error")
        func classifyTimeout() {
            let error = NSError(domain: "NSURLError", code: -1001, userInfo: [
                NSLocalizedDescriptionKey: "The request timed out",
            ])
            let classified = BedrockProvider.classifyError(error)

            if case .network = classified {
                // expected
            } else {
                Issue.record("Expected network error, got \(classified)")
            }
        }

        @Test("classifies connection failure as network error")
        func classifyConnectionFailure() {
            let error = NSError(domain: "NSURLError", code: -1004, userInfo: [
                NSLocalizedDescriptionKey: "DispatchFailure: Could not connect to host",
            ])
            let classified = BedrockProvider.classifyError(error)

            if case .network = classified {
                // expected
            } else {
                Issue.record("Expected network error, got \(classified)")
            }
        }

        @Test("classifies unknown error as provider error")
        func classifyUnknown() {
            let error = NSError(domain: "Unknown", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Something unexpected happened",
            ])
            let classified = BedrockProvider.classifyError(error)

            if case .provider(_, provider: "bedrock") = classified {
                // expected
            } else {
                Issue.record("Expected provider error, got \(classified)")
            }
        }

        @Test("classifies ServiceUnavailableException as provider error")
        func classifyServiceUnavailable() {
            let error = NSError(domain: "AWS", code: 503, userInfo: [
                NSLocalizedDescriptionKey: "ServiceUnavailableException: Service temporarily unavailable",
            ])
            let classified = BedrockProvider.classifyError(error)

            if case .provider(_, provider: "bedrock") = classified {
                // expected
            } else {
                Issue.record("Expected provider error, got \(classified)")
            }
        }

        // MARK: - Models

        @Test("staticModels returns non-empty list")
        func staticModelsNonEmpty() {
            let models = BedrockProvider.staticModels()
            #expect(!models.isEmpty)
        }

        @Test("default model is Claude Sonnet 5")
        func defaultModelIsSonnet5() {
            #expect(BedrockModels.defaultModelId == BedrockModels.claudeSonnet5)
        }

        @Test("all model IDs use cross-region format")
        func modelIdsUseCrossRegion() {
            let models = BedrockProvider.staticModels()
            for model in models {
                #expect(model.id.hasPrefix("us."), "Model \(model.id) should use cross-region format")
            }
        }

        // MARK: - Config

        @Test("default config has expected values")
        func defaultConfigValues() {
            let config = BedrockProviderConfig()
            #expect(config.modelId == BedrockModels.defaultModelId)
            #expect(config.region == "us-east-1")
            #expect(config.awsProfile == nil)
            #expect(config.maxTokens == 4096)
            #expect(config.temperature == 0.7)
        }
    }

#endif
