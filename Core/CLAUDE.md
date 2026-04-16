# Core/

Core application logic — recording state machine, hotkey detection, auto-send, transcription pipeline, and translation pipeline.

| File | Description |
|------|-------------|
| **RecordingController.swift** | Core dispatcher — recording state machine (idle/recording/processing/waitingToSend/error), audio lifecycle, audio validation, and fallback-state ownership (isInFallbackMode / currentApiMode). Delegates transcription to TranscriptionPipeline, translation to TranslationPipeline, auto-send to AutoSendManager |
| **HotkeyManager.swift** | Option key gesture detection via NSEvent monitors. Push-to-talk (hold >400ms), single tap (toggle transcribe), double tap (toggle translate), ESC (cancel). State machine: idle -> optionDown -> pushToTalkActive/waitingSecondTap |
| **AutoSendManager.swift** | Auto-send logic after transcription output. Three modes: off (do nothing), always (Enter after short delay), delayed (countdown timer with cancel support). Communicates state changes back to RecordingController via onStateChange callback |
| **TranscriptionPipeline.swift** | Audio-to-text orchestration — iterates configured engines (cloud / local) in priority order, applies network-error fallback on cloud failures, duration-based timeout on local. Stateless: only config + callbacks. Shared by RecordingController (transcription mode) and TranslationPipeline (Step 1) |
| **TranslationPipeline.swift** | Two-step translation flow: Step 1 delegates to TranscriptionPipeline; Step 2 translates the resulting text via priority engine queue (Apple Translation or Cloud GPT) with engine fallback on failure. Uses TextPostProcessor for output post-processing |
