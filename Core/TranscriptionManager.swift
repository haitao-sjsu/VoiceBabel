// TranscriptionManager.swift
// WhisperUtil - macOS menu bar speech-to-text tool
//
// Transcription manager — engine management with priority-based fallback,
// fallback state ownership, and structured output via TranscriptionResult.
//
// Responsibilities:
//   1. Own transcription engine state: preferred vs effective start engine, fallback mode
//   2. Iterate configured engines (cloud / local) in priority order
//   3. Dispatch to the matching backend: cloud (HTTP) or local (WhisperKit)
//   4. Fallback on recoverable failure — network error for cloud, any error for local
//   5. Apply dynamic timeout to local transcription (based on audio duration)
//   6. Report structured outcomes via TranscriptionResult callback
//   7. Provide engine change and fallback recovery methods
//
// Dependencies:
//   - CloudOpenAIService (cloud transcription)
//   - LocalWhisperService (local WhisperKit transcription)
//   - EngineeringOptions, LocaleManager, SettingsDefaults
//
// Architecture role:
//   Shared by AppController (transcription mode and translation Step 1).
//   Owns fallback state (isInFallbackMode / effectiveStartEngine) — callers
//   no longer need to track engine switching.

import Foundation

struct TranscriptionResult {
    let text: String
    let engine: String           // "cloud" / "local"
    let fallbackFrom: String?    // non-nil = fallback occurred
}

class TranscriptionManager {

    // MARK: - Dependencies

    var cloudOpenAIService: CloudOpenAIService
    let localWhisperService: LocalWhisperService

    // MARK: - Configuration

    var priority: [String] = SettingsDefaults.transcriptionPriority

    // MARK: - Engine State

    var preferredStartEngine: String = "cloud"
    private(set) var effectiveStartEngine: String = "cloud"
    private(set) var isInFallbackMode: Bool = false

    // MARK: - Callbacks

    /// Emitted on the main queue when any engine succeeds. Structured result
    /// includes the text, which engine succeeded, and whether fallback occurred.
    var onResult: ((TranscriptionResult) -> Void)?

    /// Emitted on the main queue when every engine in the priority list has
    /// failed (or the single attempted engine failed with a non-recoverable
    /// error). The payload is a UI-facing localized message.
    var onError: ((String) -> Void)?

    // MARK: - Private State

    /// Tracks the starting engine for the current transcribe() call, so we can
    /// populate `fallbackFrom` in the result when fallback occurs.
    private var currentCallStartEngine: String = ""

    // MARK: - Init

    init(cloudOpenAIService: CloudOpenAIService, localWhisperService: LocalWhisperService) {
        self.cloudOpenAIService = cloudOpenAIService
        self.localWhisperService = localWhisperService
    }

    // MARK: - Public

    /// Start transcription, trying engines in priority order starting from
    /// `effectiveStartEngine`.
    ///
    /// - Parameters:
    ///   - samples: Float PCM samples for transcription.
    ///   - audioDuration: Duration in seconds, used for cloud request timeout.
    func transcribe(samples: [Float], audioDuration: TimeInterval) {
        currentCallStartEngine = effectiveStartEngine
        Log.i(LocaleManager.shared.logLocalized("TranscriptionManager: starting from engine") + " '\(effectiveStartEngine)', priority: \(priority)")
        let startIndex = priority.firstIndex(of: effectiveStartEngine) ?? 0
        tryEngine(at: startIndex, samples: samples, audioDuration: audioDuration)
    }

    /// Called when the user manually changes their preferred engine.
    /// Exits fallback mode and updates both preferred and effective engines.
    func userDidChangePreferredEngine(_ engine: String) {
        let lm = LocaleManager.shared
        preferredStartEngine = engine
        effectiveStartEngine = engine
        if isInFallbackMode {
            isInFallbackMode = false
            Log.i(lm.logLocalized("User manually changed API mode, exiting fallback state"))
        }
    }

