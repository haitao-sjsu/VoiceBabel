# UI/

User interface layer.

| File | Description |
|------|-------------|
| **StatusBarController.swift** | Menu bar UI. Manages NSStatusItem icon and dropdown menu: transcribe/translate buttons, last transcription copy, settings entry, about, quit. Dynamically updates icon and menu items based on app state. Defines `ApiMode` and `AutoSendMode` enums. Subscribes to LocaleManager for locale-aware menu refresh |
| **SettingsView.swift** | SwiftUI settings panel. 5 sections: API Key, Language, Transcription, Translation, General. Binds to SettingsStore via @ObservedObject. Includes Interface Language picker (20 languages + Follow System) and expanded recognition language list. Uses `.environment(\.locale)` for instant language switching |
| **SettingsWindowController.swift** | NSWindow wrapper. Embeds SwiftUI SettingsView in NSHostingController. Provides Edit menu (Cmd+V paste support for LSUIElement apps). Triggered by StatusBarController "Settings..." menu item |
