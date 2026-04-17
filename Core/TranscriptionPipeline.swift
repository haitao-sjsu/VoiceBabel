// TranscriptionPipeline.swift
// WhisperUtil - macOS menu bar speech-to-text tool
//
// Transcription pipeline — audio to text with priority-based engine fallback.
//
// Responsibilities:
//   1. Iterate configured engines (cloud / local) in priority order
//   2. Dispatch to the matching backend: cloud (HTTP) or local (WhisperKit)
//   3. Fallback on recoverable failure — network error for cloud, any error for local
//   4. Apply dynamic timeout to local transcription (based on audio duration)
//   5. Report outcomes via callbacks — no internal state is mutated
//
// Dependencies:
//   - CloudOpenAIService (cloud transcription)
//   - LocalWhisperService (local WhisperKit transcription)
//   - EngineeringOptions, LocaleManager, SettingsDefaults
//
// Architecture role:
//   Shared by RecordingController (transcription mode) and TranslationPipeline
//   (two-step translation, Step 1). Stateless — callers wire callbacks before
//   each call. Fallback state (isInFallbackMode / currentApiMode) lives in
//   RecordingController; this pipeline only emits an onFallbackEntered signal.

import Foundation

class TranscriptionPipeline {

    // MARK: - Dependencies

    var cloudOpenAIService: CloudOpenAIService
    let localWhisperService: LocalWhisperService

    // MARK: - Configuration

    var priority: [String] = SettingsDefaults.transcriptionPriority

    // MARK: - Callbacks

    /// Emitted on the main queue when any engine succeeds. Raw text — caller
    /// is responsible for trimming and empty-result handling. Second argument
    /// is the engine identifier that succeeded ("cloud" / "local"), used by
    /// callers to build engine-specific log messages.
    var onResult: ((String, String) -> Void)?

    /// Emitted on the main queue when every engine in the priority list has
    /// failed (or the single attempted engine failed with a non-recoverable
    /// error). The payload is a UI-facing localized message.
    var onError: ((String) -> Void)?

    /// Emitted on the main queue when an engine yields to the next priority
    /// due to a recoverable failure (cloud network error, local any error).
    /// The payload is the engine identifier that just gave up ("cloud" / "local").
    var onFallbackEntered: ((String) -> Void)?

    // MARK: - Init

    init(cloudOpenAIService: CloudOpenAIService, localWhisperService: LocalWhisperService) {
        self.cloudOpenAIService = cloudOpenAIService
        self.localWhisperService = localWhisperService
    }

    // MARK: - Public

    /// Start transcription, trying engines in priority order starting from
    /// `startingEngine`. Used to respect the user's current API mode when it
    /// diverges from `priority[0]` (e.g. after `userDidChangeApiMode`).
    ///
    /// - Parameters:
    ///   - recording: Encoded audio for cloud engines. Pass `nil` to skip cloud.
    ///   - samples: Float PCM samples for local engines. Pass empty to skip local.
    ///   - audioDuration: Duration in seconds, used for cloud request timeout.
    ///   - startingEngine: Engine name ("cloud" / "local") to attempt first.
    ///     Fallback continues forward in the priority list only.
    func transcribe(
        recording: AudioRecorder.RecordingResult?,
        samples: [Float],
        audioDuration: TimeInterval,
        startingEngine: String
    ) {
        Log.i(LocaleManager.shared.logLocalized("TranscriptionPipeline: starting from engine") + " '\(startingEngine)', priority: \(priority)")
        let startIndex = priority.firstIndex(of: startingEngine) ?? 0
        tryEngine(at: startIndex, recording: recording, samples: samples, audioDuration: audioDuration)
    }

    // MARK: - Private

