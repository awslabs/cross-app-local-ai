import Testing
@testable import FastLang

// MARK: - Fixtures

/// Exactly 24 characters, including the trailing space. Chosen so budget
/// arithmetic against the 4-chars-per-token heuristic is exact rather than
/// approximate: a 12-token budget admits 48 characters, which is precisely two
/// of these sentences.
private let sentence = "Alpha beta gamma delta. "

/// Eight sentences, 192 characters. At a 12-token budget this is four chunks
/// of two sentences, with boundaries at 0, 48, 96, and 144.
private let corpus = String(repeating: sentence, count: 8)

/// Budget that packs exactly two fixture sentences per chunk.
private let twoSentenceBudget = 12

private struct TransformFailure: Error, Equatable {}

/// Collects transform inputs and progress callbacks without a data race.
/// An actor rather than a lock because the deployment floor is macOS 14, which
/// predates `Synchronization.Mutex`.
private actor CallRecorder {
    private(set) var inputs: [String] = []
    private(set) var progressCompleted: [Int] = []
    private(set) var progressTotals: [Int] = []

    var callCount: Int {
        inputs.count
    }

    func record(_ input: String) {
        inputs.append(input)
    }

    func recordProgress(completed: Int, total: Int) {
        progressCompleted.append(completed)
        progressTotals.append(total)
    }
}

// MARK: - chunk

@Suite("TextMapReduce.chunk")
struct TextMapReduceChunkTests {

    @Test("empty text yields no chunks")
    func emptyText() {
        #expect(TextMapReduce.chunk("", maxTokens: twoSentenceBudget).isEmpty)
    }

    @Test("a single short sentence yields one chunk")
    func singleSentence() {
        let chunks = TextMapReduce.chunk("Hello there.", maxTokens: 100)
        #expect(chunks.count == 1)
        #expect(chunks.first?.text == "Hello there.")
        #expect(chunks.first?.offset == 0)
    }

    @Test("sentences are packed up to the budget")
    func packsToBudget() {
        #expect(TextMapReduce.chunk(corpus, maxTokens: twoSentenceBudget).count == 4)
    }

    @Test("every chunk fits the token budget")
    func chunksFitBudget() {
        let chunks = TextMapReduce.chunk(corpus, maxTokens: twoSentenceBudget)
        #expect(chunks.allSatisfy { PromptUtils.estimateTokens($0.text) <= twoSentenceBudget })
    }

    @Test("concatenating chunks reproduces the original text")
    func losslessConcatenation() {
        let chunks = TextMapReduce.chunk(corpus, maxTokens: twoSentenceBudget)
        #expect(chunks.map(\.text).joined() == corpus)
    }

    @Test("chunk offsets mark each piece's position in the source")
    func offsetsTrackSource() {
        let chunks = TextMapReduce.chunk(corpus, maxTokens: twoSentenceBudget)
        #expect(chunks.map(\.offset) == [0, 48, 96, 144])
    }

    @Test("a sentence larger than the budget is emitted whole")
    func overBudgetSentenceKeptIntact() {
        let chunks = TextMapReduce.chunk(corpus, maxTokens: 1)
        #expect(chunks.count == 8)
        #expect(chunks.allSatisfy { $0.text == sentence })
    }

    @Test("a non-positive budget is clamped rather than looping")
    func nonPositiveBudgetClamped() {
        let chunks = TextMapReduce.chunk(corpus, maxTokens: 0)
        #expect(chunks.count == 8)
        #expect(chunks.map(\.text).joined() == corpus)
    }

    @Test("text with no sentence terminator is still chunked")
    func unterminatedText() {
        let chunks = TextMapReduce.chunk("no terminator here", maxTokens: twoSentenceBudget)
        #expect(chunks.map(\.text).joined() == "no terminator here")
    }
}

// MARK: - map

@Suite("TextMapReduce.map")
struct TextMapReduceMapTests {

    @Test("the transform is applied to every chunk in source order")
    func appliesInOrder() async throws {
        let recorder = CallRecorder()
        _ = try await TextMapReduce.map(corpus, maxTokens: twoSentenceBudget) { text in
            await recorder.record(text)
            return text
        }
        let expected = TextMapReduce.chunk(corpus, maxTokens: twoSentenceBudget).map(\.text)
        #expect(await recorder.inputs == expected)
    }

