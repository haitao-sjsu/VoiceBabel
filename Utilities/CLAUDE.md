# Utilities/

Helper modules.

| File | Description |
|------|-------------|
| **TextInputter.swift** | Text output to active window. Clipboard mode (default): save → write → simulate Cmd+V → delayed restore. Keyboard mode: CGEvent per-character input (supports CJK). `pressReturnKey()` for auto-send. Requires Accessibility permission |
| **NetworkHealthMonitor.swift** | Network health probe. NWPathMonitor for connectivity, periodic HEAD requests to `api.openai.com/v1/models` (30s interval). Triggers `onCloudRecovered` callback on success. Starts in fallback mode, stops on manual mode switch |
| **LocaleManager.swift** | i18n locale manager. Manages `currentLocale` (SwiftUI `.environment`), `currentBundle` (AppKit `localized()` calls), and `logBundle` (log messages). Supports instant language switching via `setLocale()`. Lists 20 supported UI languages with native display names |
| **Log.swift** | Logging utility. `Log.i/w/e/d()` outputs to both console and file `voicebabel.log`. Log language controlled by `EngineeringOptions.logLanguage` via `LocaleManager.logLocalized()` |
| **TextPostProcessor.swift** | Stateless text post-processing. Tag filtering (remove `[MUSIC]`/`[BLANK_AUDIO]` etc., controlled by `EngineeringOptions.enableTagFiltering`), Chinese script conversion (Traditional/Simplified based on `SettingsStore.whisperLanguage`), whitespace trimming. Used by AppController and TranslationManager |
| **AudioEncoder.swift** | PCM Float32 samples → compressed audio encoding. `encodeToM4A(samples:)` (AAC at `EngineeringOptions.aacBitRate`) and `encodeToWAV(samples:)`. Returns `EncodingResult` with data + `AudioFormat` metadata (filename, contentType). Used by CloudOpenAIService |
