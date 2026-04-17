# Core/

Core application logic — recording state machine, hotkey detection, auto-send, transcription manager, and translation manager.

| File | Description |
|------|-------------|
| **AppController.swift** | Core state machine and flow orchestrator (idle/recording/processing/waitingToSend/error). Manages recording lifecycle, dispatches to TranscriptionManager and TranslationManager, handles two-step translation orchestration (transcribe then translate). currentApiMode and isInFallbackMode are computed from TranscriptionManager |
| **HotkeyManager.swift** | Option key gesture detection via NSEvent monitors. Push-to-talk (hold >400ms), single tap (toggle transcribe), double tap (toggle translate), ESC (cancel). State machine: idle -> optionDown -> pushToTalkActive/waitingSecondTap |
| **AutoSendManager.swift** | Auto-send logic after transcription output. Three modes: off (do nothing), always (Enter after short delay), delayed (countdown timer with cancel support). Communicates state changes back to AppController via onStateChange callback |
| **TranscriptionManager.swift** | Audio-to-text orchestration — iterates configured engines (cloud / local) in priority order, applies network-error fallback on cloud failures, duration-based timeout on local. Owns effectiveStartEngine and isInFallbackMode state |
| **TranslationManager.swift** | Text translation via priority engine queue (Apple Translation or Cloud GPT) with engine fallback on failure. Stateless: only config + callbacks |
| **AudioRecorder.swift** | Audio capture via AVAudioEngine. `startRecording()` / `stopRecording() -> [Float]?`. Silence detection via `static averageRMS(of:)`. No encoding — raw PCM samples only |
