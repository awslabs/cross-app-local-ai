import Foundation
import Testing
@testable import FastLang

@Suite("ModelIntegrityError")
struct ModelIntegrityErrorTests {

    @Test("checksumMismatch provides meaningful errorDescription")
    func checksumMismatchDescription() {
        let error = ModelIntegrityError.checksumMismatch(
            modelId: "gemma-4-e2b",
            expected: "9378bc471710229ef165709b62e34bfb62231420ddaf6d729e727305b5b8672d", // pragma: allowlist secret
            actual: "0000000000000000000000000000000000000000000000000000000000000000"
        )
        let desc = error.errorDescription ?? ""
        #expect(desc.contains("gemma-4-e2b"))
        #expect(desc.contains("9378bc471710")) // pragma: allowlist secret
        #expect(desc.contains("000000000000"))
    }

    @Test("fileUnreadable includes path in description")
    func fileUnreadableDescription() {
        let underlying = NSError(domain: "test", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "permission denied",
        ])
        let error = ModelIntegrityError.fileUnreadable(
            path: "/models/test.gguf",
            underlying: underlying
        )
        let desc = error.errorDescription ?? ""
        #expect(desc.contains("/models/test.gguf"))
        #expect(desc.contains("permission denied"))
    }

    @Test("checksumMismatch has a recoverySuggestion")
    func checksumMismatchRecovery() {
        let error = ModelIntegrityError.checksumMismatch(
            modelId: "test",
            expected: "aaa",
            actual: "bbb"
        )
        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("re-downloaded") == true)
    }

    @Test("fileUnreadable has a recoverySuggestion")
    func fileUnreadableRecovery() {
        let underlying = NSError(domain: "test", code: 1)
        let error = ModelIntegrityError.fileUnreadable(path: "/tmp/x", underlying: underlying)
        #expect(error.recoverySuggestion != nil)
    }

    @Test("fileMissing provides meaningful errorDescription")
    func fileMissingDescription() {
        let error = ModelIntegrityError.fileMissing(
            modelId: "kokoro-82m",
            subpath: "kokoro_5s.mlmodelc/weights/weight.bin"
        )
        let desc = error.errorDescription ?? ""
        #expect(desc.contains("kokoro-82m"))
        #expect(desc.contains("kokoro_5s.mlmodelc/weights/weight.bin"))
        #expect(desc.contains("missing"))
    }

    @Test("fileMissing has a recoverySuggestion")
    func fileMissingRecovery() {
        let error = ModelIntegrityError.fileMissing(
            modelId: "test",
            subpath: "weights/weight.bin"
        )
        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("re-downloaded") == true)
    }
}