    private func tryEngine(
        at index: Int,
        recording: AudioRecorder.RecordingResult?,
        samples: [Float],
        audioDuration: TimeInterval
    ) {
        let lm = LocaleManager.shared

        guard index < priority.count else {
            Log.e(lm.logLocalized("TranscriptionPipeline: all engines exhausted"))
            onError?(String(localized: "All transcription modes failed"))
            return
        }

        if index > 0 && !EngineeringOptions.enableModeFallback {
            Log.e(lm.logLocalized("TranscriptionPipeline: failed and fallback disabled"))
            onError?(String(localized: "Transcription failed"))
            return
        }

        let engine = priority[index]
        let tryNext: () -> Void = { [weak self] in
            DispatchQueue.main.async {
                self?.tryEngine(at: index + 1, recording: recording, samples: samples, audioDuration: audioDuration)
            }
        }

        switch engine {
        case "cloud":
            guard let recording = recording else {
                Log.w(lm.logLocalized("No encoded audio for cloud transcription, trying next priority"))
                tryNext()
                return
            }
            cloudTranscribe(recording: recording, audioDuration: audioDuration, tryNext: tryNext)

        case "local":
            guard localWhisperService.isReady() else {
                Log.w(lm.logLocalized("Local WhisperKit not ready, trying next priority"))
                tryNext()
                return
            }
            guard !samples.isEmpty else {
                Log.w(lm.logLocalized("No audio samples for local transcription, trying next priority"))
                tryNext()
                return
            }
            localTranscribe(samples: samples, tryNext: tryNext)

        default:
            Log.w("TranscriptionPipeline: unknown engine '\(engine)', skipping")
            tryNext()
        }
    }

    private func cloudTranscribe(
        recording: AudioRecorder.RecordingResult,
        audioDuration: TimeInterval,
        tryNext: @escaping () -> Void
    ) {
        let lm = LocaleManager.shared
        let action = lm.logLocalized("Cloud speech recognition")
        Log.i(lm.logLocalized("Calling Whisper API (cloud transcription)..."))

        cloudOpenAIService.transcribe(audioData: recording.data, format: recording.format, audioDuration: audioDuration) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let text):
                    Log.i(lm.logLocalized("Cloud transcription succeeded"))
                    self.onResult?(text, "cloud")
                case .failure(let error):
                    if let whisperError = error as? CloudOpenAIService.WhisperError,
                       case .networkError = whisperError {
                        Log.w(lm.logLocalized("Cloud API failed, trying next priority:") + " \(error.localizedDescription)")
                        self.onFallbackEntered?("cloud")
                        tryNext()
                    } else {
                        Log.i("\(action) " + lm.logLocalized("failed:") + " \(error)")
                        self.onError?(String(localized: "\(action) failed: \(error.localizedDescription)"))
                    }
                }
            }
        }
    }

    private func localTranscribe(samples: [Float], tryNext: @escaping () -> Void) {
        let lm = LocaleManager.shared
        let sampleDuration = Double(samples.count) / EngineeringOptions.sampleRate
        let minutes = sampleDuration / 60.0
        let timeout = min(max(minutes * 10, EngineeringOptions.apiProcessingTimeoutMin), EngineeringOptions.apiProcessingTimeoutMax)
        let action = lm.logLocalized("Local speech recognition")
        Log.i("\(action): " + lm.logLocalized("audio duration") + " \(String(format: "%.1f", sampleDuration))s, " + lm.logLocalized("local processing timeout") + " \(String(format: "%.0f", timeout))s")

        Task {
            do {
                let text = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        try await self.localWhisperService.transcribe(samples: samples)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        throw CancellationError()
                    }
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }
                await MainActor.run {
                    Log.i(lm.logLocalized("Local transcription succeeded"))
                    self.onResult?(text, "local")
                }
            } catch is CancellationError {
                await MainActor.run {
                    Log.e("\(action) " + lm.logLocalized("timed out") + " (\(String(format: "%.0f", timeout))s)")
                    if EngineeringOptions.enableModeFallback {
                        Log.w(lm.logLocalized("Local transcription failed, trying next priority"))
                        self.onFallbackEntered?("local")
                        tryNext()
                    } else {
                        self.onError?(String(localized: "\(action) timed out, try shorter recordings"))
                    }
                }
            } catch {
                await MainActor.run {
                    Log.e("\(action) " + lm.logLocalized("failed:") + " \(error)")
                    if EngineeringOptions.enableModeFallback {
                        Log.w(lm.logLocalized("Local transcription failed, trying next priority"))
                        self.onFallbackEntered?("local")
                        tryNext()
                    } else {
                        self.onError?(String(localized: "\(action) failed: \(error.localizedDescription)"))
                    }
                }
            }
        }
    }
}
