import Testing
@testable import FastLang

// MARK: - Voice Display Name

@Suite("KokoroTtsProvider Voice Display Name")
struct VoiceDisplayNameTests {

    @Test("US female voice includes name, gender, and accent")
    func usFemaleVoice() {
        let name = KokoroTtsProvider.displayName(for: "af_heart")
        #expect(name == "Heart Female US")
    }

    @Test("US male voice includes name, gender, and accent")
    func usMaleVoice() {
        let name = KokoroTtsProvider.displayName(for: "am_adam")
        #expect(name == "Adam Male US")
    }

    @Test("UK female voice includes name, gender, and accent")
    func ukFemaleVoice() {
        let name = KokoroTtsProvider.displayName(for: "bf_emma")
        #expect(name == "Emma Female UK")
    }

    @Test("UK male voice includes name, gender, and accent")
    func ukMaleVoice() {
        let name = KokoroTtsProvider.displayName(for: "bm_george")
        #expect(name == "George Male UK")
    }

    @Test("unknown prefix returns name only")
    func unknownPrefix() {
        let name = KokoroTtsProvider.displayName(for: "xx_test")
        #expect(name == "Test")
    }

    @Test("voice ID without underscore returns raw ID")
    func noUnderscore() {
        let name = KokoroTtsProvider.displayName(for: "heart")
        #expect(name == "heart")
    }

    @Test("capitalizes multi-word names")
    func multiWordName() {
        let name = KokoroTtsProvider.displayName(for: "af_sky")
        #expect(name == "Sky Female US")
    }
}

// MARK: - Voice Language Code

@Suite("KokoroTtsProvider Language Code")
struct LanguageCodeTests {

    @Test("American prefix returns en-US")
    func americanPrefix() {
        #expect(KokoroTtsProvider.languageCode(for: "af_heart") == "en-US")
        #expect(KokoroTtsProvider.languageCode(for: "am_adam") == "en-US")
    }

    @Test("British prefix returns en-GB")
    func britishPrefix() {
        #expect(KokoroTtsProvider.languageCode(for: "bf_emma") == "en-GB")
        #expect(KokoroTtsProvider.languageCode(for: "bm_george") == "en-GB")
    }

    @Test("unknown prefix returns en")
    func unknownPrefix() {
        #expect(KokoroTtsProvider.languageCode(for: "zz_test") == "en")
    }

    @Test("empty string returns en")
    func emptyString() {
        #expect(KokoroTtsProvider.languageCode(for: "") == "en")
    }
}

// MARK: - Voice Presets

@Suite("KokoroVoicePreset")
struct VoicePresetTests {

    @Test("preset list is non-empty")
    func nonEmpty() {
        #expect(!KokoroVoicePreset.all.isEmpty)
    }

    @Test("all presets have unique IDs")
    func uniqueIds() {
        let ids = KokoroVoicePreset.all.map(\.id)
        let uniqueIds = Set(ids)
        #expect(ids.count == uniqueIds.count)
    }

    @Test("all presets have non-empty labels")
    func nonEmptyLabels() {
        for preset in KokoroVoicePreset.all {
            #expect(!preset.label.isEmpty)
        }
    }

    @Test("default voice af_heart is included")
    func defaultVoiceIncluded() {
        let ids = KokoroVoicePreset.all.map(\.id)
        #expect(ids.contains("af_heart"))
    }

    @Test("includes both US and UK voices")
    func bothAccents() {
        let ids = KokoroVoicePreset.all.map(\.id)
        let hasUS = ids.contains { $0.hasPrefix("a") }
        let hasUK = ids.contains { $0.hasPrefix("b") }
        #expect(hasUS)
        #expect(hasUK)
    }

    @Test("includes both male and female voices")
    func bothGenders() {
        let ids = KokoroVoicePreset.all.map(\.id)
        let hasFemale = ids.contains { $0.contains("f_") }
        let hasMale = ids.contains { $0.contains("m_") }
        #expect(hasFemale)
        #expect(hasMale)
    }
}
