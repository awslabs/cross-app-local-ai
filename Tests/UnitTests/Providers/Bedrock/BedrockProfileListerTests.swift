#if BEDROCK_ENABLED

    import Foundation
    import Testing
    @testable import FastLang

    /// Covers `BedrockProfileListerError`'s pure error-description logic.
    ///
    /// `BedrockProfileLister.listAvailableProfiles()` itself opens a live
    /// `NSXPCConnection` to the installed `BedrockCredentialHelper` service,
    /// which isn't available in the unit-test sandbox. The rest of the
    /// Bedrock test suite (`BedrockProviderTests`) follows the same
    /// constraint and likewise never exercises
    /// `RefreshingBedrockCredentialResolver`'s live XPC path — only its
    /// pure request/response/error logic.
    @Suite("BedrockProfileLister")
    struct BedrockProfileListerTests {

        @Test("helperUnreachable includes the underlying message and a reinstall hint")
        func helperUnreachableMessage() {
            let error = BedrockProfileListerError.helperUnreachable("connection invalidated")
            #expect(error.errorDescription?.contains("connection invalidated") == true)
            #expect(error.errorDescription?.contains("reinstalling FastLang") == true)
        }

        @Test("protocolMismatch has a fixed, descriptive message")
        func protocolMismatchMessage() {
            let error = BedrockProfileListerError.protocolMismatch
            #expect(error.errorDescription == "Bedrock helper proxy unavailable (protocol mismatch).")
        }

        @Test("listFailed forwards the helper's message verbatim")
        func listFailedMessage() {
            let error = BedrockProfileListerError.listFailed("~/.aws/config is writable by group or other")
            #expect(error.errorDescription == "~/.aws/config is writable by group or other")
        }
    }

#endif
