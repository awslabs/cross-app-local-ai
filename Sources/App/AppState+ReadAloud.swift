import AppKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "appstate.readaloud")

/// Delay after focusing the target app before simulating Cmd+C for selection capture.
private let readAloudCaptureDelayNanoseconds: UInt64 = 200_000_000

// MARK: - Read-Aloud Pipeline

extension AppState {
    /// Activates the read-aloud feature: captures selected text and shows the panel.
    ///
    /// If the read-aloud panel is already visible, this dismisses it instead (toggle).
    func triggerReadAloud() async {
        if isReadAloudVisible {
            await dismissReadAloud()
            return
        }

        do {
            let activeApp = try await platformService.getActiveApp()
            try await platformService.focusApp(activeApp)
            try await Task.sleep(nanoseconds: readAloudCaptureDelayNanoseconds)

            let selection = try await platformService.captureSelection()

            guard let text = selection, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                logger.info("Read-aloud: no text selected, aborting")
                return
            }

            logger.info("Read-aloud: captured \(text.count) chars from \(activeApp.appName)")

            let processedText: String = switch config.tts.preprocessing {
            case .none:
                text
            case .deterministic, .llm:
                SpeechTextSanitizer.sanitize(text)
            }

            setReadAloudText(processedText)
            readAloudOriginalText = processedText
            readAloudRendition = .original
            readAloudSummarizeState = .idle
            readAloudRate = config.tts.rate
            isReadAloudVisible = true
            recordTelemetryFeature(.readAloud)
        } catch {
            logger.error("Read-aloud capture failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Playback Controls

    /// Begins speaking the captured text from the beginning or a given offset.
    ///
    /// - Parameter startOffset: Character offset to begin speaking from. Defaults to 0.
    func startSpeaking(from startOffset: Int = 0) async {
        readAloudErrorMessage = nil

        guard let text = readAloudText else {
            logger.warning("startSpeaking called with no readAloudText")
            return
        }
        guard let ttsService else {
            logger.error("TTS service not initialized")
            presentTtsAlert(for: TtsError.startingUp)
            readAloudPlaybackState = .idle
            readAloudHighlightRange = nil
            return
        }

        readAloudTask?.cancel()
        readAloudPlaybackState = .playing

        let request = TtsSynthesisRequest(
            text: text,
            voice: config.tts.voiceId.map { TtsVoice(id: $0, name: "", language: "") },
            rate: readAloudRate,
            startOffset: startOffset
        )

        readAloudTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await ttsService.speak(request)
                self.recordTelemetryFeature(.ttsSpeak)
                for try await event in stream {
                    guard !Task.isCancelled else { break }
                    await self.handleTtsEvent(event)
                }
            } catch is CancellationError {
                logger.debug("Read-aloud stream cancelled")
            } catch {
                self.recordTelemetryError(.ttsSpeakFailed)
                logger.error("Read-aloud error: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.readAloudPlaybackState = .idle
                    self.readAloudHighlightRange = nil
                    self.presentTtsAlert(for: error)
                }
            }
        }
    }

    private func presentTtsAlert(for error: Error) {
        let ttsError = error as? TtsError
        let message = ttsError?.userMessage ?? error.localizedDescription
        let suggestion = ttsError?.suggestedAction
        let body = suggestion.map { "\(message). \($0)." } ?? "\(message)."
        readAloudErrorMessage = body
    }

    /// Pauses speech playback.
    func pauseSpeaking() async {
        guard readAloudPlaybackState == .playing else { return }
        await ttsService?.pause()
        readAloudPlaybackState = .paused
        logger.debug("Read-aloud paused")
    }

    /// Resumes speech playback.
    func resumeSpeaking() async {
        guard readAloudPlaybackState == .paused else { return }
        await ttsService?.resume()
        readAloudPlaybackState = .playing
        logger.debug("Read-aloud resumed")
    }

    /// Stops speech playback and resets to idle.
    func stopSpeaking() async {
        readAloudTask?.cancel()
        readAloudTask = nil
        await ttsService?.stop()
        readAloudPlaybackState = .idle
        readAloudHighlightRange = nil
        logger.debug("Read-aloud stopped")
    }

    /// Seeks to a specific word by stopping and re-starting synthesis from the given offset.
    ///
    /// - Parameter characterOffset: The character offset in the original text to begin from.
    func seekToWord(characterOffset: Int) async {
        await stopSpeaking()
        await startSpeaking(from: characterOffset)
    }

    /// Updates the speech rate. If currently playing, restarts at the current position.
    ///
    /// - Parameter rate: New rate (0.0 .. 1.0 normalized).
    func setReadAloudRate(_ rate: Float) async {
        readAloudRate = rate
        if readAloudPlaybackState == .playing {
            let currentOffset = readAloudHighlightRange?.lowerBound ?? 0
            await stopSpeaking()
            await startSpeaking(from: currentOffset)
        }
    }

    /// Dismisses the read-aloud panel: stops speech, resets state.
    func dismissReadAloud() async {
        await stopSpeaking()
        resetReadAloudState()
        logger.info("Read-aloud dismissed")
    }

    // MARK: - Event Handling

    private func handleTtsEvent(_ event: TtsEvent) async {
        switch event {
        case let .wordBoundary(timing):
            readAloudHighlightRange = timing.range
        case .finished:
            readAloudPlaybackState = .idle
            readAloudHighlightRange = nil
            logger.info("Read-aloud finished")
        case .cancelled:
            logger.debug("Read-aloud synthesis cancelled")
        }
    }
}
