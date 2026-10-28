import Foundation
import Testing
@testable import FastLang

@Suite("KokoroPhonemizer special token IDs")
struct KokoroPhonemizerSpecialTokenTests {

    /// Kokoro-82M's vocabulary has no dedicated BOS/EOS entries -- id 0 is the
    /// sole sentinel used to wrap every utterance. Ids 1 and 2 are real
    /// vocabulary entries for ';' and ':' respectively. If bosId/eosId ever
    /// drift from padId again, every synthesized chunk would silently be
    /// bookended with a bogus literal semicolon/colon instead of the model's
    /// trained start/end-of-sequence silence.
    @Test("bosId and eosId equal padId")
    func bosAndEosEqualPad() {
        let phonemizer = KokoroPhonemizer(vocab: [";": 1, ":": 2, ",": 3, ".": 4])

        #expect(phonemizer.bosId == phonemizer.padId)
        #expect(phonemizer.eosId == phonemizer.padId)
    }

    @Test("bosId and eosId do not collide with real vocabulary entries for ';' or ':'")
    func bosAndEosDoNotCollideWithSemicolonOrColon() {
        let vocab = [";": 1, ":": 2, ",": 3, ".": 4]
        let phonemizer = KokoroPhonemizer(vocab: vocab)

        #expect(phonemizer.bosId != vocab[";"])
        #expect(phonemizer.eosId != vocab[":"])
    }

    @Test("tokenize wraps phonemes with padId, not bogus punctuation tokens")
    func tokenizeWrapsWithPadId() {
        let vocab = [";": 1, ":": 2, ",": 3, ".": 4, "h": 50, "i": 51, " ": 16]
        let phonemizer = KokoroPhonemizer(vocab: vocab)

        let ids = phonemizer.tokenize("hi.", maxLength: 16, language: "en")

        #expect(ids.first == phonemizer.padId)
        #expect(ids.first != vocab[";"])
    }
}
