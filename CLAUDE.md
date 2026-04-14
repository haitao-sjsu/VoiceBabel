# CLAUDE.md - WhisperUtil Project Guidelines

## Project Overview

WhisperUtil is a macOS menu bar speech-to-text tool built with Swift. It supports three API modes:

- **Local** (WhisperKit) - offline on-device transcription
- **Cloud** (gpt-4o-transcribe) - HTTP API transcription
- **Realtime** (GA WebSocket) - streaming transcription via WebSocket

All three modes support transcription. Translation (to English) uses the Whisper HTTP API regardless of the selected mode.

## Architecture

```
main.swift -> AppDelegate (Composition Root)
                 |
                 +-- Config/Config <-- Config/UserSettings (user preference defaults)
                 |                 <-- Config/EngineeringOptions (engineering switches/constants)
                 +-- Config/SettingsStore (UserDefaults + ObservableObject)
                 +-- Config/KeychainHelper (API Key secure storage)
                 +-- UI/StatusBarController (menu bar UI)
                 +-- UI/SettingsWindowController -> UI/SettingsView (SwiftUI settings panel)
                 +-- HotkeyManager (Option key gesture detection)
                 +-- RecordingController (state machine / core dispatcher)
                 |       +-- Audio/AudioRecorder -> Audio/AudioEncoder
                 |       +-- Services/ServiceCloudOpenAI (HTTP transcription/translation)
                 |       +-- Services/ServiceRealtimeOpenAI (WebSocket streaming)
                 |       +-- Services/ServiceLocalWhisper (WhisperKit local)
                 |       +-- Services/ServiceTextCleanup (GPT-4o-mini text cleanup)
                 |       +-- Utilities/TextInputter (text output to active window)
                 +-- Utilities/LocaleManager (i18n locale management)
                 +-- Utilities/NetworkHealthMonitor (network recovery probe)
```

Components communicate via closures/callbacks, connected in `AppDelegate.setupComponents()`. Settings changes propagate in real-time via Combine publishers.

## Directory Structure

```
Root/                       — Entry, composition root, core logic, hotkey handling
Config/                     — Configuration (user prefs, engineering options, Keychain, settings store)
UI/                         — Menu bar controller, SwiftUI settings panel, settings window
Services/                   — Transcription backends (Cloud / Realtime / Local / Text cleanup)
Audio/                      — Audio capture and encoding
Utilities/                  — Helpers (text input, network probe, logging, i18n locale manager)
WhisperUtil/                — Resources (Assets, Storyboard, String Catalogs)
.claude-research-tech/      — Technical research documents
.claude-research-commercial/— Commercial research documents
.claude-plan/               — Implementation plans
.claude-code-review/        — Code review documents
.human-learn/               — Learning notes (hand-written code reproductions)
.human-devlog/              — Development log (daily work journal)
```

## Background Mode

All tasks should run in the background by default. Only report to the user in these cases:

1. Encountered an error that cannot be resolved independently
2. Need to request permissions
3. Task is complete

## Default Workflow

### Code Change -> Build -> Launch (Standard Flow)

After every code change, use the project Makefile:

```bash
make dev    # Build Debug + quit old process + launch new version
```

Other useful targets:

```bash
make build    # Build Debug only
make release  # Build Release
make run      # Quit old process + launch (without rebuilding)
make clean    # Clean build artifacts
make check    # Verify prerequisites
make help     # Show all targets
```

If build fails, debug and fix it yourself.

**Important: Do NOT use `CONFIGURATION_BUILD_DIR=$(pwd)`** -- it generates intermediate files in the project directory.
**Important: Always use `make` targets instead of raw `xcodebuild` commands.**

## Internationalization (i18n)

- UI strings are localized via String Catalogs (`WhisperUtil/Localizable.xcstrings`), supporting 20 languages
- Log strings use a separate catalog (`WhisperUtil/LogStrings.xcstrings`), supporting en + zh only
- `Utilities/LocaleManager.swift` manages runtime locale switching (instant, no restart)
- AppKit code uses `LocaleManager.shared.localized("key")`, SwiftUI uses `Text("key")` with `.environment(\.locale)`
- Log messages use `LocaleManager.shared.logLocalized("key")`
- Log language is controlled by `EngineeringOptions.logLanguage` ("en" or "zh")
