import Foundation

/// Audio encoding format.
enum AudioFormat {
    case wav
    case mp3
    case ogg
    case pcm
    case flac

    /// MIME type for HTTP headers and content negotiation.
    var mimeType: String {
        switch self {
        case .wav: "audio/wav"
        case .mp3: "audio/mpeg"
        case .ogg: "audio/ogg"
        case .pcm: "audio/pcm"
        case .flac: "audio/flac"
        }
    }

    /// Standard file extension including the leading dot.
    var fileExtension: String {
        switch self {
        case .wav: ".wav"
        case .mp3: ".mp3"
        case .ogg: ".ogg"
        case .pcm: ".pcm"
        case .flac: ".flac"
        }
    }
}

/// Audio sample rate in Hz.
///
/// Stored as a raw `UInt32` because hardware devices may report
/// non-standard rates that still need to be represented.
struct SampleRate: Equatable {
    let value: UInt32

    static let telephony = SampleRate(value: 8000)
    static let wideband = SampleRate(value: 16000)
    static let cdQuality = SampleRate(value: 44100)
    static let studio = SampleRate(value: 48000)
}

/// Mono vs stereo channel layout.
enum Channels {
    case mono
    case stereo
}

/// Describes the format of an audio buffer.
struct AudioMeta {
    var format: AudioFormat = .pcm
    var sampleRate: SampleRate = .wideband
    var channels: Channels = .mono
}

/// A buffer of raw audio data with associated format metadata.
struct AudioBuffer {
    var meta: AudioMeta
    var data: Data
}

/// The result of a completed transcription.
struct Transcription {
    var text: String
    var language: String?
    var confidence: Float?
}

/// A chunk of audio data for streaming transcription.
struct AudioChunk {
    var data: Data
    var timestamp: TimeInterval
}

/// Events emitted during streaming transcription.
enum TranscriptionEvent {
    case partial(String)
    case final(Transcription)
}
