import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "text.mapreduce")

// MARK: - TextMapReduceError

/// Failures raised while folding a body of text down to a single result.
enum TextMapReduceError: Error, LocalizedError, Equatable {

    /// The reduce ladder ran out of levels before the text fit the budget.
    case depthExhausted(depth: Int)

    /// A reduce level returned at least as much text as it was handed, so
    /// running more levels would loop forever without converging.
    case reductionStalled(depth: Int)

    var errorDescription: String? {
        switch self {
        case let .depthExhausted(depth):
            "The text was still too long after \(depth) summarization passes."
        case .reductionStalled:
            "Summarization stopped making progress and was abandoned."
        }
    }
}

// MARK: - TextMapReduce

/// Splits arbitrarily long text into token-budgeted pieces and folds it with a
/// caller-supplied transform.
///
/// The transform is injected rather than imported, so this type never depends
/// on `LlmService` and its behavior is testable with deterministic stubs -- no
/// model, no network, no clock.
///
/// Two folds are built from one chunker:
///
/// - **Map only** (`map`): every chunk is transformed and every result is
///   returned. Nothing is dropped, so this is the safe fold for rewriting,
///   where losing a paragraph would silently lose content.
/// - **Map then reduce** (`mapReduce`): partial results are rejoined and
///   re-transformed until a single result remains. This is the fold for
///   summarizing, where the final answer is derived from the previous level's
///   results rather than from the source text directly.
enum TextMapReduce {

    /// Ceiling on reduce levels before `mapReduce` gives up.
    ///
    /// Each level shrinks the text by roughly the transform's compression
    /// ratio, so four levels covers an enormous input for any transform that
    /// actually summarizes. Hitting the ceiling means the transform is barely
    /// compressing, which is a caller problem worth surfacing rather than
    /// grinding through indefinitely.
    static let defaultMaxReduceDepth = 4

    /// Separator used when rejoining one level's results before the next.
    /// A blank line reads as a paragraph break to every model we target.
    private static let joinSeparator = "\n\n"

    // MARK: - Chunking

    /// Groups `text` into consecutive pieces that each fit a token budget.
    ///
    /// Splits on sentence boundaries via `TextChunking.splitIntoSentences` and
    /// packs as many whole sentences into each piece as the budget allows. A
    /// single sentence that exceeds the budget on its own is emitted whole
    /// rather than severed mid-thought -- a truncated sentence is worse input
    /// to a language model than a slightly over-budget one, and the provider
    /// enforces the real limit anyway.
    ///
    /// Pieces are cut from the original string by offset, so concatenating
    /// `chunk(text, ...).map(\.text)` reproduces `text` exactly.
    ///
    /// - Parameters:
    ///   - text: The full body of text. May be empty.
    ///   - maxTokens: Per-piece token budget. Values below 1 are clamped to 1.
    /// - Returns: Pieces in source order, each carrying its character offset
    ///   into `text`. Empty when `text` is empty.
    static func chunk(_ text: String, maxTokens: Int) -> [SentenceChunk] {
        guard !text.isEmpty else { return [] }
        let budget = max(1, maxTokens)
        let sentences = TextChunking.splitIntoSentences(text, baseOffset: 0)
        guard let first = sentences.first else { return [SentenceChunk(text: text, offset: 0)] }

        // Start the first group at 0 rather than at the first sentence's
        // offset, so any character sentence enumeration skipped at the very
        // start still lands in a chunk.
        var starts = [0]
        var accumulated = first.text

        for sentence in sentences.dropFirst() {
            let candidate = accumulated + sentence.text
            // Estimate the joined candidate rather than summing per-sentence
            // estimates: `estimateTokens` floors at 1, so a sum over-counts
            // every short sentence and would leave chunks well under budget.
            if PromptUtils.estimateTokens(candidate) <= budget {
                accumulated = candidate
            } else {
                starts.append(sentence.offset)
                accumulated = sentence.text
            }
        }

        return slice(text, atOffsets: starts)
    }

    /// Cuts `text` at ascending character offsets, walking the string index
    /// forward once instead of re-offsetting from the start for every piece.
    private static func slice(_ text: String, atOffsets starts: [Int]) -> [SentenceChunk] {
        let totalCount = text.count
        var chunks: [SentenceChunk] = []
        chunks.reserveCapacity(starts.count)

        var cursor = text.startIndex
        var cursorOffset = 0
        for index in starts.indices {
            let end = index + 1 < starts.count ? starts[index + 1] : totalCount
            let upper = text.index(cursor, offsetBy: end - cursorOffset)
            chunks.append(SentenceChunk(text: String(text[cursor ..< upper]), offset: cursorOffset))
            cursor = upper
            cursorOffset = end
        }
        return chunks
    }

    // MARK: - Map