    /// Called when network recovers. Restores effective engine to preferred
    /// and exits fallback mode.
    func recoverFromFallback() {
        let lm = LocaleManager.shared
        guard isInFallbackMode else { return }
        isInFallbackMode = false
        effectiveStartEngine = preferredStartEngine
        Log.i(lm.logLocalized("Network recovered, switching back to") + " \(effectiveStartEngine) " + lm.logLocalized("mode"))
    }

    // MARK: - Private

    private func tryEngine(
        at index: Int,
        samples: [Float],
        audioDuration: TimeInterval
    ) {
        let lm = LocaleManager.shared

        guard index < priority.count else {
            Log.e(lm.logLocalized("TranscriptionManager: all engines exhausted"))
            onError?(String(localized: "All transcription modes failed"))
            return
        }

        if index > 0 && !EngineeringOptions.enableModeFallback {
            Log.e(lm.logLocalized("TranscriptionManager: failed and fallback disabled"))
            onError?(String(localized: "Transcription failed"))
            return
        }

        let engine = priority[index]
        let tryNext: () -> Void = { [weak self] in
            DispatchQueue.main.async {
                self?.tryEngine(at: index + 1, samples: samples, audioDuration: audioDuration)
            }
        }

        switch engine {
        case "cloud":
            guard !samples.isEmpty else {
                Log.w(lm.logLocalized("No audio samples for cloud transcription, trying next priority"))
                tryNext()
                return
            }
            cloudTranscribe(samples: samples, audioDuration: audioDuration, tryNext: tryNext)

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
            Log.w("TranscriptionManager: unknown engine '\(engine)', skipping")
            tryNext()
        }
    }

    private func cloudTranscribe(
        samples: [Float],
        audioDuration: TimeInterval,
        tryNext: @escaping () -> Void
    ) {
        let lm = LocaleManager.shared
        let action = lm.logLocalized("Cloud speech recognition")
        Log.i(lm.logLocalized("Calling Whisper API (cloud transcription)..."))

        cloudOpenAIService.transcribe(samples: samples, audioDuration: audioDuration) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let text):
                    Log.i(lm.logLocalized("Cloud transcription succeeded"))
                    let fallbackFrom = ("cloud" != self.currentCallStartEngine) ? self.currentCallStartEngine : nil
                    let transcriptionResult = TranscriptionResult(text: text, engine: "cloud", fallbackFrom: fallbackFrom)
                    self.onResult?(transcriptionResult)
                case .failure(let error):
                    if let whisperError = error as? CloudOpenAIService.WhisperError,
                       case .networkError = whisperError {
                        Log.w(lm.logLocalized("Cloud API failed, trying next priority:") + " \(error.localizedDescription)")
                        self.effectiveStartEngine = self.priority.first(where: { $0 != "cloud" }) ?? self.effectiveStartEngine
                        self.isInFallbackMode = true
                        Log.i(lm.logLocalized("Entered fallback mode, original mode:") + " cloud")
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
                    let fallbackFrom = ("local" != self.currentCallStartEngine) ? self.currentCallStartEngine : nil
                    let transcriptionResult = TranscriptionResult(text: text, engine: "local", fallbackFrom: fallbackFrom)
                    self.onResult?(transcriptionResult)
                }
            } catch is CancellationError {
                await MainActor.run {
                    Log.e("\(action) " + lm.logLocalized("timed out") + " (\(String(format: "%.0f", timeout))s)")
                    if EngineeringOptions.enableModeFallback {
                        Log.w(lm.logLocalized("Local transcription failed, trying next priority"))
                        self.effectiveStartEngine = self.priority.first(where: { $0 != "local" }) ?? self.effectiveStartEngine
                        self.isInFallbackMode = true
                        Log.i(lm.logLocalized("Entered fallback mode, original mode:") + " local")
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
                        self.effectiveStartEngine = self.priority.first(where: { $0 != "local" }) ?? self.effectiveStartEngine
                        self.isInFallbackMode = true
                        Log.i(lm.logLocalized("Entered fallback mode, original mode:") + " local")
                        tryNext()
                    } else {
                        self.onError?(String(localized: "\(action) failed: \(error.localizedDescription)"))
                    }
                }
            }
        }
    }
}
