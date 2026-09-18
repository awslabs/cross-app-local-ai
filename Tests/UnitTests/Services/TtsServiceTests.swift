import Foundation
import Testing
@testable import FastLang

@Suite("TtsService")
struct TtsServiceTests {

    @Test("mock mode (feature disabled) returns an error-surfacing provider")
    func mockModeReturnsErrorProvider() async {
        let config = TtsServiceConfig(mockMode: true)
        let service = TtsService(config: config)

        let name = await service.providerName
        #expect(name == "Unavailable (error)")

        let request = TtsSynthesisRequest(
            text: "Hello",
            voice: nil,
            rate: 0.5,
            startOffset: 0
        )
        await #expect(throws: TtsError.self) {
            _ = try await service.speak(request)
        }
    }

    @Test("system provider creates AVSpeechTtsProvider")
    func systemProviderCreatesAVSpeech() async {
        let config = TtsServiceConfig(provider: "system", mockMode: false)
        let service = TtsService(config: config)

        let name = await service.providerName
        #expect(name == "System (AVSpeech)")
    }

    @Test("unknown provider surfaces error on speak")
    func unknownProviderSurfacesError() async {
        let config = TtsServiceConfig(provider: "nonexistent")
        let service = TtsService(config: config)

        let name = await service.providerName
        #expect(name == "Unavailable (error)")

        let request = TtsSynthesisRequest(
            text: "Hello",
            voice: nil,
            rate: 0.5,
            startOffset: 0
        )
        await #expect(throws: TtsError.self) {
            _ = try await service.speak(request)
        }
    }

    @Test("disabled feature surfaces error on speak")
    func disabledFeatureSurfacesError() async {
        let config = TtsServiceConfig(mockMode: true)
        let service = TtsService(config: config)

        let request = TtsSynthesisRequest(
            text: "Hello world",
            voice: nil,
            rate: 0.5,
            startOffset: 0
        )
        await #expect(throws: TtsError.self) {
            _ = try await service.speak(request)
        }
    }

    @Test("availableVoices returns empty list from error provider")
    func availableVoicesOnErrorProvider() async {
        let config = TtsServiceConfig(mockMode: true)
        let service = TtsService(config: config)

        let voices = await service.availableVoices()
        #expect(voices.isEmpty)
    }

    @Test("validateConfig throws for disabled feature")
    func validateConfigThrowsWhenDisabled() async {
        let config = TtsServiceConfig(mockMode: true)
        let service = TtsService(config: config)

        await #expect(throws: TtsError.self) {
            try await service.validateConfig()
        }
    }

    @Test("updateConfig swaps provider")
    func updateConfigSwapsProvider() async {
        let initial = TtsServiceConfig(provider: "system", mockMode: true)
        let service = TtsService(config: initial)

        let firstName = await service.providerName
        #expect(firstName == "Unavailable (error)")

        let next = TtsServiceConfig(provider: "system", mockMode: false)
        await service.updateConfig(next)

        let updatedName = await service.providerName
        #expect(updatedName == "System (AVSpeech)")
    }
}