    @Test("one result is returned per chunk")
    func resultPerChunk() async throws {
        let results = try await TextMapReduce.map(corpus, maxTokens: twoSentenceBudget) {
            $0.uppercased()
        }
        #expect(results.count == 4)
        #expect(results.allSatisfy { $0 == $0.uppercased() })
    }

    @Test("no content is dropped when results are rejoined")
    func rejoinPreservesEverything() async throws {
        let results = try await TextMapReduce.map(corpus, maxTokens: twoSentenceBudget) { $0 }
        #expect(results.joined() == corpus)
    }

    @Test("progress is reported before the first chunk and after each one")
    func reportsProgress() async throws {
        let recorder = CallRecorder()
        _ = try await TextMapReduce.map(
            corpus,
            maxTokens: twoSentenceBudget,
            onProgress: { completed, total in
                await recorder.recordProgress(completed: completed, total: total)
            },
            transform: { $0 }
        )
        #expect(await recorder.progressCompleted == [0, 1, 2, 3, 4])
        #expect(await recorder.progressTotals == [4, 4, 4, 4, 4])
    }

    @Test("empty text produces no results and never calls the transform")
    func emptyTextSkipsTransform() async throws {
        let recorder = CallRecorder()
        let results = try await TextMapReduce.map("", maxTokens: twoSentenceBudget) { text in
            await recorder.record(text)
            return text
        }
        #expect(results.isEmpty)
        #expect(await recorder.callCount == 0)
    }

    @Test("a transform failure propagates to the caller")
    func transformFailurePropagates() async {
        await #expect(throws: TransformFailure()) {
            _ = try await TextMapReduce.map(corpus, maxTokens: twoSentenceBudget) { _ in
                throw TransformFailure()
            }
        }
    }
}

// MARK: - map concurrency