    /// Transforms every chunk of `text` and returns every result in order.
    ///
    /// Nothing is skipped and nothing is truncated, so the caller can join the
    /// results knowing the whole input was covered.
    ///
    /// - Parameters:
    ///   - text: The full body of text. May be empty.
    ///   - maxTokens: Per-chunk token budget.
    ///   - concurrency: Maximum number of chunks transformed at once. `1`
    ///     (the default) processes chunks strictly in order -- required for
    ///     providers backed by a single in-process model context. Values
    ///     above `1` bound how many `transform` calls are in flight
    ///     simultaneously, for providers that can safely serve concurrent
    ///     requests (e.g. a remote HTTP API like Bedrock).
    ///   - onProgress: Called with `(completed, total)` before the first
    ///     chunk starts and after each one finishes. `completed` always
    ///     advances by one and is reported in a monotonically increasing
    ///     sequence even when `concurrency > 1`, though chunks may finish
    ///     out of source order in that case. Async so a `@MainActor` caller
    ///     can hop back to update UI state without a detached task or a
    ///     data race.
    ///   - transform: Applied to each chunk's text.
    /// - Returns: One result per chunk, in source order. Empty when `text` is.
    /// - Throws: Whatever `transform` throws, or `CancellationError` if the
    ///   surrounding task is cancelled between chunks.
    static func map(
        _ text: String,
        maxTokens: Int,
        concurrency: Int = 1,
        onProgress: (@Sendable (Int, Int) async -> Void)? = nil,
        transform: @escaping @Sendable (String) async throws -> String
    ) async throws -> [String] {
        let pieces = chunk(text, maxTokens: maxTokens)
        guard !pieces.isEmpty else { return [] }

        guard concurrency > 1 else {
            var results: [String] = []
            results.reserveCapacity(pieces.count)

            await onProgress?(0, pieces.count)
            for (index, piece) in pieces.enumerated() {
                try Task.checkCancellation()
                try await results.append(transform(piece.text))
                await onProgress?(index + 1, pieces.count)
            }
            return results
        }

        return try await mapConcurrently(
            pieces,
            maxInFlight: concurrency,
            onProgress: onProgress,
            transform: transform
        )
    }

    /// Bounded-concurrency variant of the `map` loop.
    ///
    /// Keeps at most `maxInFlight` transforms running at once via a sliding
    /// window over `withThrowingTaskGroup`: an initial batch is submitted,
    /// then each completion immediately submits the next pending chunk.
    /// Results are written into a fixed-size array by source index, so the
    /// returned order matches source order even though completion order does
    /// not. Progress is reported once per completion regardless of which
    /// chunk finished, so `completed` still advances by exactly one each
    /// time and reaches `total` only once every chunk is done.
    private static func mapConcurrently(
        _ pieces: [SentenceChunk],
        maxInFlight: Int,
        onProgress: (@Sendable (Int, Int) async -> Void)?,
        transform: @escaping @Sendable (String) async throws -> String
    ) async throws -> [String] {
        let total = pieces.count
        var results = [String?](repeating: nil, count: total)
        var completedCount = 0
        var nextIndex = 0

        await onProgress?(0, total)

        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            func submitNext() {
                guard nextIndex < total else { return }
                let index = nextIndex
                let piece = pieces[index]
                nextIndex += 1
                group.addTask {
                    try Task.checkCancellation()
                    let result = try await transform(piece.text)
                    return (index, result)
                }
            }

            for _ in 0 ..< min(maxInFlight, total) {
                submitNext()
            }

            while let (index, result) = try await group.next() {
                results[index] = result
                completedCount += 1
                await onProgress?(completedCount, total)
                submitNext()
            }
        }

        return results.compactMap { $0 }
    }

    // MARK: - Map Reduce

    /// Folds `text` to a single result: map over every chunk, then repeatedly
    /// rejoin and re-transform the results until one remains.
    ///
    /// The final result is derived from the previous level's results, not from
    /// the source text, which is what makes this work for inputs many times
    /// larger than the model's context window.
    ///
    /// Skips the reduce ladder entirely when the map produced a single result,
    /// so short inputs cost exactly one transform call.
    ///
    /// - Parameters:
    ///   - text: The full body of text. May be empty.
    ///   - maxTokens: Per-chunk token budget for every level.
    ///   - maxDepth: Ceiling on reduce levels. Zero forbids reducing at all.
    ///   - concurrency: Maximum number of chunks transformed at once, at
    ///     every level (map and each reduce pass). See `map`'s parameter of
    ///     the same name.
    ///   - onProgress: Progress for the map level only; reduce levels are
    ///     small and fast by comparison.
    ///   - mapTransform: Applied to each chunk of the source text.
    ///   - reduceTransform: Applied to each chunk of a rejoined level. Usually
    ///     a different prompt from `mapTransform` -- "combine these partial
    ///     summaries" rather than "summarize this passage".
    /// - Returns: The single folded result, or an empty string when `text` is
    ///   empty.
    /// - Throws: `TextMapReduceError.depthExhausted` when the ladder runs out
    ///   of levels, `.reductionStalled` when a level fails to shrink the text,
    ///   or whatever the transforms throw.
    static func mapReduce(
        _ text: String,
        maxTokens: Int,
        maxDepth: Int = defaultMaxReduceDepth,
        concurrency: Int = 1,
        onProgress: (@Sendable (Int, Int) async -> Void)? = nil,
        map mapTransform: @escaping @Sendable (String) async throws -> String,
        reduce reduceTransform: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        let budget = max(1, maxTokens)
        let mapped = try await map(
            text,
            maxTokens: budget,
            concurrency: concurrency,
            onProgress: onProgress,
            transform: mapTransform
        )
        guard let single = mapped.first else { return "" }
        if mapped.count == 1 { return single }

        var current = mapped.joined(separator: joinSeparator)
        var depth = 0

        while true {
            guard depth < maxDepth else {
                throw TextMapReduceError.depthExhausted(depth: depth)
            }

            let previousLength = current.count
            let folded = try await map(
                current,
                maxTokens: budget,
                concurrency: concurrency,
                transform: reduceTransform
            )
            depth += 1
            logger.debug("Reduce level \(depth) folded \(previousLength) chars into \(folded.count) part(s)")

            guard let onlyResult = folded.first else { return "" }
            if folded.count == 1 { return onlyResult }

            current = folded.joined(separator: joinSeparator)
            // A level that did not shrink the text will not shrink it next
            // time either. Fail loudly instead of burning the depth budget.
            guard current.count < previousLength else {
                throw TextMapReduceError.reductionStalled(depth: depth)
            }
        }
    }
}
