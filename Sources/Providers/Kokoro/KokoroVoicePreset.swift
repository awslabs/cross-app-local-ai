import Foundation

/// A curated Kokoro voice preset for the settings UI.
///
/// Kokoro ships with 54 voice presets. This list surfaces the most common
/// English voices so the picker is usable without scrolling through dozens
/// of entries. The full set is available at runtime via
/// `KokoroSynthesizer.availableVoices`.
struct KokoroVoicePreset: Identifiable {
    let id: String
    let label: String

    /// Curated English voice presets.
    static let all: [KokoroVoicePreset] = [
        KokoroVoicePreset(id: "af_heart", label: "Heart (US Female)"),
        KokoroVoicePreset(id: "af_sky", label: "Sky (US Female)"),
        KokoroVoicePreset(id: "af_bella", label: "Bella (US Female)"),
        KokoroVoicePreset(id: "af_nicole", label: "Nicole (US Female)"),
        KokoroVoicePreset(id: "af_sarah", label: "Sarah (US Female)"),
        KokoroVoicePreset(id: "am_adam", label: "Adam (US Male)"),
        KokoroVoicePreset(id: "am_michael", label: "Michael (US Male)"),
        KokoroVoicePreset(id: "bf_emma", label: "Emma (UK Female)"),
        KokoroVoicePreset(id: "bf_isabella", label: "Isabella (UK Female)"),
        KokoroVoicePreset(id: "bm_george", label: "George (UK Male)"),
        KokoroVoicePreset(id: "bm_lewis", label: "Lewis (UK Male)"),
    ]
}