/// Tracks how many transforms are simultaneously "entered but not yet
/// exited" to prove the sliding window in `mapConcurrently` never exceeds
/// its bound. No sleeps or timeouts: `enter()` suspends until the target
/// concurrency is actually reached, so the test observes real overlap
/// rather than inferring it from timing.
private actor InFlightTracker {
    private(set) var maxObserved = 0
    private var current = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let target: Int

    init(target: Int) {
        self.target = target
    }

    func enter() async {
        current += 1
        maxObserved = max(maxObserved, current)
        guard current < target else {
            let toResume = waiters
            waiters.removeAll()
            for continuation in toResume {
                continuation.resume()
            }
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func exit() {
        current -= 1
    }
}

/// Lets one transform force another to complete first, so a test can prove
/// result ordering survives out-of-order completion without relying on
/// timing. No sleeps or timeouts: `waitForSignal()` suspends on a real
/// continuation until `signal()` is called.
private actor OrderGate {
    private var signaled = false
    private var waiter: CheckedContinuation<Void, Never>?

    func waitForSignal() async {
        guard !signaled else { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func signal() {
        signaled = true
        waiter?.resume()
        waiter = nil
    }
}

@Suite("TextMapReduce.map concurrency")
struct TextMapReduceMapConcurrencyTests {

    @Test("results preserve source order even when a later chunk finishes first")
    func preservesOrderDespiteOutOfOrderCompletion() async throws {
        // Distinct sentences, unlike the shared `corpus` fixture: that corpus
        // repeats one sentence, so every chunk is textually identical and
        // `text ==` cannot tell chunk 0 apart from chunk 1. A budget of 1
        // token forces one sentence per chunk (see the chunk-level tests
        // above for the same technique).
        let localCorpus = "Alpha one. Beta two."
        let chunks = TextMapReduce.chunk(localCorpus, maxTokens: 1)
        let firstText = chunks[0].text
        let secondText = chunks[1].text

        let gate = OrderGate()
        let results = try await TextMapReduce.map(
            localCorpus,
            maxTokens: 1,
            concurrency: 2
        ) { text in
            if text == firstText {
                await gate.waitForSignal()
                return text.uppercased()
            }
            let transformed = text.uppercased()
            if text == secondText {
                await gate.signal()
            }
            return transformed
        }

        #expect(results == chunks.map { $0.text.uppercased() })
    }

    @Test("no more than the requested number of chunks run at once")
    func boundsMaxInFlight() async throws {
        let tracker = InFlightTracker(target: 2)
        _ = try await TextMapReduce.map(
            corpus,
            maxTokens: twoSentenceBudget,
            concurrency: 2
        ) { text in
            await tracker.enter()
            await tracker.exit()
            return text
        }
        #expect(await tracker.maxObserved == 2)
    }

    @Test("concurrency of 1 behaves exactly like the sequential path")
    func concurrencyOneMatchesSequential() async throws {
        let results = try await TextMapReduce.map(
            corpus,
            maxTokens: twoSentenceBudget,
            concurrency: 1
        ) { $0.uppercased() }
        let expected = try await TextMapReduce.map(corpus, maxTokens: twoSentenceBudget) {
            $0.uppercased()
        }
        #expect(results == expected)
    }

    @Test("progress still advances by exactly one per completion under concurrency")
    func progressRemainsMonotonicUnderConcurrency() async throws {
        let recorder = CallRecorder()
        _ = try await TextMapReduce.map(
            corpus,
            maxTokens: twoSentenceBudget,
            concurrency: 2,
            onProgress: { completed, total in
                await recorder.recordProgress(completed: completed, total: total)
            },
            transform: { $0 }
        )
        #expect(await recorder.progressCompleted == [0, 1, 2, 3, 4])
        #expect(await recorder.progressTotals == [4, 4, 4, 4, 4])
    }

    @Test("no content is dropped when concurrency is greater than one")
    func rejoinPreservesEverythingUnderConcurrency() async throws {
        let results = try await TextMapReduce.map(
            corpus,
            maxTokens: twoSentenceBudget,
            concurrency: 2
        ) { $0 }
        #expect(results.joined() == corpus)
    }

    @Test("a transform failure under concurrency propagates to the caller")
    func transformFailurePropagatesUnderConcurrency() async {
        await #expect(throws: TransformFailure()) {
            _ = try await TextMapReduce.map(
                corpus,
                maxTokens: twoSentenceBudget,
                concurrency: 2
            ) { _ in
                throw TransformFailure()
            }
        }
    }
}

// MARK: - mapReduce

@Suite("TextMapReduce.mapReduce")
struct TextMapReduceMapReduceTests {

    @Test("a single mapped result skips the reduce pass entirely")
    func singleChunkSkipsReduce() async throws {
        let recorder = CallRecorder()
        let result = try await TextMapReduce.mapReduce(
            "Hello there.",
            maxTokens: 100,
            map: { $0.uppercased() },
            reduce: { text in
                await recorder.record(text)
                return text
            }
        )
        #expect(result == "HELLO THERE.")
        #expect(await recorder.callCount == 0)
    }

    @Test("multiple mapped results are folded to one by a single reduce pass")
    func foldsToSingleResult() async throws {
        let recorder = CallRecorder()
        let result = try await TextMapReduce.mapReduce(
            corpus,
            maxTokens: twoSentenceBudget,
            map: { _ in "Short. " },
            reduce: { text in
                await recorder.record(text)
                return "Final."
            }
        )
        #expect(result == "Final.")
        #expect(await recorder.callCount == 1)
    }

    @Test("reduce levels repeat until a single result remains")
    func recursesUntilConverged() async throws {
        let recorder = CallRecorder()
        let result = try await TextMapReduce.mapReduce(
            corpus,
            maxTokens: twoSentenceBudget,
            map: { $0 },
            reduce: { text in
                await recorder.record(text)
                return "S. "
            }
        )
        #expect(result == "S. ")
        // More than one reduce call proves a second level ran: the first level
        // could not fit the rejoined partials into a single chunk.
        #expect(await recorder.callCount > 1)
    }

    @Test("a reduce that fails to shrink the text throws rather than looping")
    func stalledReductionThrows() async {
        await #expect(throws: TextMapReduceError.reductionStalled(depth: 1)) {
            _ = try await TextMapReduce.mapReduce(
                corpus,
                maxTokens: twoSentenceBudget,
                map: { $0 },
                reduce: { $0 }
            )
        }
    }

    @Test("the depth ceiling is enforced")
    func depthCeilingEnforced() async {
        await #expect(throws: TextMapReduceError.depthExhausted(depth: 0)) {
            _ = try await TextMapReduce.mapReduce(
                corpus,
                maxTokens: twoSentenceBudget,
                maxDepth: 0,
                map: { $0 },
                reduce: { $0 }
            )
        }
    }

    @Test("empty text yields an empty result")
    func emptyTextYieldsEmpty() async throws {
        let result = try await TextMapReduce.mapReduce(
            "",
            maxTokens: twoSentenceBudget,
            map: { $0 },
            reduce: { $0 }
        )
        #expect(result.isEmpty)
    }

    @Test("map progress is reported during the map level")
    func reportsMapProgress() async throws {
        let recorder = CallRecorder()
        _ = try await TextMapReduce.mapReduce(
            corpus,
            maxTokens: twoSentenceBudget,
            onProgress: { completed, total in
                await recorder.recordProgress(completed: completed, total: total)
            },
            map: { _ in "Short. " },
            reduce: { _ in "Final." }
        )
        #expect(await recorder.progressCompleted == [0, 1, 2, 3, 4])
    }

    /// Repeats `sentence` enough times to pack 20 initial chunks at
    /// `twoSentenceBudget`. Verified empirically (see git history for the
    /// throwaway diagnostic used to derive this): the halving reduce
    /// transform below needs exactly 7 levels to converge from 20 chunks,
    /// one more than `minReduceDepth` but exactly `dynamicMaxDepth(20)` --
    /// tight enough to prove the fixed floor is insufficient while the
    /// dynamic ceiling is exactly sufficient.
    private static let manySentences = String(repeating: sentence, count: 40)

    /// Halves each chunk's own text on every reduce pass. Unlike the
    /// constant-output reduce transforms used elsewhere in this file, this
    /// one keeps shrinking proportionally to its input, which is what
    /// forces multiple reduce levels instead of converging in one or two.
    private static let halvingReduce: @Sendable (String) async throws -> String = { text in
        String(text.prefix(max(1, text.count / 2))) + ". "
    }

    @Test("an explicit depth ceiling still overrides the dynamic calculation")
    func explicitDepthOverridesDynamicCalculation() async {
        await #expect(throws: TextMapReduceError.depthExhausted(depth: TextMapReduce.minReduceDepth)) {
            _ = try await TextMapReduce.mapReduce(
                Self.manySentences,
                maxTokens: twoSentenceBudget,
                maxDepth: TextMapReduce.minReduceDepth,
                map: { $0 },
                reduce: Self.halvingReduce
            )
        }
    }

    @Test("the dynamic ceiling gives a large input enough levels to converge")
    func dynamicCeilingConvergesForLargeInput() async throws {
        // Same input and reduce transform as the override test above, but
        // with no explicit maxDepth: the dynamic ceiling scales with the 20
        // initial chunks instead of sharing the small fixed ceiling, so this
        // converges instead of throwing depthExhausted.
        let result = try await TextMapReduce.mapReduce(
            Self.manySentences,
            maxTokens: twoSentenceBudget,
            map: { $0 },
            reduce: Self.halvingReduce
        )
        #expect(!result.isEmpty)
    }
}

