import Foundation
import Testing
@testable import FastLang

@Suite("AudioFormat")
struct AudioFormatTests {

    @Test("mime types are valid MIME format")
    func mimeTypes() {
        #expect(AudioFormat.wav.mimeType == "audio/wav")
        #expect(AudioFormat.mp3.mimeType == "audio/mpeg")
        #expect(AudioFormat.ogg.mimeType == "audio/ogg")
        #expect(AudioFormat.pcm.mimeType == "audio/pcm")
        #expect(AudioFormat.flac.mimeType == "audio/flac")
    }

    @Test("file extensions start with a dot")
    func fileExtensions() {
        #expect(AudioFormat.wav.fileExtension == ".wav")
        #expect(AudioFormat.mp3.fileExtension == ".mp3")
        #expect(AudioFormat.ogg.fileExtension == ".ogg")
        #expect(AudioFormat.pcm.fileExtension == ".pcm")
        #expect(AudioFormat.flac.fileExtension == ".flac")
    }
}

@Suite("SampleRate")
struct SampleRateTests {

    @Test("named constants have correct Hz values")
    func namedConstants() {
        #expect(SampleRate.telephony.value == 8000)
        #expect(SampleRate.wideband.value == 16000)
        #expect(SampleRate.cdQuality.value == 44100)
        #expect(SampleRate.studio.value == 48000)
    }

    @Test("equatable compares by value")
    func equatable() {
        #expect(SampleRate.wideband == SampleRate(value: 16000))
        #expect(SampleRate.wideband != SampleRate.studio)
    }

    @Test("arbitrary sample rates are representable")
    func arbitraryRate() {
        let custom = SampleRate(value: 22050)
        #expect(custom.value == 22050)
    }
}

@Suite("AudioMeta")
struct AudioMetaTests {

    @Test("defaults are PCM, 16kHz, mono")
    func defaults() {
        let meta = AudioMeta()
        #expect(meta.format == .pcm)
        #expect(meta.sampleRate == .wideband)
        #expect(meta.channels == .mono)
    }
}

@Suite("Transcription")
struct TranscriptionTests {

    @Test("stores text, language, and confidence")
    func construction() {
        let transcription = Transcription(text: "hello world", language: "en", confidence: 0.95)
        #expect(transcription.text == "hello world")
        #expect(transcription.language == "en")
        #expect(transcription.confidence == 0.95)
    }

    @Test("language and confidence are optional")
    func optionals() {
        let transcription = Transcription(text: "test", language: nil, confidence: nil)
        #expect(transcription.language == nil)
        #expect(transcription.confidence == nil)
    }
}

@Suite("TranscriptionEvent")
struct TranscriptionEventTests {

    @Test("partial carries intermediate text")
    func partial() {
        let event = TranscriptionEvent.partial("hello")
        if case let .partial(text) = event {
            #expect(text == "hello")
        } else {
            Issue.record("Expected .partial")
        }
    }

    @Test("final carries a complete transcription")
    func finalEvent() {
        let transcription = Transcription(text: "done", language: "en", confidence: 0.99)
        let event = TranscriptionEvent.final(transcription)
        if case let .final(result) = event {
            #expect(result.text == "done")
        } else {
            Issue.record("Expected .final")
        }
    }
}
