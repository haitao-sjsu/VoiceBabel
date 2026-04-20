# UI/

User interface layer.

| File | Description |
|------|-------------|
| **StatusBarController.swift** | Menu bar UI. Manages NSStatusItem icon (modulated only by app state — idle/recording/processing/error, no mode variation) and dropdown menu: transcribe/translate buttons, copy & paste last transcription/translation, **"Last transcription: <glyph> <engine>" / "Last translation: <glyph> <engine>" informational items** (populated via `setLastTranscriptionEngine` / `setLastTranslationEngine` after each successful run), settings entry, about, quit. Defines `AutoSendMode` enum. Subscribes to LocaleManager for locale-aware menu refresh |
| **SettingsView.swift** | SwiftUI settings panel. 5 sections: API Key, Language, Transcription, Translation, General. Binds to SettingsStore via @ObservedObject. Transcription/Translation sections render each engine as a row with **Toggle (subjective enable), icon, name/description or unavailability reason, and one of three badges (Primary/Disabled/Unavailable)**. Primary badge tracks the first enabled+available engine, not always row 0. Section footer turns red when the effective list is empty. Injected with `EngineAvailabilityProbe` by SettingsWindowController for live availability rendering. Uses `.environment(\.locale)` for instant language switching |
| **SettingsWindowController.swift** | NSWindow wrapper. Embeds SwiftUI SettingsView in NSHostingController; forwards `SettingsStore` and `EngineAvailabilityProbe` into the view. Provides Edit menu (Cmd+V paste support for LSUIElement apps). Triggered by StatusBarController "Settings..." menu item |