// MARK: - dynamicMaxDepth

@Suite("TextMapReduce.dynamicMaxDepth")
struct DynamicMaxDepthTests {

    @Test("a chunk count of one or fewer uses the floor")
    func floorForTrivialCounts() {
        #expect(TextMapReduce.dynamicMaxDepth(forChunkCount: 0) == TextMapReduce.minReduceDepth)
        #expect(TextMapReduce.dynamicMaxDepth(forChunkCount: 1) == TextMapReduce.minReduceDepth)
    }

    @Test("a small chunk count does not exceed the floor")
    func floorForSmallCounts() {
        #expect(TextMapReduce.dynamicMaxDepth(forChunkCount: 4) == TextMapReduce.minReduceDepth)
    }

    @Test("a large chunk count raises the ceiling above the floor")
    func scalesAboveFloorForLargeCounts() {
        #expect(TextMapReduce.dynamicMaxDepth(forChunkCount: 200) > TextMapReduce.minReduceDepth)
    }

    @Test("the ceiling grows monotonically with chunk count")
    func growsMonotonicallyWithCount() {
        #expect(
            TextMapReduce.dynamicMaxDepth(forChunkCount: 1000)
                > TextMapReduce.dynamicMaxDepth(forChunkCount: 200)
        )
    }
}
