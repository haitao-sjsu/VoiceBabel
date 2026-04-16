# Core/

Core application logic — recording state machine, hotkey detection, auto-send, and translation pipeline.

| File | Description |
|------|-------------|
| **RecordingController.swift** | Core dispatcher — recording state machine (idle/recording/processing/waitingToSend/error), API mode routing (local/cloud), transcription fallback chain, text cleanup pipeline, audio validation. Delegates auto-send to AutoSendManager, translation to TranslationPipeline |
| **HotkeyManager.swift** | Option key gesture detection via NSEvent monitors. Push-to-talk (hold >400ms), single tap (toggle transcribe), double tap (toggle translate), ESC (cancel). State machine: idle -> optionDown -> pushToTalkActive/waitingSecondTap |
| **AutoSendManager.swift** | Auto-send logic after transcription output. Three modes: off (do nothing), always (Enter after short delay), delayed (countdown timer with cancel support). Communicates state changes back to RecordingController via onStateChange callback |
| **TranslationPipeline.swift** | Two-step translation flow: transcribe audio (cloud or local), then translate text via priority engine queue (Apple Translation or Cloud GPT). Engine fallback on failure. Uses TextPostProcessor for output post-processing |
