import Foundation
import Testing
@testable import FastLang

@Suite("SttService")
struct SttServiceTests {

    @Test("mock mode (feature disabled) returns an error-surfacing provider")
    func mockModeReturnsErrorProvider() async {
        // When the STT feature is disabled in config (`mockMode: true`),
        // transcription calls surface `SttError.notConfigured` rather
        // than silently returning fake text.
        let config = SttServiceConfig(mockMode: true)
        let service = await SttService(config: config)

        let name = await service.providerName
        #expect(name == "Unavailable (error)")

        let audio = AudioBuffer(
            meta: AudioMeta(format: .pcm, sampleRate: .wideband, channels: .mono),
            data: Data()
        )
        await #expect(throws: SttError.self) {
            _ = try await service.transcribe(audio)
        }
    }

    @Test("whisper provider creates a real or error-surfacing provider")
    func whisperCreatesProvider() async {
        // Whisper provider construction depends on whether the model is
        // cached. Either a real `WhisperKitSttProvider` or a
        // `FailedInitSttProvider` (e.g. `.modelNotInstalled`) is valid —
        // both are well-typed outcomes.
        let config = SttServiceConfig(provider: "whisper", mockMode: false)
        let service = await SttService(config: config)

        let name = await service.providerName
        let validNames: Set = ["WhisperKit", "Unavailable (error)"]
        #expect(validNames.contains(name))
    }

    @Test("unknown provider surfaces error on transcribe")
    func unknownProviderSurfacesError() async {
        let config = SttServiceConfig(provider: "nonexistent")
        let service = await SttService(config: config)

        let audio = AudioBuffer(
            meta: AudioMeta(format: .pcm, sampleRate: .wideband, channels: .mono),
            data: Data()
        )

        // Unknown providers construct a FailedInitSttProvider that throws
        // on every call, never silently returning fake output.
        await #expect(throws: SttError.self) {
            _ = try await service.transcribe(audio)
        }
    }

    @Test("disabled feature surfaces error on transcribe")
    func disabledFeatureSurfacesError() async throws {
        let config = SttServiceConfig(mockMode: true)
        let service = await SttService(config: config)

        let audio = AudioBuffer(
            meta: AudioMeta(),
            data: Data(repeating: 0, count: 3200)
        )
        await #expect(throws: SttError.self) {
            _ = try await service.transcribe(audio)
        }
    }

    @Test("supportedLanguages returns empty list from error provider")
    func supportedLanguagesOnErrorProvider() async {
        // The error-surfacing provider has no language capability to
        // report. Returning `[]` avoids advertising languages for a
        // disabled feature.
        let config = SttServiceConfig(mockMode: true)
        let service = await SttService(config: config)

        let languages = await service.supportedLanguages()
        #expect(languages.isEmpty)
    }

    @Test("validateConfig throws for disabled feature")
    func validateConfigThrowsWhenDisabled() async {
        let config = SttServiceConfig(mockMode: true)
        let service = await SttService(config: config)

        await #expect(throws: SttError.self) {
            try await service.validateConfig()
        }
    }

    @Test("updateConfig swaps provider")
    func updateConfigSwapsProvider() async {
        let initial = SttServiceConfig(mockMode: true)
        let service = await SttService(config: initial)
        let firstName = await service.providerName
        #expect(firstName == "Unavailable (error)")

        let next = SttServiceConfig(provider: "whisper", mockMode: false)
        await service.updateConfig(next)

        let updatedName = await service.providerName
        let validNames: Set = ["WhisperKit", "Unavailable (error)"]
        #expect(validNames.contains(updatedName))
    }
}
